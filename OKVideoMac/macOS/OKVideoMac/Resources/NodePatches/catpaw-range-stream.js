'use strict';
// Adapter for the SHA-pinned CatPaw bundle's shared Quark/UC/Ali download
// helper. Authentication and redirects remain owned by the source. No global
// sockets, source tasks, other readers or runtime leases are cancelled here.
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { Readable, Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { setMaxListeners } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');

function createCatPawRangeStream({ client, cacheRoot }) {
  const metadata = new Map();
  const cancelled = () => Object.assign(new Error('Media reader closed'), { code: 'ERR_CANCELED' });
  return async function rangeStream(request, reply, url, fid, headers = {}, options = {}) {
    const lifetime = new AbortController();
    const signal = lifetime.signal;
    // One bounded listener per active worker; do not change process defaults.
    setMaxListeners(0, signal);
    const wakeups = new Set();
    const notify = () => { for (const wake of wakeups) wake(); wakeups.clear(); };
    const wait = () => new Promise(resolve => wakeups.add(resolve));
    let output, directory, workers = [], fatal;
    const abort = () => {
      if (!signal.aborted) lifetime.abort(cancelled());
      notify();
    };
    const responseClosed = () => { if (!reply.raw?.writableFinished) { abort(); output?.destroy(); } };
    const requestAborted = () => { abort(); output?.destroy(); };
    request.raw?.once('aborted', requestAborted);
    reply.raw?.once('close', responseClosed);
    const check = () => { if (signal.aborted) throw signal.reason; };
    const detach = () => {
      request.raw?.removeListener('aborted', requestAborted);
      reply.raw?.removeListener('close', responseClosed);
    };
    // A deadline covers both response headers and the complete body, including
    // a silent upstream. Cancellation is observed even before headers arrive.
    async function upstream(range, consume) {
      check();
      const controller = new AbortController();
      const cancel = () => controller.abort(signal.reason);
      signal.addEventListener('abort', cancel, { once: true });
      const timeout = Math.max(1, Math.min(Number(options.timeout) || 10000, 60000));
      const timer = setTimeout(() => controller.abort(new Error('Media range timeout')), timeout);
      timer.unref?.();
      let response;
      try {
        response = await client.get(url, {
          responseType: 'stream', timeout, decompress: false,
          headers: { ...headers, 'Accept-Encoding': 'identity', Range: range },
          signal: controller.signal
        });
        // A non-cooperative adapter may resolve after cancellation.
        if (controller.signal.aborted) throw controller.signal.reason;
        return await consume(response, controller.signal);
      } catch (error) {
        // Axios rejects non-2xx responses with a still-readable body.
        error.response?.data?.destroy?.();
        throw error;
      } finally {
        response?.data?.destroy();
        clearTimeout(timer);
        signal.removeEventListener('abort', cancel);
      }
    }
    async function clean() {
      abort();
      detach();
      await Promise.allSettled(workers);
      if (directory) await fs.promises.rm(directory, { recursive: true, force: true });
    }
    try {
      if (request.raw?.aborted || reply.raw?.destroyed) abort();
      check();
      const key = createHash('sha256').update(JSON.stringify([url, fid, headers])).digest('hex');
      let info = metadata.get(key);
      if (!info || info.expires <= Date.now()) {
        info = await upstream('bytes=0-0', async response => {
          const match = /^bytes 0-0\/(\d+)$/i.exec(String(response.headers['content-range'] || ''));
          const size = match ? Number(match[1]) : NaN;
          if (response.status !== 206 || !Number.isSafeInteger(size) || size <= 0) return null;
          const result = { size, headers: {}, expires: Date.now() + 300000 };
          for (const name of ['content-type', 'content-disposition', 'etag', 'last-modified']) {
            if (response.headers[name]) result.headers[name] = response.headers[name];
          }
          return result;
        });
        check();
        if (!info) { reply.redirect(url); await clean(); return; }
        metadata.delete(key); metadata.set(key, info);
        while (metadata.size > 64) metadata.delete(metadata.keys().next().value);
      }
      const skip = Math.min(Math.max(0, Math.trunc(Number(options.skipBytes) || 0)), info.size - 1);
      const size = info.size - skip;
      let first = 0, last = size - 1;
      const range = request.headers?.range;
      if (range) {
        const match = /^bytes=(\d*)-(\d*)$/i.exec(String(range).trim());
        if (!match || (!match[1] && !match[2])) first = size;
        else if (!match[1]) {
          const suffix = Number(match[2]);
          first = Number.isSafeInteger(suffix) && suffix > 0 ? Math.max(0, size - suffix) : size;
        } else {
          first = Number(match[1]);
          if (match[2]) last = Math.min(last, Number(match[2]));
        }
        if (!Number.isSafeInteger(first) || !Number.isSafeInteger(last) || first > last || first >= size) {
          reply.code(416).headers({ 'content-range': `bytes */${size}` });
          await clean(); return;
        }
      }
      const responseHeaders = { ...info.headers, 'accept-ranges': 'bytes', 'content-length': String(last - first + 1) };
      if (range) responseHeaders['content-range'] = `bytes ${first}-${last}/${size}`;
      reply.code(range ? 206 : 200).headers(responseHeaders);
      if (request.method === 'HEAD') { await clean(); return; }
      // Same defaults and 100 MiB forward disk budget as the pinned helper.
      const chunkSize = Math.max(1024, Math.min(Math.trunc(Number(options.chunkSize) || 524288), 10485760));
      const ahead = Math.max(1, Math.floor(100 * 1024 * 1024 / chunkSize));
      const poolSize = Math.max(1, Math.min(Math.trunc(Number(options.poolSize) || 10), 64, ahead));
      const begin = Math.floor((first + skip) / chunkSize);
      const end = Math.floor((last + skip) / chunkSize);
      let next = begin, consumed = begin;
      const ready = new Map();
      await fs.promises.mkdir(cacheRoot, { recursive: true });
      directory = await fs.promises.mkdtemp(path.join(cacheRoot, 'okvideo-reader-'));
      check();
      async function download(index) {
        const file = path.join(directory, String(index));
        const low = index * chunkSize, high = Math.min(info.size - 1, low + chunkSize - 1);
        for (let attempt = 0; ; attempt++) {
          check();
          try {
            await upstream(`bytes=${low}-${high}`, async (response, attemptSignal) => {
              const cr = /^bytes (\d+)-(\d+)\/(\d+)$/i.exec(String(response.headers['content-range'] || ''));
              if (response.status !== 206 || !cr || Number(cr[1]) !== low || Number(cr[2]) !== high || Number(cr[3]) !== info.size) {
                throw Object.assign(new Error('Media range response mismatch'), { noRetry: true });
              }
              let count = 0;
              const limit = new Transform({ transform(data, _encoding, done) {
                count += data.length;
                done(count > high - low + 1 ? new Error('Media range exceeds declared size') : null, data);
              } });
              await pipeline(response.data, limit, fs.createWriteStream(file), { signal: attemptSignal });
              if (count !== high - low + 1) throw new Error('Incomplete media range');
            });
            check();
            return file;
          } catch (error) {
            await fs.promises.rm(file, { force: true });
            check();
            const status = error.response?.status;
            if (error.noRetry || [401, 403, 404, 416].includes(status) || attempt >= 2) throw error;
            await delay(50 * (attempt + 1), undefined, { signal });
          }
        }
      }
      async function worker() {
        try {
          while (!signal.aborted && next <= end) {
            if (next - consumed >= ahead) { await wait(); continue; }
            const index = next++;
            const file = await download(index);
            ready.set(index, file); notify();
          }
        } catch (error) {
          if (!signal.aborted) { fatal = error; abort(); output?.destroy(error); }
        }
      }
      output = Readable.from((async function* () {
        try {
          while (consumed <= end) {
            if (fatal) throw fatal;
            check();
            const file = ready.get(consumed);
            if (!file) { await wait(); continue; }
            const data = await fs.promises.readFile(file);
            check();
            const low = consumed * chunkSize;
            const from = Math.max(first + skip, low) - low;
            const to = Math.min(last + skip + 1, low + data.length) - low;
            await fs.promises.rm(file, { force: true });
            ready.delete(consumed++); notify();
            yield data.subarray(from, to);
          }
        } finally { abort(); }
      })(), { objectMode: false, highWaterMark: 65536 });
      // Fastify attaches its error handler after this function returns.
      output.on('error', () => {});
      let cleanup;
      output.once('close', () => { cleanup = clean().catch(() => {}); });
      output.cleanup = () => cleanup || Promise.resolve();
      workers = Array.from({ length: Math.min(poolSize, end - begin + 1) }, worker);
      return output;
    } catch (error) {
      const wasAborted = signal.aborted;
      await clean();
      if (!wasAborted) throw error;
      return;
    }
  };
}
module.exports = { createCatPawRangeStream };
