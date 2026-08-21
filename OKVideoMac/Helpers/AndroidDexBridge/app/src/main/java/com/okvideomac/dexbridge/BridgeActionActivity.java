package com.okvideomac.dexbridge;

import android.app.Activity;
import android.os.Bundle;

import java.lang.ref.WeakReference;

/**
 * Disposable top Activity for legacy configuration Spiders that finish the
 * current page before showing their dialog on the page underneath.
 */
public final class BridgeActionActivity extends Activity {
    private static volatile WeakReference<BridgeActionActivity> current =
            new WeakReference<>(null);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        current = new WeakReference<>(this);
        // Legacy configuration spiders call Init.context().finish(). Point
        // that global at this disposable Activity so the persistent bridge
        // host underneath survives the handoff.
        com.github.catvod.Init.set(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        current = new WeakReference<>(this);
        com.github.catvod.Init.set(this);
    }

    @Override
    protected void onDestroy() {
        BridgeActionActivity activity = current.get();
        if (activity == this) current.clear();
        android.content.Context host = BridgeActivity.hostContext();
        com.github.catvod.Init.set(
                host == null ? getApplicationContext() : host
        );
        super.onDestroy();
    }

    static boolean isReady() {
        BridgeActionActivity activity = current.get();
        return activity != null
                && !activity.isFinishing()
                && !activity.isDestroyed();
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
}
