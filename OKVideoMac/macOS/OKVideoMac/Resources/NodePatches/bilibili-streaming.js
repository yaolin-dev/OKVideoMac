'use strict';

// Bounded streaming transport for the application's verified Bilibili adapter.
// A consumer blocked on its own cache must never spend a network read deadline.
const { randomBytes } = require('node:crypto');

function failure(code) {
  return Object.assign(new Error(code), { code });
}

function allowedMediaURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password &&
      ['bilivideo.com', 'bilivideo.cn', 'akamaized.net'].some(domain =>
        url.hostname === domain || url.hostname.endsWith('.' + domain));
  } catch { return false; }
}

function parseRange(value) {
  if (value == null) return { start: 0, end: null, requested: false };
  const match = /^bytes=(\d+)-(\d*)$/.exec(String(value));
  if (!match) throw failure('invalid_range');
  const start = Number(match[1]);
  const end = match[2] ? Number(match[2]) : null;
  if (!Number.isSafeInteger(start) || start < 0 ||
      (end != null && (!Number.isSafeInteger(end) || end < start))) throw failure('invalid_range');
  return { start, end, requested: true };
}

function validateResponse(response, offset, requestedEnd, identity) {
  if (response.status !== 206) throw failure('upstream_status_' + response.status);
  const h = response.headers;
  const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(String(h['content-range'] || ''));
  if (!range) throw failure('invalid_content_range');
  const [start, end, total] = range.slice(1).map(Number);
  if (![start, end, total].every(Number.isSafeInteger) || start !== offset || end < start ||
      end >= total || end !== Math.min(requestedEnd ?? total - 1, total - 1) ||
      Number(h['content-length']) !== end - start + 1) throw failure('range_mismatch');
  const etag = h.etag && !String(h.etag).startsWith('W/') ? String(h.etag) : null;
  // Total bytes must remain stable; ETags, when provided by both mirrors,
  // must describe the same entity. Never join different representations.
  if (identity && (identity.total !== total || (identity.etag && etag && identity.etag !== etag))) {
    throw failure('entity_changed');
  }
  return { total, end, etag: identity?.etag || etag, type: h['content-type'] || 'application/octet-stream' };
}

function waitFor(operation, signal, milliseconds, code) {
  return new Promise((resolve, reject) => {
    let timer;
    const cleanup = () => { clearTimeout(timer); signal.removeEventListener('abort', aborted); };
    const finish = (callback, value) => { cleanup(); callback(value); };
    const aborted = () => finish(reject, failure('consumer_cancelled'));
    if (signal.aborted) return aborted();
    signal.addEventListener('abort', aborted, { once: true });
    if (milliseconds) timer = setTimeout(() => finish(reject, failure(code)), milliseconds);
    Promise.resolve(operation).then(value => finish(resolve, value), error => finish(reject, error));
  });
}

async function drain(response, signal) {
  if (!response.writableNeedDrain) return;
  let handler;
  try {
    await waitFor(new Promise(resolve => { handler = resolve; response.once('drain', handler); }), signal, 0);
  } finally { if (handler) response.removeListener('drain', handler); }
}

