package com.okvideomac.dexbridge;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.drawable.ColorDrawable;
import android.text.InputType;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.ListView;
import android.widget.PopupWindow;
import android.widget.TextView;

import androidx.test.platform.app.InstrumentationRegistry;

import com.github.catvod.crawler.Spider;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.common.BitMatrix;

import junit.framework.TestCase;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.IOException;
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
    public void testConfigurationHostsReplaceInsteadOfMerging() throws Exception {
        AtomicReference<List<String>> applied = new AtomicReference<>();
        AtomicInteger applyCount = new AtomicInteger();
        ConfigurationHostPolicy policy = new ConfigurationHostPolicy(hosts -> {
            applied.set(new ArrayList<>(hosts));
            applyCount.incrementAndGet();
        });
        JSONObject first = new JSONObject()
                .put("configurationID", "configuration-a")
                .put("hosts", new JSONArray()
                        .put("  api.example = edge-a.example  ")
                        .put("image.example=edge-image.example"));
        JSONObject second = new JSONObject()
                .put("configurationID", "configuration-b")
                .put("hosts", new JSONArray()
                        .put("api.example=edge-b.example"));

        try (ConfigurationHostPolicy.Lease ignored = policy.acquire(first)) {
            assertEquals(2, applied.get().size());
            assertEquals(
                    "  api.example = edge-a.example  ",
                    applied.get().get(0)
            );
        }
        try (ConfigurationHostPolicy.Lease ignored = policy.acquire(first)) {
            assertEquals(1, applyCount.get());
        }
        try (ConfigurationHostPolicy.Lease ignored = policy.acquire(second)) {
            assertEquals(2, applyCount.get());
            assertEquals(1, applied.get().size());
            assertEquals("api.example=edge-b.example", applied.get().get(0));
        }
    }

    public void testConfigurationHostLeasePreventsMidRequestReplacement()
            throws Exception {
        AtomicReference<List<String>> applied = new AtomicReference<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        ConfigurationHostPolicy policy = new ConfigurationHostPolicy(
                hosts -> applied.set(new ArrayList<>(hosts))
        );
        JSONObject first = new JSONObject()
                .put("configurationID", "configuration-a")
                .put("hosts", new JSONArray().put("api.example=edge-a.example"));
        JSONObject second = new JSONObject()
                .put("configurationID", "configuration-b")
                .put("hosts", new JSONArray().put("api.example=edge-b.example"));
        CountDownLatch waiting = new CountDownLatch(1);
        CountDownLatch switched = new CountDownLatch(1);
        ConfigurationHostPolicy.Lease firstLease = policy.acquire(first);
        Thread replacement = new Thread(() -> {
            waiting.countDown();
            try (ConfigurationHostPolicy.Lease ignored = policy.acquire(second)) {
                switched.countDown();
            } catch (Throwable error) {
                failure.set(error);
            }
        });

        try {
            replacement.start();
            assertTrue(waiting.await(1, TimeUnit.SECONDS));
            assertFalse(switched.await(100, TimeUnit.MILLISECONDS));
            assertEquals("api.example=edge-a.example", applied.get().get(0));
        } finally {
            firstLease.close();
        }
        assertTrue(switched.await(1, TimeUnit.SECONDS));
        replacement.join(1_000L);
        assertNull(failure.get());
        assertEquals("api.example=edge-b.example", applied.get().get(0));
    }

    public void testBrowseThenPlaybackUsesSeparateTransientOwners()
            throws Exception {
        BridgeProviderOwnerRegistry.resetForTests();
        String suffix = UUID.randomUUID().toString();
        String jarKey = "https://unit.invalid/transient-" + suffix + ".jar";
        JSONObject base = new JSONObject()
                .put("providerOwnerID", "transient-provider-" + suffix)
                .put("configurationID", "transient-configuration-" + suffix)
                .put("siteKey", "transient-site-" + suffix)
                .put("jarURL", jarKey)
                .put("jarMD5", "");
        JSONObject browse = new JSONObject(base.toString());
        JSONObject playback = new JSONObject(base.toString());

        BridgeProviderOwnerRegistry.Binding browseOwner =
                BridgeProviderOwnerRegistry.bind(browse, jarKey);
        BridgeProviderOwnerRegistry.Binding playbackOwner =
                BridgeProviderOwnerRegistry.bind(playback, jarKey);

        assertNotSame(browseOwner, playbackOwner);
        assertEquals(browseOwner.ownerID, playbackOwner.ownerID);
        assertEquals(browseOwner.jarKey, playbackOwner.jarKey);
        assertNull(BridgeProviderOwnerRegistry.state(""));
    }

    public void testInteractiveOwnerRejectsJarMutation()
            throws Exception {
        BridgeProviderOwnerRegistry.resetForTests();
        String suffix = UUID.randomUUID().toString();
        String jarKey = "https://unit.invalid/interactive-" + suffix + ".jar";
        JSONObject authorization = new JSONObject()
                .put("providerOwnerID", "interactive-provider-" + suffix)
                .put("configurationID", "interactive-configuration-" + suffix)
                .put("siteKey", "interactive-site-" + suffix)
                .put("interactionID", "interactive-request-" + suffix)
                .put("jarURL", jarKey)
                .put("jarMD5", "");

        BridgeProviderOwnerRegistry.bind(authorization, jarKey);
        try {
            BridgeProviderOwnerRegistry.bind(
                    authorization,
                    jarKey + ".replacement"
            );
            fail("interactive owner jar mutation must be rejected");
        } catch (IllegalStateException error) {
            assertEquals("Provider owner jar mismatch", error.getMessage());
        }
    }

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
        assertEquals("discarded", BridgeInteractionRegistry.state(first)
                .getString("returnState"));
    }

    public void testActionSessionSeparatesReturnSurfaceAndEventChannels()
            throws Exception {
        String id = "interaction-channels-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(id, "configuration", "action");

        JSONObject initial = BridgeInteractionRegistry.state(id);
        JSONObject channels = initial.getJSONObject("channels");
        assertEquals("pending", channels.getJSONObject("return")
                .getString("state"));
        assertFalse(channels.getJSONObject("surface")
                .getBoolean("visible"));
        assertEquals(0L, channels.getJSONObject("events")
                .getLong("latestSequence"));

        JSONObject recorded = BridgeInteractionRegistry.recordEvent(
                id,
                "providerMessage",
                "清除成功"
        );
        assertTrue(recorded.getBoolean("eventAccepted"));
        assertEquals(1, recorded.getJSONArray("events").length());
        assertEquals("清除成功", recorded.getJSONArray("events")
                .getJSONObject(0).getString("message"));

        JSONObject state = BridgeInteractionRegistry.state(id);
        assertFalse("event text must not enter surface state",
                state.toString().contains("清除成功"));
        assertEquals(1L, state.getJSONObject("channels")
                .getJSONObject("events").getLong("latestSequence"));

        JSONObject returned = BridgeInteractionRegistry.invocationReturned(id);
        assertTrue(returned.getBoolean("returnAccepted"));
        assertEquals("returned", returned.getString("returnState"));
        assertEquals("returned", returned.getJSONObject("channels")
                .getJSONObject("return").getString("state"));
    }

    public void testExternalSurfaceStateNeverBecomesAuthorizationSuccess()
            throws Exception {
        String id = "interaction-external-contract-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(id, "authorization", "action");
        BridgeInteractionRegistry.expectProviderUI(id);
        JSONObject external = new JSONObject()
                .put("visible", false)
                .put("surfaceActive", true)
                .put("surfaceRequestScoped", true)
                .put("surfaceDelegated", true)
                .put("surfaceInteractionID", id)
                .put("surfaceMode", "externalActivity")
                .put("surfaceHostLifecycle", "stopped");
        JSONObject waiting = BridgeInteractionRegistry.observeUI(id, external);
        assertEquals("awaitingExternalSurface", waiting.getString("phase"));
        assertEquals("stay", waiting.getString("outcome"));
        assertFalse(waiting.getBoolean("terminal"));
        assertTrue(waiting.getBoolean("surfaceActive"));
        assertTrue(waiting.getBoolean("surfaceRequestScoped"));
        assertTrue(waiting.getBoolean("surfaceDelegated"));
        assertEquals(id, waiting.getString("surfaceInteractionID"));

        JSONObject returned = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("awaitingExternalSurface", returned.getString("phase"));
        assertFalse(returned.getBoolean("terminal"));
        assertEquals("returned", returned.getString("returnState"));

        JSONObject cancelled = BridgeInteractionRegistry.cancel(id);
        assertEquals("cancelled", cancelled.getString("phase"));
        assertTrue(cancelled.getBoolean("terminal"));
        assertFalse(cancelled.getBoolean("surfaceActive"));
        assertFalse(cancelled.getBoolean("surfaceRequestScoped"));
        assertFalse(cancelled.getBoolean("surfaceDelegated"));
        JSONObject surface = cancelled.getJSONObject("channels")
                .getJSONObject("surface");
        assertFalse(surface.getBoolean("active"));
        assertFalse(surface.getBoolean("requestScoped"));
        assertEquals("", surface.getString("interactionID"));
    }

    public void testSupersededExternalSurfaceLeaseIsImmediatelyInvalid()
            throws Exception {
        String oldID = "interaction-external-old-" + UUID.randomUUID();
        String currentID = "interaction-external-new-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(oldID, "authorization", "action");
        BridgeInteractionRegistry.expectProviderUI(oldID);
        BridgeInteractionRegistry.observeUI(
                oldID,
                new JSONObject()
                        .put("visible", false)
                        .put("surfaceActive", true)
                        .put("surfaceRequestScoped", true)
                        .put("surfaceDelegated", true)
                        .put("surfaceInteractionID", oldID)
                        .put("surfaceMode", "externalActivity")
        );
        BridgeInteractionRegistry.begin(
                currentID,
                "configuration",
                "action"
        );
        JSONObject old = BridgeInteractionRegistry.state(oldID);
        assertEquals("superseded", old.getString("phase"));
        assertFalse(old.getBoolean("surfaceActive"));
        assertFalse(old.getBoolean("surfaceRequestScoped"));
        assertFalse(old.getJSONObject("channels")
                .getJSONObject("surface").getBoolean("active"));
        BridgeInteractionRegistry.cancel(currentID);
    }

    public void testEventRouteIsRequestScopedAndSequenceFiltered()
            throws Exception {
        ensureBridgeServer();
        String id = "http-events-" + UUID.randomUUID();
        request(
                "POST",
                "/v1/interactions",
                new JSONObject()
                        .put("interactionID", id)
                        .put("kind", "configuration")
                        .put("method", "action")
        );
        BridgeInteractionRegistry.recordEvent(id, "providerMessage", "第一条");
        BridgeInteractionRegistry.recordEvent(id, "toast", "第二条");

        JSONObject all = request(
                "GET",
                "/v1/interactions/" + id + "/events",
                null
        );
        assertEquals(2L, all.getLong("latestSequence"));
        assertEquals(2, all.getJSONArray("events").length());
        JSONObject afterFirst = request(
                "GET",
                "/v1/interactions/" + id + "/events?after=1",
                null
        );
        assertEquals(1, afterFirst.getJSONArray("events").length());
        assertEquals("第二条", afterFirst.getJSONArray("events")
                .getJSONObject(0).getString("message"));
        BridgeInteractionRegistry.cancel(id);
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
                "nativesetting"
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

        payload.put("interactionKind", "playback");
        assertTrue(DexSpiderRegistry.requiresDialogHandoff(payload, "play"));

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
                "interaction-playback-complete",
                "playback",
                "play"
        );
        JSONObject playable = new JSONObject()
                .put("parse", 0)
                .put("url", "http://127.0.0.1:9978/proxy/media/session");
        BridgeInteractionRegistry.expectProviderUI(id);
        JSONObject completed = BridgeInteractionRegistry.invocationReturned(
                id,
                DexSpiderRegistry.isPlayableResult(playable)
        );
        assertEquals("completed", completed.getString("phase"));
        assertEquals("completed", completed.getString("outcome"));
        assertTrue(completed.getBoolean("terminal"));
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
        JSONObject providerError = new JSONObject()
                .put("url", "https://media.example/fallback")
                .put("msg", "provider login required");
        assertFalse(DexSpiderRegistry.isPlayableResult(providerError));
        assertEquals(
                "provider login required",
                DexSpiderRegistry.providerPlaybackMessage(providerError)
        );
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
        JSONObject hidden = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", false)
        );
        assertEquals("processing", hidden.getString("phase"));
        assertEquals("stay", hidden.getString("outcome"));
        assertFalse(hidden.getBoolean("terminal"));
    }

    public void testWorkerReturnWaitsForConfirmationAfterCapturedUI()
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
        assertEquals(
                "awaitingUserConfirmation",
                returned.getString("phase")
        );
        assertEquals("stay", returned.getString("outcome"));
        assertFalse(returned.getBoolean("terminal"));
        assertTrue(returned.getBoolean("workerReturned"));
    }

    public void testHiddenSurfaceNeverCompletesWithoutUserConfirmation()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-hidden-confirmation",
                "configuration",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", true)
        );
        BridgeInteractionRegistry.invocationReturned(id);

        JSONObject hidden = BridgeInteractionRegistry.observeUI(
                id,
                new JSONObject().put("visible", false)
        );
        assertEquals(
                "awaitingUserConfirmation",
                hidden.getString("phase")
        );
        assertEquals("stay", hidden.getString("outcome"));
        assertFalse(hidden.getBoolean("terminal"));
        assertFalse(hidden.getBoolean("userConfirmed"));
    }

    public void testUserConfirmationCompletesReturnedWorker()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-user-confirmed",
                "authorization",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);
        BridgeInteractionRegistry.invocationReturned(id);

        JSONObject completed = BridgeInteractionRegistry.confirmCompleted(id);
        assertTrue(completed.getBoolean("confirmationAccepted"));
        assertTrue(completed.getBoolean("userConfirmed"));
        assertEquals("userConfirmed", completed.getString("completionSource"));
        assertEquals("completed", completed.getString("phase"));
        assertTrue(completed.getBoolean("terminal"));
    }

    public void testConfirmationBeforeWorkerReturnWaitsForProvider()
            throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-confirm-before-return",
                "configuration",
                "action"
        );
        BridgeInteractionRegistry.expectProviderUI(id);

        JSONObject confirmed = BridgeInteractionRegistry.confirmCompleted(id);
        assertEquals(
                "awaitingProviderReturnAfterConfirmation",
                confirmed.getString("phase")
        );
        assertFalse(confirmed.getBoolean("terminal"));

        JSONObject completed = BridgeInteractionRegistry.invocationReturned(id);
        assertEquals("completed", completed.getString("phase"));
        assertTrue(completed.getBoolean("terminal"));
        assertEquals("userConfirmed", completed.getString("completionSource"));
    }

    public void testCancellationRecordsReason() throws Exception {
        String id = BridgeInteractionRegistry.begin(
                "interaction-cancel-reason",
                "configuration",
                "action"
        );
        JSONObject cancelled = BridgeInteractionRegistry.cancel(id, "user");
        assertEquals("cancelled", cancelled.getString("phase"));
        assertEquals("user", cancelled.getString("cancelReason"));
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
        assertFalse(late.getBoolean("returnAccepted"));
        assertEquals("discarded", late.getString("returnState"));
    }

    public void testSupersededSessionRejectsLateReturnAndOldEvent()
            throws Exception {
        String oldID = "interaction-late-old-" + UUID.randomUUID();
        String currentID = "interaction-late-current-" + UUID.randomUUID();
        BridgeInteractionRegistry.begin(oldID, "configuration", "action");
        BridgeInteractionRegistry.begin(currentID, "configuration", "action");

        JSONObject lateReturn = BridgeInteractionRegistry.invocationReturned(
                oldID
        );
        assertFalse(lateReturn.getBoolean("returnAccepted"));
        assertEquals("discarded", lateReturn.getString("returnState"));
        JSONObject lateEvent = BridgeInteractionRegistry.recordEvent(
                oldID,
                "toast",
                "上一条操作的迟到消息"
        );
        assertFalse(lateEvent.getBoolean("eventAccepted"));
        assertEquals(0, lateEvent.getJSONArray("events").length());
        assertEquals(0, BridgeInteractionRegistry.events(currentID, 0L)
                .getJSONArray("events").length());
        BridgeInteractionRegistry.cancel(currentID);
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

    public void testForegroundExternalActivityKeepsExactSurfaceLease()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-external-activity-" + UUID.randomUUID();
        boolean externalStarted = false;
        try {
            BridgeServer.beginAndActivateInteraction(
                    context,
                    id,
                    "authorization",
                    "action"
            );
            BridgeActivity.prepareDialogHandoff(context, id);
            assertTrue(BridgeActionActivity.isReadyFor(id));

            JSONObject anchor = BridgeActivity.uiState(context, id);
            assertTrue(anchor.getBoolean("surfaceActive"));
            assertTrue(anchor.getBoolean("surfaceRequestScoped"));
            assertFalse(anchor.getBoolean("surfaceDelegated"));
            assertEquals("actionActivity", anchor.getString("surfaceMode"));

            Intent external = launchableExternalActivity(context);
            external.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(external);
            externalStarted = true;

            long deadline = System.currentTimeMillis() + 3_000L;
            BridgeActionActivity.SurfaceStatus lifecycle = null;
            while (System.currentTimeMillis() < deadline) {
                lifecycle = BridgeActionActivity.surfaceStatusFor(id);
                if (lifecycle.delegatedSurfaceActive) break;
                Thread.sleep(25L);
            }
            assertNotNull(lifecycle);
            assertTrue(lifecycle.requestScoped);
            assertTrue(lifecycle.delegatedSurfaceActive);

            JSONObject delegated = BridgeActivity.uiState(context, id);
            assertTrue(delegated.getBoolean("surfaceActive"));
            assertTrue(delegated.getBoolean("surfaceRequestScoped"));
            assertTrue(delegated.getBoolean("surfaceDelegated"));
            assertEquals(id, delegated.getString("surfaceInteractionID"));
            assertEquals(
                    "externalActivity",
                    delegated.getString("surfaceMode")
            );
            assertTrue(
                    "paused".equals(delegated.getString(
                            "surfaceHostLifecycle"
                    ))
                            || "stopped".equals(delegated.getString(
                            "surfaceHostLifecycle"
                    ))
            );
            assertEquals(
                    "awaitingExternalSurface",
                    delegated.getString("phase")
            );
            assertEquals("stay", delegated.getString("outcome"));
            assertFalse(delegated.getBoolean("terminal"));
            JSONObject surface = delegated.getJSONObject("channels")
                    .getJSONObject("surface");
            assertTrue(surface.getBoolean("active"));
            assertTrue(surface.getBoolean("requestScoped"));
            assertTrue(surface.getBoolean("delegated"));
            assertFalse(surface.getBoolean("visible"));

            JSONObject cancelled = BridgeActivity.dismissUI(context, id);
            assertEquals("cancelled", cancelled.getString("phase"));
            assertFalse(cancelled.getBoolean("surfaceActive"));
            assertFalse(cancelled.getBoolean("surfaceRequestScoped"));
            assertFalse(cancelled.getBoolean("surfaceDelegated"));
            assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
        } finally {
            if (!BridgeInteractionRegistry.terminal(id)) {
                BridgeActivity.dismissUI(context, id);
            }
            if (externalStarted) {
                InstrumentationRegistry.getInstrumentation()
                        .sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);
                InstrumentationRegistry.getInstrumentation().waitForIdleSync();
            }
        }
        JSONObject latePoll = BridgeActivity.uiState(context, id);
        assertTrue(latePoll.getBoolean("terminal"));
        assertFalse(latePoll.getBoolean("surfaceActive"));
        assertFalse(latePoll.getBoolean("surfaceRequestScoped"));
        assertEquals("none", latePoll.getString("surfaceMode"));
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
        // Finishing the request-owned Activity removes its window token. A
        // retained AlertDialog object may still report `isShowing()` even
        // though Android has removed the complete session from the display.
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
                "playback",
                "play"
        );
        BridgeActivity.prepareDialogHandoff(context, id);
        AlertDialog dialog = showOwnedDialog(id, "播放授权", null);
        JSONObject visible = awaitCapturedUI(context, id, 2_000L);
        assertEquals("providerWindow", visible.getString("surfaceMode"));
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
        assertTrue(BridgeActionActivity.awaitReleased(id, 2_000L));
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
    }

    public void testActionSessionTracksDialogBoundsAndRestoresStack()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-dialog-stack-" + UUID.randomUUID();
        AlertDialog first = null;
        AlertDialog second = null;
        try {
            BridgeServer.beginAndActivateInteraction(
                    context,
                    id,
                    "configuration",
                    "action"
            );
            BridgeActivity.prepareDialogHandoff(context, id);
            first = showOwnedDialog(id, "第一层", null);
            JSONObject firstState = awaitDialogStack(context, id, 1, 2_000L);
            assertEquals("dialogCrop", firstState.getString(
                    "surfacePresentationMode"
            ));
            assertEquals(1, firstState.getInt("surfaceWindowStackDepth"));
            assertTrue(firstState.getBoolean("surfaceDialogTrackerAvailable"));
            String firstWindowID = firstState.getString("surfaceWindowID");
            assertFalse(firstWindowID.isEmpty());
            JSONObject firstBounds = firstState.getJSONObject(
                    "surfaceWindowBounds"
            );
            JSONObject firstContentBounds = firstState.getJSONObject(
                    "surfaceWindowContentBounds"
            );
            assertTrue(firstBounds.getInt("width") > 0);
            assertTrue(firstBounds.getInt("height") > 0);
            assertTrue(firstBounds.getInt("left")
                    <= firstContentBounds.getInt("left"));
            assertTrue(firstBounds.getInt("top")
                    <= firstContentBounds.getInt("top"));
            assertTrue(firstBounds.getInt("right")
                    >= firstContentBounds.getInt("right"));
            assertTrue(firstBounds.getInt("bottom")
                    >= firstContentBounds.getInt("bottom"));
            long firstRevision = firstState.getLong("surfaceWindowRevision");

            second = showOwnedDialog(id, "第二层", null);
            JSONObject secondState = awaitDialogStack(context, id, 2, 2_000L);
            assertEquals("dialogCrop", secondState.getString(
                    "surfacePresentationMode"
            ));
            assertEquals(2, secondState.getInt("surfaceWindowStackDepth"));
            assertFalse(firstWindowID.equals(secondState.getString(
                    "surfaceWindowID"
            )));
            assertTrue(secondState.getLong("surfaceWindowRevision")
                    > firstRevision);
            JSONArray stack = secondState.getJSONArray("surfaceDialogStack");
            assertEquals(firstWindowID, stack.getJSONObject(0)
                    .getString("windowID"));

            dismissDialog(second);
            second = null;
            JSONObject restored = awaitDialogStack(context, id, 1, 2_000L);
            assertEquals(firstWindowID, restored.getString("surfaceWindowID"));
            assertTrue(restored.getLong("surfaceWindowRevision")
                    > secondState.getLong("surfaceWindowRevision"));
        } finally {
            dismissDialog(second);
            dismissDialog(first);
            if (!BridgeInteractionRegistry.terminal(id)) {
                BridgeActivity.dismissUI(context, id);
            }
        }
    }

    public void testNearFullDialogPolicyKeepsFullSurfaceFallback() {
        assertTrue(BridgeDialogWindowTracker.isNearFullDisplay(
                new Rect(0, 48, 720, 1_552),
                720,
                1_600
        ));
        assertFalse(BridgeDialogWindowTracker.isNearFullDisplay(
                new Rect(18, 363, 701, 1_195),
                720,
                1_600
        ));
        assertFalse(BridgeDialogWindowTracker.isNearFullDisplay(
                new Rect(18, 560, 701, 1_120),
                720,
                1_600
        ));
    }

    public void testSessionWindowPolicyIncludesAttachedPanelsOnly() {
        assertTrue(BridgeDialogWindowTracker.isSessionWindowType(
                android.view.WindowManager.LayoutParams.TYPE_APPLICATION
        ));
        assertTrue(BridgeDialogWindowTracker.isSessionWindowType(
                android.view.WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG
        ));
        assertTrue(BridgeDialogWindowTracker.isSessionWindowType(
                android.view.WindowManager.LayoutParams.TYPE_APPLICATION_PANEL
        ));
        assertTrue(BridgeDialogWindowTracker.isSessionWindowType(
                android.view.WindowManager.LayoutParams.TYPE_APPLICATION_SUB_PANEL
        ));
        assertTrue(BridgeDialogWindowTracker.isSessionWindowType(1005));
        assertFalse(BridgeDialogWindowTracker.isSessionWindowType(
                android.view.WindowManager.LayoutParams.TYPE_TOAST
        ));
        assertFalse(BridgeDialogWindowTracker.isSessionWindowType(
                android.view.WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        ));
    }

    public void testDialogCaptureGuardBandExpandsAndClampsToDisplay() {
        Rect expanded = BridgeDialogWindowTracker.guardedCaptureBounds(
                new Rect(30, 40, 690, 1_560),
                720,
                1_600,
                2f
        );
        assertEquals(new Rect(6, 16, 714, 1_584), expanded);
        Rect clamped = BridgeDialogWindowTracker.guardedCaptureBounds(
                new Rect(2, 3, 718, 1_598),
                720,
                1_600,
                3f
        );
        assertEquals(new Rect(0, 0, 720, 1_600), clamped);
    }

    public void testActionSessionGroupsPopupWithOwningDialogLayer()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-dialog-popup-" + UUID.randomUUID();
        AlertDialog dialog = null;
        PopupWindow popup = null;
        try {
            BridgeServer.beginAndActivateInteraction(
                    context,
                    id,
                    "authorization",
                    "action"
            );
            BridgeActivity.prepareDialogHandoff(context, id);
            dialog = showOwnedDialog(id, "二维码登录", null);
            JSONObject dialogOnly = awaitDialogMemberCount(
                    context,
                    id,
                    1,
                    2_000L
            );
            long dialogRevision = dialogOnly.getLong("surfaceWindowRevision");
            popup = showOwnedPopup(dialog);
            JSONObject grouped = awaitDialogMemberCount(
                    context,
                    id,
                    2,
                    2_000L
            );
            assertEquals(1, grouped.getInt("surfaceWindowStackDepth"));
            assertTrue(grouped.getLong("surfaceWindowRevision") > dialogRevision);
            JSONObject top = grouped.getJSONArray("surfaceDialogStack")
                    .getJSONObject(0);
            assertEquals(2, top.getInt("memberWindowCount"));
            JSONObject capture = top.getJSONObject("bounds");
            JSONObject content = top.getJSONObject("contentBounds");
            assertTrue(capture.getInt("left") <= content.getInt("left"));
            assertTrue(capture.getInt("top") <= content.getInt("top"));
            assertTrue(capture.getInt("right") >= content.getInt("right"));
            assertTrue(capture.getInt("bottom") >= content.getInt("bottom"));

            dismissPopup(popup);
            popup = null;
            JSONObject restored = awaitDialogMemberCount(
                    context,
                    id,
                    1,
                    2_000L
            );
            assertEquals(1, restored.getInt("surfaceWindowStackDepth"));
            assertTrue(restored.getLong("surfaceWindowRevision")
                    > grouped.getLong("surfaceWindowRevision"));
        } finally {
            dismissPopup(popup);
            dismissDialog(dialog);
            if (!BridgeInteractionRegistry.terminal(id)) {
                BridgeActivity.dismissUI(context, id);
            }
        }
    }

    public void testActionSessionBackingSurfaceIsBlankAndOpaque()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-blank-backing-" + UUID.randomUUID();
        try {
            BridgeServer.beginAndActivateInteraction(
                    context,
                    id,
                    "configuration",
                    "action"
            );
            BridgeActivity.prepareDialogHandoff(context, id);
            Activity activity = BridgeActionActivity.currentActivity();
            assertNotNull(activity);
            InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
                ViewGroup content = activity.findViewById(android.R.id.content);
                assertNotNull(content);
                assertEquals(1, content.getChildCount());
                assertTrue(content.getChildAt(0) instanceof FrameLayout);
                assertEquals(
                        0,
                        ((FrameLayout) content.getChildAt(0)).getChildCount()
                );
                assertNotNull(content.getChildAt(0).getBackground());
            });
        } finally {
            if (!BridgeInteractionRegistry.terminal(id)) {
                BridgeActivity.dismissUI(context, id);
            }
        }
    }

    public void testSessionDialogCommitsUnicodeThroughFocusedInputConnection()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-dialog-text-" + UUID.randomUUID();
        AlertDialog dialog = null;
        try {
            BridgeServer.beginAndActivateInteraction(
                    context,
                    id,
                    "configuration",
                    "action"
            );
            BridgeActivity.prepareDialogHandoff(context, id);
            dialog = showOwnedInputDialog(id, false);
            JSONObject state = awaitDialogStack(context, id, 1, 2_000L);
            assertTrue(BridgeActionActivity.commitTextIfOwnedBy(
                    id,
                    state.getString("surfaceWindowID"),
                    state.getLong("surfaceWindowRevision"),
                    "中文输入"
            ));
            AlertDialog exactDialog = dialog;
            AtomicReference<String> input = new AtomicReference<>();
            InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
                View focused = exactDialog.getWindow().getDecorView().findFocus();
                assertTrue(focused instanceof EditText);
                input.set(((EditText) focused).getText().toString());
            });
            assertEquals("中文输入", input.get());
        } finally {
            dismissDialog(dialog);
            if (!BridgeInteractionRegistry.terminal(id)) {
                BridgeActivity.dismissUI(context, id);
            }
        }
    }

    public void testNearFullOwnedDialogPublishesFullSurfaceFallback()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-near-full-dialog-" + UUID.randomUUID();
        AlertDialog dialog = null;
        try {
            BridgeServer.beginAndActivateInteraction(
                    context,
                    id,
                    "authorization",
                    "action"
            );
            BridgeActivity.prepareDialogHandoff(context, id);
            dialog = showOwnedDialog(id, "透明全屏容器", null);
            AlertDialog exactDialog = dialog;
            InstrumentationRegistry.getInstrumentation().runOnMainSync(() ->
                    exactDialog.getWindow().setLayout(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT
                    )
            );
            InstrumentationRegistry.getInstrumentation().waitForIdleSync();
            JSONObject state = awaitSurfacePresentation(
                    context,
                    id,
                    "fullDisplay",
                    2_000L
            );
            assertEquals(
                    "nearFullDisplayDialog",
                    state.getString("surfaceFallbackReason")
            );
            assertEquals(1, state.getInt("surfaceWindowStackDepth"));
        } finally {
            dismissDialog(dialog);
            if (!BridgeInteractionRegistry.terminal(id)) {
                BridgeActivity.dismissUI(context, id);
            }
        }
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

    public void testIgnoredInterruptRequiresWorkerExitBeforeReuse()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        String id = "interaction-stubborn-worker-" + UUID.randomUUID();
        BridgeServer.beginAndActivateInteraction(
                context,
                id,
                "authorization",
                "action"
        );
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        BridgeServer.claimInteractionWorker(id, () -> {
            entered.countDown();
            while (release.getCount() > 0L) {
                try {
                    release.await(50L, TimeUnit.MILLISECONDS);
                } catch (InterruptedException ignored) {
                    // Models a third-party DEX provider that swallows the
                    // cooperative Future cancellation interrupt.
                }
            }
            return "late";
        });
        assertTrue(entered.await(2L, TimeUnit.SECONDS));

        BridgeInteractionRegistry.cancel(id, "test");
        BridgeServer.releaseTerminalInteraction(context, id);
        assertFalse(BridgeServer.awaitInteractionWorkerStopped(id, 100L));

        release.countDown();
        assertTrue(BridgeServer.awaitInteractionWorkerStopped(id, 2_000L));
        assertFalse(BridgeServer.hasTrackedInteractionWorker(id));
    }

    public void testMissingAndUnavailableStatesExcludeTranslatedUI()
            throws Exception {
        JSONObject missing = BridgeInteractionRegistry.state(
                "missing-interaction-schema"
        );
        assertTrue(missing.getBoolean("terminal"));
        assertFalse(missing.has("visible"));
        assertFalse(missing.has("title"));
        assertFalse(missing.has("inputCount"));
        assertFalse(missing.has("buttons"));
        assertFalse(missing.has("controls"));

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
        assertFalse(unavailable.has("visible"));
        assertFalse(unavailable.has("buttons"));
        assertFalse(unavailable.has("controls"));
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

    public void testFongMiCompatibilityProxyUsesSeparateLoopbackPortAndLease()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        ensureBridgeServer();
        int compatPort = FongMiCompatProxyServer.ensureStarted(context);
        assertTrue(compatPort >= FongMiCompatProxyServer.FIRST_PORT);
        assertTrue(compatPort <= FongMiCompatProxyServer.LAST_PORT);
        assertFalse(compatPort == BridgeServer.PORT);
        assertEquals(compatPort, com.github.catvod.Proxy.getPort());
        assertEquals(
                410,
                loopbackStatus(compatPort, "GET", "/proxy?do=idle", null, null)
        );

        String jarKey = "https://unit.invalid/compat-a-"
                + UUID.randomUUID() + ".jar";
        BridgeProviderOwnerRegistry.Binding owner = playbackOwner(
                "compat-a",
                jarKey
        );
        installProxyMethod(jarKey, CompatibilityProxyA.class);
        CompatibilityProxyA.lastParameters.set(null);
        try (FongMiCompatProxyServer.Lease ignored =
                     FongMiCompatProxyServer.acquire(context, owner)) {
            byte[] body = "token=form-value".getBytes(StandardCharsets.UTF_8);
            Map<String, String> requestHeaders = new LinkedHashMap<>();
            requestHeaders.put(
                    "Content-Type",
                    "application/x-www-form-urlencoded; charset=utf-8"
            );
            requestHeaders.put("Range", "bytes=100-199");
            assertEquals(
                    206,
                    loopbackStatus(
                            compatPort,
                            "POST",
                            "/proxy?do=play",
                            requestHeaders,
                            body
                    )
            );
        }
        Map<String, String> parameters = CompatibilityProxyA.lastParameters.get();
        assertNotNull(parameters);
        assertEquals("play", parameters.get("do"));
        assertEquals("form-value", parameters.get("token"));
        assertEquals("bytes=100-199", parameters.get("range"));
        assertEquals(
                410,
                loopbackStatus(compatPort, "GET", "/proxy?do=closed", null, null)
        );
    }

    public void testCompatibilityProxySessionRetainsExactOwnerAfterLeaseEnds()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        ensureBridgeServer();
        int compatPort = FongMiCompatProxyServer.ensureStarted(context);
        String suffix = UUID.randomUUID().toString();
        String jarA = "https://unit.invalid/owner-a-" + suffix + ".jar";
        String jarB = "https://unit.invalid/owner-b-" + suffix + ".jar";
        BridgeProviderOwnerRegistry.Binding ownerA = playbackOwner("owner-a", jarA);
        BridgeProviderOwnerRegistry.Binding ownerB = playbackOwner("owner-b", jarB);
        installProxyMethod(jarA, CompatibilityProxyA.class);
        installProxyMethod(jarB, CompatibilityProxyB.class);
        CompatibilityProxyA.invocations.set(0);
        CompatibilityProxyB.invocations.set(0);

        JSONObject secured;
        try (FongMiCompatProxyServer.Lease ignored =
                     FongMiCompatProxyServer.acquire(context, ownerA)) {
            secured = (JSONObject) BridgeMediaSessionRegistry
                    .securePlaybackResult(
                            new JSONObject()
                                    .put("parse", 0)
                                    .put(
                                            "url",
                                            "http://127.0.0.1:" + compatPort
                                                    + "/proxy?do=media"
                                    ),
                            false,
                            null,
                            ownerA
                    );
        }

        HttpURLConnection media = (HttpURLConnection) new URL(
                secured.getString("url")
        ).openConnection();
        media.setConnectTimeout(2_000);
        media.setReadTimeout(5_000);
        media.setRequestProperty("Range", "bytes=200-299");
        assertEquals(206, media.getResponseCode());
        try (InputStream input = media.getInputStream()) {
            assertEquals('A', input.read());
            assertEquals(-1, input.read());
        } finally {
            media.disconnect();
        }
        assertEquals(1, CompatibilityProxyA.invocations.get());
        assertEquals(0, CompatibilityProxyB.invocations.get());
        assertEquals(
                "bytes=200-299",
                CompatibilityProxyA.lastParameters.get().get("range")
        );

        try (FongMiCompatProxyServer.Lease ignored =
                     FongMiCompatProxyServer.acquire(context, ownerB)) {
            assertEquals(
                    206,
                    loopbackStatus(
                            compatPort,
                            "GET",
                            "/proxy?do=other-owner",
                            null,
                            null
                    )
            );
        }
        assertEquals(1, CompatibilityProxyA.invocations.get());
        assertEquals(1, CompatibilityProxyB.invocations.get());
    }

    public void testPlayerContentRestartsBrokenCompatibilityProxyOnlyOnce()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        ensureBridgeServer();
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
        String jarKey = "https://unit.invalid/recovery-" + suffix + ".jar";
        JSONObject payload = new JSONObject()
                .put("siteKey", "recovery-site-" + suffix)
                .put("configurationID", "recovery-config-" + suffix)
                .put("providerOwnerID", "recovery-owner-" + suffix)
                .put("jarURL", jarKey)
                .put("jarMD5", "");
        BridgeProviderOwnerRegistry.Binding owner =
                BridgeProviderOwnerRegistry.bind(payload, jarKey);
        installProxyMethod(jarKey, CompatibilityProxyFlaky.class);
        CompatibilityProxyFlaky.invocations.set(0);
        AtomicInteger playerInvocations = new AtomicInteger();
        Spider spider = proxyResolvingSpider(playerInvocations, suffix);

        JSONObject result = (JSONObject) invokePlayer.invoke(
                registry,
                payload,
                spider,
                new JSONArray()
                        .put("line")
                        .put("episode")
                        .put(new JSONArray()),
                owner
        );

        assertEquals(2, playerInvocations.get());
        assertEquals(2, CompatibilityProxyFlaky.invocations.get());
        assertEquals(
                "https://media.example/" + suffix + ".mp4",
                result.getString("url")
        );
    }

    public void testTrueUpstreamProxyStatusDoesNotRestartPlayerContent()
            throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        ensureBridgeServer();
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
        String jarKey = "https://unit.invalid/upstream-" + suffix + ".jar";
        JSONObject payload = new JSONObject()
                .put("siteKey", "upstream-site-" + suffix)
                .put("configurationID", "upstream-config-" + suffix)
                .put("providerOwnerID", "upstream-owner-" + suffix)
                .put("jarURL", jarKey)
                .put("jarMD5", "");
        BridgeProviderOwnerRegistry.Binding owner =
                BridgeProviderOwnerRegistry.bind(payload, jarKey);
        installProxyMethod(jarKey, CompatibilityProxyUpstreamFailure.class);
        CompatibilityProxyUpstreamFailure.invocations.set(0);
        AtomicInteger playerInvocations = new AtomicInteger();
        Spider spider = proxyResolvingSpider(playerInvocations, suffix);

        try {
            invokePlayer.invoke(
                    registry,
                    payload,
                    spider,
                    new JSONArray()
                            .put("line")
                            .put("episode")
                            .put(new JSONArray()),
                    owner
            );
            fail("real upstream HTTP failure must remain authoritative");
        } catch (java.lang.reflect.InvocationTargetException error) {
            assertTrue(error.getCause() instanceof IOException);
        }
        assertEquals(1, playerInvocations.get());
        assertEquals(1, CompatibilityProxyUpstreamFailure.invocations.get());
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

    private static AlertDialog showDialogOnActivity(
            Activity owner,
            String title
    ) {
        AtomicReference<AlertDialog> result = new AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            AlertDialog dialog = new AlertDialog.Builder(owner)
                    .setTitle(title)
                    .setMessage("未归属当前 ActionSession")
                    .setPositiveButton("好", null)
                    .create();
            dialog.show();
            result.set(dialog);
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNotNull(result.get());
        assertTrue(isShowing(result.get()));
        return result.get();
    }

    private static void dismissDialog(AlertDialog dialog) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            if (dialog != null && dialog.isShowing()) dialog.dismiss();
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
    }

    private static PopupWindow showOwnedPopup(AlertDialog dialog) {
        AtomicReference<PopupWindow> result = new AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            TextView content = new TextView(dialog.getContext());
            content.setText("附属窗口");
            content.setGravity(Gravity.CENTER);
            content.setTextColor(Color.BLACK);
            content.setBackgroundColor(Color.WHITE);
            PopupWindow popup = new PopupWindow(content, 260, 220, true);
            popup.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
            popup.setOutsideTouchable(false);
            popup.showAtLocation(
                    dialog.getWindow().getDecorView(),
                    Gravity.CENTER,
                    0,
                    0
            );
            result.set(popup);
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
        assertNotNull(result.get());
        assertTrue(result.get().isShowing());
        return result.get();
    }

    private static void dismissPopup(PopupWindow popup) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            if (popup != null && popup.isShowing()) popup.dismiss();
        });
        InstrumentationRegistry.getInstrumentation().waitForIdleSync();
    }

    private static AlertDialog showOwnedImageDialog(
            String interactionID,
            boolean qrCode
    ) throws Exception {
        return showOwnedBitmapDialog(
                interactionID,
                qrCode
                        ? qrBitmap("okvideomac-legacy-login")
                        : ordinaryBitmap()
        );
    }

    private static AlertDialog showOwnedBitmapDialog(
            String interactionID,
            Bitmap bitmap
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
                image.setImageBitmap(bitmap);
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

    private static AlertDialog showOwnedVirtualListDialog(
            String interactionID,
            int itemCount,
            AtomicInteger clickedPosition
    ) throws Exception {
        assertTrue(BridgeActionActivity.isReadyFor(interactionID));
        Context owner = com.github.catvod.Init.context();
        assertTrue(owner instanceof Activity);
        AtomicReference<AlertDialog> result = new AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            ListView list = new ListView((Activity) owner);
            list.setLayoutParams(new ViewGroup.LayoutParams(520, 260));
            list.setAdapter(new BaseAdapter() {
                @Override
                public int getCount() {
                    return itemCount;
                }

                @Override
                public Object getItem(int position) {
                    return "线路 " + (position + 1);
                }

                @Override
                public long getItemId(int position) {
                    return 10_000L + position;
                }

                @Override
                public View getView(
                        int position,
                        View convertView,
                        ViewGroup parent
                ) {
                    TextView row = convertView instanceof TextView
                            ? (TextView) convertView
                            : new TextView((Activity) owner);
                    row.setText("线路 " + (position + 1));
                    row.setMinHeight(72);
                    row.setPadding(20, 8, 20, 8);
                    row.setEnabled(true);
                    row.setClickable(true);
                    row.setOnClickListener(
                            ignored -> clickedPosition.set(position)
                    );
                    return row;
                }
            });
            AlertDialog dialog = new AlertDialog.Builder((Activity) owner)
                    .setTitle("网盘线路前后排序")
                    .setView(list)
                    .setNegativeButton("关闭", null)
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

    private static Bitmap invertedQRCodeBitmap(String content) throws Exception {
        Bitmap source = qrBitmap(content);
        int width = source.getWidth();
        int height = source.getHeight();
        int[] pixels = new int[width * height];
        source.getPixels(pixels, 0, width, 0, 0, width, height);
        for (int index = 0; index < pixels.length; index++) {
            int color = pixels[index];
            pixels[index] = Color.argb(
                    Color.alpha(color),
                    255 - Color.red(color),
                    255 - Color.green(color),
                    255 - Color.blue(color)
            );
        }
        source.recycle();
        Bitmap output = Bitmap.createBitmap(
                width,
                height,
                Bitmap.Config.ARGB_8888
        );
        output.setPixels(pixels, 0, width, 0, 0, width, height);
        return output;
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

    private static JSONObject awaitDialogStack(
            Context context,
            String interactionID,
            int depth,
            long timeoutMilliseconds
    ) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        JSONObject last = null;
        while (System.currentTimeMillis() < deadline) {
            last = BridgeActivity.uiState(context, interactionID);
            if (last.optInt("surfaceWindowStackDepth", 0) == depth
                    && !last.optString("surfaceWindowID", "").isEmpty()) {
                return last;
            }
            Thread.sleep(25L);
        }
        return last == null
                ? BridgeInteractionRegistry.state(interactionID)
                : last;
    }

    private static JSONObject awaitDialogMemberCount(
            Context context,
            String interactionID,
            int memberCount,
            long timeoutMilliseconds
    ) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        JSONObject last = null;
        while (System.currentTimeMillis() < deadline) {
            last = BridgeActivity.uiState(context, interactionID);
            JSONArray stack = last.optJSONArray("surfaceDialogStack");
            if (stack != null && stack.length() == 1
                    && stack.getJSONObject(0).optInt(
                            "memberWindowCount",
                            0
                    ) == memberCount) {
                return last;
            }
            Thread.sleep(25L);
        }
        return last == null
                ? BridgeInteractionRegistry.state(interactionID)
                : last;
    }

    private static JSONObject awaitSurfacePresentation(
            Context context,
            String interactionID,
            String presentationMode,
            long timeoutMilliseconds
    ) throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        JSONObject last = null;
        while (System.currentTimeMillis() < deadline) {
            last = BridgeActivity.uiState(context, interactionID);
            if (presentationMode.equals(last.optString(
                    "surfacePresentationMode",
                    ""
            ))) {
                return last;
            }
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

    private static BridgeProviderOwnerRegistry.Binding playbackOwner(
            String prefix,
            String jarKey
    ) throws Exception {
        String suffix = UUID.randomUUID().toString();
        JSONObject payload = new JSONObject()
                .put("providerOwnerID", prefix + "-provider-" + suffix)
                .put("configurationID", prefix + "-configuration-" + suffix)
                .put("siteKey", prefix + "-site-" + suffix)
                .put("jarURL", jarKey)
                .put("jarMD5", "");
        return BridgeProviderOwnerRegistry.bind(payload, jarKey);
    }

    @SuppressWarnings("unchecked")
    private static void installProxyMethod(
            String jarKey,
            Class<?> proxyType
    ) throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation()
                .getTargetContext();
        DexSpiderRegistry registry = DexSpiderRegistry.get(context);
        Field methodsField = DexSpiderRegistry.class.getDeclaredField(
                "proxyMethods"
        );
        methodsField.setAccessible(true);
        Map<String, Method> methods = (Map<String, Method>) methodsField.get(
                registry
        );
        methods.put(jarKey, proxyType.getMethod("proxy", Map.class));
    }

    private static int loopbackStatus(
            int port,
            String method,
            String path,
            Map<String, String> headers,
            byte[] body
    ) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(
                "http://127.0.0.1:" + port + path
        ).openConnection();
        connection.setRequestMethod(method);
        connection.setConnectTimeout(2_000);
        connection.setReadTimeout(5_000);
        if (headers != null) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                connection.setRequestProperty(entry.getKey(), entry.getValue());
            }
        }
        if (body != null) {
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(body.length);
            try (OutputStream output = connection.getOutputStream()) {
                output.write(body);
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

    public static final class CompatibilityProxyA {
        static final AtomicInteger invocations = new AtomicInteger();
        static final AtomicReference<Map<String, String>> lastParameters =
                new AtomicReference<>();

        public static Object[] proxy(Map<String, String> params) {
            invocations.incrementAndGet();
            lastParameters.set(new LinkedHashMap<>(params));
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("Accept-Ranges", "bytes");
            headers.put("Content-Range", "bytes 100-100/1000");
            return new Object[] {
                    206,
                    "video/mp4",
                    new ByteArrayInputStream(new byte[] {'A'}),
                    headers
            };
        }
    }

    public static final class CompatibilityProxyB {
        static final AtomicInteger invocations = new AtomicInteger();

        public static Object[] proxy(Map<String, String> params) {
            invocations.incrementAndGet();
            return new Object[] {
                    206,
                    "video/mp4",
                    new ByteArrayInputStream(new byte[] {'B'})
            };
        }
    }

    public static final class CompatibilityProxyFlaky {
        static final AtomicInteger invocations = new AtomicInteger();

        public static Object[] proxy(Map<String, String> params) {
            if (invocations.incrementAndGet() == 1) return null;
            return new Object[] {
                    206,
                    "video/mp4",
                    new ByteArrayInputStream(new byte[] {'O', 'K'})
            };
        }
    }

    public static final class CompatibilityProxyUpstreamFailure {
        static final AtomicInteger invocations = new AtomicInteger();

        public static Object[] proxy(Map<String, String> params) {
            invocations.incrementAndGet();
            return new Object[] {
                    502,
                    "text/plain",
                    new ByteArrayInputStream("upstream".getBytes(
                            StandardCharsets.UTF_8
                    ))
            };
        }
    }

    private static Spider proxyResolvingSpider(
            AtomicInteger invocations,
            String mediaSuffix
    ) {
        return new Spider() {
            @Override
            public String playerContent(
                    String flag,
                    String id,
                    java.util.List<String> vipFlags
            ) throws Exception {
                invocations.incrementAndGet();
                HttpURLConnection connection = (HttpURLConnection) new URL(
                        com.github.catvod.Proxy.getUrl(true) + "?do=resolve"
                ).openConnection();
                connection.setConnectTimeout(2_000);
                connection.setReadTimeout(5_000);
                try {
                    int status = connection.getResponseCode();
                    InputStream response = status >= 400
                            ? connection.getErrorStream()
                            : connection.getInputStream();
                    if (response != null) {
                        try (InputStream input = response) {
                            while (input.read() != -1) {
                                // Drain the provider response.
                            }
                        }
                    }
                    if (status != 206) {
                        throw new IOException("provider proxy HTTP " + status);
                    }
                } finally {
                    connection.disconnect();
                }
                return new JSONObject()
                        .put("parse", 0)
                        .put(
                                "url",
                                "https://media.example/" + mediaSuffix + ".mp4"
                        )
                        .toString();
            }
        };
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

    private static Intent launchableExternalActivity(Context context) {
        for (String packageName : new String[] {
                "com.android.calendar",
                "com.android.contacts",
                "com.android.gallery3d",
                "com.android.music"
        }) {
            Intent intent = context.getPackageManager()
                    .getLaunchIntentForPackage(packageName);
            if (intent != null) return intent;
        }
        throw new AssertionError(
                "Test AVD has no launchable external Activity"
        );
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
