;
// OKVideoMac deterministic CatPaw Quark lifecycle patch, version 3.
// The surrounding bundle is accepted only at its pinned input SHA-256 and the
// final concatenated script is accepted only at its pinned output SHA-256.
(() => {
  'use strict';
  const lifecycleModulePath = process.env.OKVIDEO_TRANSFER_PATCH_MODULE;
  const ledgerPath = process.env.OKVIDEO_TRANSFER_LEDGER_PATH;
  const installationUUID = process.env.OKVIDEO_INSTALLATION_UUID;
  const ownerSessionID = process.env.OKVIDEO_TRANSFER_OWNER_SESSION_ID;
  const hmacKeyHex = process.env.OKVIDEO_INSTALLATION_HMAC_KEY;
  if (!lifecycleModulePath || !ledgerPath || !installationUUID ||
      !ownerSessionID || !hmacKeyHex) {
    throw new Error('OKVideoMac transfer lifecycle environment is incomplete');
  }
  const { createQuarkTransferLifecycle, createQuarkCredentialCoordinator, createQuarkMediaFailureStore } = require(lifecycleModulePath);
  const { createCatPawRangeStream } = require(process.env.OKVIDEO_RANGE_STREAM_MODULE);
  const { AsyncLocalStorage } = require('node:async_hooks');
  const credentialContext = new AsyncLocalStorage();
  const stores = new WeakMap();
  const mediaFailures = createQuarkMediaFailureStore();
  // Observe only this playback's Quark CDN responses, never another provider
  // or account API. A probe alone does not interrupt playback or demand login.
  const observe = (response) => {
    const context = credentialContext.getStore();
    if (context) mediaFailures.record(context.request, response, context.phase || 'media');
  };
  ge.interceptors.response.use((response) => { observe(response); return response; },
    (error) => { observe(error?.response); return Promise.reject(error); });
  const originalPlay = DM;
  const originalDownload = Vae;
  const originalTranscode = gtt;
  const originalQuarkProxy = PM;
  const originalRouteRegistration = pIn;
  const originalInitialize = mT;
  const originalAPI = ro;
  const originalMaskProbe = _Pr;
  const originalStream = createCatPawRangeStream({ client: ge, cacheRoot: Wg });

  function storeFor(request) {
    const db = request.server.db;
    if (stores.has(db)) return stores.get(db);
    let writes = Promise.resolve();
    const serialize = (operation) => {
      const result = writes.then(operation, operation);
      writes = result.catch(() => {});
      return result;
    };
    const originalPush = db.push.bind(db);
    // Include manual authorization writes in the same critical section as
    // conditional rotation. Other provider paths keep their original behavior.
    for (const method of ['push', 'delete']) {
      if (typeof db[method] !== 'function') continue;
      const original = db[method].bind(db);
      db[method] = (path, ...args) => /^\/?quark(?:\/|$)/.test(String(path)) || path === '/'
        ? serialize(() => original(path, ...args)) : original(path, ...args);
    }
    const read = async () => {
      const profile = await db.getObjectDefault('/quark', {});
      // An explicitly empty canonical value means the user revoked login.
      // Only an absent field may inherit the source's configured credential.
      if (Object.prototype.hasOwnProperty.call(profile, 'cookie')) {
        return String(profile.cookie || '').trim();
      }
      return String(await xa(db, {
        path: '/quark', key: 'cookie', legacySeeds: [request.server.config?.quark?.cookie, '']
      }) || request.server.config?.quark?.cookie || '').trim();
    };
    const coordinator = createQuarkCredentialCoordinator({
      read,
      compareAndSet: (expected, next) => serialize(async () => {
        if (await read() !== expected) return false;
        await originalPush('/quark/cookie', next);
        return true;
      })
    });
    stores.set(db, coordinator);
    return coordinator;
  }
  async function withCredentials(request, operation) {
    const store = storeFor(request);
    const ticket = await store.begin();
    return credentialContext.run({ store, cookie: ticket.cookie, request }, operation);
  }
  mT = async function okvideoInitializeQuark(request) {
    await originalInitialize(request);
    const context = credentialContext.getStore();
    if (context) {
      const ticket = await context.store.begin(context.cookie);
      context.cookie = ticket.cookie;
      qc = ticket.cookie;
    }
  };

  const credentialAPI = async (request) => {
    const context = credentialContext.getStore();
    const ticket = context ? await context.store.begin(request.accountCookie) : null;
    const separator = request.path.includes('?') ? '&' : '?';
    const url = `${xtt}/${request.path}${separator}${to}`;
    const config = {
      headers: Object.assign({}, request.headers, f_, {
        Cookie: ticket?.cookie ?? request.accountCookie ?? ''
      }),
      validateStatus: () => true,
      timeout: 10000
    };
    try {
      const response = request.method === 'get'
        ? await ge.get(url, config)
        : await ge.post(url, request.body || {}, config);
      if (context) {
        await context.store.rotate(ticket, response.headers);
        const latest = await context.store.begin(ticket.cookie);
        context.cookie = latest.cookie;
        if (qc === ticket.cookie) qc = latest.cookie;
      }
      return { status: response.status, data: response.data };
    } catch (error) {
      if (error?.code === 'OKVIDEO_ACCOUNT_CHANGED') throw error;
      return { status: Number(error?.response?.status || 0), data: error?.response?.data || null };
    }
  };
  ro = async function okvideoQuarkAPI(endpoint, body, headers, method, retries) {
    const context = credentialContext.getStore();
    if (!context) return originalAPI(endpoint, body, headers, method, retries);
    const accountEndpoint = /^file\//.test(endpoint);
    if (accountEndpoint) lifecycle.requireAccount();
    const result = await credentialAPI({ path: endpoint, body, headers,
      method: method || 'post', accountCookie: context.cookie });
    if (accountEndpoint) lifecycle.validateAccountResponse(result, 'quark account authorization required');
    return result.data || {};
  };
  _Pr = async function okvideoQuarkMaskProbe(url) {
    const context = credentialContext.getStore();
    if (context) {
      const latest = await context.store.begin(context.cookie);
      context.cookie = latest.cookie;
      // The original probe copies qc into headers synchronously, before its
      // first await. Updating here does not share another request's snapshot.
      qc = latest.cookie;
    }
    return context ? credentialContext.run({ ...context, phase: 'probe' }, () => originalMaskProbe(url))
      : originalMaskProbe(url);
  };
  x_ = async function okvideoCredentialBoundStream(request, reply, url, fid, headers, options) {
    const context = credentialContext.getStore();
    if (context) {
      const latest = await context.store.begin(context.cookie);
      headers = Object.assign({}, headers, { Cookie: latest.cookie });
    }
    return originalStream(request, reply, url, fid, headers, options);
  };

  const lifecycle = createQuarkTransferLifecycle({
    ledgerPath,
    installationUUID,
    ownerSessionID,
    hmacKeyHex,
    getCookie: () => credentialContext.getStore()?.cookie ?? qc,
    setSourceCache: (sourceFID, savedFID) => {
      D6[sourceFID] = savedFID;
    },
    clearSourceCache: (sourceFID, savedFID) => {
      if (D6[sourceFID] === savedFID) delete D6[sourceFID];
    },
    publishAuthorizationRequired: async (authorization) => {
      await messageToDart({
        action: 'authorizationRequired',
        opt: authorization
      });
    },
    api: credentialAPI
  });

  // Quark is the only provider connected in this version. Own-drive playback
  // and every other provider retain the original implementation.
  const play = lifecycle.wrapPlay(originalPlay);
  DM = (request, reply) => withCredentials(request, async () => {
    mediaFailures.clear(request);
    const result = await play(request, reply);
    const context = credentialContext.getStore();
    const latest = await context.store.begin(context.cookie);
    if (result && typeof result === 'object' && !Array.isArray(result)) {
      result.header = Object.assign({}, result.header, { Cookie: latest.cookie });
    }
    return result;
  });
  const proxy = lifecycle.wrapProxy(originalQuarkProxy, async (request) => {
    await mT(request);
  });
  PM = (request, reply) => withCredentials(request, () => proxy(request, reply));
  Vae = async function okvideoQuarkDownload(
    shareID,
    shareToken,
    sourceFID,
    sourceToken,
    _legacyClear
  ) {
    if (shareID === 'own') {
      return originalDownload(
        shareID,
        shareToken,
        sourceFID,
        sourceToken,
        false
      );
    }
    return lifecycle.download(shareID, shareToken, sourceFID, sourceToken);
  };
  gtt = async function okvideoQuarkTranscode(
    shareID,
    shareToken,
    sourceFID,
    sourceToken
  ) {
    if (shareID === 'own') {
      return originalTranscode(shareID, shareToken, sourceFID, sourceToken);
    }
    return lifecycle.transcode(shareID, shareToken, sourceFID, sourceToken);
  };
  htt = async function okvideoQuarkTransfer(
    shareID,
    shareToken,
    sourceFID,
    sourceToken,
    _legacyClear
  ) {
    return lifecycle.ensureTransfer(
      shareID,
      shareToken,
      sourceFID,
      sourceToken
    );
  };

  // These legacy functions enumerate and delete a directory. They remain
  // unreachable from the new Quark path and are neutralized defensively.
  utt = async function okvideoDirectoryClearDisabled() {};
  cPr = async function okvideoLegacyFolderLifecycleDisabled() {};

  pIn = function okvideoRegisterLifecycleRoutes(server) {
    originalRouteRegistration(server);
    server.get('/__okvideo/quark/media-failure', async (request) => ({ failure: mediaFailures.consume(request) }));
    const scopedRoutes = {
      get: (path, handler) => server.get(path, (request, reply) =>
        withCredentials(request, () => handler(request, reply))),
      post: (path, handler) => server.post(path, (request, reply) =>
        withCredentials(request, () => handler(request, reply)))
    };
    lifecycle.registerRoutes(scopedRoutes, async (request) => {
      await mT(request);
    });
  };
})();
