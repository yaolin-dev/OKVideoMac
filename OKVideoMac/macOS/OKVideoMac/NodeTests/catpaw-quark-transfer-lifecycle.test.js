'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  createQuarkTransferLifecycle
} = require('../Resources/NodePatches/catpaw-quark-transfer-lifecycle.js');

const INSTALLATION_ID = '11111111-1111-4111-8111-111111111111';
const OWNER_SESSION_ID = '22222222-2222-4222-8222-222222222222';
const HMAC_KEY = 'ab'.repeat(32);

function response(data, status = 200) {
  return { status, data: { data } };
}

function createHarness(t, options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'okvideo-transfer-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const ledgerPath = path.join(directory, 'ledger.json');
  let currentMilliseconds = Date.parse('2026-09-04T00:00:00.000Z');
  let cookie = options.cookie || 'sid=account-a; token=secret';
  let folderSequence = 0;
  let taskSequence = 0;
  const taskSavedFIDs = new Map();
  const calls = [];
  const deleteStatuses = [];

  const api = async (request) => {
    calls.push(structuredClone(request));
    if (options.beforeAPI) await options.beforeAPI(request);
    if (request.method === 'post' && request.path === 'file') {
      folderSequence += 1;
      return response({ fid: `folder-${folderSequence}` });
    }
    if (request.method === 'post' && request.path === 'share/sharepage/save') {
      taskSequence += 1;
      const taskID = `task-${taskSequence}`;
      const suffix = options.uniqueSavedFIDs ? `-${taskSequence}` : '';
      taskSavedFIDs.set(
        taskID,
        `saved-${request.body.fid_list[0]}${suffix}`
      );
      return response({ task_id: taskID });
    }
    if (request.method === 'get' && request.path.startsWith('task?')) {
      const taskID = new URLSearchParams(request.path.split('?')[1]).get('task_id');
      return response({
        save_as: { save_as_top_fids: [taskSavedFIDs.get(taskID)] }
      });
    }
    if (request.method === 'post' && request.path === 'file/download') {
      return response([{ download_url: `https://media.invalid/${request.body.fids[0]}` }]);
    }
    if (request.method === 'post' && request.path === 'file/v2/play') {
      return response({ video_list: [{ url: `https://media.invalid/${request.body.fid}` }] });
    }
    if (request.method === 'post' && request.path === 'file/delete') {
      const status = deleteStatuses.length ? deleteStatuses.shift() : 204;
      return status >= 200 && status < 300
        ? { status, data: {} }
        : { status, data: { message: 'mock deletion failure' } };
    }
    return { status: 500, data: { message: 'unexpected mock API call' } };
  };

  function makeLifecycle(
    ownerSessionID = options.ownerSessionID || OWNER_SESSION_ID
  ) {
    return createQuarkTransferLifecycle({
      ledgerPath,
      installationUUID: INSTALLATION_ID,
      ownerSessionID,
      hmacKeyHex: HMAC_KEY,
      api,
      getCookie: () => cookie,
      now: () => new Date(currentMilliseconds),
      randomUUID: () => crypto.randomUUID(),
      sleep: async () => {},
      orphanGraceMilliseconds: 1000,
      retryBaseMilliseconds: 1000,
      timersEnabled: false
    });
  }

  return {
    api,
    calls,
    deleteStatuses,
    directory,
    ledgerPath,
    makeLifecycle,
    advance(milliseconds) { currentMilliseconds += milliseconds; },
    setCookie(value) { cookie = value; }
  };
}

function request(requestID, requestGeneration) {
  return {
    headers: {
      'x-okvideo-transfer-request-id': requestID,
      'x-okvideo-transfer-generation': String(requestGeneration)
    }
  };
}

