'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { createBilibiliStreaming, allowedMediaURL } = require('../Resources/NodePatches/bilibili-streaming.js');

async function listen(handler) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { server, url: `http://127.0.0.1:${server.address().port}` };
}
function request(url, options) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { headers: options.headers, signal: options.signal }, res =>
      resolve({ status: res.statusCode, headers: res.headers, data: res }));
    req.on('error', reject);
  });
}
async function fixture(t, handler, options = {}) {
  const upstream = await listen(handler);
  const streaming = createBilibiliStreaming({ request, allowURL: url => url.startsWith(upstream.url),
    headerTimeout: 200, readTimeout: 100, ...options });
  const proxy = await listen((req, res) => {
    const reply = { raw: res, hijack() {}, code(code) { res.statusCode = code; return this; }, send(text) { res.end(text); return this; } };
    streaming.serve(req.url.slice(1), { Referer: 'https://www.bilibili.com' },
      { raw: req, headers: req.headers }, reply).catch(error => res.destroy(error));
  });
  t.after(() => { upstream.server.closeAllConnections(); upstream.server.close(); proxy.server.closeAllConnections(); proxy.server.close(); });
  return { ...streaming, upstream: upstream.url, proxy: proxy.url };
}
function mediaResponse(req, res, data, override = {}) {
  const [, startText, endText] = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range);
  const start = +startText, end = endText ? Math.min(+endText, data.length - 1) : data.length - 1;
  res.writeHead(206, { 'Content-Type': 'video/mp4', 'Content-Range': `bytes ${start}-${end}/${data.length}`,
    'Content-Length': end - start + 1, ETag: '"same-representation"', ...override });
  return data.subarray(start, end + 1);
}
function fetchBytes(url, headers = {}, pause = 0) {
  return new Promise((resolve, reject) => {
    http.get(url, { headers }, res => {
      const chunks = [];
      res.on('data', data => chunks.push(data));
      res.on('error', reject);
      res.on('end', () => resolve({ data: Buffer.concat(chunks), status: res.statusCode, headers: res.headers }));
      if (pause) { res.pause(); setTimeout(() => res.resume(), pause); }
    }).on('error', reject);
  });
}

test('short upstream response resumes at exactly the delivered byte offset', async t => {
  const data = Buffer.alloc(512 * 1024); for (let i = 0; i < data.length; i++) data[i] = i % 251;
  const ranges = [];
  const f = await fixture(t, (req, res) => {
    ranges.push(req.headers.range);
    const bytes = mediaResponse(req, res, data);
    if (ranges.length === 1) { res.write(bytes.subarray(0, 65536)); setTimeout(() => res.destroy(), 15); }
    else res.end(bytes);
  });
  const id = f.register({ urls: [f.upstream + '/media'] });
  const result = await fetchBytes(f.proxy + '/' + id, { Range: 'bytes=2000-200000' });
  assert.equal(result.status, 206);
  assert.deepEqual(result.data, data.subarray(2000, 200001));
  assert.deepEqual(ranges, ['bytes=2000-200000', 'bytes=67536-200000']);
});

test('consumer cache backpressure longer than read deadline does not abort media', async t => {
  const data = Buffer.alloc(16 * 1024 * 1024, 71);
  let requests = 0;
  const f = await fixture(t, (req, res) => { requests++; res.end(mediaResponse(req, res, data)); }, { readTimeout: 80 });
  const id = f.register({ urls: [f.upstream + '/media'] });
  const result = await fetchBytes(f.proxy + '/' + id, {}, 450);
  assert.deepEqual(result.data, data);
  assert.equal(result.status, 200);
  assert.equal(requests, 1);
});

test('expired signed URL refreshes the same representation once', async t => {
  const data = Buffer.alloc(4096, 23); let refreshes = 0;
  const f = await fixture(t, (req, res) => {
    if (req.url === '/expired') { res.writeHead(403); res.end(); }
    else res.end(mediaResponse(req, res, data));
  });
  const id = f.register({ urls: [f.upstream + '/expired'], refresh: async () => { refreshes++; return [f.upstream + '/fresh']; } });
  const result = await fetchBytes(f.proxy + '/' + id);
  assert.deepEqual(result.data, data);
  assert.equal(refreshes, 1);
});

test('permanent truncation stops after the bounded retry budget', async t => {
  let requests = 0; const data = Buffer.alloc(65536, 8);
  const f = await fixture(t, (req, res) => {
    requests++; const bytes = mediaResponse(req, res, data);
    res.write(bytes.subarray(0, 64)); setTimeout(() => res.destroy(), 10);
  });
  const id = f.register({ urls: [f.upstream + '/media'] });
  await assert.rejects(fetchBytes(f.proxy + '/' + id));
  assert.equal(requests, 4);
});

test('different entity or wrong Range is never concatenated into the media', async t => {
  let requests = 0; const data = Buffer.alloc(65536, 12);
  const f = await fixture(t, (req, res) => {
    requests++;
    const bytes = mediaResponse(req, res, data, requests > 1 ? { ETag: '"different-entity"' } : {});
    if (requests === 1) { res.write(bytes.subarray(0, 1024)); setTimeout(() => res.destroy(), 10); }
    else res.end(bytes);
  });
  const id = f.register({ urls: [f.upstream + '/media'] });
  await assert.rejects(fetchBytes(f.proxy + '/' + id));
  assert.equal(requests, 2);
});

test('cancelling a seek closes upstream and cannot start recovery', async t => {
  let requests = 0; let closed = false;
  const f = await fixture(t, (req, res) => {
    requests++;
    mediaResponse(req, res, Buffer.alloc(1024 * 1024)); res.write(Buffer.alloc(1024));
    res.on('close', () => { closed = true; });
  });
  const id = f.register({ urls: [f.upstream + '/media'] });
  await new Promise((resolve, reject) => {
    http.get(f.proxy + '/' + id, res => { res.once('data', () => { res.destroy(); resolve(); }); res.on('error', () => {}); }).on('error', reject);
  });
  await new Promise(resolve => setTimeout(resolve, 220));
  assert.equal(requests, 1); assert.equal(closed, true);
});

test('unavailable session and malformed range fail without upstream traffic', async t => {
  let requests = 0;
  const f = await fixture(t, (req, res) => { requests++; res.end(); });
  const id = f.register({ urls: [f.upstream + '/media'] });
  assert.equal((await fetchBytes(f.proxy + '/' + id, { Range: 'bytes=10-2' })).status, 416);
  assert.equal((await fetchBytes(f.proxy + '/okb1_missing')).status, 410);
  assert.equal(requests, 0);
});

test('only Bilibili CDN HTTPS URLs are eligible for the legacy path', () => {
  assert.equal(allowedMediaURL('https://upos-sz-mirror.bilivideo.com/file.m4s'), true);
  for (const url of ['http://127.0.0.1/private', 'https://example.com/file', 'https://bilivideo.com.evil.test/file', 'file:///tmp/x'])
    assert.equal(allowedMediaURL(url), false);
});
