'use strict';

// OKVideoMac-owned lifecycle module. This file is loaded only by the
// deterministic CatPaw patch bootstrap. It deliberately has no access to a
// raw arbitrary-FID deletion API: cleanup accepts a receipt ID and resolves
// the exact saved FIDs from this module's durable ledger.

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { AsyncLocalStorage } = require('node:async_hooks');

const LEDGER_VERSION = 1;
const RECEIPT_VERSION = 1;
const PROVIDER = 'quark';
const PROXY_RECEIPT_QUERY = '_okvideoReceipt';
const CLEANABLE_STATES = new Set([
  'transferred',
  'cleanupPending',
  'orphaned',
  'retryPending'
]);

function nonEmptyString(value, maximumBytes = 4096) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  if (!normalized || Buffer.byteLength(normalized, 'utf8') > maximumBytes) {
    return null;
  }
  return normalized;
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : null;
}

function isUUID(value) {
  return typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isoDate(value) {
  const date = value instanceof Date ? value : new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function createEmptyLedger() {
  return {
    version: LEDGER_VERSION,
    folders: {},
    entries: []
  };
}

function validateLedger(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      value.version !== LEDGER_VERSION ||
      !value.folders || typeof value.folders !== 'object' ||
      Array.isArray(value.folders) || !Array.isArray(value.entries)) {
    throw new Error('transfer ledger schema rejected');
  }
  for (const entry of value.entries) {
    if (!entry || typeof entry !== 'object' ||
        !isUUID(entry.receiptID) || entry.version !== RECEIPT_VERSION ||
        entry.provider !== PROVIDER ||
        !/^[0-9a-f]{64}$/.test(String(entry.accountScope || '')) ||
        !isUUID(entry.requestID) || !positiveInteger(entry.requestGeneration) ||
        !nonEmptyString(entry.sourceFID) ||
        !Array.isArray(entry.savedFIDs) ||
        !entry.savedFIDs.every((fid) => Boolean(nonEmptyString(fid))) ||
        !nonEmptyString(entry.state, 64) ||
        (entry.leaseOwnerSessionID != null &&
          !isUUID(entry.leaseOwnerSessionID)) ||
        !isoDate(entry.createdAt) || !isoDate(entry.updatedAt)) {
      throw new Error('transfer ledger entry rejected');
    }
  }
  return value;
}

function quarantineCorruptLedger(ledgerPath, now) {
  if (!fs.existsSync(ledgerPath)) return;
  const stamp = now().toISOString().replace(/[:.]/g, '-');
  let destination = `${ledgerPath}.corrupt-${stamp}`;
  let suffix = 0;
  while (fs.existsSync(destination)) {
    suffix += 1;
    destination = `${ledgerPath}.corrupt-${stamp}-${suffix}`;
  }
  fs.renameSync(ledgerPath, destination);
}

function readLedger(ledgerPath, now) {
  if (!fs.existsSync(ledgerPath)) return createEmptyLedger();
  try {
    const data = fs.readFileSync(ledgerPath);
    if (data.length === 0 || data.length > 8 * 1024 * 1024) {
      throw new Error('transfer ledger size rejected');
    }
    return validateLedger(JSON.parse(data.toString('utf8')));
  } catch (_) {
    quarantineCorruptLedger(ledgerPath, now);
    return createEmptyLedger();
  }
}

function writeFileDurably(filePath, data) {
  const descriptor = fs.openSync(
    filePath,
    fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_WRONLY,
    0o600
  );
  try {
    fs.writeFileSync(descriptor, data);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function createQuarkTransferLifecycle(options) {
  if (!options || typeof options !== 'object') {
    throw new Error('transfer lifecycle options rejected');
  }
  const ledgerPath = path.resolve(nonEmptyString(options.ledgerPath) || '');
  const installationUUID = nonEmptyString(options.installationUUID, 128);
  const ownerSessionID = nonEmptyString(options.ownerSessionID, 128);
  const hmacKeyHex = nonEmptyString(options.hmacKeyHex, 128);
  if (!ledgerPath || !isUUID(installationUUID) || !isUUID(ownerSessionID) ||
      !hmacKeyHex || !/^[0-9a-f]{64}$/i.test(hmacKeyHex)) {
    throw new Error('transfer lifecycle identity rejected');
  }
  if (typeof options.api !== 'function' ||
      typeof options.getCookie !== 'function') {
    throw new Error('transfer lifecycle adapter rejected');
  }

  const api = options.api;
  const getCookie = options.getCookie;
  const setSourceCache = typeof options.setSourceCache === 'function'
    ? options.setSourceCache : () => {};
  const clearSourceCache = typeof options.clearSourceCache === 'function'
    ? options.clearSourceCache : () => {};
  const now = typeof options.now === 'function' ? options.now : () => new Date();
  const randomUUID = typeof options.randomUUID === 'function'
    ? options.randomUUID : () => crypto.randomUUID();
  const sleep = typeof options.sleep === 'function'
    ? options.sleep
    : (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
  const orphanGraceMilliseconds = Math.max(
    1000,
    Number(options.orphanGraceMilliseconds) || 5 * 60 * 1000
  );
  const retryBaseMilliseconds = Math.max(
    1000,
    Number(options.retryBaseMilliseconds) || 30 * 1000
  );
  const timersEnabled = options.timersEnabled !== false;
  const hmacKey = Buffer.from(hmacKeyHex, 'hex');
  const contextStorage = new AsyncLocalStorage();
  const inflightTransfers = new Map();
  const accountQueues = new Map();
  const sourceCache = new Map();
  const scheduledOrphanTimers = new Map();

  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true, mode: 0o700 });
  try { fs.chmodSync(path.dirname(ledgerPath), 0o700); } catch (_) {}
  let ledger = readLedger(ledgerPath, now);

  function persistLedger() {
    validateLedger(ledger);
    const temporary = `${ledgerPath}.tmp-${process.pid}-${randomUUID()}`;
    const data = Buffer.from(JSON.stringify(ledger), 'utf8');
    try {
      writeFileDurably(temporary, data);
      fs.renameSync(temporary, ledgerPath);
      try { fs.chmodSync(ledgerPath, 0o600); } catch (_) {}
      try {
        const directory = fs.openSync(path.dirname(ledgerPath), fs.constants.O_RDONLY);
        try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
      } catch (_) {}
    } finally {
      try { fs.unlinkSync(temporary); } catch (_) {}
    }
  }

  function currentTime() {
    const value = now();
    return value instanceof Date ? value : new Date(value);
  }

  function accountScopeForCookie(cookie) {
    const normalized = nonEmptyString(cookie, 64 * 1024);
    if (!normalized) return null;
    return crypto.createHmac('sha256', hmacKey)
      .update('quark\0', 'utf8')
      .update(normalized, 'utf8')
      .digest('hex');
  }

  function currentAccount() {
    const cookie = nonEmptyString(getCookie(), 64 * 1024);
    if (!cookie) return null;
    return { cookie, scope: accountScopeForCookie(cookie) };
  }

  function entryForReceipt(receiptID) {
    if (!isUUID(receiptID)) return null;
    return ledger.entries.find((entry) => entry.receiptID === receiptID) || null;
  }

  function transferKey(scope, requestID, generation, sourceFID) {
    return `${scope}\0${requestID}\0${generation}\0${sourceFID}`;
  }

  function existingTransfer(scope, requestID, generation, sourceFID) {
    return ledger.entries.find((entry) =>
      entry.provider === PROVIDER &&
      entry.accountScope === scope &&
      entry.requestID === requestID &&
      entry.requestGeneration === generation &&
      entry.sourceFID === sourceFID &&
      entry.state !== 'cleaned' &&
      entry.state !== 'permanentFailure'
    ) || null;
  }

  function receiptPayload(entry) {
    return {
      version: RECEIPT_VERSION,
      receiptID: entry.receiptID,
      provider: PROVIDER,
      accountScope: entry.accountScope,
      requestID: entry.requestID,
      requestGeneration: entry.requestGeneration,
      sourceFID: entry.sourceFID,
      savedFIDs: entry.savedFIDs.slice(),
      parentFolderFID: entry.parentFolderFID || null,
      createdAt: entry.createdAt
    };
  }

  function appendReceiptToProxyURL(value, receiptID) {
    if (typeof value !== 'string' || !isUUID(receiptID)) return value;
    const isTransferProxy = [
      '/proxy/quark/src/down/',
      '/proxy/quark/src/redirect/',
      '/proxy/quark/trans/'
    ].some((marker) => value.includes(marker));
    if (!isTransferProxy) return value;
    const fragmentIndex = value.indexOf('#');
    const base = fragmentIndex >= 0 ? value.slice(0, fragmentIndex) : value;
    const fragment = fragmentIndex >= 0 ? value.slice(fragmentIndex) : '';
    const separator = base.includes('?') ? '&' : '?';
    return `${base}${separator}${PROXY_RECEIPT_QUERY}=${encodeURIComponent(receiptID)}${fragment}`;
  }

  function decoratePlayResult(result, receiptID) {
    if (!result || typeof result !== 'object' || Array.isArray(result)) {
      return result;
    }
    if (Array.isArray(result.url)) {
      result.url = result.url.map((value) =>
        appendReceiptToProxyURL(value, receiptID)
      );
    } else {
      result.url = appendReceiptToProxyURL(result.url, receiptID);
    }
    return result;
  }

  function proxyReceiptID(request) {
    const value = request?.query?.[PROXY_RECEIPT_QUERY];
    return isUUID(value) ? value : null;
  }

  function proxySourceFID(request) {
    const fileID = nonEmptyString(request?.params?.fileId, 16 * 1024);
    if (!fileID) return null;
    return nonEmptyString(fileID.split('*')[1]);
  }

  function proxyPlaybackContext(request, receiptID) {
    const entry = entryForReceipt(receiptID);
    const sourceFID = proxySourceFID(request);
    const account = currentAccount();
    if (!entry || !sourceFID || !account ||
        request?.params?.site !== PROVIDER ||
        entry.accountScope !== account.scope ||
        entry.sourceFID !== sourceFID ||
        !entry.savedFIDs.length ||
        (entry.state !== 'transferred' && entry.state !== 'leased')) {
      return null;
    }
    return {
      requestID: entry.requestID,
      requestGeneration: entry.requestGeneration,
      receipt: receiptPayload(entry),
      account,
      boundReceiptID: entry.receiptID,
      allowTransferCreation: false
    };
  }

  function statusCode(result) {
    const value = Number(result && result.status);
    return Number.isInteger(value) ? value : 0;
  }

  function responseBody(result) {
    return result && Object.prototype.hasOwnProperty.call(result, 'data')
      ? result.data : null;
  }

  function responseData(result) {
    const body = responseBody(result);
    return body && typeof body === 'object' ? body.data : null;
  }

  function isSuccessful(result) {
    const status = statusCode(result);
    return status >= 200 && status < 300;
  }

  function errorCategory(result) {
    const status = statusCode(result);
    if (status === 401 || status === 403) return 'accountUnavailable';
    if (status === 408 || status === 429 || status === 0 || status >= 500) {
      return 'temporary';
    }
    return 'permanent';
  }

  function markError(entry, result, category) {
    entry.updatedAt = currentTime().toISOString();
    entry.lastErrorCode = String(statusCode(result) || 'transport');
    entry.lastErrorCategory = category;
  }

  function backoffMilliseconds(attempt) {
    const exponent = Math.max(0, Math.min(Number(attempt) - 1, 10));
    return Math.min(retryBaseMilliseconds * (2 ** exponent), 6 * 60 * 60 * 1000);
  }

  function serializeAccount(scope, operation) {
    const previous = accountQueues.get(scope) || Promise.resolve();
    const run = previous.catch(() => {}).then(operation);
    let tracked = null;
    tracked = run.finally(() => {
      if (accountQueues.get(scope) === tracked) accountQueues.delete(scope);
    });
    accountQueues.set(scope, tracked);
    return run;
  }

  async function callAPI(method, requestPath, body, account) {
    try {
      const result = await api({
        method,
        path: requestPath,
        body,
        // The credential is request-local, never persisted in the ledger and
        // never returned in a receipt. Capturing it here prevents a later
        // account switch from running an already queued operation as another
        // user.
        accountCookie: account?.cookie || null,
        accountScope: account?.scope || null
      });
      if (result && typeof result === 'object') return result;
      return { status: 0, data: null };
    } catch (_) {
      return { status: 0, data: null };
    }
  }

  async function createFolder(parentFID, name, account) {
    const result = await callAPI('post', 'file', {
      pdir_fid: parentFID,
      file_name: name,
      dir_path: '',
      dir_init_lock: false
    }, account);
    const fid = nonEmptyString(responseData(result)?.fid);
    if (!isSuccessful(result) || !fid) {
      const error = new Error('application transfer folder creation failed');
      error.result = result;
      throw error;
    }
    return fid;
  }

  async function ensureApplicationFolderUnlocked(scope, account) {
    const recorded = ledger.folders[scope];
    if (recorded && nonEmptyString(recorded.installationFolderFID)) {
      return recorded.installationFolderFID;
    }
    const folder = recorded && typeof recorded === 'object'
      ? recorded : { createdAt: currentTime().toISOString() };
    if (!nonEmptyString(folder.rootFolderFID)) {
      folder.rootFolderFID = await createFolder('0', 'OKVideoMac', account);
      folder.updatedAt = currentTime().toISOString();
      ledger.folders[scope] = folder;
      persistLedger();
    }
    folder.installationFolderFID = await createFolder(
      folder.rootFolderFID,
      installationUUID,
      account
    );
    folder.updatedAt = currentTime().toISOString();
    ledger.folders[scope] = folder;
    persistLedger();
    return folder.installationFolderFID;
  }

  function savedFIDFromTask(result) {
    const fids = responseData(result)?.save_as?.save_as_top_fids;
    return Array.isArray(fids) ? nonEmptyString(fids[0]) : null;
  }

  async function finishTransferTaskUnlocked(entry, account) {
    const taskID = nonEmptyString(entry.providerTaskID);
    if (!taskID) return null;
    for (let retryIndex = 0; retryIndex <= 5; retryIndex += 1) {
      const result = await callAPI(
        'get',
        `task?task_id=${encodeURIComponent(taskID)}&retry_index=${retryIndex}`,
        null,
        account
      );
      if (statusCode(result) === 401 || statusCode(result) === 403) {
        entry.state = 'retryPending';
        entry.cleanupAttempts += 1;
        entry.nextRetryAt = new Date(
          currentTime().getTime() + 6 * 60 * 60 * 1000
        ).toISOString();
        markError(entry, result, 'accountUnavailable');
        persistLedger();
        scheduleRecoveryCheck(entry);
        return null;
      }
      const savedFID = savedFIDFromTask(result);
      if (isSuccessful(result) && savedFID) return savedFID;
      if (retryIndex < 5) await sleep(1000);
    }
    entry.state = 'retryPending';
    entry.cleanupAttempts += 1;
    entry.nextRetryAt = new Date(
      currentTime().getTime() + backoffMilliseconds(entry.cleanupAttempts)
    ).toISOString();
    entry.updatedAt = currentTime().toISOString();
    entry.lastErrorCode = 'task-incomplete';
    entry.lastErrorCategory = 'temporary';
    persistLedger();
    scheduleRecoveryCheck(entry);
    return null;
  }

  function cacheEntry(entry) {
    if (!entry.savedFIDs.length) return;
    const value = {
      receiptID: entry.receiptID,
      accountScope: entry.accountScope,
      requestGeneration: entry.requestGeneration,
      savedFID: entry.savedFIDs[0]
    };
    sourceCache.set(entry.sourceFID, value);
    setSourceCache(entry.sourceFID, value.savedFID);
  }

  function scheduleRecoveryCheck(entry) {
    if (!timersEnabled) return;
    let targetMilliseconds = null;
    if (entry.state === 'transferred') {
      targetMilliseconds = new Date(entry.createdAt).getTime()
        + orphanGraceMilliseconds;
    } else if (entry.state === 'leased' &&
               entry.leaseOwnerSessionID !== ownerSessionID) {
      targetMilliseconds = new Date(entry.updatedAt).getTime()
        + orphanGraceMilliseconds;
    } else if (entry.state === 'retryPending' && entry.nextRetryAt) {
      targetMilliseconds = new Date(entry.nextRetryAt).getTime();
    } else if (entry.state === 'cleanupPending' || entry.state === 'orphaned') {
      targetMilliseconds = currentTime().getTime() + 1000;
    }
    if (!Number.isFinite(targetMilliseconds)) return;
    const old = scheduledOrphanTimers.get(entry.receiptID);
    if (old) clearTimeout(old);
    const delay = Math.max(1, targetMilliseconds - currentTime().getTime());
    const timer = setTimeout(() => {
      scheduledOrphanTimers.delete(entry.receiptID);
      void retryPendingForCurrentAccount();
    }, delay);
    if (typeof timer.unref === 'function') timer.unref();
    scheduledOrphanTimers.set(entry.receiptID, timer);
  }

  async function createTransferUnlocked(context, account, sourceFID, save) {
    const parentFolderFID = await ensureApplicationFolderUnlocked(
      account.scope,
      account
    );
    const timestamp = currentTime().toISOString();
    const entry = {
      version: RECEIPT_VERSION,
      receiptID: randomUUID(),
      provider: PROVIDER,
      accountScope: account.scope,
      requestID: context.requestID,
      requestGeneration: context.requestGeneration,
      sourceFID,
      savedFIDs: [],
      parentFolderFID,
      providerTaskID: null,
      createdAt: timestamp,
      updatedAt: timestamp,
      state: 'transferring',
      cleanupAttempts: 0,
      nextRetryAt: null,
      lastErrorCode: null,
      lastErrorCategory: null,
      deletedFromActiveDrive: false,
      leaseOwnerSessionID: null
    };
    ledger.entries.push(entry);
    persistLedger();

    const saveResult = await callAPI('post', 'share/sharepage/save', {
      fid_list: [sourceFID],
      fid_token_list: [save.sourceToken],
      to_pdir_fid: parentFolderFID,
      pwd_id: save.shareID,
      stoken: save.shareToken,
      pdir_fid: '0',
      scene: 'link'
    }, account);
    const taskID = nonEmptyString(responseData(saveResult)?.task_id);
    if (!isSuccessful(saveResult) || !taskID) {
      // Without a provider task ID there is no exact identity that can be
      // polled or deleted safely. Retain the record as an explicit permanent
      // failure instead of guessing a FID or retrying save and risking a
      // duplicate side effect.
      entry.state = 'permanentFailure';
      markError(entry, saveResult, 'saveOutcomeUnknown');
      persistLedger();
      throw new Error('quark transfer did not return a durable task identity');
    }
    entry.providerTaskID = taskID;
    entry.updatedAt = currentTime().toISOString();
    persistLedger();

    const savedFID = await finishTransferTaskUnlocked(entry, account);
    if (!savedFID) {
      throw new Error('quark transfer task did not return a saved file identity');
    }
    entry.savedFIDs = [savedFID];
    entry.state = 'transferred';
    entry.updatedAt = currentTime().toISOString();
    entry.nextRetryAt = null;
    entry.lastErrorCode = null;
    entry.lastErrorCategory = null;
    persistLedger();
    cacheEntry(entry);
    scheduleRecoveryCheck(entry);
    return entry;
  }

  async function resumeTransferUnlocked(entry, account) {
    if (entry.savedFIDs.length) return entry;
    const savedFID = await finishTransferTaskUnlocked(entry, account);
    if (!savedFID) return null;
    entry.savedFIDs = [savedFID];
    entry.state = 'transferred';
    entry.updatedAt = currentTime().toISOString();
    entry.nextRetryAt = null;
    entry.lastErrorCode = null;
    entry.lastErrorCategory = null;
    persistLedger();
    cacheEntry(entry);
    scheduleRecoveryCheck(entry);
    return entry;
  }

  async function deleteEntryUnlocked(entry, account, reason) {
    if (entry.state === 'cleaned') {
      return { status: 'cleaned', receiptID: entry.receiptID };
    }
    if (entry.state === 'leased') {
      return { status: 'stillInUse', receiptID: entry.receiptID };
    }
    if (!account || account.scope !== entry.accountScope) {
      entry.state = 'retryPending';
      entry.cleanupAttempts += 1;
      entry.nextRetryAt = new Date(
        currentTime().getTime() + 6 * 60 * 60 * 1000
      ).toISOString();
      entry.updatedAt = currentTime().toISOString();
      entry.lastErrorCode = 'account-unavailable';
      entry.lastErrorCategory = 'accountUnavailable';
      persistLedger();
      scheduleRecoveryCheck(entry);
      return { status: 'accountUnavailable', receiptID: entry.receiptID };
    }
    if (!entry.savedFIDs.length) {
      const resumed = await resumeTransferUnlocked(entry, account);
      if (!resumed || !entry.savedFIDs.length) {
        return { status: 'retryScheduled', receiptID: entry.receiptID };
      }
    }

    entry.state = 'cleanupPending';
    entry.updatedAt = currentTime().toISOString();
    entry.cleanupReason = nonEmptyString(reason, 64) || 'unspecified';
    persistLedger();
    const result = await callAPI('post', 'file/delete', {
      action_type: 2,
      filelist: entry.savedFIDs.slice(),
      exclude_fids: []
    }, account);
    const status = statusCode(result);
    if (isSuccessful(result) || status === 404 || status === 410) {
      entry.state = 'cleaned';
      entry.updatedAt = currentTime().toISOString();
      entry.nextRetryAt = null;
      entry.lastErrorCode = null;
      entry.lastErrorCategory = null;
      entry.deletedFromActiveDrive = true;
      persistLedger();
      const cached = sourceCache.get(entry.sourceFID);
      if (cached && cached.receiptID === entry.receiptID) {
        sourceCache.delete(entry.sourceFID);
        clearSourceCache(entry.sourceFID, cached.savedFID);
      }
      const timer = scheduledOrphanTimers.get(entry.receiptID);
      if (timer) clearTimeout(timer);
      scheduledOrphanTimers.delete(entry.receiptID);
      return {
        status: status === 404 || status === 410
          ? 'alreadyMissing' : 'cleaned',
        receiptID: entry.receiptID
      };
    }

    const category = errorCategory(result);
    entry.cleanupAttempts += 1;
    markError(entry, result, category);
    if (category === 'permanent') {
      entry.state = 'permanentFailure';
      entry.nextRetryAt = null;
      persistLedger();
      return { status: 'permanentFailure', receiptID: entry.receiptID };
    }
    entry.state = 'retryPending';
    const delay = category === 'accountUnavailable'
      ? 6 * 60 * 60 * 1000
      : backoffMilliseconds(entry.cleanupAttempts);
    entry.nextRetryAt = new Date(currentTime().getTime() + delay).toISOString();
    persistLedger();
    scheduleRecoveryCheck(entry);
    return {
      status: category === 'accountUnavailable'
        ? 'accountUnavailable' : 'retryScheduled',
      receiptID: entry.receiptID
    };
  }

  async function recoverScopeUnlocked(scope, account) {
    const currentMilliseconds = currentTime().getTime();
    const candidates = ledger.entries.filter((entry) =>
      entry.accountScope === scope && (
        CLEANABLE_STATES.has(entry.state) ||
        (entry.state === 'leased' &&
          entry.leaseOwnerSessionID !== ownerSessionID)
      )
    );
    const results = [];
    for (const entry of candidates) {
      if (entry.state === 'transferred' || entry.state === 'leased') {
        const ageAnchor = entry.state === 'leased'
          ? entry.updatedAt : entry.createdAt;
        const age = currentMilliseconds - new Date(ageAnchor).getTime();
        if (age < orphanGraceMilliseconds) {
          scheduleRecoveryCheck(entry);
          continue;
        }
        entry.state = 'orphaned';
        entry.updatedAt = currentTime().toISOString();
        persistLedger();
      }
      if (entry.state === 'retryPending' && entry.nextRetryAt &&
          new Date(entry.nextRetryAt).getTime() > currentMilliseconds) {
        scheduleRecoveryCheck(entry);
        continue;
      }
      results.push(await deleteEntryUnlocked(entry, account, 'orphanRecovery'));
    }
    return results;
  }

  async function recoverCurrentAccount(account) {
    await serializeAccount(
      account.scope,
      () => recoverScopeUnlocked(account.scope, account)
    );
  }

  async function ensureTransfer(shareID, shareToken, sourceFID, sourceToken) {
    const context = contextStorage.getStore();
    const normalizedSourceFID = nonEmptyString(sourceFID);
    const normalizedShareID = nonEmptyString(shareID);
    const normalizedShareToken = nonEmptyString(shareToken, 16 * 1024);
    const normalizedSourceToken = nonEmptyString(sourceToken, 16 * 1024);
    if (!context || !normalizedSourceFID || !normalizedShareID ||
        !normalizedShareToken || !normalizedSourceToken) {
      return null;
    }
    const account = context.account || currentAccount();
    if (!account) throw new Error('quark account unavailable');
    context.account = account;
    await recoverCurrentAccount(account);
    const key = transferKey(
      account.scope,
      context.requestID,
      context.requestGeneration,
      normalizedSourceFID
    );
    if (inflightTransfers.has(key)) {
      const entry = await inflightTransfers.get(key);
      if (entry) context.receipt = receiptPayload(entry);
      return entry?.savedFIDs?.[0] || null;
    }
    const operation = serializeAccount(account.scope, async () => {
      let entry = context.boundReceiptID
        ? entryForReceipt(context.boundReceiptID)
        : existingTransfer(
          account.scope,
          context.requestID,
          context.requestGeneration,
          normalizedSourceFID
        );
      if (entry && (
        entry.accountScope !== account.scope ||
        entry.requestID !== context.requestID ||
        entry.requestGeneration !== context.requestGeneration ||
        entry.sourceFID !== normalizedSourceFID ||
        entry.state === 'cleaned' ||
        entry.state === 'permanentFailure'
      )) {
        entry = null;
      }
      if (entry && !entry.savedFIDs.length) {
        entry = await resumeTransferUnlocked(entry, account);
      }
      if (!entry && context.allowTransferCreation === false) return null;
      if (!entry) {
        entry = await createTransferUnlocked(
          context,
          account,
          normalizedSourceFID,
          {
            shareID: normalizedShareID,
            shareToken: normalizedShareToken,
            sourceToken: normalizedSourceToken
          }
        );
      }
      return entry;
    });
    inflightTransfers.set(key, operation);
    try {
      const entry = await operation;
      if (!entry) return null;
      context.receipt = receiptPayload(entry);
      return entry.savedFIDs[0] || null;
    } finally {
      if (inflightTransfers.get(key) === operation) inflightTransfers.delete(key);
    }
  }

  async function download(shareID, shareToken, sourceFID, sourceToken) {
    const context = contextStorage.getStore();
    // A sourceFID alone cannot identify the owning request generation. Quark
    // playback is therefore allowed only inside the /play AsyncLocal context;
    // D6 remains a compatibility hint for the pinned bundle, never an
    // ownership or out-of-context lookup mechanism.
    const savedFID = context
      ? await ensureTransfer(shareID, shareToken, sourceFID, sourceToken)
      : null;
    if (!savedFID) return null;
    const result = await callAPI(
      'post',
      'file/download',
      { fids: [savedFID] },
      context?.account || currentAccount()
    );
    const data = responseData(result);
    return isSuccessful(result) && Array.isArray(data) ? data[0] || null : null;
  }

  async function transcode(shareID, shareToken, sourceFID, sourceToken) {
    const context = contextStorage.getStore();
    const savedFID = context
      ? await ensureTransfer(shareID, shareToken, sourceFID, sourceToken)
      : null;
    if (!savedFID) return null;
    const result = await callAPI('post', 'file/v2/play', {
      fid: savedFID,
      resolutions: 'normal,low,high,super,2k,4k',
      supports: 'fmp4'
    }, context?.account || currentAccount());
    const data = responseData(result);
    return isSuccessful(result) && data && Array.isArray(data.video_list)
      ? data.video_list : null;
  }

  function playbackContext(request) {
    const legacyValue = request?.body?._okvideo?.transferContext;
    const requestID = nonEmptyString(
      request?.headers?.['x-okvideo-transfer-request-id'] ||
        legacyValue?.requestID,
      64
    );
    const requestGeneration = positiveInteger(
      request?.headers?.['x-okvideo-transfer-generation'] ||
        legacyValue?.requestGeneration
    );
    if (!requestID || !isUUID(requestID) || !requestGeneration) return null;
    return { requestID, requestGeneration, receipt: null };
  }

  function wrapPlay(originalPlay) {
    if (typeof originalPlay !== 'function') {
      throw new Error('CatPaw play adapter rejected');
    }
    return async function okvideoLifecyclePlay(request, reply) {
      const context = playbackContext(request);
      if (!context) return originalPlay(request, reply);
      return contextStorage.run(context, async () => {
        try {
          const result = await originalPlay(request, reply);
          if (context.receipt && result && typeof result === 'object' &&
              !Array.isArray(result)) {
            decoratePlayResult(result, context.receipt.receiptID);
            result._okvideo = Object.assign({}, result._okvideo, {
              transferReceipt: context.receipt
            });
          }
          return result;
        } catch (error) {
          if (context.receipt) {
            await cleanup(context.receipt.receiptID, 'playURLFailure');
          }
          throw error;
        }
      });
    };
  }

  function wrapProxy(originalProxy, ensureAccount) {
    if (typeof originalProxy !== 'function') {
      throw new Error('CatPaw proxy adapter rejected');
    }
    const initialize = typeof ensureAccount === 'function'
      ? ensureAccount : async () => {};
    return async function okvideoLifecycleProxy(request, reply) {
      const suppliedReceipt = request?.query?.[PROXY_RECEIPT_QUERY];
      // noSaveMode can legitimately return a CatPaw proxy without creating a
      // transfer. Preserve that upstream path when no lifecycle capability is
      // present; a supplied but invalid capability always fails closed.
      if (suppliedReceipt == null) return originalProxy(request, reply);
      await initialize(request);
      const receiptID = proxyReceiptID(request);
      const context = receiptID
        ? proxyPlaybackContext(request, receiptID) : null;
      if (!context) {
        if (reply && typeof reply.code === 'function' &&
            typeof reply.send === 'function') {
          return reply.code(404).send('quark transfer receipt unavailable');
        }
        return null;
      }
      return contextStorage.run(
        context,
        () => originalProxy(request, reply)
      );
    };
  }

  async function acquire(receiptID) {
    const entry = entryForReceipt(receiptID);
    if (!entry) return { status: 'receiptNotFound', receiptID: receiptID || null };
    return serializeAccount(entry.accountScope, async () => {
      if (entry.state === 'cleaned') {
        return { status: 'alreadyMissing', receiptID: entry.receiptID };
      }
      if (entry.state === 'leased') {
        return {
          status: entry.leaseOwnerSessionID === ownerSessionID
            ? 'leased' : 'stillInUse',
          receiptID: entry.receiptID
        };
      }
      if (entry.state !== 'transferred') {
        return { status: 'retryScheduled', receiptID: entry.receiptID };
      }
      entry.state = 'leased';
      entry.leaseOwnerSessionID = ownerSessionID;
      entry.updatedAt = currentTime().toISOString();
      persistLedger();
      const timer = scheduledOrphanTimers.get(entry.receiptID);
      if (timer) clearTimeout(timer);
      scheduledOrphanTimers.delete(entry.receiptID);
      return { status: 'leased', receiptID: entry.receiptID };
    });
  }

  async function cleanup(receiptID, reason) {
    const entry = entryForReceipt(receiptID);
    if (!entry) return { status: 'receiptNotFound', receiptID: receiptID || null };
    const account = currentAccount();
    return serializeAccount(
      entry.accountScope,
      () => deleteEntryUnlocked(entry, account, reason)
    );
  }

  async function release(receiptID, reason) {
    const entry = entryForReceipt(receiptID);
    if (!entry) return { status: 'receiptNotFound', receiptID: receiptID || null };
    return serializeAccount(entry.accountScope, async () => {
      if (entry.state === 'cleaned') {
        return { status: 'alreadyMissing', receiptID: entry.receiptID };
      }
      if (entry.state === 'leased') {
        entry.state = 'cleanupPending';
        entry.updatedAt = currentTime().toISOString();
        persistLedger();
      }
      return deleteEntryUnlocked(entry, currentAccount(), reason || 'mediaReleased');
    });
  }

  async function retryPendingForCurrentAccount() {
    const account = currentAccount();
    if (!account) {
      const retryAt = new Date(
        currentTime().getTime() + 6 * 60 * 60 * 1000
      ).toISOString();
      let changed = false;
      for (const entry of ledger.entries) {
        if (!CLEANABLE_STATES.has(entry.state) &&
            !(entry.state === 'leased' &&
              entry.leaseOwnerSessionID !== ownerSessionID)) {
          continue;
        }
        entry.state = 'retryPending';
        entry.cleanupAttempts += 1;
        entry.nextRetryAt = retryAt;
        entry.updatedAt = currentTime().toISOString();
        entry.lastErrorCode = 'account-unavailable';
        entry.lastErrorCategory = 'accountUnavailable';
        scheduleRecoveryCheck(entry);
        changed = true;
      }
      if (changed) persistLedger();
      return [{ status: 'accountUnavailable', receiptID: null }];
    }
    return serializeAccount(
      account.scope,
      () => recoverScopeUnlocked(account.scope, account)
    );
  }

  function pendingReceipts() {
    return ledger.entries
      .filter((entry) => entry.state !== 'cleaned')
      .map((entry) => ({
        receiptID: entry.receiptID,
        provider: entry.provider,
        accountScope: entry.accountScope,
        requestID: entry.requestID,
        requestGeneration: entry.requestGeneration,
        state: entry.state,
        cleanupAttempts: entry.cleanupAttempts,
        nextRetryAt: entry.nextRetryAt,
        createdAt: entry.createdAt,
        updatedAt: entry.updatedAt
      }));
  }

  function registerRoutes(server, ensureAccount) {
    const initialize = typeof ensureAccount === 'function'
      ? ensureAccount : async () => {};
    const receiptID = (request) => nonEmptyString(request?.body?.receiptID, 64);
    server.post('/__okvideo/transfers/acquire', async (request, reply) => {
      await initialize(request);
      const value = receiptID(request);
      if (!value || !isUUID(value)) return reply.code(400).send({ status: 'receiptNotFound' });
      return acquire(value);
    });
    server.post('/__okvideo/transfers/release', async (request, reply) => {
      await initialize(request);
      const value = receiptID(request);
      if (!value || !isUUID(value)) return reply.code(400).send({ status: 'receiptNotFound' });
      return release(value, nonEmptyString(request.body?.reason, 64));
    });
    server.post('/__okvideo/transfers/cleanup', async (request, reply) => {
      await initialize(request);
      const value = receiptID(request);
      if (!value || !isUUID(value)) return reply.code(400).send({ status: 'receiptNotFound' });
      return cleanup(value, nonEmptyString(request.body?.reason, 64));
    });
    server.post('/__okvideo/transfers/retry', async (request) => {
      await initialize(request);
      return { results: await retryPendingForCurrentAccount() };
    });
    server.get('/__okvideo/transfers/pending', async () => ({
      receipts: pendingReceipts()
    }));
  }

  // Restore only exact, still-live mappings. A corrupt ledger is quarantined
  // above and never reconstructed from a directory listing.
  for (const entry of ledger.entries) {
    if ((entry.state === 'transferred' || entry.state === 'leased') &&
        entry.savedFIDs.length > 0) {
      cacheEntry(entry);
    }
    scheduleRecoveryCheck(entry);
  }

  return {
    acquire,
    cleanup,
    download,
    ensureTransfer,
    pendingReceipts,
    registerRoutes,
    release,
    retryPendingForCurrentAccount,
    transcode,
    wrapPlay,
    wrapProxy,
    accountScopeForCookie,
    snapshotForTesting: () => clone(ledger)
  };
}

module.exports = {
  createQuarkTransferLifecycle
};
