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

test('a mirror cannot omit the original strong ETag and splice bytes', () => {
  const { validateResponse } = require('../Resources/NodePatches/bilibili-streaming.js');
  const response = {status:206, headers:{'content-range':'bytes 10-99/100','content-length':'90'}};
  assert.throws(() => validateResponse(response, 10, null, {total:100,etag:'"original"',url:'a'}, 'a'), /entity_changed/);
  assert.throws(() => validateResponse(response, 10, null, {total:100,etag:null,url:'a'}, 'b'), /entity_changed/);
});


test('static DASH transport works across arbitrary Node site names without source code patches', async t => {
  const {createDASHTransport}=require('../Resources/NodePatches/bilibili-streaming.js');
  const data=Buffer.alloc(150000);for(let i=0;i<data.length;i++)data[i]=i%251;
  const ranges=[];let cuts=0;let origin;
  origin=await listen((req,res)=>{
    if(req.url.includes('/mpd/')) {res.setHeader('Content-Type','application/dash+xml');res.end(`<MPD type="static"><Period><AdaptationSet><Representation id="32" codecs="avc1" mimeType="video/mp4"><BaseURL>${origin.url}/media</BaseURL><SegmentBase indexRange="0-5"/></Representation></AdaptationSet></Period></MPD>`);return;}
    ranges.push(req.headers.range);const bytes=mediaResponse(req,res,data);
    if(cuts++===0){res.write(bytes.subarray(0,8192));setTimeout(()=>res.destroy(),10);}else res.end(bytes);
  });
  const transport=createDASHTransport({request,isOwned:url=>url.startsWith(origin.url+'/'),headerTimeout:500,readTimeout:100});
  const proxy=await listen((req,res)=>transport.handle(req,res));
  t.after(()=>{for(const {server} of [origin,proxy]){server.closeAllConnections();server.close();}});
  for(const site of ['brand-new-source','renamed-provider','any-script-version']) {
    const path=transport.register(origin.url+`/spider/${site}/3/proxy/mpd/opaque`);
    const manifest=await fetchBytes(proxy.url+path);
    const child=/<BaseURL>([^<]+)<\/BaseURL>/.exec(manifest.data.toString())[1];
    const result=await fetchBytes(proxy.url+child,{Range:'bytes=333-99999'});
    assert.deepEqual(result.data,data.subarray(333,100000));
  }
  assert.deepEqual(ranges.slice(0,2),['bytes=333-99999','bytes=8525-99999']);
  assert.throws(()=>transport.register('http://localhost/private'),/unowned_manifest/);
});

test('DASH expiration refreshes the manifest after its initial response has closed', async t=>{
  const {createDASHTransport}=require('../Resources/NodePatches/bilibili-streaming.js');
  const data=Buffer.alloc(4096,91);let manifests=0;let origin;
  origin=await listen((req,res)=>{
    if(req.url.includes('/mpd/')){manifests++;res.end(`<MPD><Representation id="7" codecs="avc1" mimeType="video/mp4"><BaseURL>${origin.url}/${manifests===1?'expired':'fresh'}</BaseURL><SegmentBase/></Representation></MPD>`);return;}
    if(req.url==='/expired'){res.writeHead(403);res.end();return;}
    res.end(mediaResponse(req,res,data));
  });
  const transport=createDASHTransport({request,isOwned:url=>url.startsWith(origin.url+'/'),headerTimeout:500,readTimeout:100});
  const proxy=await listen((req,res)=>transport.handle(req,res));
  t.after(()=>{for(const {server} of [origin,proxy]){server.closeAllConnections();server.close();}});
  const path=transport.register(origin.url+'/spider/unknown/3/proxy/mpd/opaque');
  const manifest=await fetchBytes(proxy.url+path);
  const child=/<BaseURL>([^<]+)<\/BaseURL>/.exec(manifest.data.toString())[1];
  assert.deepEqual((await fetchBytes(proxy.url+child)).data,data);
  assert.equal(manifests,2);
});

test('DASH redirects remain bounded and strip private headers at the network boundary', async t=>{
  const {Readable}=require('node:stream');
  const {createDASHTransport}=require('../Resources/NodePatches/bilibili-streaming.js');
  const seen=[];const data=Buffer.alloc(1000,74);
  const transport=createDASHTransport({isOwned:u=>u.startsWith('http://127.0.0.1:12345/'),
    request:async(url,options)=>{
      seen.push({url,headers:options.headers});
      if(url.includes('/proxy/mpd/'))return {status:302,headers:{location:'https://manifest.example/new/location.mpd'},data:Readable.from([])};
      if(url.endsWith('.mpd'))return {status:200,headers:{},data:Readable.from([Buffer.from('<MPD><Representation id="v"><BaseURL>../clip.m4s</BaseURL><SegmentBase/></Representation></MPD>')])};
      if(url.endsWith('/clip.m4s'))return {status:307,headers:{location:'https://cdn.example/final'},data:Readable.from([])};
      return {status:206,headers:{'content-range':'bytes 0-999/1000','content-length':'1000',etag:'"stable"'},data:Readable.from([data])};
    }});
  const proxy=await listen((req,res)=>transport.handle(req,res));
  t.after(()=>{proxy.server.closeAllConnections();proxy.server.close();});
  const path=transport.register('http://127.0.0.1:12345/spider/arbitrary/3/proxy/mpd/opaque',
    {Authorization:'private',Cookie:'private','X-Private':'private',Referer:'https://public.example/'});
  const result=await fetchBytes(proxy.url+path);
  const child=/<BaseURL>([^<]+)<\/BaseURL>/.exec(result.data.toString())[1];
  assert.deepEqual((await fetchBytes(proxy.url+child)).data,data);
  assert.equal(seen[0].headers.Authorization,'private');
  assert.equal(seen[2].url,'https://manifest.example/clip.m4s');
  for(const entry of seen.slice(1)){
    for(const key of ['Authorization','Cookie','X-Private'])assert.equal(entry.headers[key],undefined);
    assert.equal(entry.headers.Referer,'https://public.example/');
  }
  let loops=0;
  const looping=createDASHTransport({isOwned:u=>u.startsWith('http://127.0.0.1:12345/'),request:async()=>{
    loops++;return {status:302,headers:{location:'http://127.0.0.1:12345/proxy/loop'},data:Readable.from([])};
  }});
  const loopProxy=await listen((req,res)=>looping.handle(req,res));
  t.after(()=>{loopProxy.server.closeAllConnections();loopProxy.server.close();});
  assert.equal((await fetchBytes(loopProxy.url+looping.register('http://127.0.0.1:12345/proxy/loop'))).status,502);
  assert.equal(loops,6);
});

