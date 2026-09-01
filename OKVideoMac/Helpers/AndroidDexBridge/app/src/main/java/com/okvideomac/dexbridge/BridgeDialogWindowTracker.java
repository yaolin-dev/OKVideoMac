package com.okvideomac.dexbridge;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Rect;
import android.os.IBinder;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Tracks only top-level Dialog windows attached to one ActionSession Activity.
 *
 * <p>This class deliberately inspects WindowManager root metadata only. It
 * never traverses child Views, reads labels, recognizes QR codes, or infers a
 * provider action from visible content. The exact Activity window token is the
 * ownership boundary, and TYPE_TOAST/system/foreign-Activity roots are never
 * admitted to the session stack.</p>
 */
final class BridgeDialogWindowTracker {
    private static final long SNAPSHOT_TIMEOUT_MS = 750L;
    private static final double NEAR_FULL_WIDTH_COVERAGE = 0.90;
    private static final double NEAR_FULL_HEIGHT_COVERAGE = 0.88;
    private static final double NEAR_FULL_AREA_COVERAGE = 0.82;

    private final WeakReference<Activity> owner;
    private final String interactionID;
    private final Map<View, String> windowIDs = new IdentityHashMap<>();
    private long nextWindowSequence;
    private long revision;
    private String lastSignature = "";
    private Snapshot lastSnapshot = Snapshot.empty(false, 0L, 0, 0);
    private boolean released;

    BridgeDialogWindowTracker(Activity owner, String interactionID) {
        this.owner = new WeakReference<>(owner);
        this.interactionID = clean(interactionID);
    }