async function resolveEpisode(lifecycle, sourceFID, generation, options = {}) {
  const requestID = options.requestID || crypto.randomUUID();
  const play = lifecycle.wrapPlay(async () => {
    const media = await lifecycle.download(
      'share-id',
      'share-token',
      sourceFID,
      `source-token-${sourceFID}`
    );
    if (options.throwAfterTransfer) throw new Error('mock URL resolution failed');
    return { parse: 0, url: media.download_url };
  });
  return play(request(requestID, generation), null);
}

async function resolveProxiedEpisode(
  lifecycle,
  sourceFID,
  generation,
  options = {}
) {
  const requestID = options.requestID || crypto.randomUUID();
  const play = lifecycle.wrapPlay(async () => {
    await lifecycle.download(
      'share-id',
      'share-token',
      sourceFID,
      `source-token-${sourceFID}`
    );
    const fileID = `share-token*${sourceFID}*source-token-${sourceFID}`;
    return {
      parse: 0,
      url: [
        '代理',
        `http://127.0.0.1:2333/spider/myquark/3/proxy/quark/src/down/share-id/${fileID}/.bin`,
        '高清',
        `http://127.0.0.1:2333/spider/myquark/3/proxy/quark/trans/high/share-id/${fileID}/.mp4`
      ]
    };
  });
  return play(request(requestID, generation), null);
}

function proxyRequest(proxyURL, overrides = {}) {
  const url = new URL(proxyURL);
  const parts = url.pathname.split('/');
  const quarkIndex = parts.indexOf('quark');
  return {
    query: {
      _okvideoReceipt: url.searchParams.get('_okvideoReceipt')
    },
    params: {
      site: 'quark',
      what: parts[quarkIndex + 1],
      flag: parts[quarkIndex + 2],
      shareId: parts[quarkIndex + 3],
      fileId: decodeURIComponent(parts[quarkIndex + 4]),
      ...overrides
    }
  };
}

function createReply() {
  return {
    statusCode: 200,
    body: null,
    code(value) {
      this.statusCode = value;
      return this;
    },
    send(value) {
      this.body = value;
      return this;
    }
  };
}

function callsAt(harness, method, requestPath) {
  return harness.calls.filter((call) =>
    call.method === method && call.path === requestPath
  );
}

test('A -> B -> C keeps the active file leased and deletes only recorded saved FIDs', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();

  const a = await resolveEpisode(lifecycle, 'source-a', 1);
  const aReceipt = a._okvideo.transferReceipt;
  assert.equal((await lifecycle.acquire(aReceipt.receiptID)).status, 'leased');

  const b = await resolveEpisode(lifecycle, 'source-b', 2);
  const bReceipt = b._okvideo.transferReceipt;
  assert.equal(callsAt(harness, 'post', 'file/delete').length, 0);
  assert.equal((await lifecycle.acquire(bReceipt.receiptID)).status, 'leased');
  assert.equal((await lifecycle.release(aReceipt.receiptID, 'mediaReleased')).status, 'cleaned');

  const c = await resolveEpisode(lifecycle, 'source-c', 3);
  const cReceipt = c._okvideo.transferReceipt;
  assert.equal((await lifecycle.acquire(cReceipt.receiptID)).status, 'leased');
  assert.equal((await lifecycle.release(bReceipt.receiptID, 'mediaReleased')).status, 'cleaned');
  assert.equal((await lifecycle.release(cReceipt.receiptID, 'playerClosed')).status, 'cleaned');

  const deleted = callsAt(harness, 'post', 'file/delete')
    .flatMap((call) => call.body.filelist);
  assert.deepEqual(deleted, ['saved-source-a', 'saved-source-b', 'saved-source-c']);
  assert.ok(!deleted.includes('unrelated-user-file'));
  assert.equal(harness.calls.some((call) => /list/i.test(call.path)), false);
  assert.equal(callsAt(harness, 'post', 'file').length, 2);
});

