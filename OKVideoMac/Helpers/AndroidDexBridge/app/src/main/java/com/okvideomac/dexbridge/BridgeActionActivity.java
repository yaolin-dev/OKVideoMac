package com.okvideomac.dexbridge;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;

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
    protected void onResume() {
        super.onResume();
        if (!isCurrentRequest(interactionID)) {
            finish();
            return;
        }
        synchronized (lifecycleLock) {
            current = new WeakReference<>(this);
        }
        com.github.catvod.Init.set(this);
    }

    @Override
    protected void onDestroy() {
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

    static boolean isReady() {
        synchronized (lifecycleLock) {
            return usable(current.get());
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
                activity.finish();
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
                activity.finish();
            }
        });
        return true;
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
}