    Snapshot snapshot() {
        Activity activity = owner.get();
        if (released || activity == null || activity.isDestroyed()) {
            return unavailableSnapshot();
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return inspect(activity);
        }
        CountDownLatch completed = new CountDownLatch(1);
        AtomicReference<Snapshot> result = new AtomicReference<>();
        activity.runOnUiThread(() -> {
            try {
                result.set(inspect(activity));
            } finally {
                completed.countDown();
            }
        });
        try {
            if (completed.await(SNAPSHOT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    && result.get() != null) {
                return result.get();
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
        }
        return unavailableSnapshot();
    }

    boolean commitText(String windowID, long expectedRevision, String text) {
        Activity activity = owner.get();
        String exactWindowID = clean(windowID);
        String value = text == null ? "" : text;
        if (released || activity == null || activity.isDestroyed()
                || exactWindowID.isEmpty() || expectedRevision <= 0L
                || value.isEmpty() || value.length() > 16_384) {
            return false;
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return commitTextOnMain(
                    activity,
                    exactWindowID,
                    expectedRevision,
                    value
            );
        }
        CountDownLatch completed = new CountDownLatch(1);
        AtomicReference<Boolean> result = new AtomicReference<>(false);
        activity.runOnUiThread(() -> {
            try {
                result.set(commitTextOnMain(
                        activity,
                        exactWindowID,
                        expectedRevision,
                        value
                ));
            } finally {
                completed.countDown();
            }
        });
        try {
            return completed.await(SNAPSHOT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    && Boolean.TRUE.equals(result.get());
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    synchronized void release() {
        released = true;
        windowIDs.clear();
        lastSignature = "released";
        revision++;
        lastSnapshot = Snapshot.empty(false, revision, 0, 0);
    }

    private synchronized Snapshot inspect(Activity activity) {
        if (released) return lastSnapshot;
        DisplayMetrics display = realDisplayMetrics(activity);
        final List<View> roots;
        try {
            roots = windowRoots();
        } catch (Throwable ignored) {
            return updateUnavailable(display.widthPixels, display.heightPixels);
        }

        View activityRoot = activity.getWindow() == null
                ? null
                : activity.getWindow().getDecorView();
        IBinder ownerToken = activityRoot == null
                ? null
                : activityRoot.getApplicationWindowToken();
        List<WindowEntry> stack = new ArrayList<>();
        Set<View> retained = Collections.newSetFromMap(new IdentityHashMap<>());
        for (View root : roots) {
            if (root == null || root == activityRoot || !isVisible(root)) {
                continue;
            }
            ViewGroup.LayoutParams baseParams = root.getLayoutParams();
            if (!(baseParams instanceof WindowManager.LayoutParams)) continue;
            WindowManager.LayoutParams params =
                    (WindowManager.LayoutParams) baseParams;
            if (!isDialogWindowType(params.type)) continue;
            if (!ownedBy(activity, ownerToken, root)) continue;
            Rect bounds = rootBounds(root, display.widthPixels, display.heightPixels);
            if (bounds.isEmpty()) continue;
            retained.add(root);
            String windowID = windowIDs.get(root);
            if (windowID == null) {
                windowID = String.format(
                        Locale.ROOT,
                        "%s-dialog-%d",
                        shortID(interactionID),
                        ++nextWindowSequence
                );
                windowIDs.put(root, windowID);
            }
            stack.add(new WindowEntry(
                    windowID,
                    bounds,
                    isNearFullDisplay(
                            bounds,
                            display.widthPixels,
                            display.heightPixels
                    )
            ));
        }
        windowIDs.keySet().retainAll(retained);
        String signature = signature(stack, display.widthPixels, display.heightPixels);
        if (!signature.equals(lastSignature)) {
            lastSignature = signature;
            revision++;
        }
        lastSnapshot = new Snapshot(
                true,
                revision,
                display.widthPixels,
                display.heightPixels,
                stack
        );
        return lastSnapshot;
    }

    private synchronized boolean commitTextOnMain(
            Activity activity,
            String windowID,
            long expectedRevision,
            String text
    ) {
        Snapshot current = inspect(activity);
        WindowEntry top = current.topWindow();
        if (!current.scanAvailable
                || current.revision != expectedRevision
                || top == null
                || !windowID.equals(top.windowID)) {
            return false;
        }
        View root = null;
        for (Map.Entry<View, String> entry : windowIDs.entrySet()) {
            if (windowID.equals(entry.getValue())) {
                root = entry.getKey();
                break;
            }
        }
        if (root == null) return false;
        // This is Android's existing focus route, not control-tree parsing.
        // The provider still owns the EditText/InputConnection and all
        // validation, selection and persistence behavior.
        View focused = root.findFocus();
        if (focused == null) return false;
        InputConnection connection = focused.onCreateInputConnection(
                new EditorInfo()
        );
        if (connection == null) return false;
        connection.beginBatchEdit();
        try {
            return connection.commitText(text, 1);
        } finally {
            connection.endBatchEdit();
        }
    }

    private synchronized Snapshot unavailableSnapshot() {
        Activity activity = owner.get();
        DisplayMetrics display = activity == null
                ? new DisplayMetrics()
                : realDisplayMetrics(activity);
        return updateUnavailable(display.widthPixels, display.heightPixels);
    }

    private Snapshot updateUnavailable(int displayWidth, int displayHeight) {
        String signature = "unavailable:" + displayWidth + "x" + displayHeight;
        if (!signature.equals(lastSignature)) {
            lastSignature = signature;
            revision++;
        }
        lastSnapshot = Snapshot.empty(
                false,
                revision,
                displayWidth,
                displayHeight
        );
        return lastSnapshot;
    }

    @SuppressWarnings("deprecation")
    private static DisplayMetrics realDisplayMetrics(Activity activity) {
        DisplayMetrics metrics = new DisplayMetrics();
        try {
            activity.getWindowManager().getDefaultDisplay().getRealMetrics(metrics);
        } catch (Throwable ignored) {
            metrics.setTo(activity.getResources().getDisplayMetrics());
        }
        return metrics;
    }

    private static boolean isVisible(View root) {
        return root.isAttachedToWindow()
                && root.getVisibility() == View.VISIBLE
                && root.getWindowVisibility() == View.VISIBLE
                && root.getAlpha() > 0f
                && root.getWidth() > 0
                && root.getHeight() > 0;
    }

    private static boolean isDialogWindowType(int type) {
        return type == WindowManager.LayoutParams.TYPE_APPLICATION
                || type == WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG;
    }

    private static boolean ownedBy(
            Activity activity,
            IBinder ownerToken,
            View root
    ) {
        IBinder rootToken = root.getApplicationWindowToken();
        if (ownerToken != null && rootToken == ownerToken) return true;
        Context context = root.getContext();
        for (int depth = 0; context != null && depth < 16; depth++) {
            if (context == activity) return true;
            if (!(context instanceof ContextWrapper)) break;
            Context base = ((ContextWrapper) context).getBaseContext();
            if (base == context) break;
            context = base;
        }
        return false;
    }

    private static Rect rootBounds(
            View root,
            int displayWidth,
            int displayHeight
    ) {
        int[] location = new int[2];
        root.getLocationOnScreen(location);
        Rect bounds = new Rect(
                location[0],
                location[1],
                location[0] + root.getWidth(),
                location[1] + root.getHeight()
        );
        if (displayWidth > 0 && displayHeight > 0
                && !bounds.intersect(0, 0, displayWidth, displayHeight)) {
            return new Rect();
        }
        return bounds;
    }

    static boolean isNearFullDisplay(
            Rect bounds,
            int displayWidth,
            int displayHeight
    ) {
        if (bounds == null || bounds.isEmpty()
                || displayWidth <= 0 || displayHeight <= 0) {
            return false;
        }
        double widthCoverage = (double) bounds.width() / displayWidth;
        double heightCoverage = (double) bounds.height() / displayHeight;
        double areaCoverage = (double) bounds.width() * bounds.height()
                / ((double) displayWidth * displayHeight);
        return widthCoverage >= NEAR_FULL_WIDTH_COVERAGE
                && heightCoverage >= NEAR_FULL_HEIGHT_COVERAGE
                && areaCoverage >= NEAR_FULL_AREA_COVERAGE;
    }

    private static String signature(
            List<WindowEntry> stack,
            int displayWidth,
            int displayHeight
    ) {
        StringBuilder value = new StringBuilder()
                .append("available:")
                .append(displayWidth)
                .append('x')
                .append(displayHeight);
        for (WindowEntry entry : stack) {
            value.append('|')
                    .append(entry.windowID)
                    .append(':')
                    .append(entry.bounds.flattenToString())
                    .append(':')
                    .append(entry.nearFullDisplay);
        }
        return value.toString();
    }

    @SuppressLint("BlockedPrivateApi")
    @SuppressWarnings("unchecked")
    private static List<View> windowRoots() throws Exception {
        Class<?> type = Class.forName("android.view.WindowManagerGlobal");
        Method getInstance = type.getDeclaredMethod("getInstance");
        getInstance.setAccessible(true);
        Object global = getInstance.invoke(null);
        try {
            Method getWindowViews = type.getDeclaredMethod("getWindowViews");
            getWindowViews.setAccessible(true);
            Object value = getWindowViews.invoke(global);
            if (value instanceof List) {
                return new ArrayList<>((List<View>) value);
            }
        } catch (Throwable ignored) {
            // Older Android releases expose the same ordered roots as mViews;
            // also try it when a vendor build hides getWindowViews itself.
        }
        Field views = type.getDeclaredField("mViews");
        views.setAccessible(true);
        Object value = views.get(global);
        if (!(value instanceof List)) {
            throw new IllegalStateException("WindowManager roots unavailable");
        }
        return new ArrayList<>((List<View>) value);
    }

    private static String shortID(String value) {
        String clean = clean(value);
        if (clean.isEmpty()) return "session";
        return clean.length() <= 8 ? clean : clean.substring(0, 8);
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    static final class Snapshot {
        final boolean scanAvailable;
        final long revision;
        final int displayWidth;
        final int displayHeight;
        final List<WindowEntry> stack;

        Snapshot(
                boolean scanAvailable,
                long revision,
                int displayWidth,
                int displayHeight,
                List<WindowEntry> stack
        ) {
            this.scanAvailable = scanAvailable;
            this.revision = revision;
            this.displayWidth = displayWidth;
            this.displayHeight = displayHeight;
            this.stack = Collections.unmodifiableList(new ArrayList<>(stack));
        }

        static Snapshot empty(
                boolean scanAvailable,
                long revision,
                int displayWidth,
                int displayHeight
        ) {
            return new Snapshot(
                    scanAvailable,
                    revision,
                    displayWidth,
                    displayHeight,
                    Collections.emptyList()
            );
        }

        boolean hasWindows() {
            return !stack.isEmpty();
        }

        WindowEntry topWindow() {
            return stack.isEmpty() ? null : stack.get(stack.size() - 1);
        }

        JSONObject displayJSON() {
            JSONObject value = new JSONObject();
            try {
                value.put("width", displayWidth);
                value.put("height", displayHeight);
            } catch (Throwable ignored) {
            }
            return value;
        }

        JSONArray stackJSON() {
            JSONArray value = new JSONArray();
            for (WindowEntry entry : stack) value.put(entry.json());
            return value;
        }
    }

    static final class WindowEntry {
        final String windowID;
        final Rect bounds;
        final boolean nearFullDisplay;

        WindowEntry(String windowID, Rect bounds, boolean nearFullDisplay) {
            this.windowID = windowID;
            this.bounds = new Rect(bounds);
            this.nearFullDisplay = nearFullDisplay;
        }

        JSONObject json() {
            JSONObject value = new JSONObject();
            try {
                value.put("windowID", windowID);
                value.put("bounds", boundsJSON(bounds));
                value.put("nearFullDisplay", nearFullDisplay);
            } catch (Throwable ignored) {
            }
            return value;
        }

        static JSONObject boundsJSON(Rect bounds) {
            JSONObject value = new JSONObject();
            try {
                value.put("left", bounds.left);
                value.put("top", bounds.top);
                value.put("right", bounds.right);
                value.put("bottom", bounds.bottom);
                value.put("width", bounds.width());
                value.put("height", bounds.height());
            } catch (Throwable ignored) {
            }
            return value;
        }
    }
}