test('URL resolution failure cleans the new transfer without touching an older lease', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const a = await resolveEpisode(lifecycle, 'source-a', 1);
  const aReceipt = a._okvideo.transferReceipt;
  await lifecycle.acquire(aReceipt.receiptID);

  await assert.rejects(
    resolveEpisode(lifecycle, 'source-b', 2, { throwAfterTransfer: true }),
    /mock URL resolution failed/
  );

  const deleted = callsAt(harness, 'post', 'file/delete')
    .flatMap((call) => call.body.filelist);
  assert.deepEqual(deleted, ['saved-source-b']);
  assert.equal(lifecycle.pendingReceipts().find(
    (entry) => entry.receiptID === aReceipt.receiptID
  ).state, 'leased');
});

test('failure before transfer creates no receipt and does not touch the active lease', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const a = await resolveEpisode(lifecycle, 'source-a', 1);
  await lifecycle.acquire(a._okvideo.transferReceipt.receiptID);
  const failBeforeTransfer = lifecycle.wrapPlay(async () => {
    throw new Error('mock pre-transfer failure');
  });

  await assert.rejects(
    failBeforeTransfer(request(crypto.randomUUID(), 2), null),
    /mock pre-transfer failure/
  );
  assert.equal(callsAt(harness, 'post', 'share/sharepage/save').length, 1);
  assert.equal(callsAt(harness, 'post', 'file/delete').length, 0);
  assert.equal(lifecycle.pendingReceipts()[0].state, 'leased');
});

test('same account, generation, and source coalesces duplicate transfer requests', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const requestID = crypto.randomUUID();
  const play = lifecycle.wrapPlay(async () => {
    const values = await Promise.all([
      lifecycle.download('share', 'token', 'duplicate', 'source-token'),
      lifecycle.transcode('share', 'token', 'duplicate', 'source-token')
    ]);
    return { url: values[0].download_url, urls: values[1] };
  });

  const result = await play(request(requestID, 7), null);
  assert.ok(result._okvideo.transferReceipt);
  assert.equal(callsAt(harness, 'post', 'share/sharepage/save').length, 1);
  assert.equal(lifecycle.snapshotForTesting().entries.length, 1);
});

test('CatPaw proxy requests reuse the exact receipt created by /play', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const result = await resolveProxiedEpisode(lifecycle, 'proxy-source', 8);
  const receiptID = result._okvideo.transferReceipt.receiptID;
  const proxyURLs = result.url.filter((value) => value.startsWith('http://'));
  assert.equal(proxyURLs.length, 2);
  for (const value of proxyURLs) {
    assert.equal(new URL(value).searchParams.get('_okvideoReceipt'), receiptID);
  }

  const proxy = lifecycle.wrapProxy(async (proxyRequestValue) => {
    const components = proxyRequestValue.params.fileId.split('*');
    if (proxyRequestValue.params.what === 'trans') {
      return lifecycle.transcode(
        proxyRequestValue.params.shareId,
        components[0],
        components[1],
        components[2]
      );
    }
    return lifecycle.download(
      proxyRequestValue.params.shareId,
      components[0],
      components[1],
      components[2]
    );
  });

  const download = await proxy(proxyRequest(proxyURLs[0]), createReply());
  const transcodes = await proxy(proxyRequest(proxyURLs[1]), createReply());
  assert.equal(download.download_url, 'https://media.invalid/saved-proxy-source');
  assert.equal(transcodes[0].url, 'https://media.invalid/saved-proxy-source');
  assert.equal(callsAt(harness, 'post', 'share/sharepage/save').length, 1);
});

