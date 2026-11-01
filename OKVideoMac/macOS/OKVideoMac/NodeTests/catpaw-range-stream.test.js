'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter, once } = require('node:events');
const { createCatPawRangeStream } = require('../Resources/NodePatches/catpaw-range-stream.js');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) {
  for (let i = 0; i < 200; i++) { if (predicate()) return; await delay(5); }
  assert.fail('condition was not reached within one second');
}
async function fixture(t, mode = 'normal') {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'catpaw-range-test-'));
  const data = Buffer.from(Array.from({ length: 262144 }, (_, i) => i % 251));
  const stats = { active: 0, maximum: 0, cancelled: 0, completed: 0, calls: 0, headers: [] };
  const sockets = new Set();
  const server = http.createServer((req, res) => {
    const match = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range || '');
    assert.ok(match);
    const low = +match[1], high = Math.min(+match[2], data.length - 1);
    const probe = low === 0 && high === 0;
    stats.headers.push(req.headers);
    if (!probe) { stats.active++; stats.calls++; stats.maximum = Math.max(stats.maximum, stats.active); }
    res.on('close', () => {
      if (!probe) { stats.active--; if (!res.writableFinished) stats.cancelled++; else stats.completed++; }
    });
    if ((mode === 'headers-stall' && !probe) || mode === 'probe-stall') return;
    if (mode === 'unsupported') { res.writeHead(200, { 'content-length': data.length }); res.end(data); return; }
    if (mode === 'forbidden' && !probe) { res.writeHead(403); res.end(); return; }
    if (mode === 'retry' && !probe && stats.calls <= 2) { res.writeHead(503); res.end(); return; }
    res.writeHead(206, { 'content-type': 'video/mp4', 'accept-ranges': 'bytes',
      'content-range': `bytes ${low + (mode === 'bad-range' && !probe ? 1 : 0)}-${high}/${data.length}`,
      'content-length': high - low + 1 });
    if (mode === 'body-stall' && !probe) { res.write(data.subarray(low, low + 1)); return; }
    res.end(data.subarray(low, high + 1));
  });
  server.on('connection', s => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    for (const s of sockets) s.destroy();
    await new Promise(resolve => server.close(resolve));
    await fs.rm(root, { recursive: true, force: true });
  });
  const client = { get(url, opts) {
    return new Promise((resolve, reject) => {
      const req = http.get(url, { headers: opts.headers, signal: opts.signal }, res => {
        if (res.statusCode >= 400) { res.resume(); reject(Object.assign(new Error('HTTP error'), { response: { status: res.statusCode } })); }
        else resolve({ status: res.statusCode, headers: res.headers, data: res });
      });
      req.on('error', reject);
    });
  } };
  const handler = createCatPawRangeStream({ client, cacheRoot: root });
  async function open(range, options = {}, method = 'GET') {
    const raw = new EventEmitter();
    const request = { id: 'same-id', raw: new EventEmitter(), method, headers: range ? { range } : {} };
    const reply = { raw, code(value) { this.status = value; return this; }, headers(value) { this.fields = value; return this; }, redirect(value) { this.location = value; } };
    const promise = handler(request, reply, `http://127.0.0.1:${server.address().port}/movie`, 'file',
      { 'User-Agent': 'fixture-player', Referer: 'https://fixture.invalid', Cookie: 'fixture-only' },
      { chunkSize: 32768, poolSize: 3, timeout: 1000, ...options });
    return { request, reply, promise };
  }
  return { open, data, root, stats };
}
async function collect(body) {
  const pieces = [];
  try { for await (const piece of body) pieces.push(piece); }
  finally { await body.cleanup(); }
  return Buffer.concat(pieces);
}
for (const [name, range, from, to, skip] of [
  ['whole file', undefined, 0, 262144, 0], ['closed range', 'bytes=441-65549', 441, 65550, 0],
  ['open range', 'bytes=131071-', 131071, 262144, 0], ['suffix', 'bytes=-1051', 261093, 262144, 0],
  ['masked source', 'bytes=0-53219', 123, 53343, 123], ['near EOF', 'bytes=262130-999999', 262130, 262144, 0]
]) test(name + ' preserves ordered bytes and headers', async t => {
  const f = await fixture(t); const reader = await f.open(range, { skipBytes: skip });
  assert.deepEqual(await collect(await reader.promise), f.data.subarray(from, to));
  assert.equal(reader.reply.status, range ? 206 : 200);
  assert.equal(+reader.reply.fields['content-length'], to - from);
  assert.ok(f.stats.maximum <= 3);
  assert.ok(f.stats.headers.every(h => h.cookie === 'fixture-only' && h['user-agent'] === 'fixture-player' && h.referer === 'https://fixture.invalid'));
  assert.deepEqual(await fs.readdir(f.root), []);
});
for (const mode of ['headers-stall', 'body-stall']) test('disconnect cancels all in-flight requests during ' + mode, async t => {
  const f = await fixture(t, mode); const reader = await f.open(); const body = await reader.promise;
  await until(() => f.stats.active === 3);
  const closed = once(body, 'close'); reader.reply.raw.emit('close'); await closed; await body.cleanup();
  await until(() => f.stats.active === 0);
  assert.equal(f.stats.cancelled, 3); assert.equal(f.stats.calls, 3);
  assert.deepEqual(await fs.readdir(f.root), []);
});
test('disconnect while metadata headers are pending never redirects or starts chunks', async t => {
  const f = await fixture(t, 'probe-stall'); const reader = await f.open();
  await until(() => f.stats.headers.length === 1); reader.reply.raw.emit('close');
  assert.equal(await reader.promise, undefined); assert.equal(f.stats.calls, 0);
  assert.equal(reader.reply.location, undefined);
});
test('closing an unconsumed reader preserves another reader of the same file', async t => {
  const f = await fixture(t); const a = await f.open(), b = await f.open('bytes=521-');
  const first = await a.promise, second = await b.promise;
  const closed = once(first, 'close'); first.destroy(); await closed; await first.cleanup();
  assert.deepEqual(await collect(second), f.data.subarray(521));
  assert.deepEqual(await fs.readdir(f.root), []);
});
test('rapid replacement readers leave no downloads or temporary directories', async t => {
  const f = await fixture(t, 'headers-stall');
  for (let i = 0; i < 10; i++) {
    const reader = await f.open(`bytes=${i * 1307}-`); const body = await reader.promise;
    await until(() => f.stats.active > 0);
    const closed = once(body, 'close'); body.destroy(); await closed; await body.cleanup();
    await until(() => f.stats.active === 0);
  }
  assert.deepEqual(await fs.readdir(f.root), []);
});
test('silent body has a bounded deadline and finite retries', async t => {
  const f = await fixture(t, 'body-stall'); const reader = await f.open(undefined, { poolSize: 1, timeout: 40 });
  await assert.rejects(collect(await reader.promise));
  await until(() => f.stats.active === 0);
  assert.equal(f.stats.calls, 3); assert.deepEqual(await fs.readdir(f.root), []);
});
for (const mode of ['bad-range', 'forbidden']) test(mode + ' fails without retries or leftover files', async t => {
  const f = await fixture(t, mode); const reader = await f.open(undefined, { poolSize: 1 });
  await assert.rejects(collect(await reader.promise)); assert.equal(f.stats.calls, 1);
  assert.deepEqual(await fs.readdir(f.root), []);
});
test('transient failures retry within the same reader and preserve content', async t => {
  const f = await fixture(t, 'retry'); const reader = await f.open(undefined, { poolSize: 1 });
  assert.deepEqual(await collect(await reader.promise), f.data);
  assert.equal(f.stats.calls, 10);
});
test('HEAD and unsatisfiable ranges start no chunk workers', async t => {
  const f = await fixture(t);
  for (const range of ['bytes=262144-', 'bytes=1-0', 'bytes=-0', 'bytes=0-1,3-4']) {
    const reader = await f.open(range); await reader.promise; assert.equal(reader.reply.status, 416);
  }
  const reader = await f.open('bytes=5-15', {}, 'HEAD'); await reader.promise;
  assert.equal(reader.reply.status, 206); assert.equal(reader.reply.fields['content-length'], '11');
  assert.equal(f.stats.calls, 0);
});
test('unsupported Range preserves provider redirect behavior', async t => {
  const f = await fixture(t, 'unsupported'); const reader = await f.open();
  assert.equal(await reader.promise, undefined); assert.ok(reader.reply.location.endsWith('/movie'));
  assert.equal(f.stats.calls, 0);
});
