'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { AsyncLocalStorage } = require('node:async_hooks');
const { createQuarkCredentialCoordinator, createQuarkMediaFailureStore } = require('../Resources/NodePatches/catpaw-quark-transfer-lifecycle.js');
const patch = fs.readFileSync(require.resolve('../Resources/NodePatches/catpaw-quark-lifecycle.patch.js'), 'utf8');
function harness(initial = '__uid=a; __puus=old', configured = '') {
  let stored = initial, adapter;
  const sent = [];
  const db = {
    getObjectDefault: async () => stored === undefined ? {} : ({ cookie: stored }),
    push: async (path, value) => { if (path === '/quark/cookie') stored = value; },
    delete: async () => { stored = ''; }
  };
  const request = { server: { db, config: { quark: { cookie: configured } } } };
  const context = {
    process: { env: { OKVIDEO_TRANSFER_PATCH_MODULE: 'lifecycle', OKVIDEO_TRANSFER_LEDGER_PATH: 'unused',
      OKVIDEO_RANGE_STREAM_MODULE: 'range', OKVIDEO_INSTALLATION_UUID: 'unused', OKVIDEO_TRANSFER_OWNER_SESSION_ID: 'unused', OKVIDEO_INSTALLATION_HMAC_KEY: 'unused' } },
    Wg: 'unused',
    require: (name) => name === 'range' ? { createCatPawRangeStream: () => async (...args) => args[4] }
      : name === 'node:async_hooks' ? { AsyncLocalStorage } : {
      createQuarkCredentialCoordinator,
      createQuarkMediaFailureStore,
      createQuarkTransferLifecycle: (options) => { adapter = options; return {
        wrapPlay: (fn) => fn, wrapProxy: (fn) => fn, registerRoutes: () => {},
        download: async () => (await options.api({ method: 'post', path: 'file/download', accountCookie: options.getCookie() })).data
      }; }
    },
    qc: '', D6: {}, xtt: 'https://mock.invalid', to: 'test=1', f_: {},
    mT: async () => { context.qc = stored; },
    xa: async () => stored,
    ro: async () => ({ legacy: true }),
    _Pr: async () => ({ cookie: context.qc }),
    x_: async (...args) => args[4],
    DM: async () => {
      await context.mT(request);
      const header = { Cookie: context.qc };
      await context.Vae('share', 'token', 'file', 'token');
      await context.Vae('share', 'token', 'file', 'token');
      return { header, url: 'https://mock.invalid/media' };
    },
    PM: async () => {}, Vae: async () => {}, gtt: async () => {}, pIn: () => {},
    ge: { interceptors: { response: { use() {} } }, post: async (url, body, config) => {
      sent.push(config.headers.Cookie);
      return { status: 200, data: { download_url: 'https://mock.invalid/media' },
        headers: { 'set-cookie': ['__puus=new; Path=/'] } };
    } }, messageToDart: async () => {}
  };
  vm.runInNewContext(patch, context);
  return { context, request, sent, read: () => stored, adapter: () => adapter };
}
test('actual deterministic adapter persists rotation and rebuilds returned media headers', async () => {
  const h = harness();
  const result = await h.context.DM(h.request, {});
  assert.deepEqual(h.sent, ['__uid=a; __puus=old', '__uid=a; __puus=new']);
  assert.equal(h.read(), '__uid=a; __puus=new');
  assert.equal(result.header.Cookie, h.read());
});
test('manual account switch during network request wins over old rotation', async () => {
  const h = harness();
  h.context.ge.post = async () => {
    await h.request.server.db.push('/quark/cookie', '__uid=b; __puus=manual');
    return { status: 200, data: {}, headers: { 'set-cookie': ['__puus=late'] } };
  };
  await assert.rejects(h.context.DM(h.request, {}), { code: 'OKVIDEO_ACCOUNT_CHANGED' });
  assert.equal(h.read(), '__uid=b; __puus=manual');
});
test('unscoped legacy API and other providers are not intercepted', async () => {
  const h = harness();
  assert.deepEqual(await h.context.ro('file/test'), { legacy: true });
  const headers = { Cookie: 'other-provider' };
  assert.equal(await h.context.x_({}, {}, '', '', headers, {}), headers);
});
test('configured credentials seed only absent fields, never an explicitly revoked credential', async () => {
  const seeded = harness(undefined, '__uid=a; __puus=configured');
  // Explicit undefined must bypass the harness default initial value.
  seeded.request.server.db.getObjectDefault = async () => ({});
  seeded.context.xa = async () => '';
  seeded.context.ge.post = async (_url, _body, config) => {
    seeded.sent.push(config.headers.Cookie);
    return { status: 200, data: {}, headers: {} };
  };
  await seeded.context.DM(seeded.request, {});
  assert.equal(seeded.sent[0], '__uid=a; __puus=configured');
  const revoked = harness('', '__uid=a; __puus=configured');
  await revoked.context.DM(revoked.request, {});
  assert.equal(revoked.sent[0], '');
});