test('proxy receipt keeps reused source FIDs isolated by playback generation', async (t) => {
  const harness = createHarness(t, { uniqueSavedFIDs: true });
  const lifecycle = harness.makeLifecycle();
  const first = await resolveProxiedEpisode(lifecycle, 'same-source', 1);
  const second = await resolveProxiedEpisode(lifecycle, 'same-source', 2);
  const firstURL = first.url.find((value) => value.startsWith('http://'));
  const secondURL = second.url.find((value) => value.startsWith('http://'));
  const proxy = lifecycle.wrapProxy(async (proxyRequestValue) => {
    const components = proxyRequestValue.params.fileId.split('*');
    return lifecycle.download(
      proxyRequestValue.params.shareId,
      components[0],
      components[1],
      components[2]
    );
  });

  const firstDownload = await proxy(proxyRequest(firstURL), createReply());
  const secondDownload = await proxy(proxyRequest(secondURL), createReply());
  assert.equal(firstDownload.download_url, 'https://media.invalid/saved-same-source-1');
  assert.equal(secondDownload.download_url, 'https://media.invalid/saved-same-source-2');
  assert.notEqual(
    first._okvideo.transferReceipt.receiptID,
    second._okvideo.transferReceipt.receiptID
  );
});

test('proxy receipt cannot authorize a different source FID', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const result = await resolveProxiedEpisode(lifecycle, 'owned-source', 1);
  const proxyURL = result.url.find((value) => value.startsWith('http://'));
  const reply = createReply();
  let proxyInvoked = false;
  const proxy = lifecycle.wrapProxy(async () => {
    proxyInvoked = true;
  });
  const forged = proxyRequest(proxyURL, {
    fileId: 'share-token*foreign-source*source-token-foreign-source'
  });

  await proxy(forged, reply);
  assert.equal(reply.statusCode, 404);
  assert.equal(reply.body, 'quark transfer receipt unavailable');
  assert.equal(proxyInvoked, false);
  assert.equal(callsAt(harness, 'post', 'share/sharepage/save').length, 1);
});

test('a reused generation in a different App request cannot reuse an old transfer', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const firstRequestID = crypto.randomUUID();
  const secondRequestID = crypto.randomUUID();

  const first = await resolveEpisode(lifecycle, 'same-source', 1, {
    requestID: firstRequestID
  });
  const second = await resolveEpisode(lifecycle, 'same-source', 1, {
    requestID: secondRequestID
  });

  assert.notEqual(
    first._okvideo.transferReceipt.receiptID,
    second._okvideo.transferReceipt.receiptID
  );
  assert.equal(first._okvideo.transferReceipt.requestID, firstRequestID);
  assert.equal(second._okvideo.transferReceipt.requestID, secondRequestID);
  assert.equal(callsAt(harness, 'post', 'share/sharepage/save').length, 2);
});

test('temporary delete failure is retried with backoff and 404 is idempotent success', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const first = await resolveEpisode(lifecycle, 'retry-file', 1);
  await lifecycle.acquire(first._okvideo.transferReceipt.receiptID);
  harness.deleteStatuses.push(503, 204);
  assert.equal((await lifecycle.release(
    first._okvideo.transferReceipt.receiptID,
    'mediaReleased'
  )).status, 'retryScheduled');
  assert.equal(lifecycle.pendingReceipts()[0].state, 'retryPending');
  harness.advance(1100);
  const retried = await lifecycle.retryPendingForCurrentAccount();
  assert.equal(retried[0].status, 'cleaned');

  const second = await resolveEpisode(lifecycle, 'missing-file', 2);
  await lifecycle.acquire(second._okvideo.transferReceipt.receiptID);
  harness.deleteStatuses.push(404);
  assert.equal((await lifecycle.release(
    second._okvideo.transferReceipt.receiptID,
    'mediaReleased'
  )).status, 'alreadyMissing');
  assert.equal(lifecycle.snapshotForTesting().entries[1].state, 'cleaned');
});

test('restart recovery deletes an unleased transfer after its orphan grace period', async (t) => {
  const harness = createHarness(t);
  const firstRuntime = harness.makeLifecycle();
  const result = await resolveEpisode(firstRuntime, 'orphan-file', 1);
  assert.equal(firstRuntime.pendingReceipts()[0].state, 'transferred');

  harness.advance(1100);
  const restartedRuntime = harness.makeLifecycle();
  const recovered = await restartedRuntime.retryPendingForCurrentAccount();
  assert.equal(recovered[0].status, 'cleaned');
  const deletion = callsAt(harness, 'post', 'file/delete').at(-1);
  assert.deepEqual(deletion.body.filelist, ['saved-orphan-file']);
  assert.equal(result._okvideo.transferReceipt.savedFIDs[0], 'saved-orphan-file');
});