function createBilibiliStreaming({ request, allowURL = allowedMediaURL,
  headerTimeout = 15000, readTimeout = 20000, maximumRetries = 3 } = {}) {
  const resources = new Map();
  const candidates = values => [...new Set(values)].filter(allowURL);
  function register({ urls, refresh }) {
    const item = { urls: candidates(urls), refresh };
    if (!item.urls.length) throw failure('no_supported_media_url');
    const id = 'okb1_' + randomBytes(18).toString('hex');
    resources.set(id, item);
    while (resources.size > 512) resources.delete(resources.keys().next().value);
    return id;
  }

  async function serve(token, headers, incoming, reply) {
    if (typeof token !== 'string' || !token) return reply.code(400).send('Missing media session');
    let range;
    try { range = parseRange(incoming.headers?.range); }
    catch { return reply.code(416).send('Invalid byte range'); }
    let item = resources.get(token);
    if (!item && !token.startsWith('okb1_')) {
      const url = Buffer.from(token, 'base64url').toString('utf8');
      if (allowURL(url)) item = { urls: [url] };
    }
    if (!item) return reply.code(410).send('Media session expired');
    const response = reply.raw;
    const consumer = new AbortController();
    const cancel = () => consumer.abort();
    response.once('close', cancel);
    incoming.raw?.once('aborted', cancel);
    let current, identity, offset = range.start, attempt = 0, refreshed = false;
    let urls = item.urls, candidate = 0;
    try {
      while (!consumer.signal.aborted) {
        const controller = new AbortController();
        const cancelRequest = () => controller.abort();
        consumer.signal.addEventListener('abort', cancelRequest, { once: true });
        try {
          const responsePromise = request(urls[candidate % urls.length], {
            headers: { ...headers, Range: `bytes=${offset}-${range.end ?? ''}`, 'Accept-Encoding': 'identity' },
            responseType: 'stream', timeout: 0, signal: controller.signal,
            maxRedirects: 0, validateStatus: () => true
          });
          current = await waitFor(responsePromise, consumer.signal, headerTimeout, 'header_timeout');
          const received = validateResponse(current, offset, range.end, identity);
          if (!identity) {
            identity = received;
            reply.hijack();
            response.statusCode = range.requested ? 206 : 200;
            response.setHeader('Content-Type', identity.type);
            response.setHeader('Accept-Ranges', 'bytes');
            response.setHeader('Content-Length', identity.end - range.start + 1);
            if (range.requested) response.setHeader('Content-Range', `bytes ${range.start}-${identity.end}/${identity.total}`);
          }
          const iterator = current.data[Symbol.asyncIterator]();
          while (offset <= identity.end) {
            // The timer exists only while actively waiting for upstream data.
            // It is not running while the player has paused/backpressured us.
            const chunk = await waitFor(iterator.next(), consumer.signal, readTimeout, 'read_timeout');
            if (chunk.done) throw failure('short_read');
            if (chunk.value.length > identity.end - offset + 1) throw failure('body_overflow');
            if (!response.write(chunk.value)) await drain(response, consumer.signal);
            offset += chunk.value.length;
          }
          current.data.destroy();
          response.end();
          return reply;
        } catch (error) {
          current?.data?.destroy();
          controller.abort();
          if (consumer.signal.aborted) return reply;
          if (['entity_changed', 'body_overflow', 'range_mismatch', 'invalid_content_range'].includes(error.code)) throw error;
          if (attempt++ >= maximumRetries) throw failure('retries_exhausted');
          incoming.log?.info({ event: 'bilibili_stream_retry', attempt, offset,
            reason: /^upstream_status_\d+$/.test(error.code || '') ? error.code : 'transport_interrupted' });
          candidate++;
          if (!refreshed && item.refresh &&
              (/^upstream_status_(401|403|410)$/.test(error.code || '') || candidate >= urls.length)) {
            refreshed = true;
            const fresh = await waitFor(item.refresh(), consumer.signal, headerTimeout, 'refresh_timeout');
            urls = candidates(fresh);
            if (!urls.length) throw failure('representation_unavailable');
            item.urls = urls;
            candidate = 0;
          }
          await waitFor(new Promise(resolve => setTimeout(resolve, 150 * attempt)), consumer.signal, 0);
        } finally {
          consumer.signal.removeEventListener('abort', cancelRequest);
        }
      }
    } catch (error) {
      incoming.log?.warn({ event: 'bilibili_stream_failed', reason: error.code || 'transport_failure', offset });
      if (!response.headersSent && !response.destroyed) {
        reply.hijack();
        // A hijacked response still needs an explicit terminal response.
        response.statusCode = 502;
        response.removeHeader('Content-Length');
        response.removeHeader('Content-Range');
        response.end('Media transport failed');
      } else if (!response.destroyed) response.destroy(failure('media_transport_failed'));
    } finally {
      current?.data?.destroy();
      response.removeListener('close', cancel);
      incoming.raw?.removeListener('aborted', cancel);
    }
    return reply;
  }
  return { register, serve };
}

module.exports = { createBilibiliStreaming, parseRange, validateResponse, allowedMediaURL };
