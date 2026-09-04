;
// OKVideoMac deterministic CatPaw Quark lifecycle patch, version 1.
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
  const { createQuarkTransferLifecycle } = require(lifecycleModulePath);
  const originalPlay = DM;
  const originalDownload = Vae;
  const originalTranscode = gtt;
  const originalQuarkProxy = PM;
  const originalRouteRegistration = pIn;

  const lifecycle = createQuarkTransferLifecycle({
    ledgerPath,
    installationUUID,
    ownerSessionID,
    hmacKeyHex,
    getCookie: () => qc,
    setSourceCache: (sourceFID, savedFID) => {
      D6[sourceFID] = savedFID;
    },
    clearSourceCache: (sourceFID, savedFID) => {
      if (D6[sourceFID] === savedFID) delete D6[sourceFID];
    },
    api: async (request) => {
      const separator = request.path.includes('?') ? '&' : '?';
      const url = `${xtt}/${request.path}${separator}${to}`;
      const config = {
        headers: Object.assign({}, f_, {
          Cookie: request.accountCookie || ''
        }),
        validateStatus: () => true
      };
      try {
        const response = request.method === 'get'
          ? await ge.get(url, config)
          : await ge.post(url, request.body || {}, config);
        return { status: response.status, data: response.data };
      } catch (error) {
        return {
          status: Number(error?.response?.status || 0),
          data: error?.response?.data || null
        };
      }
    }
  });

  // Quark is the only provider connected in this version. Own-drive playback
  // and every other provider retain the original implementation.
  DM = lifecycle.wrapPlay(originalPlay);
  PM = lifecycle.wrapProxy(originalQuarkProxy, async (request) => {
    await mT(request);
  });
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
    lifecycle.registerRoutes(server, async (request) => {
      await mT(request);
    });
  };
})();
