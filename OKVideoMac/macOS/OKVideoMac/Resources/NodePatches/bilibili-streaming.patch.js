;
// Applied only to the validated CatPaw input SHA-256 named by the Swift host.
(() => {
  const { createBilibiliStreaming } = require(process.env.OKVIDEO_BILIBILI_STREAM_MODULE);
  const { AsyncLocalStorage } = require('node:async_hooks');
  const context = new AsyncLocalStorage();
  const streaming = createBilibiliStreaming({ request: (url, options) => t0.get(url, options) });
  const originalRepresentation = Qp0;
  const urlsFor = representation => [wer(representation),
    ...Eer(representation.backup_url || representation.backupUrl),
    fr(representation.base_url || representation.baseUrl)].filter(Boolean);
  nw.prototype.mpd = async function(parameters = {}) {
    const data = await this.playData(parameters);
    if (!data?.dash) throw new Error('Bilibili DASH unavailable');
    return context.run({ client: this, parameters },
      () => ver(data.dash, parameters.qn || '', parameters.proxyBaseUrl || ''));
  };
  Qp0 = function(representation = {}, proxyBase = '') {
    const xml = originalRepresentation(representation, proxyBase);
    const owner = context.getStore();
    if (!xml || !proxyBase || !owner) return xml;
    const mime = representation.mime_type || representation.mimeType;
    const collection = String(mime).startsWith('audio/') ? 'audio' : 'video';
    const token = streaming.register({
      urls: urlsFor(representation),
      refresh: async () => {
        const data = await owner.client.playData(owner.parameters);
        const match = (data?.dash?.[collection] || []).find(item =>
          String(item.id) === String(representation.id) && item.codecs === representation.codecs);
        if (!match) throw new Error('Bilibili representation unavailable');
        return urlsFor(match);
      }
    });
    const original = `${proxyBase}/${Buffer.from(wer(representation), 'utf8').toString('base64url')}.m4s`;
    return xml.replace(original, `${proxyBase}/${token}.m4s`);
  };
  a0r = (client, request, reply) => streaming.serve(o0r(request), client.headers(true), request, reply);
  Ker = (client, request, reply) => streaming.serve(Jer(request), client.headers(true), request, reply);
})();
