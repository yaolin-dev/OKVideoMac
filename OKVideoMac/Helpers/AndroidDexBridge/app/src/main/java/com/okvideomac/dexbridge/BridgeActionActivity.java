package com.okvideomac.dexbridge;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.graphics.Color;
import android.view.Gravity;
import android.widget.TextView;

import java.lang.ref.WeakReference;

/**
 * Disposable top Activity for legacy configuration Spiders that finish the
 * current page before showing their dialog on the page underneath.
 */
public final class BridgeActionActivity extends Activity {
    static final String EXTRA_INTERACTION_ID =
            "okvideomac_interaction_id";
    private static final Object lifecycleLock = new Object();
    private static volatile WeakReference<BridgeActionActivity> current =
            new WeakReference<>(null);
    private static String pendingLaunchInteractionID = "";
    private String interactionID = "";
    private volatile boolean terminalReleaseAuthorized;
    private volatile boolean everResumed;
    private volatile boolean resumed;
    private volatile boolean stopped;
    private volatile boolean windowFocused;
    private volatile boolean everFocused;
    private volatile boolean providerWindowActive;
    private volatile boolean sawProviderWindow;
    private volatile long surfaceGeneration;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        interactionID = getIntent() == null
                ? ""
                : getIntent().getStringExtra(EXTRA_INTERACTION_ID);
        if (interactionID == null) interactionID = "";
        if (!isCurrentRequest(interactionID)) {
            releaseLaunchReservation(interactionID);
            finish();
            return;
        }
        synchronized (lifecycleLock) {
            current = new WeakReference<>(this);
            if (interactionID.equals(pendingLaunchInteractionID)) {
                pendingLaunchInteractionID = "";
            }
        }
        // Legacy configuration spiders call Init.context().finish(). Point
        // that global at this disposable Activity so the persistent bridge
        // host underneath survives the handoff.
        com.github.catvod.Init.set(this);
        TextView placeholder = new TextView(this);
        placeholder.setText("OKVideo Android Action Session");
        placeholder.setTextColor(Color.DKGRAY);
        placeholder.setTextSize(16f);
        placeholder.setGravity(Gravity.CENTER);
        placeholder.setBackgroundColor(Color.rgb(245, 245, 245));
        setContentView(placeholder);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String nextInteractionID = intent == null
                ? ""
                : intent.getStringExtra(EXTRA_INTERACTION_ID);
        if (nextInteractionID == null) nextInteractionID = "";
        if (isFinishing() || !isCurrentRequest(nextInteractionID)) {
            releaseLaunchReservation(nextInteractionID);
            finish();
            return;
        }
        setIntent(intent);
        interactionID = nextInteractionID;
        synchronized (lifecycleLock) {
            current = new WeakReference<>(this);
            if (interactionID.equals(pendingLaunchInteractionID)) {
                pendingLaunchInteractionID = "";
            }
        }
        com.github.catvod.Init.set(this);
    }

    @Override
    protected void onStart() {
        super.onStart();
        stopped = false;
    }

    @Override
    protected void onResume() {
        super.onResume();
        everResumed = true;
        resumed = true;
        stopped = false;
        if (!isCurrentRequest(interactionID)) {
            finish();
            return;
        }
        synchronized (lifecycleLock) {
            current = new WeakReference<>(this);
        }
        com.github.catvod.Init.set(this);
        surfaceGeneration++;
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        windowFocused = hasFocus;
        if (hasFocus) {
            everFocused = true;
            providerWindowActive = false;
        } else if (resumed) {
            // A Dialog owned by this Activity takes window focus without
            // changing the Activity lifecycle. This request-local callback is
            // the presentation signal; no global WindowManager traversal or
            // view-content inspection is needed.
            providerWindowActive = true;
            sawProviderWindow = true;
        }
        surfaceGeneration++;
    }

    @Override
    protected void onPause() {
        resumed = false;
        windowFocused = false;
        surfaceGeneration++;
        super.onPause();
    }

    @Override
    protected void onStop() {
        stopped = true;
        surfaceGeneration++;
        super.onStop();
    }

    @Override
    public void finish() {
        // Some legacy providers implement a multi-step action by calling
        // Init.context().finish() and posting the next Dialog immediately
        // afterwards. Letting that finish escape the request-owned Activity
        // moves the child Dialog onto the persistent BridgeActivity, where it
        // has no reliable session identity and can be mistaken for the next
        // action. Keep the disposable Activity alive until the owning action
        // session reaches a terminal state; only Bridge cleanup may authorize
        // the real Activity finish.
        if (!terminalReleaseAuthorized && isCurrentRequest(interactionID)) {
            com.github.catvod.Init.set(this);
            return;
        }
        // Terminal cleanup dismisses request-owned Dialogs and synchronously
        // hands Init back to a usable host before the Activity window is
        // destroyed. Provider-requested finishes never reach this branch.
        handoffInitContextBeforeFinish();
        super.finish();
    }

    @Override
    protected void onDestroy() {
        resumed = false;
        stopped = true;
        BridgeActionActivity replacement;
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            if (activity == this) current.clear();
            if (interactionID.equals(pendingLaunchInteractionID)) {
                pendingLaunchInteractionID = "";
            }
            replacement = current.get();
        }
        // An old handoff can finish after the next one has already resumed.
        // Its onDestroy must not reset CatVod's global Init context back to the
        // host and detach the newer provider dialog from its Activity.
        if (usable(replacement)) {
            com.github.catvod.Init.set(replacement);
            super.onDestroy();
            return;
        }
        android.content.Context host = BridgeActivity.hostContext();
        com.github.catvod.Init.set(
                host == null ? getApplicationContext() : host
        );
        if (host == null) BridgeActivity.requestHost(getApplicationContext());
        super.onDestroy();
    }

    private void handoffInitContextBeforeFinish() {
        BridgeActionActivity replacement;
        synchronized (lifecycleLock) {
            replacement = current.get();
        }
        if (replacement != this && usable(replacement)
                && isCurrentRequest(replacement.interactionID)) {
            com.github.catvod.Init.set(replacement);
            return;
        }
        Context host = BridgeActivity.hostContext();
        Context fallback = getApplicationContext();
        com.github.catvod.Init.set(host == null ? fallback : host);
        if (host == null) BridgeActivity.requestHost(fallback);
    }

    static boolean isReady() {
        synchronized (lifecycleLock) {
            return usable(current.get());
        }
    }

    static BridgeActionActivity currentActivity() {
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            return usable(activity) ? activity : null;
        }
    }

    static boolean isReadyFor(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            return usable(activity) && id.equals(activity.interactionID);
        }
    }

    static boolean ownsInitContext(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            return usable(activity)
                    && id.equals(activity.interactionID)
                    && com.github.catvod.Init.context() == activity;
        }
    }

    /**
     * Returns a point-in-time lifecycle lease without consulting interaction
     * state. The caller must additionally prove that the ID is the current,
     * nonterminal request before exposing it as request-scoped.
     */
    static SurfaceStatus surfaceStatusFor(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            boolean owned = usable(activity)
                    && !id.isEmpty()
                    && id.equals(activity.interactionID);
            if (!owned) return SurfaceStatus.none();
            String lifecycle = activity.resumed
                    ? "resumed"
                    : activity.stopped
                    ? "stopped"
                    : activity.everResumed ? "paused" : "created";
            // A request-owned ActionActivity is intentionally translucent and
            // remains alive underneath provider-launched full-screen/browser
            // Activities. Once it has resumed at least once, losing resumed
            // state is the conservative lifecycle signal for that external
            // surface. Android lifecycle cannot distinguish that delegation
            // from HOME/lock/background, so this is presentation state only,
            // never provider ownership or login success.
            boolean delegatedSurfaceActive = activity.everResumed
                    && !activity.resumed;
            return new SurfaceStatus(
                    true,
                    delegatedSurfaceActive,
                    activity.providerWindowActive,
                    activity.sawProviderWindow,
                    activity.windowFocused,
                    activity.surfaceGeneration,
                    lifecycle
            );
        }
    }

    static void finishIfOwnedByOther(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        BridgeActionActivity activity;
        synchronized (lifecycleLock) {
            activity = current.get();
        }
        if (activity == null || id.equals(activity.interactionID)) return;
        activity.runOnUiThread(() -> {
            if (!activity.isFinishing() && !activity.isDestroyed()) {
                activity.releaseAndFinish();
            }
        });
    }

    static boolean finishIfOwnedBy(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        BridgeActionActivity activity;
        synchronized (lifecycleLock) {
            activity = current.get();
            if (activity == null || !id.equals(activity.interactionID)) {
                return false;
            }
        }
        activity.runOnUiThread(() -> {
            if (!activity.isFinishing() && !activity.isDestroyed()) {
                activity.releaseAndFinish();
            }
        });
        return true;
    }

    private void releaseAndFinish() {
        terminalReleaseAuthorized = true;
        finish();
    }

    /** Restores CatVod Init to the newest valid owner, never to stale UI. */
    static void restoreInitContext(Context fallbackContext) {
        BridgeActionActivity replacement;
        synchronized (lifecycleLock) {
            replacement = current.get();
        }
        if (usable(replacement)
                && isCurrentRequest(replacement.interactionID)) {
            com.github.catvod.Init.set(replacement);
            return;
        }
        Context host = BridgeActivity.hostContext();
        Context fallback = fallbackContext == null
                ? null
                : fallbackContext.getApplicationContext();
        com.github.catvod.Init.set(host != null ? host : fallback);
        if (host == null && fallback != null) {
            BridgeActivity.requestHost(fallback);
        }
    }

    static String interactionIDFor(Activity activity) {
        if (!(activity instanceof BridgeActionActivity)) return "";
        return ((BridgeActionActivity) activity).interactionID;
    }

    /** Ensures concurrent handoff preparation launches at most one Activity. */
    static boolean reserveLaunch(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            if (usable(activity) && id.equals(activity.interactionID)) {
                return false;
            }
            if (!pendingLaunchInteractionID.isEmpty()) return false;
            if (!isCurrentRequest(id)) return false;
            pendingLaunchInteractionID = id;
            return true;
        }
    }

    static void releaseLaunchReservation(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        synchronized (lifecycleLock) {
            if (id.equals(pendingLaunchInteractionID)) {
                pendingLaunchInteractionID = "";
            }
        }
    }

    static void supersedePendingLaunch(String currentInteractionID) {
        String id = currentInteractionID == null
                ? ""
                : currentInteractionID.trim();
        synchronized (lifecycleLock) {
            if (!pendingLaunchInteractionID.equals(id)) {
                pendingLaunchInteractionID = "";
            }
        }
    }

    static boolean awaitNoForeignOwner(
            String requestedInteractionID,
            long timeoutMilliseconds
    ) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        while (System.currentTimeMillis() < deadline) {
            if (hasNoForeignOwner(requestedInteractionID)) {
                return true;
            }
            Thread.sleep(25L);
        }
        return hasNoForeignOwner(requestedInteractionID);
    }

    static boolean awaitReleased(
            String requestedInteractionID,
            long timeoutMilliseconds
    ) throws InterruptedException {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        while (System.currentTimeMillis() < deadline) {
            if (!isOwnedBy(id)) return true;
            Thread.sleep(25L);
        }
        return !isOwnedBy(id);
    }

    static boolean awaitReady(long timeoutMilliseconds)
            throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        while (System.currentTimeMillis() < deadline) {
            if (isReady()) return true;
            Thread.sleep(25);
        }
        return isReady();
    }

    static boolean awaitReadyFor(
            String interactionID,
            long timeoutMilliseconds
    ) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMilliseconds;
        while (System.currentTimeMillis() < deadline) {
            if (isReadyFor(interactionID)) return true;
            Thread.sleep(25);
        }
        return isReadyFor(interactionID);
    }

    private static boolean hasNoForeignOwner(String requestedInteractionID) {
        String id = requestedInteractionID == null
                ? ""
                : requestedInteractionID.trim();
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            // A finishing foreign Activity still owns a window until
            // onDestroy. Starting its replacement earlier is what produced
            // duplicate BridgeActionActivity windows and WindowLeaked.
            boolean noForeignActivity = activity == null
                    || activity.isDestroyed()
                    || id.equals(activity.interactionID);
            boolean noForeignLaunch = pendingLaunchInteractionID.isEmpty()
                    || id.equals(pendingLaunchInteractionID);
            return noForeignActivity && noForeignLaunch;
        }
    }

    private static boolean isOwnedBy(String requestedInteractionID) {
        synchronized (lifecycleLock) {
            BridgeActionActivity activity = current.get();
            return activity != null
                    && !activity.isDestroyed()
                    && requestedInteractionID.equals(activity.interactionID);
        }
    }

    private static boolean isCurrentRequest(String interactionID) {
        return interactionID != null
                && !interactionID.trim().isEmpty()
                && BridgeInteractionRegistry.ownsLatest(interactionID)
                && !BridgeInteractionRegistry.terminal(interactionID);
    }

    private static boolean usable(BridgeActionActivity activity) {
        return activity != null
                && !activity.isFinishing()
                && !activity.isDestroyed();
    }

    static final class SurfaceStatus {
        final boolean requestScoped;
        final boolean delegatedSurfaceActive;
        final boolean providerWindowActive;
        final boolean sawProviderWindow;
        final boolean windowFocused;
        final long generation;
        final String hostLifecycle;

        SurfaceStatus(
                boolean requestScoped,
                boolean delegatedSurfaceActive,
                boolean providerWindowActive,
                boolean sawProviderWindow,
                boolean windowFocused,
                long generation,
                String hostLifecycle
        ) {
            this.requestScoped = requestScoped;
            this.delegatedSurfaceActive = delegatedSurfaceActive;
            this.providerWindowActive = providerWindowActive;
            this.sawProviderWindow = sawProviderWindow;
            this.windowFocused = windowFocused;
            this.generation = generation;
            this.hostLifecycle = hostLifecycle;
        }

        private static SurfaceStatus none() {
            return new SurfaceStatus(
                    false,
                    false,
                    false,
                    false,
                    false,
                    0L,
                    "none"
            );
        }
    }
}