test('a cancelled HTTP consumer cannot erase the Node-owned orphan receipt', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  // The response is intentionally discarded to model a client that closed
  // after Quark save completed but before it consumed /play.
  await resolveEpisode(lifecycle, 'cancelled-file', 1);
  assert.equal(lifecycle.snapshotForTesting().entries[0].state, 'transferred');
  harness.advance(1100);
  const recovered = await lifecycle.retryPendingForCurrentAccount();
  assert.equal(recovered[0].status, 'cleaned');
  assert.deepEqual(
    callsAt(harness, 'post', 'file/delete')[0].body.filelist,
    ['saved-cancelled-file']
  );
});

test('Node restart preserves a live lease, while a new App session recovers a crashed lease', async (t) => {
  const harness = createHarness(t);
  const firstRuntime = harness.makeLifecycle();
  const result = await resolveEpisode(firstRuntime, 'crash-file', 1);
  const receiptID = result._okvideo.transferReceipt.receiptID;
  await firstRuntime.acquire(receiptID);
  harness.advance(1100);

  const sameAppRestart = harness.makeLifecycle(OWNER_SESSION_ID);
  assert.deepEqual(await sameAppRestart.retryPendingForCurrentAccount(), []);
  assert.equal(callsAt(harness, 'post', 'file/delete').length, 0);

  const nextAppRuntime = harness.makeLifecycle(
    '33333333-3333-4333-8333-333333333333'
  );
  const recovered = await nextAppRuntime.retryPendingForCurrentAccount();
  assert.equal(recovered[0].status, 'cleaned');
  assert.deepEqual(
    callsAt(harness, 'post', 'file/delete')[0].body.filelist,
    ['saved-crash-file']
  );
});

test('a foreign App session cannot acquire a lease that is still in its crash grace period', async (t) => {
  const harness = createHarness(t);
  const firstRuntime = harness.makeLifecycle();
  const result = await resolveEpisode(firstRuntime, 'foreign-lease', 1);
  const receiptID = result._okvideo.transferReceipt.receiptID;
  await firstRuntime.acquire(receiptID);

  const nextAppRuntime = harness.makeLifecycle(
    '33333333-3333-4333-8333-333333333333'
  );
  assert.equal((await nextAppRuntime.acquire(receiptID)).status, 'stillInUse');
  assert.equal(callsAt(harness, 'post', 'file/delete').length, 0);
});

test('account loss preserves the receipt for a later authenticated retry', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const result = await resolveEpisode(lifecycle, 'account-file', 1);
  const receiptID = result._okvideo.transferReceipt.receiptID;
  await lifecycle.acquire(receiptID);
  harness.setCookie('');
  assert.equal((await lifecycle.release(receiptID, 'appShutdown')).status, 'accountUnavailable');
  assert.equal(callsAt(harness, 'post', 'file/delete').length, 0);

  harness.setCookie('sid=account-a; token=secret');
  harness.advance(6 * 60 * 60 * 1000 + 1);
  const recovered = await lifecycle.retryPendingForCurrentAccount();
  assert.equal(recovered[0].status, 'cleaned');
  assert.deepEqual(
    callsAt(harness, 'post', 'file/delete')[0].body.filelist,
    ['saved-account-file']
  );
});

test('corrupt ledger is quarantined instead of inferring ownership from drive contents', (t) => {
  const harness = createHarness(t);
  fs.writeFileSync(harness.ledgerPath, '{ definitely-not-json', { mode: 0o600 });
  const lifecycle = harness.makeLifecycle();
  assert.deepEqual(lifecycle.pendingReceipts(), []);
  const quarantined = fs.readdirSync(harness.directory)
    .filter((name) => name.startsWith('ledger.json.corrupt-'));
  assert.equal(quarantined.length, 1);
  assert.equal(harness.calls.length, 0);
});

