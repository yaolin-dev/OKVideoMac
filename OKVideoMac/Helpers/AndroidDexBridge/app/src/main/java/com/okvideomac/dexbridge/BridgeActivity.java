package com.okvideomac.dexbridge;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;

import org.json.JSONObject;

import java.lang.ref.WeakReference;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Persistent host for the local Dex bridge.
 *
 * <p>Interactive provider actions run in a disposable
 * {@link BridgeActionActivity}. The bridge observes only that Activity's
 * request-owned lifecycle and top-level window metadata. It never traverses
 * provider child-view trees, reads labels, decodes QR codes, or translates
 * Android controls into a second host UI.</p>
 */
public final class BridgeActivity extends Activity {
    private static volatile WeakReference<BridgeActivity> current =
            new WeakReference<>(null);
    private static volatile Context applicationContext;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        applicationContext = getApplicationContext();
        current = new WeakReference<>(this);
        com.github.catvod.Init.set(this);
        updateRuntimeGeneration(getIntent());
        BridgeServer.start(getApplicationContext());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        updateRuntimeGeneration(intent);
        BridgeServer.start(getApplicationContext());
    }

    @Override
    protected void onResume() {
        super.onResume();
        current = new WeakReference<>(this);
        if (!BridgeActionActivity.isReady()) {
            com.github.catvod.Init.set(this);
        }
        BridgeServer.start(getApplicationContext());
    }

    @Override
    protected void onDestroy() {
        BridgeActivity activity = current.get();
        if (activity == this) {
            current.clear();
            if (!BridgeActionActivity.isReady()) {
                com.github.catvod.Init.set(getApplicationContext());
            }
        }
        super.onDestroy();
    }

    private static void updateRuntimeGeneration(Intent intent) {
        if (intent == null) return;
        String generation = intent.getStringExtra(
                "okvideomac_runtime_generation"
        );
        if (generation != null && !generation.isEmpty()) {
            BridgeServer.setRuntimeGeneration(generation);
        }
    }

    static Context hostContext() {
        BridgeActionActivity action = BridgeActionActivity.currentActivity();
        return action == null ? current.get() : action;
    }

    /** Called after the registry has synchronously superseded the old ID. */
    static void beginInteraction(String interactionID) {
        BridgeActionActivity.supersedePendingLaunch(clean(interactionID));
    }

    static void providerCompleted(String interactionID) {
        String id = clean(interactionID);
        if (BridgeInteractionRegistry.terminal(id)) {
            BridgeServer.releaseTerminalInteraction(applicationContext, id);
        }
    }

    static void prepareDialogHandoff(Context context) throws Exception {
        prepareDialogHandoff(context, "");
    }

    /** Starts the one opaque, request-owned Android surface for an action. */
    static void prepareDialogHandoff(Context context, String interactionID)
            throws Exception {
        String id = clean(interactionID);
        if (id.isEmpty()
                || !BridgeInteractionRegistry.ownsLatest(id)
                || BridgeInteractionRegistry.terminal(id)) {
            throw new IllegalStateException("Interaction is no longer current");
        }
        BridgeInteractionRegistry.expectProviderUI(id);
        BridgeActivity host = ensureHost(context, 2_000L);
        if (host == null) {
            throw new IllegalStateException("Bridge host activity is unavailable");
        }
        if (BridgeActionActivity.isReadyFor(id)) return;
        BridgeActionActivity.finishIfOwnedByOther(id);
        if (!BridgeActionActivity.awaitNoForeignOwner(id, 2_000L)) {
            throw new IllegalStateException(
                    "Previous action session is still active"
            );
        }
        boolean ownsReservation = BridgeActionActivity.reserveLaunch(id);
        if (ownsReservation) {
            CountDownLatch started = new CountDownLatch(1);
            AtomicReference<Throwable> failure = new AtomicReference<>();
            host.runOnUiThread(() -> {
                try {
                    if (!BridgeInteractionRegistry.ownsLatest(id)
                            || BridgeInteractionRegistry.terminal(id)) {
                        BridgeActionActivity.releaseLaunchReservation(id);
                        return;
                    }
                    Intent intent = new Intent(host, BridgeActionActivity.class);
                    intent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
                    intent.putExtra(
                            BridgeActionActivity.EXTRA_INTERACTION_ID,
                            id
                    );
                    host.startActivity(intent);
                    host.overridePendingTransition(0, 0);
                } catch (Throwable error) {
                    failure.set(error);
                    BridgeActionActivity.releaseLaunchReservation(id);
                } finally {
                    started.countDown();
                }
            });
            if (!started.await(2L, TimeUnit.SECONDS)) {
                BridgeActionActivity.releaseLaunchReservation(id);
                throw new IllegalStateException(
                        "Timed out starting action session"
                );
            }
            if (failure.get() != null) {
                throw new IllegalStateException(
                        "Unable to start action session",
                        failure.get()
                );
            }
        }
        if (!BridgeActionActivity.awaitReadyFor(id, 2_000L)) {
            BridgeActionActivity.releaseLaunchReservation(id);
            throw new IllegalStateException("Action session is unavailable");
        }
    }

    static JSONObject uiState() throws Exception {
        return uiState(applicationContext, BridgeInteractionRegistry.latestID());
    }

    static JSONObject uiState(Context context, String interactionID)
            throws Exception {
        String id = clean(interactionID);
        if (id.isEmpty() || !BridgeInteractionRegistry.exists(id)) {
            return BridgeInteractionRegistry.state(id);
        }
        JSONObject state = BridgeInteractionRegistry.observeUI(
                id,
                actionSurfaceState(id)
        );
        if (state.optBoolean("terminal", false)) {
            BridgeServer.releaseTerminalInteraction(context, id);
        }
        return state;
    }

    static JSONObject dismissUI() throws Exception {
        return dismissUI(applicationContext, BridgeInteractionRegistry.latestID());
    }

    static JSONObject dismissUI(Context context, String interactionID)
            throws Exception {
        String id = clean(interactionID);
        BridgeInteractionRegistry.cancel(id, "legacyDismiss");
        boolean dismissed = BridgeServer.releaseTerminalInteraction(context, id);
        JSONObject result = BridgeInteractionRegistry.state(id);
        result.put("dismissed", dismissed);
        return result;
    }

    /** Ends the exact disposable Activity; Android owns all child windows. */
    static boolean releaseTerminalUI(Context context, String interactionID)
            throws Exception {
        String id = clean(interactionID);
        if (id.isEmpty()) return false;
        boolean finished = BridgeActionActivity.finishIfOwnedBy(id);
        if (finished) BridgeActionActivity.awaitReleased(id, 2_000L);
        BridgeActionActivity.releaseLaunchReservation(id);
        BridgeActionActivity.restoreInitContext(context);
        return finished;
    }

    static void requestHost(Context context) {
        try {
            ensureHost(context, 0L);
        } catch (Throwable ignored) {
        }
    }

    private static JSONObject actionSurfaceState(String interactionID)
            throws Exception {
        BridgeActionActivity.SurfaceStatus status =
                BridgeActionActivity.surfaceStatusFor(interactionID);
        boolean current = BridgeInteractionRegistry.ownsLatest(interactionID)
                && !BridgeInteractionRegistry.terminal(interactionID);
        boolean scoped = current && status.requestScoped;
        boolean external = scoped && status.delegatedSurfaceActive;
        BridgeDialogWindowTracker.Snapshot windows = status.dialogWindows;
        BridgeDialogWindowTracker.WindowEntry topWindow =
                windows == null ? null : windows.topWindow();
        boolean providerWindow = scoped
                && (status.providerWindowActive || topWindow != null);
        String presentationMode = "none";
        String fallbackReason = "";
        if (external) {
            presentationMode = "fullDisplay";
            fallbackReason = "externalActivity";
        } else if (topWindow != null) {
            if (topWindow.nearFullDisplay) {
                presentationMode = "fullDisplay";
                fallbackReason = "nearFullDisplayDialog";
            } else {
                presentationMode = "dialogCrop";
            }
        } else if (providerWindow) {
            presentationMode = "fullDisplay";
            fallbackReason = windows != null && windows.scanAvailable
                    ? "dialogBoundsUnavailable"
                    : "dialogTrackerUnavailable";
        }

        JSONObject state = new JSONObject();
        state.put("visible", providerWindow);
        state.put("generation", status.generation);
        state.put("surfaceActive", scoped);
        state.put("surfaceRequestScoped", scoped);
        state.put("surfaceDelegated", external);
        state.put("surfaceInteractionID", scoped ? interactionID : "");
        state.put(
                "surfaceMode",
                external
                        ? "externalActivity"
                        : providerWindow
                        ? "providerWindow"
                        : scoped ? "actionActivity" : "none"
        );
        state.put(
                "surfaceHostLifecycle",
                scoped ? status.hostLifecycle : "none"
        );
        state.put("surfacePresentationMode", presentationMode);
        state.put("surfaceFallbackReason", fallbackReason);
        state.put(
                "surfaceWindowID",
                topWindow == null ? "" : topWindow.windowID
        );
        state.put(
                "surfaceWindowRevision",
                windows == null ? 0L : windows.revision
        );
        state.put(
                "surfaceWindowStackDepth",
                windows == null ? 0 : windows.stack.size()
        );
        state.put(
                "surfaceWindowBounds",
                topWindow == null
                        ? JSONObject.NULL
                        : BridgeDialogWindowTracker.WindowEntry.boundsJSON(
                                topWindow.bounds
                        )
        );
        state.put(
                "surfaceWindowContentBounds",
                topWindow == null
                        ? JSONObject.NULL
                        : BridgeDialogWindowTracker.WindowEntry.boundsJSON(
                                topWindow.contentBounds
                        )
        );
        state.put(
                "surfaceDisplayBounds",
                windows == null ? JSONObject.NULL : windows.displayJSON()
        );
        state.put(
                "surfaceDialogStack",
                windows == null ? new org.json.JSONArray() : windows.stackJSON()
        );
        state.put(
                "surfaceDialogTrackerAvailable",
                windows != null && windows.scanAvailable
        );
        state.put("providerWindowActive", providerWindow);
        state.put("sawProviderWindow", scoped && status.sawProviderWindow);
        state.put("windowFocused", scoped && status.windowFocused);
        state.put(
                "phase",
                external
                        ? "awaitingExternalSurface"
                        : providerWindow ? "awaitingUser" : "actionSession"
        );
        state.put("outcome", "stay");
        state.put("hostUnavailable", !scoped);
        return state;
    }

    private static BridgeActivity ensureHost(
            Context suppliedContext,
            long timeoutMilliseconds
    ) throws InterruptedException {
        BridgeActivity activity = current.get();
        if (usable(activity)) return activity;
        Context context = suppliedContext == null
                ? applicationContext
                : suppliedContext.getApplicationContext();
        if (context == null) return null;
        applicationContext = context;
        Intent intent = new Intent(context, BridgeActivity.class);
        intent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        | Intent.FLAG_ACTIVITY_CLEAR_TOP
        );
        context.startActivity(intent);
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        do {
            activity = current.get();
            if (usable(activity)) return activity;
            if (timeoutMilliseconds <= 0L) break;
            Thread.sleep(25L);
        } while (System.currentTimeMillis() < deadline);
        return usable(activity) ? activity : null;
    }

    private static boolean usable(BridgeActivity activity) {
        return activity != null
                && !activity.isFinishing()
                && !activity.isDestroyed();
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
