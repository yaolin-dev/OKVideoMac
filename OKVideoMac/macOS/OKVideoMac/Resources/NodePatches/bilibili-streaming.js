'use strict';

// Bounded DASH byte transport; the legacy export remains for older callers.
// A consumer blocked on its own cache must never spend a network read deadline.
const { randomBytes } = require('node:crypto');

function failure(code) {
  return Object.assign(new Error(code), { code });
}

function allowedMediaURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password &&
      ['bilivideo.com', 'bilivideo.cn', 'mountaintoys.cn', 'akamaized.net'].some(domain =>
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

function validateResponse(response, offset, requestedEnd, identity, url) {
  if (response.status !== 206) throw failure('upstream_status_' + response.status);
  const h = response.headers;
  const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(String(h['content-range'] || ''));
  if (!range) throw failure('invalid_content_range');
  const [start, end, total] = range.slice(1).map(Number);
  if (![start, end, total].every(Number.isSafeInteger) || start !== offset || end < start ||
      end >= total || end !== Math.min(requestedEnd ?? total - 1, total - 1) ||
      Number(h['content-length']) !== end - start + 1) throw failure('range_mismatch');
  const etag = h.etag && !String(h.etag).startsWith('W/') ? String(h.etag) : null;
  // A URL change needs a shared strong validator. A missing validator must
  // never silently weaken an identity established by the first response.
  const sameEntity = identity?.etag != null && identity.etag === etag;
  if (identity && (identity.total !== total || (identity.etag && !sameEntity) ||
      (identity.url !== url && !sameEntity))) {
    throw failure('entity_changed');
  }
  return { total, end, url, etag: identity?.etag || etag, type: h['content-type'] || 'application/octet-stream' };
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

function createDASHStreaming({ request, allowURL = allowedMediaURL,
  headerTimeout = 15000, readTimeout = 20000, maximumRetries = 3, passthroughWithoutRange = false } = {}) {
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
          if (!identity && current.status === 200 && passthroughWithoutRange) {
            // The server did not honor Range. Preserve ordinary full-response
            // playback; never append a second response to these unproven bytes.
            reply.hijack(); response.statusCode = 200;
            for (const name of ['content-type', 'content-length', 'content-encoding'])
              if (current.headers[name] != null) response.setHeader(name, current.headers[name]);
            if (incoming.method === 'HEAD') { current.data.destroy(); response.end(); return reply; }
            try {
              const iterator = current.data[Symbol.asyncIterator]();
              let delivered = 0;
              while (true) {
                const chunk = await waitFor(iterator.next(), consumer.signal, readTimeout, 'read_timeout');
                if (chunk.done) break;
                if (!response.write(chunk.value)) await drain(response, consumer.signal);
                delivered += chunk.value.length;
              }
              const declared = current.headers['content-length'];
              if (declared != null && Number(declared) !== delivered) throw failure('short_read');
              response.end(); return reply;
            } catch { throw failure('non_range_interrupted'); }
          }
          const received = validateResponse(current, offset, range.end, identity, current.finalURL || urls[candidate % urls.length]);
          if (!identity) {
            identity = received;
            reply.hijack();
            response.statusCode = range.requested ? 206 : 200;
            response.setHeader('Content-Type', identity.type);
            response.setHeader('Accept-Ranges', 'bytes');
            response.setHeader('Content-Length', identity.end - range.start + 1);
            if (range.requested) response.setHeader('Content-Range', `bytes ${range.start}-${identity.end}/${identity.total}`);
          }
          if (incoming.method === 'HEAD') { current.data.destroy(); response.end(); return reply; }
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
          if (['entity_changed', 'body_overflow', 'range_mismatch', 'invalid_content_range', 'non_range_interrupted'].includes(error.code)) throw error;
          if (attempt++ >= maximumRetries) throw failure('retries_exhausted');
          incoming.log?.info({ event: 'dash_stream_retry', attempt, offset,
            reason: /^upstream_status_\d+$/.test(error.code || '') ? error.code : 'transport_interrupted' });
          const expired = /^upstream_status_(401|403|410)$/.test(error.code || '');
          // First continue the pinned URL; a transient read failure does not
          // require reparsing the video or changing its signed representation.
          if (attempt > 1 || expired) candidate++;
          if (!refreshed && item.refresh && (expired || candidate >= urls.length)) {
            refreshed = true;
            const fresh = await waitFor(item.refresh(consumer.signal), consumer.signal, headerTimeout, 'refresh_timeout');
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
      incoming.log?.warn({ event: 'dash_stream_failed', reason: error.code || 'transport_failure', offset });
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

module.exports = { createDASHStreaming, createBilibiliStreaming: createDASHStreaming, parseRange, validateResponse, allowedMediaURL };

// Host-owned static DASH transport. It consumes MPD/HTTP capabilities, never
// provider names, checksums or JavaScript implementation symbols.
function createDASHTransport({ request, isOwned, report = () => {}, headerTimeout = 15000, readTimeout = 12000 }) {
  const prefix = '/__okvideo/dash/';
  const sessions = new Map();
  const safeURL = value => {
    try {
      const url = new URL(value);
      return !url.username && !url.password && (url.protocol === 'https:' || isOwned(value));
    } catch { return false; }
  };
  async function transferRequest(value, options) {
    let url = value;
    for (let hop = 0; hop <= 5; hop++) {
      if (!safeURL(url)) throw failure('unsafe_redirect');
      const headers = {};
      for (const [name, item] of Object.entries(options.headers || {}))
        if (isOwned(url) || ['user-agent', 'referer', 'origin', 'range', 'accept-encoding', 'cache-control'].includes(name.toLowerCase())) headers[name] = item;
      const response = await request(url, {...options, headers});
      if (![301,302,303,307,308].includes(response.status)) return {...response, finalURL:url};
      response.data.destroy();
      if (hop === 5 || !response.headers.location) throw failure('redirect_limit');
      const next = new URL(response.headers.location, url).href;
      if (!safeURL(next) || (!isOwned(url) && isOwned(next))) throw failure('unsafe_redirect');
      url = next;
    }
  }
  const streaming = createDASHStreaming({ request:transferRequest, allowURL: safeURL, headerTimeout, readTimeout, passthroughWithoutRange:true });
  const text = value => value.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>');
  function resourceURL(raw, manifestURL) {
    const resolved = new URL(text(raw.trim().replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, '$1')), manifestURL).href;
    if (isOwned(resolved)) {
      // A common loopback proxy represents the upstream as a base64 URL. Decode
      // only a complete HTTPS Bili URL; opaque provider capabilities stay local.
      const url = new URL(resolved);
      const token = (url.searchParams.get('url') || url.pathname.split('/').pop()).replace(/\.m4s$/i, '');
      if (/^[A-Za-z0-9_-]{16,8192}={0,2}$/.test(token)) {
        const decoded = Buffer.from(token, 'base64url').toString('utf8');
        if (allowedMediaURL(decoded)) return decoded;
      }
    }
    return safeURL(resolved) ? resolved : null;
  }
  function parse(xml, manifestURL) {
    if (Buffer.byteLength(xml) > 2*1024*1024 || /<!DOCTYPE|<!ENTITY|\0/i.test(xml)) throw failure('invalid_manifest');
    const root = /<MPD\b([^>]*)>/i.exec(xml);
    if (!root || /\btype\s*=\s*['"]dynamic['"]/i.test(root[1])) return null;
    const entries = [];
    const attribute = (value, name) => new RegExp('\\b'+name+'\\s*=\\s*([\'"])(.*?)\\1','i').exec(value)?.[2] || '';
    // These layouts require inherited-base/segment resolution. Preserve the
    // provider's original MPD until this transport can resolve them completely.
    if (/\bxml:base\s*=|<SegmentTemplate\b|<SegmentList\b/i.test(xml)) return null;
    let unsupported = false, representedBases = 0;
    xml.replace(/<Representation\b([^>]*)>([\s\S]*?)<\/Representation>/gi, (block, attrs, body) => {
      const bases = [...body.matchAll(/<BaseURL\b[^>]*>([\s\S]*?)<\/BaseURL>/gi)];
      if (!/<SegmentBase\b/i.test(body) || !bases.length || /<SegmentTemplate\b|<SegmentList\b/i.test(body)) { unsupported = true; return block; }
      representedBases += bases.length;
      const urls = bases.map(base => resourceURL(base[1], manifestURL));
      const key = JSON.stringify(['id','codecs','mimeType'].map(name => attribute(attrs,name)));
      if (urls.some(url=>!url) || entries.some(entry=>entry.key===key)) { unsupported=true; return block; }
      entries.push({key,urls,block}); return block;
    });
    if ([...xml.matchAll(/<BaseURL\b/gi)].length !== representedBases) return null;
    return !unsupported && entries.length ? entries : null;
  }
  async function manifest(session, signal) {
    const response = await waitFor(transferRequest(session.url, {headers:{...session.headers,'Cache-Control':'no-cache','Accept-Encoding':'identity'},
      signal, responseType:'stream',timeout:0,maxRedirects:0,validateStatus:()=>true}),signal,headerTimeout,'header_timeout');
    try {
      if (response.status !== 200) throw failure('manifest_status_'+response.status);
      const chunks=[];let size=0;const iterator=response.data[Symbol.asyncIterator]();
      while(true) {
        const chunk=await waitFor(iterator.next(),signal,readTimeout,'read_timeout');
        if(chunk.done)break;
        size+=chunk.value.length;if(size>2*1024*1024)throw failure('manifest_too_large');chunks.push(chunk.value);
      }
      return {xml:Buffer.concat(chunks).toString('utf8'), url:response.finalURL};
    } finally {response.data.destroy();}
  }
  function register(url, headers = {}) {
    if (!isOwned(url) || !/\/proxy\//i.test(new URL(url).pathname)) throw failure('unowned_manifest');
    const token=randomBytes(18).toString('hex');
    sessions.set(token,{url,headers,created:Date.now()});
    while(sessions.size>64)sessions.delete(sessions.keys().next().value);
    return prefix+token+'/manifest.mpd';
  }
  async function handle(req,res) {
    const path=new URL(req.url,'http://127.0.0.1').pathname;
    if(!path.startsWith(prefix))return false;
    const [,token,resource]=path.slice(prefix.length-1).split('/');
    const session=sessions.get(token);
    if(!session || Date.now()-session.created>8*60*60*1000) {res.statusCode=410;res.end();return true;}
    const controller=new AbortController();const cancel=()=>controller.abort();res.once('close',cancel);
    try {
      if(resource==='manifest.mpd') {
        const loaded=await manifest(session,controller.signal);
        let xml=loaded.xml;
        const entries=parse(xml,loaded.url);
        if(!entries) {res.statusCode=307;res.setHeader('Location',session.url);res.end();return true;}
        session.children ||= new Map();
        for(const entry of entries) {
          const id=streaming.register({urls:entry.urls,refresh:async signal=>{
            const loaded=await manifest(session,signal);
            const fresh=parse(loaded.xml,loaded.url);
            const match=fresh?.find(value=>value.key===entry.key);
            if(!match)throw failure('representation_unavailable');return match.urls;
          }});
          session.children.set(id,entry.urls);
          const child=prefix+token+'/'+id;
          const block=entry.block.replace(/<BaseURL\b[^>]*>[\s\S]*?<\/BaseURL>/gi,(_value,index)=>'<BaseURL>'+child+'</BaseURL>');
          xml=xml.replace(entry.block,block);
        }
        res.statusCode=200;res.setHeader('Content-Type','application/dash+xml');res.setHeader('Cache-Control','no-store');
        res.end(req.method==='HEAD'?undefined:xml);
        report({event:'dash_transport_ready',representations:entries.length});
      } else if(session.children?.has(resource)) {
        const urls=session.children.get(resource);
        // Cross-origin media gets only public playback headers. Authentication
        // remains on the provider's loopback request unless its URL is owned.
        const headers={};
        for(const [name,value] of Object.entries(session.headers))
          if(isOwned(urls[0]) || ['user-agent','referer','origin'].includes(name.toLowerCase()))headers[name]=value;
        if(allowedMediaURL(urls[0])) {
          if(!Object.keys(headers).some(k=>k.toLowerCase()==='referer'))headers.Referer='https://www.bilibili.com/';
          if(!Object.keys(headers).some(k=>k.toLowerCase()==='user-agent'))headers['User-Agent']='Mozilla/5.0';
        }
        const reply={raw:res,hijack(){},code(code){res.statusCode=code;return this;},send(value){res.end(value);return this;}};
        await streaming.serve(resource,headers,{raw:req,headers:req.headers,method:req.method,
          log:{info:report,warn:report}},reply);
      } else {res.statusCode=404;res.end();}
    } catch(error) {
      if(!controller.signal.aborted) {
        report({event:'dash_transport_failed',reason:error.code||'transport_failure'});
        if(!res.headersSent){res.statusCode=502;res.end('Media transport failed');}else res.destroy();
      }
    } finally {res.removeListener('close',cancel);}
    return true;
  }
  return {register,handle,parse};
}
module.exports.createDASHTransport = createDASHTransport;