test('inherited DASH addressing falls back without rewriting wrong byte resources', async t=>{
  const {createDASHTransport}=require('../Resources/NodePatches/bilibili-streaming.js');
  const xml='<MPD><BaseURL>https://cdn.example/show/</BaseURL><Representation id="v"><BaseURL>clip.m4s</BaseURL><SegmentBase/></Representation></MPD>';
  let origin;origin=await listen((_req,res)=>res.end(xml));
  const transport=createDASHTransport({request,isOwned:u=>u.startsWith(origin.url+'/')});
  const proxy=await listen((req,res)=>transport.handle(req,res));
  t.after(()=>{for(const {server} of [origin,proxy]){server.closeAllConnections();server.close();}});
  const original=origin.url+'/spider/new/3/proxy/mpd/opaque';
  const response=await fetchBytes(proxy.url+transport.register(original));
  assert.equal(response.status,307);assert.equal(response.headers.location,original);
  assert.equal(transport.parse('<MPD xml:base="https://cdn.example/"><Representation id="v"><BaseURL>clip.m4s</BaseURL><SegmentBase/></Representation></MPD>',original),null);
});

test('a redirected representation cannot change final entity without a strong validator', async t=>{
  const {Readable}=require('node:stream');
  const {createDASHTransport}=require('../Resources/NodePatches/bilibili-streaming.js');
  let redirects=0;
  const transport=createDASHTransport({isOwned:u=>u.startsWith('http://127.0.0.1:12345/'),
    request:async(url)=>{
      if(url.includes('/proxy/mpd/'))return {status:200,headers:{},data:Readable.from([Buffer.from('<MPD><Representation id="v"><BaseURL>https://cdn.example/route</BaseURL><SegmentBase/></Representation></MPD>')])};
      if(url.endsWith('/route'))return {status:302,headers:{location:'https://cdn.example/entity'+(++redirects)},data:Readable.from([])};
      const offset=redirects===1?0:100;
      return {status:206,headers:{'content-range':`bytes ${offset}-999/1000`,'content-length':String(1000-offset)},data:Readable.from([Buffer.alloc(100,redirects)])};
    }});
  const proxy=await listen((req,res)=>transport.handle(req,res));
  t.after(()=>{proxy.server.closeAllConnections();proxy.server.close();});
  const manifest=await fetchBytes(proxy.url+transport.register('http://127.0.0.1:12345/proxy/mpd/a'));
  const child=/<BaseURL>([^<]+)<\/BaseURL>/.exec(manifest.data.toString())[1];
  await assert.rejects(fetchBytes(proxy.url+child));assert.equal(redirects,2);
});

test('DASH without HTTP Range stays a full stream and never splices a retry', async t=>{
  const {createDASHTransport}=require('../Resources/NodePatches/bilibili-streaming.js');
  const data=Buffer.alloc(10000,27);let mediaRequests=0,cut=false;let origin;
  origin=await listen((req,res)=>{
    if(req.url.includes('/proxy/mpd/')){res.end(`<MPD><Representation id="v"><BaseURL>${origin.url}/media</BaseURL><SegmentBase/></Representation></MPD>`);return;}
    mediaRequests++;res.writeHead(200,{'Content-Type':'video/mp4','Content-Length':data.length});
    if(cut){res.write(data.subarray(0,100));setTimeout(()=>res.destroy(),15);}else res.end(data);
  });
  const transport=createDASHTransport({request,isOwned:u=>u.startsWith(origin.url+'/'),readTimeout:100});
  const proxy=await listen((req,res)=>transport.handle(req,res));
  t.after(()=>{for(const {server} of [origin,proxy]){server.closeAllConnections();server.close();}});
  const manifest=await fetchBytes(proxy.url+transport.register(origin.url+'/proxy/mpd/a'));
  const child=/<BaseURL>([^<]+)<\/BaseURL>/.exec(manifest.data.toString())[1];
  const response=await fetchBytes(proxy.url+child,{Range:'bytes=500-'});
  assert.equal(response.status,200);assert.deepEqual(response.data,data);
  assert.equal(response.headers['content-range'],undefined);assert.equal(mediaRequests,1);
  cut=true;await assert.rejects(fetchBytes(proxy.url+child));assert.equal(mediaRequests,2);
});
