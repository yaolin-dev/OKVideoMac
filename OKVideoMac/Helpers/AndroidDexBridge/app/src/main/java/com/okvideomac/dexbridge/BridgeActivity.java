package com.okvideomac.dexbridge;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public final class BridgeActivity extends Activity {
    private static volatile WeakReference<BridgeActivity> current =
            new WeakReference<>(null);
    private static volatile String selectedProvider = "";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        current = new WeakReference<>(this);
        // Guard spiders create account-setting dialogs from their package Init
        // context. Supplying the visible Activity (rather than only the
        // Application) gives AlertDialog a valid themed window owner.
        com.github.catvod.Init.set(this);
        BridgeServer.start(getApplicationContext());
    }

    @Override
    protected void onResume() {
        super.onResume();
        current = new WeakReference<>(this);
        com.github.catvod.Init.set(this);
    }

    @Override
    protected void onDestroy() {
        BridgeActivity activity = current.get();
        if (activity == this) {
            current.clear();
            com.github.catvod.Init.set(getApplicationContext());
        }
        super.onDestroy();
    }

    static Context hostContext() {
        BridgeActivity activity = current.get();
        return activity == null ? null : activity;
    }

    /**
     * WexConfig closes the current Android Activity before posting its account
     * dialog. A normal TV app has its persistent main Activity underneath; the
     * bridge used to have only one Activity, so the delayed dialog received a
     * null Context. Put a disposable translucent Activity above this host so
     * the Spider can finish it and then attach the dialog to the resumed host.
     */
    static void prepareDialogHandoff(Context context) throws Exception {
        BridgeActivity host = current.get();
        if (host == null || host.isFinishing() || host.isDestroyed()) {
            Intent hostIntent = new Intent(context, BridgeActivity.class);
            hostIntent.addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK
                            | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            );
            context.startActivity(hostIntent);
            for (int attempt = 0; attempt < 80; attempt++) {
                Thread.sleep(25);
                host = current.get();
                if (host != null && !host.isFinishing() && !host.isDestroyed()) {
                    break;
                }
            }
        }
        if (host == null || host.isFinishing() || host.isDestroyed()) {
            throw new IllegalStateException("Bridge host activity is unavailable");
        }
        if (BridgeActionActivity.isReady()) return;

        CountDownLatch started = new CountDownLatch(1);
        BridgeActivity selectedHost = host;
        selectedHost.runOnUiThread(() -> {
            try {
                Intent actionIntent = new Intent(
                        selectedHost,
                        BridgeActionActivity.class
                );
                actionIntent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
                selectedHost.startActivity(actionIntent);
                selectedHost.overridePendingTransition(0, 0);
            } finally {
                started.countDown();
            }
        });
        if (!started.await(2, TimeUnit.SECONDS)) {
            throw new IllegalStateException("Timed out starting dialog handoff");
        }
        if (!BridgeActionActivity.awaitReady(2_000L)) {
            throw new IllegalStateException("Dialog handoff activity is unavailable");
        }
    }

    static JSONObject uiState() throws Exception {
        return onUIThread(() -> {
            JSONObject state = new JSONObject();
            JSONArray buttons = new JSONArray();
            JSONArray controls = new JSONArray();
            JSONArray texts = new JSONArray();
            String title = "";
            int inputCount = 0;
            int imageCount = 0;
            int buttonIndex = 0;
            int clickableIndex = 0;
            View root = activeRoot(rootViews());
            if (root != null) {
                for (View view : flattened(root)) {
                    if (!view.isShown()) continue;
                    if (view instanceof EditText) {
                        inputCount++;
                    } else if (view instanceof ImageView) {
                        imageCount++;
                    } else if (view instanceof Button) {
                        String label = textOf((TextView) view);
                        if (!label.isEmpty()) {
                            String id = "button:" + buttonIndex++;
                            JSONObject control = new JSONObject();
                            control.put("id", id);
                            control.put("title", label);
                            controls.put(control);
                            buttons.put(label);
                        }
                    } else if (view.isClickable()) {
                        String label = labelOf(view);
                        if (!label.isEmpty()) {
                            String id = "clickable:" + clickableIndex++;
                            JSONObject control = new JSONObject();
                            control.put("id", id);
                            control.put("title", label);
                            controls.put(control);
                            buttons.put(label);
                        }
                    } else if (view instanceof TextView) {
                        String label = textOf((TextView) view);
                        if (label.isEmpty()) continue;
                        texts.put(label);
                        if (isAlertTitle(view)) title = label;
                    }
                }
            }
            boolean hasContent = inputCount > 0
                    || imageCount > 0
                    || controls.length() > 0
                    || texts.length() > 0;
            rememberProvider(title);
            boolean remoteInput = isRemoteInput(texts);
            String phase = !hasContent
                    ? "hidden"
                    : imageCount > 0 && !remoteInput
                    ? "qr"
                    : inputCount > 0 ? "credentials" : "chooser";
            boolean credentialPush = isCredentialPush(texts);
            if (credentialPush) {
                title = credentialTitle(selectedProvider);
            } else if (title.isEmpty() && hasContent) {
                title = imageCount > 0
                        ? qrTitle(selectedProvider)
                        : "选择网盘登录方式";
            }
            boolean visible = root != null && hasContent;
            String authenticatedProvider = authenticatedProvider(
                    selectedProvider,
                    buttons,
                    texts
            );
            if (!authenticatedProvider.isEmpty()) {
                selectedProvider = authenticatedProvider;
            }
            state.put("visible", visible);
            state.put("title", title);
            state.put("inputCount", inputCount);
            state.put("imageCount", imageCount);
            state.put("buttons", buttons);
            state.put("controls", controls);
            state.put("texts", texts);
            state.put("phase", phase);
            state.put("provider", selectedProvider);
            state.put("credentialPush", credentialPush);
            state.put("remoteInput", remoteInput);
            state.put(
                    "authenticated",
                    !authenticatedProvider.isEmpty()
            );
            return state;
        });
    }

    static JSONObject submitUI(
            String text,
            String buttonText,
            String controlId
    ) throws Exception {
        return onUIThread(() -> {
            View root = activeRoot(rootViews());
            if (root == null) {
                JSONObject result = new JSONObject();
                result.put("clicked", false);
                return result;
            }
            List<View> views = flattened(root);
            for (View view : views) {
                if (view.isShown() && view instanceof EditText && text != null) {
                    ((EditText) view).setText(text);
                }
            }
            boolean clicked = false;
            int buttonIndex = 0;
            int clickableIndex = 0;
            for (View view : views) {
                if (!view.isShown() || !view.isClickable()) continue;
                boolean isButton = view instanceof Button;
                String label = isButton
                        ? textOf((Button) view)
                        : labelOf(view);
                if (label.isEmpty()) continue;
                String id = isButton
                        ? "button:" + buttonIndex++
                        : "clickable:" + clickableIndex++;
                if ((controlId != null && controlId.equals(id))
                        || (controlId == null && label.equals(buttonText))) {
                    rememberProvider(label);
                    clicked = view.performClick();
                    break;
                }
            }
            JSONObject result = new JSONObject();
            result.put("clicked", clicked);
            return result;
        });
    }

    static byte[] snapshotUI() throws Exception {
        return onUIThread(() -> {
            View root = activeRoot(rootViews());
            if (root == null) throw new IllegalStateException("No visible dialog");
            View selected = null;
            int selectedArea = 0;
            for (View view : flattened(root)) {
                if (!view.isShown() || !(view instanceof ImageView)) continue;
                int area = view.getWidth() * view.getHeight();
                if (area > selectedArea) {
                    selected = view;
                    selectedArea = area;
                }
            }
            if (selected == null) {
                throw new IllegalStateException("No visible QR code");
            }
            int width = selected.getWidth();
            int height = selected.getHeight();
            if (width <= 0 || height <= 0) {
                throw new IllegalStateException("Dialog has no drawable bounds");
            }
            Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            canvas.drawColor(Color.WHITE);
            selected.draw(canvas);
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output);
            bitmap.recycle();
            return output.toByteArray();
        });
    }

    private static List<View> rootViews() throws Exception {
        Class<?> type = Class.forName("android.view.WindowManagerGlobal");
        Method getInstance = type.getDeclaredMethod("getInstance");
        getInstance.setAccessible(true);
        Object instance = getInstance.invoke(null);
        Field views = type.getDeclaredField("mViews");
        views.setAccessible(true);
        Object value = views.get(instance);
        ArrayList<View> roots = new ArrayList<>();
        if (value instanceof List) {
            for (Object item : (List<?>) value) {
                if (item instanceof View) roots.add((View) item);
            }
        }
        return roots;
    }

    private static View activeRoot(List<View> roots) {
        for (int index = roots.size() - 1; index >= 0; index--) {
            View root = roots.get(index);
            if (root.getWindowVisibility() == View.VISIBLE
                    && root.isShown()
                    && root.getWidth() > 0
                    && root.getHeight() > 0) {
                return root;
            }
        }
        return null;
    }

    private static List<View> flattened(View root) {
        ArrayList<View> output = new ArrayList<>();
        collect(root, output);
        return output;
    }

    private static void collect(View view, List<View> output) {
        output.add(view);
        if (!(view instanceof ViewGroup)) return;
        ViewGroup group = (ViewGroup) view;
        for (int index = 0; index < group.getChildCount(); index++) {
            collect(group.getChildAt(index), output);
        }
    }

    private static boolean isAlertTitle(View view) {
        if (view.getId() == View.NO_ID) return false;
        try {
            return "alertTitle".equals(
                    view.getResources().getResourceEntryName(view.getId())
            );
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static String textOf(TextView view) {
        CharSequence text = view.getText();
        return text == null ? "" : text.toString().trim();
    }

    private static String labelOf(View view) {
        if (view instanceof TextView) return textOf((TextView) view);
        if (!(view instanceof ViewGroup)) return "";
        for (View child : flattened(view)) {
            if (child == view || !child.isShown() || !(child instanceof TextView)) {
                continue;
            }
            String label = textOf((TextView) child);
            if (!label.isEmpty()) return label;
        }
        return "";
    }

    private static void rememberProvider(String label) {
        String lower = label.toLowerCase();
        if (label.contains("夸父") || label.contains("夸克")
                || lower.contains("quark")) {
            selectedProvider = "quark";
        } else if (label.contains("优汐") || lower.contains("uc")) {
            selectedProvider = "uc";
        } else if (label.contains("嘟嘟") || label.contains("百度")
                || lower.contains("baidu")) {
            selectedProvider = "baidu";
        } else if (label.contains("阿狸") || label.contains("阿里")
                || lower.contains("ali")) {
            selectedProvider = "ali";
        }
    }

    private static String qrTitle(String provider) {
        switch (provider) {
            case "quark":
                return "请使用夸克网盘 APP 扫码登录";
            case "uc":
                return "请使用 UC 网盘 APP 扫码登录";
            case "ali":
                return "请使用阿里云盘 APP 扫码登录";
            case "baidu":
                return "请使用百度网盘 APP 扫码登录";
            default:
                return "请使用对应网盘 APP 扫码登录";
        }
    }

    private static boolean isCredentialPush(JSONArray texts) {
        for (int index = 0; index < texts.length(); index++) {
            String text = texts.optString(index, "");
            String lower = text.toLowerCase();
            if (text.contains("微信扫码推送")
                    || (text.contains("推送")
                    && (lower.contains("cookie") || lower.contains("token")))) {
                return true;
            }
        }
        return false;
    }

    private static boolean isRemoteInput(JSONArray texts) {
        for (int index = 0; index < texts.length(); index++) {
            if (texts.optString(index, "").toLowerCase()
                    .contains("/proxy?do=input")) {
                return true;
            }
        }
        return false;
    }

    private static String credentialTitle(String provider) {
        switch (provider) {
            case "quark":
                return "夸克网盘 Cookie 授权";
            case "uc":
                return "UC 网盘 Cookie 授权";
            case "ali":
                return "阿里云盘 Token 授权";
            case "baidu":
                return "百度网盘 Cookie 授权";
            default:
                return "网盘 Cookie / Token 授权";
        }
    }

    private static String authenticatedProvider(
            String provider,
            JSONArray buttons,
            JSONArray texts
    ) {
        String[] candidates;
        if (provider == null || provider.isEmpty()) {
            candidates = new String[] {"quark", "uc", "baidu", "ali"};
        } else {
            candidates = new String[] {provider};
        }
        for (String candidate : candidates) {
            for (int index = 0; index < buttons.length(); index++) {
                if (isLoggedInText(candidate, buttons.optString(index, ""))) {
                    return candidate;
                }
            }
            for (int index = 0; index < texts.length(); index++) {
                if (isLoggedInText(candidate, texts.optString(index, ""))) {
                    return candidate;
                }
            }
        }
        return "";
    }

    private static boolean isLoggedInText(String provider, String value) {
        if (!value.contains("已登录") || value.contains("未登录")) return false;
        String lower = value.toLowerCase();
        switch (provider) {
            case "quark":
                return value.contains("夸父")
                        || value.contains("夸克")
                        || lower.contains("quark");
            case "uc":
                return value.contains("优汐")
                        || lower.contains("uc");
            case "baidu":
                return value.contains("嘟嘟")
                        || value.contains("百度")
                        || lower.contains("baidu");
            case "ali":
                return value.contains("阿狸")
                        || value.contains("阿里")
                        || lower.contains("ali");
            default:
                return false;
        }
    }

    private static <T> T onUIThread(ValueProvider<T> provider) throws Exception {
        BridgeActivity activity = current.get();
        if (activity == null) throw new IllegalStateException("Bridge activity is unavailable");
        if (Thread.currentThread() == activity.getMainLooper().getThread()) {
            return provider.value();
        }
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<T> value = new AtomicReference<>();
        AtomicReference<Throwable> error = new AtomicReference<>();
        activity.runOnUiThread(() -> {
            try {
                value.set(provider.value());
            } catch (Throwable throwable) {
                error.set(throwable);
            } finally {
                latch.countDown();
            }
        });
        if (!latch.await(5, TimeUnit.SECONDS)) {
            throw new IllegalStateException("Timed out waiting for Android UI");
        }
        if (error.get() != null) {
            Throwable throwable = error.get();
            if (throwable instanceof Exception) throw (Exception) throwable;
            throw new IllegalStateException(throwable);
        }
        return value.get();
    }

    private interface ValueProvider<T> {
        T value() throws Exception;
    }
}
