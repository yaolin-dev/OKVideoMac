package com.okvideomac.dexbridge;

import android.content.Context;
import android.os.SystemClock;
import org.json.JSONObject;
import java.util.concurrent.Callable;
import java.util.concurrent.CancellationException;

/** Keeps a legacy asynchronous login inside the original playback worker. */
final class BridgePlaybackAuthorization {
    static Object invoke(Context context, JSONObject payload, Callable<Object> provider) throws Exception {
        if (!"play".equals(payload.optString("method"))
                || !payload.optBoolean("monitorsAuthorization", false)) return provider.call();
        String id = payload.optString("interactionID", "");
        Object initial = null;
        Exception failure = null;
        try { initial = provider.call(); }
        catch (Exception error) {
            if (error instanceof InterruptedException || error instanceof CancellationException) throw error;
            failure = error;
        }
        if (BridgeServer.isTerminalPlaybackResult(payload, initial)) return initial;

        // Some providers post a login Dialog and immediately return an error
        // instead of blocking playerContent. Do not destroy that UI before the
        // Mac has had a chance to present it. No labels/QR pixels are inspected.
        JSONObject state = null;
        long deadline = SystemClock.uptimeMillis() + 1000L;
        do {
            requireCurrent(id);
            state = BridgeActivity.uiState(context, id);
            if (state.optBoolean("uiObserved", false)) break;
            Thread.sleep(25L);
        } while (SystemClock.uptimeMillis() < deadline);
        boolean targetedLogin = false;
        if (!state.optBoolean("uiObserved", false)) {
            targetedLogin = DexSpiderRegistry.get(context).presentPlaybackLogin(payload, initial);
            if (targetedLogin) {
                long readyDeadline = SystemClock.uptimeMillis() + 6000L;
                do {
                    requireCurrent(id);
                    state = BridgeActivity.uiState(context, id);
                    if (state.optBoolean("uiObserved", false)) break;
                    Thread.sleep(25L);
                } while (SystemClock.uptimeMillis() < readyDeadline);
            }
        }
        if (!state.optBoolean("uiObserved", false)) {
            if (failure != null) throw failure;
            if (DexSpiderRegistry.providerMessage(initial).isEmpty()) {
                throw new IllegalStateException("Provider returned no playable media or authorization interface");
            }
            return initial;
        }
        BridgeInteractionRegistry.awaitPlaybackAuthorization(id);
        BridgeInteractionRegistry.setWebLinks(id, BridgeConfigurationWebView.linksFromResult(initial));
        long hiddenSince = 0L;
        deadline = SystemClock.uptimeMillis() + 590_000L;
        while (SystemClock.uptimeMillis() < deadline) {
            requireCurrent(id);
            state = BridgeActivity.uiState(context, id);
            // Never poll playerContent for login state. It may create remote
            // resources. Continue once when the native login closes or the
            // user explicitly asks to verify, retaining the same playback ID.
            boolean returnedToHost = state.optBoolean("surfaceActive", false)
                    && state.optBoolean("surfaceRequestScoped", false)
                    && "actionActivity".equals(state.optString("surfaceMode"));
            if (returnedToHost) {
                if (hiddenSince == 0L) hiddenSince = SystemClock.uptimeMillis();
            } else hiddenSince = 0L;
            if (state.optBoolean("userConfirmed", false)
                    || (hiddenSince != 0L && SystemClock.uptimeMillis() - hiddenSince >= 750L)) {
                requireCurrent(id);
                BridgeInteractionRegistry.endPlaybackAuthorization(id);
                // Explicit completion or a native dialog closing requests
                // one continuation of the SAME episode/flag/provider.
                // Dismissal is not authorization success: only a usable media
                // response can resume playback. Configuration actions are
                // never replayed, and failed authorization never loops.
                Object resumed = provider.call();
                if (!BridgeServer.isTerminalPlaybackResult(payload, resumed)) {
                    String message = DexSpiderRegistry.providerMessage(resumed);
                    throw new IllegalStateException(message.isEmpty()
                            ? "Authorization did not return playable media" : message);
                }
                return resumed;
            }
            Thread.sleep(100L);
        }
        throw new IllegalStateException("Playback authorization timed out");
    }

    private static void requireCurrent(String id) {
        if (Thread.currentThread().isInterrupted()
                || !BridgeInteractionRegistry.ownsLatest(id)
                || BridgeInteractionRegistry.terminal(id)) throw new CancellationException();
    }
}
