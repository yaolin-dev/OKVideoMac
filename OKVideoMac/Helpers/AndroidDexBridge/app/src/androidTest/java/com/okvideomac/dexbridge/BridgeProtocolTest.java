package com.okvideomac.dexbridge;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.text.InputType;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.ImageView;

import androidx.test.platform.app.InstrumentationRegistry;

import com.github.catvod.crawler.Spider;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.common.BitMatrix;

import junit.framework.TestCase;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.net.HttpURLConnection;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

public final class BridgeProtocolTest extends TestCase {
    public void testRequestScopedHTTPRouteAndLegacyHostRecovery() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        Intent intent = new Intent(context, BridgeActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(intent);
        Thread.sleep(500L);

        JSONObject created = request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", "http-interaction")
                        .put("kind", "ordering")
                        .put("method", "action")
        );
        assertEquals("http-interaction", created.getString("interactionID"));
        JSONObject state = request(
                "GET",
                "/v1/interactions/http-interaction/state",
                null
        );
        assertEquals("http-interaction", state.getString("interactionID"));
        assertTrue(state.has("revision"));
        assertTrue(state.has("phase"));
        assertTrue(state.has("outcome"));

        JSONObject legacy = request("GET", "/v1/ui/state", null);
        assertEquals("http-interaction", legacy.getString("interactionID"));
        assertFalse("hostUnavailable".equals(legacy.optString("outcome")));
    }

    public void testInteractionSessionsAreRequestScoped() throws Exception {
        String first = BridgeInteractionRegistry.begin(
                "interaction-one",
                "authorization",
                "action"
        );
        assertEquals("interaction-one", first);
        String second = BridgeInteractionRegistry.begin(
                "interaction-two",
                "ordering",
                "action"
        );
        assertEquals("interaction-two", second);
        assertEquals(
                "superseded",
                BridgeInteractionRegistry.state(first).getString("phase")
        );
        assertEquals(
                "started",
                BridgeInteractionRegistry.state(second).getString("phase")
        );
        assertFalse(BridgeInteractionRegistry.ownsLatest(first));
        assertTrue(BridgeInteractionRegistry.ownsLatest(second));
    }

    public void testHTTPRetryOfSupersededRequestIsRejectedWithoutStealingLatest()
            throws Exception {
        ensureBridgeServer();
        String oldID = "http-old-" + UUID.randomUUID();
        String currentID = "http-current-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", oldID)
                        .put("kind", "ordering")
                        .put("method", "action")
        );
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", currentID)
                        .put("kind", "authorization")
                        .put("method", "action")
        );

        assertEquals(
                409,
                requestStatus(
                        "POST",
                        "/v1/interactions",
                        new JSONObject()
                                .put("interactionID", oldID)
                                .put("kind", "ordering")
                                .put("method", "action")
                )
        );
        assertEquals(currentID, BridgeInteractionRegistry.latestID());
        assertTrue(BridgeInteractionRegistry.ownsLatest(currentID));
    }

    public void testSnapshotBeforeUIIsStructuredTooEarlyNotServerError()
            throws Exception {
        ensureBridgeServer();
        String id = "http-snapshot-pending-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", id)
                        .put("kind", "authorization")
                        .put("method", "action")
        );
        assertEquals(
                425,
                requestStatus(
                        "GET",
                        "/v1/interactions/" + id + "/snapshot",
                        null
                )
        );
    }

    public void testSupersededSnapshotIsStructuredConflict() throws Exception {
        ensureBridgeServer();
        String staleID = "http-snapshot-stale-" + UUID.randomUUID();
        String currentID = "http-snapshot-current-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", staleID)
                        .put("kind", "ordering")
                        .put("method", "action")
        );
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", currentID)
                        .put("kind", "authorization")
                        .put("method", "action")
        );
        assertEquals(
                409,
                requestStatus(
                        "GET",
                        "/v1/interactions/" + staleID + "/snapshot",
                        null
                )
        );
        assertEquals(currentID, BridgeInteractionRegistry.latestID());
    }

    public void testInteractionRevisionAndTerminalOutcome() throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-revision",
                "toggle",
                "action"
        );
        long initial = BridgeInteractionRegistry.state(id).getLong("revision");
        JSONObject ui = new JSONObject();
        ui.put("visible", true);
        ui.put("controls", new JSONArray().put("enabled"));
        JSONObject visible = BridgeInteractionRegistry.observeUI(id, ui);
        assertEquals("awaitingUser", visible.getString("phase"));
        assertTrue(visible.getLong("revision") > initial);
        JSONObject cancelled = BridgeInteractionRegistry.cancel(id);
        assertEquals("cancelled", cancelled.getString("phase"));
        assertEquals("cancelled", cancelled.getString("outcome"));
        assertTrue(cancelled.getBoolean("terminal"));
    }

    public void testActionWithoutUIExpectationCompletesWhenInvocationReturns()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-immediate",
                "toggle",
                "action"
        );
        // A provider that did not actually prepare a UI handoff completes on
        // return. The semantic action kind alone does not make it interactive.
        JSONObject state = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("completed", state.getString("phase"));
        assertEquals("completed", state.getString("outcome"));
        assertTrue(state.getBoolean("terminal"));
    }

    public void testDialogHandoffUsesExplicitInteractionKind() throws Exception {
        JSONObject payload = new JSONObject()
                .put("monitorsAuthorization", true);

        payload.put("interactionKind", "command");
        assertFalse(DexSpiderRegistry.requiresDialogHandoff(payload, "action"));
        payload.put("interactionKind", "immediate");
        assertFalse(DexSpiderRegistry.requiresDialogHandoff(payload, "action"));

        for (String kind : new String[]{
                "ordering",
                "toggle",
                "configuration",
                "authorization",
                "websetting",
                "nativesetting",
                "playback"
        }) {
            payload.put("interactionKind", kind);
            assertTrue(
                    kind,
                    DexSpiderRegistry.requiresDialogHandoff(
                            payload,
                            "playback".equals(kind) ? "play" : "action"
                    )
            );
        }

        payload.put("interactionKind", "authorization");
        payload.put("monitorsAuthorization", false);
        assertFalse(DexSpiderRegistry.requiresDialogHandoff(payload, "action"));
        payload.put("monitorsAuthorization", true);
        assertFalse(DexSpiderRegistry.requiresDialogHandoff(payload, "search"));
    }

    public void testInteractionKindsRemainStructuredAndUnchanged()
            throws Exception {
        for (String kind : new String[]{
                "command",
                "immediate",
                "ordering",
                "toggle",
                "configuration",
                "authorization"
        }) {
            String id = "interaction-kind-" + kind + "-" + UUID.randomUUID();
            BridgeInteractionRegistry.begin(id, kind, "action");
            assertEquals(kind, BridgeInteractionRegistry.state(id)
                    .getString("kind"));
        }
    }

    public void testCommandAndImmediateReturnWithoutUIGrace()
            throws Exception {
        for (String kind : new String[]{"command", "immediate"}) {
            String id = "interaction-fast-" + kind + "-" + UUID.randomUUID();
            BridgeInteractionRegistry.begin(id, kind, "action");
            long started = System.nanoTime();
            JSONObject returned = BridgeInteractionRegistry.invocationReturned(id);
            long elapsedMilliseconds = TimeUnit.NANOSECONDS.toMillis(
                    System.nanoTime() - started
            );
            assertTrue(kind, elapsedMilliseconds < 500L);
            assertEquals("completed", returned.getString("phase"));
            assertTrue(returned.getBoolean("terminal"));
            assertFalse(returned.getBoolean("expectsProviderUI"));
        }
    }

    public void testOrderingActionHonorsExplicitUIExpectation()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-ordering-ui",
                "ordering",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        JSONObject returned = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("ordering", returned.getString("kind"));
        assertTrue(returned.getBoolean("expectsProviderUI"));
        assertEquals("awaitingProviderUI", returned.getString("phase"));
        assertEquals("stay", returned.getString("outcome"));
        assertFalse(returned.getBoolean("terminal"));

        JSONObject visible = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", true)
                        .put("generation", 19L)
        );
        assertEquals("awaitingUser", visible.getString("phase"));
        assertFalse(visible.getBoolean("terminal"));
    }

    public void testValidPlaybackResultCompletesWithoutUIGrace() throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-playback",
                "playback",
                "play"
        );
        JSONObject playable = new JSONObject()
                .put("parse", 0)
                .put("url", "http://127.0.0.1:9978/proxy/media/session");
        BridgeInteractionRegistry.expectProviderUI(id);
        JSONObject state = BridgeInteractionRegistry.invocationReturned(
                id,
                DexSpiderRegistry.isPlayableResult(playable)
        );
        assertEquals("completed", state.getString("phase"));
        assertEquals("completed", state.getString("outcome"));
        assertTrue(state.getBoolean("terminal"));
    }

    public void testPlayableShapeOnlyTerminatesPlaybackInteractions()
            throws Exception {
        JSONObject playable = new JSONObject()
                .put("parse", 0)
                .put("url", "https://media.example/movie");
        assertTrue(BridgeServer.isTerminalPlaybackResult(
                new JSONObject().put("method", "play"),
                playable
        ));
        assertFalse(BridgeServer.isTerminalPlaybackResult(
                new JSONObject().put("method", "action"),
                playable
        ));
        assertFalse(BridgeServer.isTerminalPlaybackResult(
                new JSONObject().put("method", "detail"),
                playable
        ));
    }

    public void testHiddenUIDoesNotManufactureCompletion() throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-hidden-ui",
                "authorization",
                "action"
        );
        BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", true)
        );
        BridgeInteractionRegistry.submitted(id);
        JSONObject hidden = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", false)
        );
        assertEquals("processing", hidden.getString("phase"));
        assertEquals("stay", hidden.getString("outcome"));
        assertFalse(hidden.getBoolean("terminal"));
    }

    public void testWorkerReturnKeepsCapturedUIInHandoffGrace()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-ui-worker",
                "configuration",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", true)
        );
        JSONObject hidden = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", false)
        );
        assertEquals("processing", hidden.getString("phase"));
        JSONObject returned = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("awaitingProviderUI", returned.getString("phase"));
        assertEquals("stay", returned.getString("outcome"));
        assertFalse(returned.getBoolean("terminal"));
        assertTrue(returned.getBoolean("workerReturned"));
    }

    public void testDelayedProviderUIRemainsOwnedAfterWorkerReturns() throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-delayed-ui",
                "configuration",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        JSONObject returned = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("awaitingProviderUI", returned.getString("phase"));
        assertEquals("stay", returned.getString("outcome"));
        assertFalse(returned.getBoolean("terminal"));

        // WexConfig commonly posts its QR dialog after the Spider invocation
        // has returned. A delay over one second must still belong to the same
        // request instead of becoming a global window for the next action.
        Thread.sleep(1_100L);
        JSONObject visible = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", true)
                        .put("generation", 7L)
        );
        assertEquals(id, visible.getString("interactionID"));
        assertEquals("awaitingUser", visible.getString("phase"));
        assertEquals("stay", visible.getString("outcome"));
        assertFalse(visible.getBoolean("terminal"));
        assertTrue(visible.getBoolean("workerReturned"));
    }

    public void testMissingExpectedProviderUIFailsAndReleasesHandoffAndTrackedWorker()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-grace-release-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "configuration",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        Future<Object> worker = BridgeServer.claimInteractionWorker(
                id,
                () -> "finished-without-ui"
        );
        assertEquals("finished-without-ui", worker.get(2, TimeUnit.SECONDS));
        JSONObject pending = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("awaitingProviderUI", pending.getString("phase"));
        assertTrue(BridgeServer.hasTrackedInteractionWorker(id));

        // The provider is allowed an 8 second delayed-dialog window. If it
        // never presents the UI it promised, this is an explicit provider
        // failure rather than a fabricated success. The state poll also owns
        // release of the exact worker and disposable host.
        Thread.sleep(8_150L);
        JSONObject failed = BridgeActivity.uiState(context, id);
        assertEquals("failed", failed.getString("phase"));
        assertEquals("failed", failed.getString("outcome"));
        assertEquals("providerUIUnavailable", failed.getString("error"));
        assertTrue(failed.getBoolean("terminal"));
        assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
    }

    public void testDismissedProviderUIRequiresExplicitVerification()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-dismissed-unverified-" + UUID.randomUUID(),
                "authorization",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", true)
                        .put("generation", 9L)
        );
        BridgeInteractionRegistry.invocationReturned(id);

        JSONObject pending = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", false)
                        .put("generation", 9L)
        );
        assertEquals("awaitingVerification", pending.getString("phase"));
        assertEquals("stay", pending.getString("outcome"));
        assertFalse(pending.getBoolean("terminal"));

        // Closing a provider dialog or QR window is not proof that the
        // provider accepted the operation. Without verified(true), expiry of
        // the handoff grace must be an explicit unverified failure.
        Thread.sleep(8_150L);
        JSONObject failed = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", false)
                        .put("generation", 9L)
        );
        assertEquals("failed", failed.getString("phase"));
        assertEquals("failed", failed.getString("outcome"));
        assertEquals("providerOutcomeUnverified", failed.getString("error"));
        assertTrue(failed.getBoolean("terminal"));
        assertTrue(failed.getBoolean("uiObserved"));
        assertFalse(failed.optBoolean("verificationPerformed", false));
    }

    public void testTransientQRCodeCaptureGapKeepsStableRequestUI()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-qr-capture-gap-" + UUID.randomUUID(),
                "authorization",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        JSONObject qr = new JSONObject()
                .put("visible", true)
                .put("imageCount", 1)
                .put("qrImageCount", 1)
                .put("uiRole", "qrCode")
                .put("generation", 21L);
        JSONObject visible = BridgeInteractionRegistry.observeUI(id, qr);
        assertTrue(visible.getBoolean("visible"));
        assertEquals("qrCode", visible.getString("uiRole"));
        BridgeInteractionRegistry.invocationReturned(id);

        JSONObject transientGap = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", false)
                        .put("imageCount", 0)
                        .put("qrImageCount", 0)
                        .put("uiRole", "configuration")
                        .put("generation", 22L)
        );
        assertTrue(transientGap.getBoolean("visible"));
        assertEquals("qrCode", transientGap.getString("uiRole"));
        assertEquals(21L, transientGap.getLong("generation"));

        Thread.sleep(950L);
        JSONObject stableExit = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", false)
                        .put("imageCount", 0)
                        .put("qrImageCount", 0)
                        .put("uiRole", "configuration")
                        .put("generation", 22L)
        );
        assertFalse(stableExit.getBoolean("visible"));
        assertEquals("awaitingVerification", stableExit.getString("phase"));
        assertFalse(stableExit.getBoolean("terminal"));
        BridgeInteractionRegistry.cancel(id);
    }

    public void testAcceptedConfigurationClickCompletesAfterUIHandoffGrace()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-clicked-configuration-" + UUID.randomUUID(),
                "configuration",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", true)
                        .put("generation", 12L)
        );
        BridgeInteractionRegistry.submitted(id);
        BridgeInteractionRegistry.invocationReturned(id);

        JSONObject pending = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", false)
                        .put("generation", 13L)
        );
        assertEquals("awaitingVerification", pending.getString("phase"));
        assertFalse(pending.getBoolean("terminal"));

        Thread.sleep(8_150L);
        JSONObject completed = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", false)
                        .put("generation", 13L)
        );
        assertEquals("completed", completed.getString("phase"));
        assertEquals("completed", completed.getString("outcome"));
        assertTrue(completed.getBoolean("terminal"));
        assertFalse(completed.optBoolean("verificationPerformed", false));
    }

    public void testCancelledInteractionIgnoresLateWorkerReturn() throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-cancel-late",
                "configuration",
                "action"
        );
        BridgeInteractionRegistry.cancel(id);
        JSONObject late = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("cancelled", late.getString("phase"));
        assertEquals("cancelled", late.getString("outcome"));
        assertTrue(late.getBoolean("terminal"));
    }

    public void testSupersededInteractionCannotReclaimLatestRequest()
            throws Exception {
        String oldID = "interaction-old-" + UUID.randomUUID();
        String currentID = "interaction-current-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(oldID, "ordering", "action");
        BridgeInteractionRegistry.begin(currentID, "authorization", "action");
        assertEquals("superseded", BridgeInteractionRegistry.state(oldID)
                .getString("phase"));

        assertEquals(
                oldID,
                BridgeInteractionRegistry.begin(oldID, "ordering", "action")
        );
        assertEquals(currentID, BridgeInteractionRegistry.latestID());
        assertFalse(BridgeInteractionRegistry.ownsLatest(oldID));
        assertTrue(BridgeInteractionRegistry.ownsLatest(currentID));
    }

    public void testUnknownLateCallbackCannotStealLatestRequest()
            throws Exception {
        String currentID = "interaction-callback-current-" + UUID.randomUUID();
        String unknownID = "interaction-callback-stale-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(currentID, "ordering", "action");

        JSONObject expected = BridgeInteractionRegistry.expectProviderUI(unknownID);
        JSONObject observed = BridgeInteractionRegistry.observeUI(
                unknownID,
                new JSONObject().put("visible", true)
        );
        JSONObject returned = BridgeInteractionRegistry.invocationReturned(unknownID);

        assertEquals("missing", expected.getString("phase"));
        assertEquals("missing", observed.getString("phase"));
        assertEquals("missing", returned.getString("phase"));
        assertEquals(currentID, BridgeInteractionRegistry.latestID());
        assertTrue(BridgeInteractionRegistry.ownsLatest(currentID));
    }

    public void testOrderingDialogHandoffSurvivesWorkerReturn()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-ordering-handoff-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(id, "ordering", "action");
        BridgeActivity.beginInteraction(id);

        BridgeActivity.prepareDialogHandoff(context, id);
        assertTrue(BridgeActionActivity.isReadyFor(id));
        // A duplicate preparation for the same request is idempotent and must
        // not launch a second ActionActivity/window.
        BridgeActivity.prepareDialogHandoff(context, id);
        assertTrue(BridgeActionActivity.isReadyFor(id));

        JSONObject returned = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("awaitingProviderUI", returned.getString("phase"));
        assertFalse(returned.getBoolean("terminal"));

        BridgeActionActivity.finishIfOwnedByOther("test-cleanup");
        assertTrue(BridgeActionActivity.awaitNoForeignOwner(
                "test-cleanup",
                2_000L
        ));
        BridgeInteractionRegistry.cancel(id);
    }

    public void testCancelBeforeFirstUIPollReleasesActionHostForRetry()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String first = "interaction-cancel-before-poll-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(first, "ordering", "action");
        BridgeActivity.beginInteraction(first);
        BridgeActivity.prepareDialogHandoff(context, first);
        assertTrue(BridgeActionActivity.isReadyFor(first));

        JSONObject cancelled = BridgeActivity.dismissUI(context, first);
        assertTrue(cancelled.getBoolean("dismissed"));
        assertEquals("cancelled", cancelled.getString("phase"));
        assertTrue(BridgeActionActivity.awaitReleased(first, 2_000L));
        assertFalse(BridgeActionActivity.isReadyFor(first));

        String retry = "interaction-retry-after-cancel-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(retry, "ordering", "action");
        BridgeActivity.beginInteraction(retry);
        BridgeActivity.prepareDialogHandoff(context, retry);
        assertTrue(BridgeActionActivity.isReadyFor(retry));
        assertTrue(BridgeActionActivity.ownsInitContext(retry));
        BridgeActivity.dismissUI(context, retry);
        assertTrue(BridgeActionActivity.awaitReleased(retry, 2_000L));
    }

    public void testCancelBeforeFirstPollClosesAlreadyPostedProviderDialog()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-cancel-posted-dialog-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "configuration",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedDialog(id, "延迟出现的配置界面", null);

        // Deliberately cancel before /state has captured or assigned this
        // dialog. Terminal cleanup must still dismiss the request-owned
        // window and ActionActivity; otherwise the next action inherits it.
        JSONObject cancelled = BridgeActivity.dismissUI(context, id);
        assertEquals("cancelled", cancelled.getString("phase"));
        assertFalse(isShowing(dialog));
        assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
    }

    public void testProviderFinishHandsDialogsBackToPersistentHost()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-provider-finish-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "authorization",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedDialog(id, "即将切换到二维码", null);
        Activity disposableOwner = (Activity) com.github.catvod.Init.context();

        // Spider actions run on the Bridge worker, so exercise the real
        // off-main handoff rather than only Activity button callbacks.
        Thread finishThread = new Thread(
                disposableOwner::finish,
                "provider-finish-test"
        );
        finishThread.start();
        finishThread.join(2_000L);
        assertFalse(finishThread.isAlive());
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();

        assertFalse(isShowing(dialog));
        assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
        assertFalse(com.github.catvod.Init.context() == disposableOwner);
        BridgeInteractionRegistry.cancel(id);
    }

    public void testLegacyUntaggedLoginQRCodePromotesAndVerifies()
            throws Exception {
        ensureBridgeServer();
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-legacy-qr-login-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", id)
                        .put("kind", "configuration")
                        .put("method", "action")
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedImageDialog(id, true);

        JSONObject visible = awaitCapturedUI(context, id, 2_000L);
        assertTrue(visible.getBoolean("visible"));
        assertEquals("authorization", visible.getString("kind"));
        assertEquals("configuration", visible.getString("declaredKind"));
        assertTrue(visible.getBoolean("authorizationPromoted"));
        assertEquals("qrCode", visible.getString("uiRole"));
        assertEquals(1, visible.getInt("qrImageCount"));
        assertTrue(visible.getBoolean("authorizationCandidate"));

        // Snapshot is the host-side scan handoff. It must select only an
        // image that actually decodes as QR, without returning its payload in
        // interaction state or logs.
        byte[] snapshot = BridgeActivity.snapshotUI(context, id);
        assertTrue(snapshot.length > 100);
        assertFalse(visible.toString().contains("okvideomac-legacy-login"));

        JSONObject verified = request(
                "POST",
                "/v1/interactions/" + id + "/verify",
                new JSONObject()
                        .put("succeeded", true)
                        .put("refreshPerformed", true)
        );
        assertEquals("completed", verified.getString("phase"));
        assertFalse(isShowing(dialog));
        assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
    }

    public void testOrdinaryImageDoesNotPromoteConfigurationToAuthorization()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-ordinary-image-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "configuration",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedImageDialog(id, false);
        JSONObject visible = awaitCapturedUI(context, id, 2_000L);
        assertTrue(visible.getBoolean("visible"));
        assertEquals("configuration", visible.getString("kind"));
        assertEquals("configuration", visible.getString("uiRole"));
        assertEquals(0, visible.getInt("qrImageCount"));
        assertFalse(visible.getBoolean("authorizationCandidate"));
        BridgeActivity.dismissUI(context, id);
        assertFalse(isShowing(dialog));
    }

    public void testExplicitOrderingQRCodeRetainsOrderingSemantics()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-ordering-qr-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "ordering",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedImageDialog(id, true);
        JSONObject visible = awaitCapturedUI(context, id, 2_000L);
        assertTrue(visible.getBoolean("visible"));
        assertEquals("ordering", visible.getString("kind"));
        assertEquals("ordering", visible.getString("declaredKind"));
        assertEquals("qrCode", visible.getString("uiRole"));
        assertFalse(visible.optBoolean("authorizationPromoted", false));
        BridgeActivity.dismissUI(context, id);
        assertFalse(isShowing(dialog));
    }

    public void testSecureCredentialFormPromotesButPlainInputDoesNot()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String secureID = "interaction-secure-credential-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                secureID,
                "configuration",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, secureID);
        AlertDialog secureDialog = showOwnedInputDialog(secureID, true);
        JSONObject secure = awaitCapturedUI(context, secureID, 2_000L);
        assertEquals("authorization", secure.getString("kind"));
        assertEquals("credentialForm", secure.getString("uiRole"));
        assertEquals(1, secure.getInt("credentialInputCount"));
        BridgeActivity.dismissUI(context, secureID);
        assertFalse(isShowing(secureDialog));

        String plainID = "interaction-plain-input-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                plainID,
                "configuration",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, plainID);
        AlertDialog plainDialog = showOwnedInputDialog(plainID, false);
        JSONObject plain = awaitCapturedUI(context, plainID, 2_000L);
        assertEquals("configuration", plain.getString("kind"));
        assertEquals("configuration", plain.getString("uiRole"));
        assertEquals(0, plain.getInt("credentialInputCount"));
        BridgeActivity.dismissUI(context, plainID);
        assertFalse(isShowing(plainDialog));
    }

    public void testFiftySequentialDialogHandoffsReleaseEveryWindow()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        for (int index = 0; index < 50; index++) {
            String id = "interaction-pressure-" + index + "-"
                    + UUID.randomUUID();
            BridgeServer.beginAndActivateInteraction(
                    context,
                    id,
                    "ordering",
                    "action"
            );
            BridgeActivity.prepareDialogHandoff(context, id);
            assertTrue("handoff " + index, BridgeActionActivity.isReadyFor(id));
            AlertDialog dialog = showOwnedDialog(
                    id,
                    "网盘线路前后排序 " + index,
                    null
            );
            JSONObject visible = awaitCapturedUI(context, id, 2_000L);
            assertTrue("visible dialog " + index, visible.getBoolean("visible"));
            JSONObject dismissed = BridgeActivity.dismissUI(context, id);
            assertTrue("dismiss " + index, dismissed.getBoolean("dismissed"));
            assertTrue(
                    "release " + index,
                    BridgeActionActivity.awaitReleased(id, 2_000L)
            );
            assertFalse("dialog release " + index, isShowing(dialog));
            assertFalse(
                    "worker release " + index,
                    BridgeServer.hasTrackedInteractionWorker(id)
            );
        }
        assertFalse(BridgeActionActivity.isReady());
    }

    public void testConcurrentDuplicateInvocationClaimsOneProviderWorker()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-duplicate-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "ordering",
                "action"
        );
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AtomicInteger invocationCount = new AtomicInteger();
        AtomicReference<Future<Object>> first = new AtomicReference<>();
        AtomicReference<Future<Object>> second = new AtomicReference<>();
        AtomicReference<Throwable> claimFailure = new AtomicReference<>();
        Runnable claim = () -> {
            try {
                start.await(2, TimeUnit.SECONDS);
                Future<Object> future = BridgeServer.claimInteractionWorker(
                        id,
                        () -> {
                            invocationCount.incrementAndGet();
                            entered.countDown();
                            release.await(2, TimeUnit.SECONDS);
                            return "done";
                        }
                );
                if (!first.compareAndSet(null, future)) second.set(future);
            } catch (Throwable error) {
                claimFailure.compareAndSet(null, error);
            }
        };
        Thread one = new Thread(claim, "bridge-duplicate-one");
        Thread two = new Thread(claim, "bridge-duplicate-two");
        one.start();
        two.start();
        start.countDown();
        one.join(2_000L);
        two.join(2_000L);
        assertFalse(one.isAlive());
        assertFalse(two.isAlive());
        assertNull(claimFailure.get());
        assertTrue(entered.await(2, TimeUnit.SECONDS));
        assertNotNull(first.get());
        assertSame(first.get(), second.get());
        assertEquals(1, invocationCount.get());
        release.countDown();
        assertEquals("done", first.get().get(2, TimeUnit.SECONDS));
        BridgeInteractionRegistry.invocationReturned(id);
        BridgeServer.releaseTerminalInteraction(context, id);
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
    }

    public void testCancellingDuplicateClaimLeavesNoUntrackedWorker()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-cancel-duplicate-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "ordering",
                "action"
        );
        CountDownLatch entered = new CountDownLatch(1);
        AtomicInteger invocationCount = new AtomicInteger();
        Future<Object> first = BridgeServer.claimInteractionWorker(id, () -> {
            invocationCount.incrementAndGet();
            entered.countDown();
            Thread.sleep(TimeUnit.MINUTES.toMillis(5));
            return "late";
        });
        Future<Object> duplicate = BridgeServer.claimInteractionWorker(
                id,
                () -> {
                    invocationCount.incrementAndGet();
                    return "duplicate";
                }
        );
        assertSame(first, duplicate);
        assertTrue(entered.await(2, TimeUnit.SECONDS));
        BridgeInteractionRegistry.cancel(id);
        BridgeServer.releaseTerminalInteraction(context, id);
        assertTrue(first.isCancelled() || first.isDone());
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
        assertEquals(1, invocationCount.get());
    }

    public void testConcurrentDistinctBeginsLeaveOnlyLatestOwnerAndWorker()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String original = "interaction-distinct-original-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                original,
                "ordering",
                "action"
        );
        BridgeActivity.prepareDialogHandoff(context, original);
        AlertDialog originalDialog = showOwnedDialog(
                original,
                "旧排序窗口",
                null
        );
        awaitCapturedUI(context, original, 2_000L);
        Future<Object> originalWorker = BridgeServer.claimInteractionWorker(
                original,
                () -> {
                    Thread.sleep(TimeUnit.MINUTES.toMillis(5));
                    return "late";
                }
        );

        String first = "interaction-distinct-a-" + UUID.randomUUID();
        String second = "interaction-distinct-b-" + UUID.randomUUID();
        CountDownLatch start = new CountDownLatch(1);
        AtomicReference<Throwable> beginFailure = new AtomicReference<>();
        Thread one = new Thread(() -> {
            try {
                start.await(2, TimeUnit.SECONDS);
                BridgeServer.beginAndActivateInteraction(
                        context,
                        first,
                        "toggle",
                        "action"
                );
            } catch (Throwable error) {
                beginFailure.compareAndSet(null, error);
            }
        }, "bridge-distinct-a");
        Thread two = new Thread(() -> {
            try {
                start.await(2, TimeUnit.SECONDS);
                BridgeServer.beginAndActivateInteraction(
                        context,
                        second,
                        "authorization",
                        "action"
                );
            } catch (Throwable error) {
                beginFailure.compareAndSet(null, error);
            }
        }, "bridge-distinct-b");
        one.start();
        two.start();
        start.countDown();
        one.join(4_000L);
        two.join(4_000L);
        assertFalse(one.isAlive());
        assertFalse(two.isAlive());
        assertNull(beginFailure.get());

        String latest = BridgeInteractionRegistry.latestID();
        String superseded = latest.equals(first) ? second : first;
        assertTrue(latest.equals(first) || latest.equals(second));
        assertTrue(BridgeInteractionRegistry.ownsLatest(latest));
        assertEquals(
                "superseded",
                BridgeInteractionRegistry.state(superseded).getString("phase")
        );
        assertEquals(
                "superseded",
                BridgeInteractionRegistry.state(original).getString("phase")
        );
        assertTrue(originalWorker.isCancelled() || originalWorker.isDone());
        assertFalse(BridgeServer.hasTrackedInteractionWorker(original));
        assertFalse(BridgeServer.hasTrackedInteractionWorker(superseded));
        assertFalse(isShowing(originalDialog));
        assertTrue(BridgeActionActivity.awaitReleased(original, 2_000L));

        BridgeActivity.prepareDialogHandoff(context, latest);
        assertTrue(BridgeActionActivity.isReadyFor(latest));
        assertTrue(BridgeActionActivity.ownsInitContext(latest));
        BridgeActivity.dismissUI(context, latest);
    }

    public void testPlayableTerminalReleaseClosesExactDialogAndWorker()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-playable-release-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "authorization",
                "play"
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedDialog(id, "播放授权", null);
        awaitCapturedUI(context, id, 2_000L);
        Future<Object> worker = BridgeServer.claimInteractionWorker(
                id,
                () -> "playable"
        );
        assertEquals("playable", worker.get(2, TimeUnit.SECONDS));
        JSONObject completed = BridgeInteractionRegistry.invocationReturned(
                id,
                true
        );
        assertTrue(completed.getBoolean("terminal"));
        BridgeServer.releaseTerminalInteraction(context, id);
        assertFalse(isShowing(dialog));
        assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
    }

    public void testVerifyTerminalReleaseClosesRequestOwnedDialog()
            throws Exception {
        ensureBridgeServer();
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-verify-release-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", id)
                        .put("kind", "authorization")
                        .put("method", "action")
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedDialog(id, "扫码登录", null);
        awaitCapturedUI(context, id, 2_000L);
        JSONObject verified = request(
                "POST",
                "/v1/interactions/" + id + "/verify",
                new JSONObject()
                        .put("succeeded", true)
                        .put("refreshPerformed", true)
        );
        assertEquals("completed", verified.getString("phase"));
        assertFalse(isShowing(dialog));
        assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
    }

    public void testSupersededSubmitReturnsConflictWithoutClickingOldDialog()
            throws Exception {
        ensureBridgeServer();
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String oldID = "interaction-submit-old-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", oldID)
                        .put("kind", "ordering")
                        .put("method", "action")
        );
        BridgeActivity.prepareDialogHandoff(context, oldID);
        AtomicInteger clicks = new AtomicInteger();
        AlertDialog oldDialog = showOwnedDialog(
                oldID,
                "自定网盘排序",
                clicks
        );
        JSONObject captured = awaitCapturedUI(context, oldID, 2_000L);
        assertTrue(captured.getBoolean("visible"));

        String currentID = "interaction-submit-current-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", currentID)
                        .put("kind", "authorization")
                        .put("method", "action")
        );
        assertEquals(
                409,
                requestStatus(
                        "POST",
                        "/v1/interactions/" + oldID + "/submit",
                        new JSONObject().put("button", "应用")
                )
        );
        assertEquals(0, clicks.get());
        assertFalse(isShowing(oldDialog));
        assertEquals(
                "superseded",
                BridgeInteractionRegistry.state(oldID).getString("phase")
        );
        BridgeInteractionRegistry.cancel(currentID);
        BridgeServer.releaseTerminalInteraction(context, currentID);
    }

    public void testCancelEndpointInterruptsTrackedWorker() throws Exception {
        FutureTask<Void> worker = new FutureTask<>(() -> {
            Thread.sleep(TimeUnit.MINUTES.toMillis(5));
            return null;
        });
        Thread thread = new Thread(worker, "bridge-cancel-test");
        BridgeServer.trackInteractionWorker("cancel-worker", worker);
        thread.start();
        assertTrue(BridgeServer.cancelInteractionWorker("cancel-worker"));
        thread.join(1_000L);
        assertTrue(worker.isCancelled());
        assertFalse(thread.isAlive());
    }

    public void testMissingAndUnavailableStatesUseFixedSchema() throws Exception {
        JSONObject missing = BridgeInteractionRegistry.state(
                "missing-interaction-schema"
        );
        assertTrue(missing.getBoolean("terminal"));
        assertFalse(missing.getBoolean("visible"));
        assertEquals("", missing.getString("title"));
        assertEquals(0, missing.getInt("inputCount"));
        assertNotNull(missing.getJSONArray("buttons"));
        assertNotNull(missing.getJSONArray("controls"));

        String id = BridgeInteractionRegistry.begin(
                "unavailable-schema",
                "configuration",
                "action"
        );
        JSONObject unavailable = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject()
                        .put("visible", false)
                        .put("hostUnavailable", true)
        );
        assertEquals("reattaching", unavailable.getString("phase"));
        assertFalse(unavailable.getBoolean("visible"));
        assertTrue(unavailable.has("buttons"));
        assertTrue(unavailable.has("controls"));
    }

    public void testProviderVerificationTerminatesInteraction() throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-verification",
                "authorization",
                "action"
        );
        BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", true)
        );
        BridgeInteractionRegistry.submitted(id);
        JSONObject completed = BridgeInteractionRegistry.verified(
                id,
                true,
                "",
                Boolean.TRUE
        );
        assertEquals("completed", completed.getString("phase"));
        assertEquals("completed", completed.getString("outcome"));
        assertTrue(completed.getBoolean("terminal"));
        assertTrue(completed.getBoolean("verificationPerformed"));
        assertTrue(completed.getBoolean("refreshPerformed"));
    }

    public void testRemotePlaybackWithProviderHeadersStaysPlayerOwned()
            throws Exception {
        JSONObject result = new JSONObject();
        result.put("parse", 0);
        String mediaURL = "https://media.example/video.mp4?signature=secret";
        result.put("url", mediaURL);
        result.put(
                "header",
                new JSONObject()
                        .put("Cookie", "BDUSS=secret")
                        .put("Referer", "https://pan.example/")
        );
        JSONObject secured = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(result);
        assertEquals(mediaURL, secured.getString("url"));
        assertFalse(secured.has("mediaSessionID"));
        assertFalse(secured.has("upstreamFingerprint"));
        assertEquals(
                "BDUSS=secret",
                secured.getJSONObject("header").getString("Cookie")
        );
        assertEquals(
                "https://pan.example/",
                secured.getJSONObject("header").getString("Referer")
        );
        assertFalse(secured.getBoolean("refreshPerformed"));
    }

    public void testPlainRemotePlaybackKeepsDirectPlayerFastPath()
            throws Exception {
        String mediaURL = "https://media.example/video.mp4?signature=fixture";
        JSONObject result = new JSONObject()
                .put("parse", 0)
                .put("url", mediaURL)
                .put("header", new JSONObject()
                        .put("User-Agent", "Fixture Agent")
                        .put("Referer", "https://site.example/"));

        JSONObject secured = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(result);

        assertEquals(mediaURL, secured.getString("url"));
        assertFalse(secured.has("mediaSessionID"));
        assertFalse(secured.has("upstreamFingerprint"));
        assertEquals(
                "Fixture Agent",
                secured.getJSONObject("header").getString("User-Agent")
        );
        assertEquals(
                "https://site.example/",
                secured.getJSONObject("header").getString("Referer")
        );
    }

    public void testMediaSessionLeavesTruncatedRangeRecoveryToPlayer()
            throws Exception {
        ensureBridgeServer();
        InetAddress loopback = InetAddress.getByName("127.0.0.1");
        try (ServerSocket providerServer = new ServerSocket(0, 2, loopback)) {
            providerServer.setSoTimeout(5_000);
            FutureTask<List<Map<String, String>>> providerRequests =
                    new FutureTask<>(() -> {
                        List<Map<String, String>> requests = new ArrayList<>();
                        requests.add(serveOnce(
                                providerServer,
                                "HTTP/1.1 206 Partial Content\r\n"
                                        + "Content-Type: video/mp4\r\n"
                                        + "Content-Range: bytes 0-9/10\r\n"
                                        + "Content-Length: 10\r\n"
                                        + "ETag: \"stream-v1\"\r\n"
                                        + "Connection: close\r\n\r\n"
                                        + "01234"
                        ));
                        requests.add(serveOnce(
                                providerServer,
                                "HTTP/1.1 206 Partial Content\r\n"
                                        + "Content-Type: video/mp4\r\n"
                                        + "Content-Range: bytes 5-9/10\r\n"
                                        + "Content-Length: 5\r\n"
                                        + "ETag: \"stream-v1\"\r\n"
                                        + "Connection: close\r\n\r\n"
                                        + "56789"
                        ));
                        return requests;
                    });
            new Thread(providerRequests, "media-player-range-retry-test").start();

            JSONObject secured = (JSONObject)
                    BridgeMediaSessionRegistry.securePlaybackResult(
                            new JSONObject()
                                    .put("parse", 0)
                                    .put(
                                            "url",
                                            "http://127.0.0.1:"
                                                    + providerServer.getLocalPort()
                                                    + "/movie.mp4"
                                    )
                    );
            ByteArrayOutputStream firstBytes = new ByteArrayOutputStream();
            HttpURLConnection first = (HttpURLConnection) new URL(
                    secured.getString("url")
            ).openConnection();
            first.setConnectTimeout(2_000);
            first.setReadTimeout(5_000);
            first.setRequestProperty("Range", "bytes=0-9");
            assertEquals(206, first.getResponseCode());
            try (InputStream input = first.getInputStream()) {
                byte[] buffer = new byte[16];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    firstBytes.write(buffer, 0, count);
                }
                fail("A truncated range must remain visible to the player");
            } catch (java.io.IOException expected) {
                // The player owns the next request after this premature EOF.
            } finally {
                first.disconnect();
            }
            assertEquals(
                    "01234",
                    firstBytes.toString(StandardCharsets.US_ASCII.name())
            );

            HttpURLConnection retry = (HttpURLConnection) new URL(
                    secured.getString("url")
            ).openConnection();
            retry.setConnectTimeout(2_000);
            retry.setReadTimeout(5_000);
            retry.setRequestProperty("Range", "bytes=5-9");
            assertEquals(206, retry.getResponseCode());
            assertEquals("56789", readText(retry.getInputStream()));
            retry.disconnect();

            List<Map<String, String>> requests = providerRequests.get(
                    5,
                    TimeUnit.SECONDS
            );
            assertEquals("bytes=0-9", header(requests.get(0), "range"));
            assertEquals("bytes=5-9", header(requests.get(1), "range"));
        }
    }

    public void testMediaSessionDoesNotRetryZeroProgressRange()
            throws Exception {
        ensureBridgeServer();
        InetAddress loopback = InetAddress.getByName("127.0.0.1");
        try (ServerSocket providerServer = new ServerSocket(0, 2, loopback)) {
            providerServer.setSoTimeout(5_000);
            FutureTask<Map<String, String>> providerRequest =
                    new FutureTask<>(() -> serveOnce(
                            providerServer,
                            "HTTP/1.1 206 Partial Content\r\n"
                                    + "Content-Type: video/mp4\r\n"
                                    + "Content-Range: bytes 0-9/10\r\n"
                                    + "Content-Length: 10\r\n"
                                    + "Connection: close\r\n\r\n"
                    ));
            new Thread(providerRequest, "media-zero-progress-test").start();

            JSONObject secured = (JSONObject)
                    BridgeMediaSessionRegistry.securePlaybackResult(
                            new JSONObject()
                                    .put("parse", 0)
                                    .put(
                                            "url",
                                            "http://127.0.0.1:"
                                                    + providerServer.getLocalPort()
                                                    + "/movie.mp4"
                                    )
                    );
            HttpURLConnection mediaConnection = (HttpURLConnection) new URL(
                    secured.getString("url")
            ).openConnection();
            mediaConnection.setConnectTimeout(2_000);
            mediaConnection.setReadTimeout(5_000);
            mediaConnection.setRequestProperty("Range", "bytes=0-9");
            assertEquals(206, mediaConnection.getResponseCode());
            boolean interrupted = false;
            try (InputStream input = mediaConnection.getInputStream()) {
                while (input.read() != -1) {
                    fail("Zero-progress upstream must not produce media bytes");
                }
            } catch (java.io.IOException expected) {
                interrupted = true;
            } finally {
                mediaConnection.disconnect();
            }

            assertTrue(interrupted);
            Map<String, String> request = providerRequest.get(
                    5,
                    TimeUnit.SECONDS
            );
            assertEquals("bytes=0-9", header(request, "range"));
            providerServer.setSoTimeout(500);
            try (Socket unexpected = providerServer.accept()) {
                fail("Zero progress must not trigger an internal Range retry");
            } catch (SocketTimeoutException expected) {
                // The bridge closes this response and waits for the player.
            }
        }
    }

    public void testRequestScopedSiteHeadersEnterMediaSessionWithResultPrecedence()
            throws Exception {
        JSONObject siteHeaders = new JSONObject()
                .put("Cookie", "site-secret")
                .put("User-Agent", "site-agent")
                .put("Origin", "https://site.example/");
        JSONObject result = new JSONObject()
                .put("parse", 0)
                .put("url", "http://127.0.0.1:6677/context.mkv")
                .put("headers", new JSONObject()
                        .put("cookie", "player-secret")
                        .put("Referer", "https://player.example/"));

        JSONObject secured = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(
                        result,
                        false,
                        siteHeaders
                );
        BridgeMediaSessionRegistry.Session session =
                BridgeMediaSessionRegistry.get(
                        secured.getString("mediaSessionID")
                );
        assertNotNull(session);
        Map<String, String> headers = session.headerSnapshot();
        assertEquals("player-secret", header(headers, "cookie"));
        assertEquals("site-agent", header(headers, "user-agent"));
        assertEquals(
                "https://site.example/",
                header(headers, "origin")
        );
        assertEquals(
                "https://player.example/",
                header(headers, "referer")
        );
        assertFalse(secured.has("header"));
        assertFalse(secured.has("headers"));
        assertFalse(secured.toString().contains("site-secret"));
        assertFalse(secured.toString().contains("player-secret"));
    }

    public void testMediaSessionFingerprintIncludesRequestContext()
            throws Exception {
        String mediaURL = "http://127.0.0.1:6677/fingerprint.mkv";
        JSONObject first = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(
                        new JSONObject().put("parse", 0).put("url", mediaURL),
                        false,
                        new JSONObject()
                                .put("Cookie", "generation-one")
                                .put("User-Agent", "fixture-agent")
                );
        JSONObject repeated = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(
                        new JSONObject().put("parse", 0).put("url", mediaURL),
                        false,
                        new JSONObject()
                                .put("user-agent", "fixture-agent")
                                .put("cookie", "generation-one")
                );
        JSONObject changed = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(
                        new JSONObject().put("parse", 0).put("url", mediaURL),
                        false,
                        new JSONObject()
                                .put("Cookie", "generation-two")
                                .put("User-Agent", "fixture-agent")
                );

        assertEquals(
                first.getString("upstreamFingerprint"),
                repeated.getString("upstreamFingerprint")
        );
        assertFalse(first.getString("upstreamFingerprint").equals(
                changed.getString("upstreamFingerprint")
        ));
    }

    public void testExpiredBridgeCapabilityIsRejectedInsteadOfWrapped()
            throws Exception {
        String missingID = "missing-" + UUID.randomUUID();
        String staleURL = "http://127.0.0.1:9978/proxy/media/"
                + missingID;
        try {
            BridgeMediaSessionRegistry.securePlaybackResult(
                    new JSONObject()
                            .put("parse", 0)
                            .put("url", staleURL)
                            .put("headers", new JSONObject()
                                    .put("Cookie", "must-not-migrate"))
            );
            fail("stale media capability must be rejected");
        } catch (IllegalStateException error) {
            assertEquals(
                    "Media session expired or missing",
                    error.getMessage()
            );
        }
        assertNull(BridgeMediaSessionRegistry.get(missingID));
    }

    public void testDexPlaybackPlumbsSiteHeadersIntoSecureSession()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        DexSpiderRegistry registry = DexSpiderRegistry.get(context);
        Method invokePlayer = DexSpiderRegistry.class.getDeclaredMethod(
                "invokePlayer",
                JSONObject.class,
                Spider.class,
                JSONArray.class,
                BridgeProviderOwnerRegistry.Binding.class
        );
        invokePlayer.setAccessible(true);
        String suffix = UUID.randomUUID().toString();
        JSONObject payload = new JSONObject()
                .put("siteKey", "site-context-" + suffix)
                .put("configurationID", "configuration-context-" + suffix)
                .put("providerOwnerID", "provider-context-" + suffix)
                .put("jarURL", "https://unit.invalid/" + suffix + ".jar")
                .put("jarMD5", "")
                .put("siteHeaders", new JSONObject()
                        .put("Cookie", "site-cookie")
                        .put("User-Agent", "site-agent"));
        JSONArray arguments = new JSONArray()
                .put("line")
                .put("episode")
                .put(new JSONArray());
        Spider spider = new Spider() {
            @Override
            public String playerContent(
                    String flag,
                    String id,
                    java.util.List<String> vipFlags
            ) throws Exception {
                return new JSONObject()
                        .put("parse", 0)
                        .put(
                                "url",
                                "http://127.0.0.1:6677/" + suffix + ".mkv"
                        )
                        .put("headers", new JSONObject()
                                .put("cookie", "player-cookie"))
                        .toString();
            }
        };

        JSONObject secured = (JSONObject) invokePlayer.invoke(
                registry,
                payload,
                spider,
                arguments,
                BridgeProviderOwnerRegistry.bind(
                        payload,
                        payload.getString("jarURL")
                )
        );
        BridgeMediaSessionRegistry.Session session =
                BridgeMediaSessionRegistry.get(
                        secured.getString("mediaSessionID")
                );
        assertNotNull(session);
        assertEquals(
                "player-cookie",
                header(session.headerSnapshot(), "cookie")
        );
        assertEquals(
                "site-agent",
                header(session.headerSnapshot(), "user-agent")
        );
    }

    public void testParseRequiredStaysUnchangedAndLoopbackMediaIsScoped()
            throws Exception {
        JSONObject parsed = new JSONObject()
                .put("parse", 1)
                .put("url", "https://parser.example/?url=target");
        BridgeMediaSessionRegistry.securePlaybackResult(parsed);
        assertEquals(
                "https://parser.example/?url=target",
                parsed.getString("url")
        );

        for (String localURL : new String[] {
                "http://127.0.0.1:5266/fishplay/go/quark_vip/movie.mkv",
                "http://127.0.0.1:43127/provider-dynamic/movie.m3u8",
                "http://127.0.0.1:6677/proxy/play/movie.mkv"
        }) {
            JSONObject loopback = new JSONObject()
                    .put("parse", 0)
                    .put("url", localURL);
            BridgeMediaSessionRegistry.securePlaybackResult(loopback);
            assertTrue(loopback.getString("url").startsWith(
                    "http://127.0.0.1:9978/proxy/media/"
            ));
            String sessionID = loopback.getString("mediaSessionID");
            BridgeMediaSessionRegistry.Session session =
                    BridgeMediaSessionRegistry.get(sessionID);
            assertNotNull(session);
            assertEquals(localURL, session.upstreamURL);
        }
    }

    public void testDynamicLoopbackMediaWithoutHeadersStreamsThroughBridge()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        BridgeServer.start(context);
        Thread.sleep(250L);
        InetAddress loopback = InetAddress.getByName("127.0.0.1");
        try (ServerSocket providerServer = new ServerSocket(0, 1, loopback)) {
            providerServer.setSoTimeout(5_000);
            FutureTask<Map<String, String>> providerRequest =
                    new FutureTask<>(() -> serveOnce(
                            providerServer,
                            "HTTP/1.1 200 OK\r\n"
                                    + "Content-Type: video/mp4\r\n"
                                    + "Content-Length: 2\r\n"
                                    + "Connection: close\r\n\r\nOK"
                    ));
            new Thread(providerRequest, "dynamic-media-test").start();

            String providerURL = "http://127.0.0.1:"
                    + providerServer.getLocalPort()
                    + "/fishplay/go/quark_vip/movie.mkv";
            JSONObject result = new JSONObject()
                    .put("parse", 0)
                    .put("url", providerURL);
            JSONObject secured = (JSONObject)
                    BridgeMediaSessionRegistry.securePlaybackResult(result);
            HttpURLConnection connection = (HttpURLConnection) new URL(
                    secured.getString("url")
            ).openConnection();
            connection.setConnectTimeout(2_000);
            connection.setReadTimeout(5_000);
            assertEquals(200, connection.getResponseCode());
            try (InputStream input = connection.getInputStream()) {
                assertEquals('O', input.read());
                assertEquals('K', input.read());
                assertEquals(-1, input.read());
            } finally {
                connection.disconnect();
            }
            assertEquals(
                    "GET /fishplay/go/quark_vip/movie.mkv HTTP/1.1",
                    providerRequest.get(5, TimeUnit.SECONDS).get(":request")
            );
        }
    }

    public void testNestedSignedURLStaysInsideProviderLoopbackSession()
            throws Exception {
        String providerProxy = "http://127.0.0.1:9978/proxy?do=play"
                + "&url=https%3A%2F%2Fsigned.example%2Fmovie.mkv%3Ftoken%3Done"
                + "&expires=two";
        JSONObject result = new JSONObject()
                .put("parse", 0)
                .put("url", providerProxy)
                .put("headers", new JSONObject().put("Cookie", "secret"));
        JSONObject secured = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(result);
        String localURL = secured.getString("url");
        assertTrue(localURL.startsWith(
                "http://127.0.0.1:9978/proxy/media/"
        ));
        BridgeMediaSessionRegistry.Session session = BridgeMediaSessionRegistry.get(
                localURL.substring(localURL.lastIndexOf('/') + 1)
        );
        assertNotNull(session);
        assertEquals(providerProxy, session.upstreamURL);
        assertEquals("secret", session.headers.get("Cookie"));
        assertFalse(secured.has("headers"));
        assertEquals(
                session.id,
                secured.getString("mediaSessionID")
        );
        assertEquals(
                session.upstreamFingerprint,
                secured.getString("upstreamFingerprint")
        );
    }

    public void testOrdinaryLoopbackWithHeadersBecomesOwnedSession()
            throws Exception {
        JSONObject result = new JSONObject()
                .put("parse", 0)
                .put("url", "http://127.0.0.1:6677/proxy/play")
                .put("headers", new JSONObject()
                        .put("Referer", "https://provider.example/")
                        .put("Cookie", "secret"));
        JSONObject secured = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(result);
        String localURL = secured.getString("url");
        assertTrue(localURL.startsWith(
                "http://127.0.0.1:9978/proxy/media/"
        ));
        String id = localURL.substring(localURL.lastIndexOf('/') + 1);
        assertEquals(id, secured.getString("mediaSessionID"));
        BridgeMediaSessionRegistry.Session session =
                BridgeMediaSessionRegistry.get(id);
        assertNotNull(session);
        assertEquals(
                "http://127.0.0.1:6677/proxy/play",
                session.upstreamURL
        );
        assertEquals("secret", session.headers.get("Cookie"));
        assertFalse(secured.has("headers"));
    }

    public void testIssuedSessionIsNotWrappedTwiceAndRefreshIsExplicit()
            throws Exception {
        JSONObject first = new JSONObject()
                .put("parse", 0)
                .put("url", "http://127.0.0.1:6677/refresh.mkv?token=one")
                .put("headers", new JSONObject().put("Cookie", "first"));
        JSONObject secured = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(first, true);
        String issuedURL = secured.getString("url");
        String issuedID = secured.getString("mediaSessionID");
        assertTrue(secured.getBoolean("refreshPerformed"));

        JSONObject repeated = new JSONObject()
                .put("parse", 0)
                .put("url", issuedURL)
                .put("header", new JSONObject().put("Referer", "https://ref/"));
        JSONObject securedAgain = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(repeated, false);
        assertEquals(issuedURL, securedAgain.getString("url"));
        assertEquals(issuedID, securedAgain.getString("mediaSessionID"));
        assertFalse(securedAgain.has("header"));
        BridgeMediaSessionRegistry.Session session =
                BridgeMediaSessionRegistry.get(issuedID);
        assertNotNull(session);
        assertEquals("https://ref/", session.headers.get("Referer"));
    }

    public void testPlaybackRefreshFlagsAreProviderNeutral() throws Exception {
        assertTrue(DexSpiderRegistry.requestsPlaybackRefresh(
                new JSONObject().put("refreshPlayback", true)
        ));
        assertTrue(DexSpiderRegistry.requestsPlaybackRefresh(
                new JSONObject().put("bypassPlaybackCache", true)
        ));
        assertFalse(DexSpiderRegistry.requestsPlaybackRefresh(
                new JSONObject()
        ));
    }

    public void testPlaybackLocksStaySharedUntilEveryWaiterReleases()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        DexSpiderRegistry registry = DexSpiderRegistry.get(context);
        Method retain = DexSpiderRegistry.class.getDeclaredMethod(
                "retainPlaybackLock",
                String.class
        );
        retain.setAccessible(true);
        String key = "lock-test-" + UUID.randomUUID();
        Object first = retain.invoke(registry, key);
        Object second = retain.invoke(registry, key);
        assertSame(first, second);

        Method release = DexSpiderRegistry.class.getDeclaredMethod(
                "releasePlaybackLock",
                String.class,
                first.getClass()
        );
        release.setAccessible(true);
        Field locksField = DexSpiderRegistry.class.getDeclaredField(
                "playbackLocks"
        );
        locksField.setAccessible(true);
        Map<?, ?> locks = (Map<?, ?>) locksField.get(registry);

        release.invoke(registry, key, first);
        assertSame(first, locks.get(key));
        Object third = retain.invoke(registry, key);
        assertSame(first, third);
        release.invoke(registry, key, second);
        assertSame(first, locks.get(key));
        release.invoke(registry, key, third);
        assertFalse(locks.containsKey(key));
    }

    public void testRefreshInvalidatesPlaybackCompletedWhileWaitingForLock()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        DexSpiderRegistry registry = DexSpiderRegistry.get(context);
        Method invokePlayer = DexSpiderRegistry.class.getDeclaredMethod(
                "invokePlayer",
                JSONObject.class,
                Spider.class,
                JSONArray.class,
                BridgeProviderOwnerRegistry.Binding.class
        );
        invokePlayer.setAccessible(true);
        Field locksField = DexSpiderRegistry.class.getDeclaredField(
                "playbackLocks"
        );
        locksField.setAccessible(true);
        Map<?, ?> locks = (Map<?, ?>) locksField.get(registry);

        String suffix = UUID.randomUUID().toString();
        String siteKey = "refresh-site-" + suffix;
        String jarURL = "https://unit.invalid/" + suffix + ".jar";
        JSONObject normalPayload = new JSONObject()
                .put("siteKey", siteKey)
                .put("configurationID", "refresh-configuration-" + suffix)
                .put("providerOwnerID", "refresh-provider-" + suffix)
                .put("jarURL", jarURL)
                .put("jarMD5", "");
        JSONObject refreshPayload = new JSONObject(normalPayload.toString())
                .put("refreshPlayback", true);
        JSONArray arguments = new JSONArray()
                .put("line")
                .put("episode")
                .put(new JSONArray());
        String playbackKey = jarURL + ":" + siteKey
                + "\u0000line\u0000episode";
        AtomicInteger invocations = new AtomicInteger();
        CountDownLatch firstEntered = new CountDownLatch(1);
        CountDownLatch allowFirstReturn = new CountDownLatch(1);
        Spider spider = new Spider() {
            @Override
            public String playerContent(
                    String flag,
                    String id,
                    java.util.List<String> vipFlags
            ) throws Exception {
                int invocation = invocations.incrementAndGet();
                if (invocation == 1) {
                    firstEntered.countDown();
                    if (!allowFirstReturn.await(5, TimeUnit.SECONDS)) {
                        throw new IllegalStateException("test handoff timed out");
                    }
                }
                return new JSONObject()
                        .put("parse", 0)
                        .put(
                                "url",
                                "https://media.example/" + suffix
                                        + "?generation=" + invocation
                        )
                        .toString();
            }
        };
        FutureTask<Object> normal = new FutureTask<>(() -> invokePlayer.invoke(
                registry,
                normalPayload,
                spider,
                arguments,
                BridgeProviderOwnerRegistry.bind(normalPayload, jarURL)
        ));
        FutureTask<Object> refresh = new FutureTask<>(() -> invokePlayer.invoke(
                registry,
                refreshPayload,
                spider,
                arguments,
                BridgeProviderOwnerRegistry.bind(refreshPayload, jarURL)
        ));
        Thread normalThread = new Thread(normal, "normal-playback-test");
        Thread refreshThread = new Thread(refresh, "refresh-playback-test");
        normalThread.start();
        assertTrue(firstEntered.await(2, TimeUnit.SECONDS));
        refreshThread.start();
        try {
            long deadline = System.currentTimeMillis() + 2_000L;
            boolean refreshRetainedLock = false;
            while (System.currentTimeMillis() < deadline) {
                Object lock = locks.get(playbackKey);
                if (lock != null) {
                    Field retainCount = lock.getClass().getDeclaredField(
                            "retainCount"
                    );
                    retainCount.setAccessible(true);
                    if (retainCount.getInt(lock) >= 2) {
                        refreshRetainedLock = true;
                        break;
                    }
                }
                Thread.sleep(10L);
            }
            assertTrue("refresh did not queue on playback lock", refreshRetainedLock);
        } finally {
            allowFirstReturn.countDown();
        }
        normal.get(5, TimeUnit.SECONDS);
        refresh.get(5, TimeUnit.SECONDS);

        // A refresh must remove the successful handoff produced while it was
        // waiting. Otherwise this ordinary request would consume generation 1
        // instead of invoking the provider for generation 3.
        invokePlayer.invoke(
                registry,
                normalPayload,
                spider,
                arguments,
                BridgeProviderOwnerRegistry.bind(normalPayload, jarURL)
        );
        assertEquals(3, invocations.get());
    }

    public void testMixedCaseProviderHeadersReplaceWithoutLeavingOldSecret()
            throws Exception {
        JSONObject result = new JSONObject()
                .put("parse", 0)
                .put("url", "http://127.0.0.1:6677/header-case")
                .put("header", new JSONObject().put("Cookie", "old-secret"))
                .put("headers", new JSONObject().put("cookie", "new-secret"));
        JSONObject secured = (JSONObject)
                BridgeMediaSessionRegistry.securePlaybackResult(result);
        BridgeMediaSessionRegistry.Session session =
                BridgeMediaSessionRegistry.get(
                        secured.getString("mediaSessionID")
                );
        assertNotNull(session);
        Map<String, String> headers = session.headerSnapshot();
        assertEquals(1, headers.size());
        assertEquals("new-secret", header(headers, "cookie"));
        assertFalse(headers.containsValue("old-secret"));
        assertFalse(secured.has("header"));
        assertFalse(secured.has("headers"));
    }

    public void testProviderSecretsDoNotFollowCrossOriginMediaRedirect()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        BridgeServer.start(context);
        Thread.sleep(250L);
        InetAddress loopback = InetAddress.getByName("127.0.0.1");
        try (ServerSocket destination = new ServerSocket(0, 1, loopback);
             ServerSocket redirector = new ServerSocket(0, 1, loopback)) {
            destination.setSoTimeout(5_000);
            redirector.setSoTimeout(5_000);
            FutureTask<Map<String, String>> destinationRequest =
                    new FutureTask<>(() -> serveOnce(
                            destination,
                            "HTTP/1.1 200 OK\r\n"
                                    + "Content-Type: video/mp4\r\n"
                                    + "Content-Length: 2\r\n"
                                    + "Connection: close\r\n\r\nOK"
                    ));
            FutureTask<Map<String, String>> redirectRequest =
                    new FutureTask<>(() -> serveOnce(
                            redirector,
                            "HTTP/1.1 302 Found\r\n"
                                    + "Location: http://127.0.0.1:"
                                    + destination.getLocalPort()
                                    + "/movie\r\n"
                                    + "Content-Length: 0\r\n"
                                    + "Connection: close\r\n\r\n"
                    ));
            new Thread(destinationRequest, "media-destination-test").start();
            new Thread(redirectRequest, "media-redirect-test").start();

            JSONObject providerResult = new JSONObject()
                    .put("parse", 0)
                    .put(
                            "url",
                            "http://127.0.0.1:"
                                    + redirector.getLocalPort()
                                    + "/start"
                    )
                    .put(
                            "headers",
                            new JSONObject()
                                    .put("Cookie", "session-cookie")
                                    .put("Authorization", "Bearer session-token")
                                    .put("X-Provider-Token", "custom-secret")
                                    .put("Referer", "https://provider.example/")
                    );
            JSONObject secured = (JSONObject)
                    BridgeMediaSessionRegistry.securePlaybackResult(
                            providerResult
                    );
            HttpURLConnection connection = (HttpURLConnection) new URL(
                    secured.getString("url")
            ).openConnection();
            connection.setConnectTimeout(2_000);
            connection.setReadTimeout(5_000);
            assertEquals(200, connection.getResponseCode());
            try (InputStream input = connection.getInputStream()) {
                while (input.read() != -1) {
                    // Drain the bridge's chunked response.
                }
            } finally {
                connection.disconnect();
            }

            Map<String, String> initial = redirectRequest.get(
                    5,
                    TimeUnit.SECONDS
            );
            assertEquals("session-cookie", header(initial, "cookie"));
            assertEquals(
                    "Bearer session-token",
                    header(initial, "authorization")
            );
            assertEquals(
                    "custom-secret",
                    header(initial, "x-provider-token")
            );
            Map<String, String> redirected = destinationRequest.get(
                    5,
                    TimeUnit.SECONDS
            );
            assertNull(header(redirected, "cookie"));
            assertNull(header(redirected, "authorization"));
            assertNull(header(redirected, "x-provider-token"));
            assertEquals(
                    "https://provider.example/",
                    header(redirected, "referer")
            );
        }
    }

    private static AlertDialog showOwnedDialog(
            String interactionID,
            String title,
            AtomicInteger clickCount
    ) throws Exception {
        assertTrue(BridgeActionActivity.isReadyFor(interactionID));
        Context owner = com.github.catvod.Init.context();
        assertTrue("provider UI owner must be an Activity", owner instanceof Activity);
        assertTrue(BridgeActionActivity.ownsInitContext(interactionID));
        AtomicReference<AlertDialog> result = new AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            AlertDialog dialog = new AlertDialog.Builder((Activity) owner)
                    .setTitle(title)
                    .setMessage("请求级 Android Bridge 配置窗口")
                    .setPositiveButton("应用", (ignored, which) -> {
                        if (clickCount != null) clickCount.incrementAndGet();
                    })
                    .setNegativeButton("取消", null)
                    .create();
            dialog.show();
            result.set(dialog);
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNotNull(result.get());
        assertTrue(isShowing(result.get()));
        return result.get();
    }

    private static AlertDialog showOwnedImageDialog(
            String interactionID,
            boolean qrCode
    ) throws Exception {
        assertTrue(BridgeActionActivity.isReadyFor(interactionID));
        Context owner = com.github.catvod.Init.context();
        assertTrue(owner instanceof Activity);
        assertTrue(BridgeActionActivity.ownsInitContext(interactionID));
        AtomicReference<AlertDialog> result = new AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            try {
                ImageView image = new ImageView((Activity) owner);
                image.setLayoutParams(new ViewGroup.LayoutParams(320, 320));
                image.setAdjustViewBounds(true);
                image.setImageBitmap(qrCode
                        ? qrBitmap("okvideomac-legacy-login")
                        : ordinaryBitmap());
                AlertDialog dialog = new AlertDialog.Builder((Activity) owner)
                        .setTitle("结构化配置界面")
                        .setView(image)
                        .setNegativeButton("取消", null)
                        .create();
                dialog.show();
                result.set(dialog);
            } catch (Throwable error) {
                throw new AssertionError(error);
            }
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNotNull(result.get());
        assertTrue(isShowing(result.get()));
        return result.get();
    }

    private static AlertDialog showOwnedInputDialog(
            String interactionID,
            boolean secure
    ) throws Exception {
        assertTrue(BridgeActionActivity.isReadyFor(interactionID));
        Context owner = com.github.catvod.Init.context();
        assertTrue(owner instanceof Activity);
        AtomicReference<AlertDialog> result = new AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            EditText input = new EditText((Activity) owner);
            input.setInputType(InputType.TYPE_CLASS_TEXT
                    | (secure
                    ? InputType.TYPE_TEXT_VARIATION_PASSWORD
                    : InputType.TYPE_TEXT_VARIATION_NORMAL));
            AlertDialog dialog = new AlertDialog.Builder((Activity) owner)
                    .setTitle("结构化输入界面")
                    .setView(input)
                    .setPositiveButton("提交", null)
                    .setNegativeButton("取消", null)
                    .create();
            dialog.show();
            result.set(dialog);
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNotNull(result.get());
        assertTrue(isShowing(result.get()));
        return result.get();
    }

    private static Bitmap qrBitmap(String content) throws Exception {
        BitMatrix matrix = new QRCodeWriter().encode(
                content,
                BarcodeFormat.QR_CODE,
                256,
                256
        );
        Bitmap bitmap = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888);
        int[] pixels = new int[256 * 256];
        for (int y = 0; y < 256; y++) {
            for (int x = 0; x < 256; x++) {
                pixels[y * 256 + x] = matrix.get(x, y)
                        ? Color.BLACK
                        : Color.WHITE;
            }
        }
        bitmap.setPixels(pixels, 0, 256, 0, 0, 256, 256);
        return bitmap;
    }

    private static Bitmap ordinaryBitmap() {
        Bitmap bitmap = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888);
        bitmap.eraseColor(Color.rgb(64, 128, 192));
        return bitmap;
    }

    private static JSONObject awaitCapturedUI(
            Context context,
            String interactionID,
            long timeoutMilliseconds
    ) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        JSONObject last = null;
        while (System.currentTimeMillis() < deadline) {
            last = BridgeActivity.uiState(context, interactionID);
            if (last.optBoolean("visible", false)) return last;
            Thread.sleep(25L);
        }
        return last == null
                ? BridgeInteractionRegistry.state(interactionID)
                : last;
    }

    private static boolean isShowing(AlertDialog dialog) {
        if (dialog == null) return false;
        AtomicBoolean result = new AtomicBoolean();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(
                () -> result.set(dialog.isShowing())
        );
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        return result.get();
    }

    private static Map<String, String> serveOnce(
            ServerSocket server,
            String response
    ) throws Exception {
        try (Socket socket = server.accept();
             BufferedReader reader = new BufferedReader(
                     new InputStreamReader(
                             socket.getInputStream(),
                             StandardCharsets.US_ASCII
                     )
             );
             OutputStream output = socket.getOutputStream()) {
            socket.setSoTimeout(5_000);
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put(":request", reader.readLine());
            String line;
            while ((line = reader.readLine()) != null && !line.isEmpty()) {
                int separator = line.indexOf(':');
                if (separator > 0) {
                    headers.put(
                            line.substring(0, separator)
                                    .trim()
                                    .toLowerCase(Locale.ROOT),
                            line.substring(separator + 1).trim()
                    );
                }
            }
            output.write(response.getBytes(StandardCharsets.US_ASCII));
            output.flush();
            return headers;
        }
    }

    private static String header(
            Map<String, String> headers,
            String expected
    ) {
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if (entry.getKey().equalsIgnoreCase(expected)) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static String readText(InputStream input) throws Exception {
        try (InputStream stream = input;
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4_096];
            int count;
            while ((count = stream.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return output.toString(StandardCharsets.US_ASCII.name());
        }
    }

    private static JSONObject request(
            String method,
            String path,
            JSONObject body
    ) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(
                "http://127.0.0.1:" + BridgeServer.PORT + path
        ).openConnection();
        connection.setRequestMethod(method);
        connection.setConnectTimeout(2_000);
        connection.setReadTimeout(5_000);
        if (body != null) {
            byte[] data = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setFixedLengthStreamingMode(data.length);
            connection.getOutputStream().write(data);
            connection.getOutputStream().close();
        }
        assertEquals(200, connection.getResponseCode());
        try (InputStream input = connection.getInputStream();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4_096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return new JSONObject(output.toString("UTF-8"));
        } finally {
            connection.disconnect();
        }
    }

    private static void ensureBridgeServer() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        BridgeServer.start(context);
        long deadline = System.currentTimeMillis() + 2_000L;
        Throwable lastError = null;
        while (System.currentTimeMillis() < deadline) {
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(
                        "http://127.0.0.1:" + BridgeServer.PORT + "/health"
                ).openConnection();
                connection.setConnectTimeout(250);
                connection.setReadTimeout(250);
                if (connection.getResponseCode() == 200) return;
            } catch (Throwable error) {
                lastError = error;
                Thread.sleep(25L);
            } finally {
                if (connection != null) connection.disconnect();
            }
        }
        AssertionError failure = new AssertionError(
                "Bridge test server did not become ready"
        );
        if (lastError != null) failure.initCause(lastError);
        throw failure;
    }

    private static int requestStatus(
            String method,
            String path,
            JSONObject body
    ) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(
                "http://127.0.0.1:" + BridgeServer.PORT + path
        ).openConnection();
        connection.setRequestMethod(method);
        connection.setConnectTimeout(2_000);
        connection.setReadTimeout(5_000);
        if (body != null) {
            byte[] data = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setFixedLengthStreamingMode(data.length);
            try (OutputStream output = connection.getOutputStream()) {
                output.write(data);
            }
        }
        try {
            int status = connection.getResponseCode();
            InputStream response = status >= 400
                    ? connection.getErrorStream()
                    : connection.getInputStream();
            if (response != null) {
                try (InputStream ignored = response) {
                    byte[] buffer = new byte[1_024];
                    while (ignored.read(buffer) != -1) {
                        // Drain the loopback response before disconnecting.
                    }
                }
            }
            return status;
        } finally {
            connection.disconnect();
        }
    }
}