test('cleanup surface accepts receipt identity rather than arbitrary file identity', async (t) => {
  const harness = createHarness(t);
  const lifecycle = harness.makeLifecycle();
  const result = await resolveEpisode(lifecycle, 'owned-file', 1);
  const receiptID = result._okvideo.transferReceipt.receiptID;
  assert.equal((await lifecycle.cleanup('saved-owned-file', 'forged')).status, 'receiptNotFound');
  assert.equal(callsAt(harness, 'post', 'file/delete').length, 0);
  assert.equal((await lifecycle.cleanup(receiptID, 'resolutionFailed')).status, 'cleaned');
  assert.deepEqual(
    callsAt(harness, 'post', 'file/delete')[0].body.filelist,
    ['saved-owned-file']
  );
});

test('account queues serialize one scope while allowing different scopes to overlap', async (t) => {
  let activeTotal = 0;
  let maximumTotal = 0;
  const activeByScope = new Map();
  const maximumByScope = new Map();
  const harness = createHarness(t, {
    beforeAPI: async (apiRequest) => {
      if (apiRequest.path !== 'share/sharepage/save') return;
      const scope = apiRequest.accountScope;
      activeTotal += 1;
      maximumTotal = Math.max(maximumTotal, activeTotal);
      const active = (activeByScope.get(scope) || 0) + 1;
      activeByScope.set(scope, active);
      maximumByScope.set(scope, Math.max(maximumByScope.get(scope) || 0, active));
      await new Promise((resolve) => setImmediate(resolve));
      await new Promise((resolve) => setImmediate(resolve));
      activeByScope.set(scope, activeByScope.get(scope) - 1);
      activeTotal -= 1;
    }
  });
  const lifecycle = harness.makeLifecycle();

  harness.setCookie('sid=account-a');
  await Promise.all([
    resolveEpisode(lifecycle, 'same-a', 1),
    resolveEpisode(lifecycle, 'same-b', 2)
  ]);
  for (const maximum of maximumByScope.values()) assert.equal(maximum, 1);

  maximumTotal = 0;
  harness.setCookie('sid=account-a');
  const accountA = resolveEpisode(lifecycle, 'parallel-a', 3);
  harness.setCookie('sid=account-b');
  const accountB = resolveEpisode(lifecycle, 'parallel-b', 4);
  await Promise.all([accountA, accountB]);
  assert.equal(maximumTotal, 2);
  for (const maximum of maximumByScope.values()) assert.equal(maximum, 1);

  const parallelCalls = callsAt(harness, 'post', 'share/sharepage/save')
    .filter((call) => call.body.fid_list[0].startsWith('parallel-'));
  assert.equal(new Set(parallelCalls.map((call) => call.accountScope)).size, 2);
  assert.equal(new Set(parallelCalls.map((call) => call.accountCookie)).size, 2);
});

test('ledger and receipt omit credentials, share tokens, and playback URLs', async (t) => {
  const secretCookie = 'sid=raw-cookie-secret; authorization=must-not-persist';
  const harness = createHarness(t, { cookie: secretCookie });
  const lifecycle = harness.makeLifecycle();
  const result = await resolveEpisode(lifecycle, 'opaque-source', 1);
  const persisted = fs.readFileSync(harness.ledgerPath, 'utf8');
  const receipt = JSON.stringify(result._okvideo.transferReceipt);
  for (const forbidden of [
    secretCookie,
    'share-token',
    'source-token-opaque-source',
    'https://media.invalid/'
  ]) {
    assert.equal(persisted.includes(forbidden), false);
    assert.equal(receipt.includes(forbidden), false);
  }
  assert.match(result._okvideo.transferReceipt.accountScope, /^[0-9a-f]{64}$/);
});
