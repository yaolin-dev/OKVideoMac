package com.okvideomac.dexbridge;

import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.Looper;
import android.text.InputType;
import android.text.method.PasswordTransformationMethod;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.Window;
import android.widget.Button;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.MultiFormatReader;
import com.google.zxing.RGBLuminanceSource;
import com.google.zxing.common.HybridBinarizer;

import java.io.ByteArrayOutputStream;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.EnumMap;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public final class BridgeActivity extends Activity {
    private static final int UI_SCHEMA_VERSION = 2;
    private static volatile WeakReference<BridgeActivity> current =
            new WeakReference<>(null);
    private static volatile Context applicationContext;
    private static volatile String activeInteractionID = "";
    private static volatile String expectedUIInteractionID = "";
    private static volatile String uiOwnerInteractionID = "";
    private static volatile long expectedUIMinimumGeneration = Long.MAX_VALUE;
    private static final Object uiOwnerLock = new Object();
    private static volatile long uiGeneration = 0L;
    private static volatile String lastUISignature = "";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        applicationContext = getApplicationContext();
        current = new WeakReference<>(this);
        // Guard spiders create account-setting dialogs from their package Init
        // context. Supplying the visible Activity (rather than only the
        // Application) gives AlertDialog a valid themed window owner.
        com.github.catvod.Init.set(this);
        updateRuntimeGeneration(getIntent());
        BridgeServer.start(getApplicationContext());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        updateRuntimeGeneration(intent);
        // A retry normally targets the already-running singleTop Activity.
        // If the listener's first bind/serve attempt failed, onCreate will not
        // run again, so this intent must be able to restart it idempotently.
        BridgeServer.start(getApplicationContext());
    }

    @Override
    protected void onResume() {
        super.onResume();
        current = new WeakReference<>(this);
        com.github.catvod.Init.set(this);
        // Also heal a listener that stopped while the Activity was paused.
        BridgeServer.start(getApplicationContext());
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

    private static void updateRuntimeGeneration(Intent intent) {
        if (intent == null) return;
        String generation = intent.getStringExtra(
                "okvideomac_runtime_generation"
        );
        // Internal handoff/reorder intents do not carry a generation. They
        // must never erase the generation established by the Mac runtime or
        // the next health check will incorrectly restart a healthy bridge.
        if (generation != null && !generation.isEmpty()) {
            BridgeServer.setRuntimeGeneration(generation);
        }
    }

    static Context hostContext() {
        BridgeActivity activity = current.get();
        return activity == null ? null : activity;
    }

    /** Invalidates UI ownership before a new request-scoped worker starts. */
    static void beginInteraction(String interactionID) {
        String id = cleanInteractionID(interactionID);
        BridgeActionActivity.supersedePendingLaunch(id);
        synchronized (uiOwnerLock) {
            activeInteractionID = id;
            expectedUIInteractionID = "";
            expectedUIMinimumGeneration = Long.MAX_VALUE;
            // Keep the old owner identity until its window is explicitly
            // dismissed. A new request must never inherit a global window
            // merely because it became the registry's latest request.
        }
    }

    /** Marks the precise worker that is allowed to create the next UI. */
    private static void expectUIForInteraction(String interactionID) {
        String id = cleanInteractionID(interactionID);
        boolean accepted = false;
        synchronized (uiOwnerLock) {
            if (id.isEmpty() || !id.equals(activeInteractionID)) return;
            expectedUIInteractionID = id;
            expectedUIMinimumGeneration = uiGeneration + 1L;
            accepted = true;
        }
        if (accepted) BridgeInteractionRegistry.expectProviderUI(id);
    }

    static void providerCompleted(String interactionID) {
        String id = cleanInteractionID(interactionID);
        // A worker may return before a provider posts its request-owned dialog
        // (notably WexConfig's QR flow). Keep the handoff owner alive while the
        // interaction is in its explicit delayed-UI phase.
        if (!BridgeInteractionRegistry.terminal(id)) return;
        BridgeServer.releaseTerminalInteraction(applicationContext, id);
    }

    /**
     * WexConfig closes the current Android Activity before posting its account
     * dialog. A normal TV app has its persistent main Activity underneath; the
     * bridge used to have only one Activity, so the delayed dialog received a
     * null Context. Put a disposable translucent Activity above this host so
     * the Spider can finish it and then attach the dialog to the resumed host.
     */
    static void prepareDialogHandoff(Context context) throws Exception {
        prepareDialogHandoff(context, "");
    }

    static void prepareDialogHandoff(
            Context context,
            String interactionID
    ) throws Exception {
        if (interactionID != null && !interactionID.trim().isEmpty()) {
            expectUIForInteraction(interactionID);
        }
        BridgeActivity host = ensureHost(context, 2_000L);
        if (host == null) throw new IllegalStateException(
                "Bridge host activity is unavailable"
        );
        String scopedInteractionID = cleanInteractionID(interactionID);
        if (BridgeActionActivity.isReadyFor(scopedInteractionID)) return;
        BridgeActionActivity.finishIfOwnedByOther(scopedInteractionID);
        if (!BridgeActionActivity.awaitNoForeignOwner(
                scopedInteractionID,
                2_000L
        )) {
            throw new IllegalStateException(
                    "Previous dialog handoff is still active"
            );
        }

        boolean ownsLaunchReservation =
                BridgeActionActivity.reserveLaunch(scopedInteractionID);
        if (ownsLaunchReservation) {
            CountDownLatch started = new CountDownLatch(1);
            AtomicReference<Throwable> launchFailure = new AtomicReference<>();
            BridgeActivity selectedHost = host;
            selectedHost.runOnUiThread(() -> {
                try {
                    if (!BridgeInteractionRegistry.ownsLatest(scopedInteractionID)
                            || BridgeInteractionRegistry.terminal(
                                    scopedInteractionID
                            )) {
                        BridgeActionActivity.releaseLaunchReservation(
                                scopedInteractionID
                        );
                        return;
                    }
                    Intent actionIntent = new Intent(
                            selectedHost,
                            BridgeActionActivity.class
                    );
                    actionIntent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
                    actionIntent.putExtra(
                            BridgeActionActivity.EXTRA_INTERACTION_ID,
                            scopedInteractionID
                    );
                    selectedHost.startActivity(actionIntent);
                    selectedHost.overridePendingTransition(0, 0);
                } catch (Throwable error) {
                    launchFailure.set(error);
                } finally {
                    started.countDown();
                }
            });
            if (!started.await(2, TimeUnit.SECONDS)) {
                BridgeActionActivity.releaseLaunchReservation(
                        scopedInteractionID
                );
                throw new IllegalStateException(
                        "Timed out starting dialog handoff"
                );
            }
            if (launchFailure.get() != null) {
                BridgeActionActivity.releaseLaunchReservation(
                        scopedInteractionID
                );
                throw new IllegalStateException(
                        "Unable to start dialog handoff",
                        launchFailure.get()
                );
            }
        }
        if (!BridgeActionActivity.awaitReadyFor(scopedInteractionID, 2_000L)) {
            BridgeActionActivity.releaseLaunchReservation(scopedInteractionID);
            throw new IllegalStateException("Dialog handoff activity is unavailable");
        }
    }

    static JSONObject uiState() throws Exception {
        return uiState(applicationContext, BridgeInteractionRegistry.latestID());
    }

    static JSONObject uiState(Context context, String interactionID) throws Exception {
        boolean explicitlyScoped = interactionID != null
                && !interactionID.trim().isEmpty();
        if (explicitlyScoped
                && !BridgeInteractionRegistry.exists(interactionID)) {
            return BridgeInteractionRegistry.state(interactionID);
        }
        String id = normalizedInteractionID(interactionID);
        BridgeActivity host = ensureHost(context, 2_000L);
        if (host == null) {
            return observeAndFinalize(context, id, hostUnavailableUI());
        }
        try {
            return observeAndFinalize(
                    context,
                    id,
                    scopedUIState(id, captureUIState(host))
            );
        } catch (Throwable firstFailure) {
            // Keep the state endpoint structured across the short Activity
            // replacement window used by provider dialogs. A lost weak
            // reference must not turn polling into an HTTP 500.
            BridgeActivity recovered = ensureHost(context, 500L);
            if (recovered != null && recovered != host) {
                try {
                    return observeAndFinalize(
                            context,
                            id,
                            scopedUIState(id, captureUIState(recovered))
                    );
                } catch (Throwable ignored) {
                    // Return the request-owned availability state below.
                }
            }
            return observeAndFinalize(context, id, hostUnavailableUI());
        }
    }

    private static JSONObject observeAndFinalize(
            Context context,
            String interactionID,
            JSONObject ui
    ) {
        JSONObject state = BridgeInteractionRegistry.observeUI(
                interactionID,
                ui
        );
        if (state.optBoolean("terminal", false)) {
            BridgeServer.releaseTerminalInteraction(context, interactionID);
        }
        return state;
    }

    private static JSONObject hostUnavailableUI() throws Exception {
        JSONObject unavailable = new JSONObject();
        unavailable.put("visible", false);
        unavailable.put("title", "");
        unavailable.put("inputCount", 0);
        unavailable.put("imageCount", 0);
        unavailable.put("credentialInputCount", 0);
        unavailable.put("qrImageCount", 0);
        unavailable.put("uiRole", "configuration");
        unavailable.put("authorizationCandidate", false);
        unavailable.put("buttons", new JSONArray());
        unavailable.put("controls", new JSONArray());
        unavailable.put("texts", new JSONArray());
        unavailable.put("uiSchemaVersion", UI_SCHEMA_VERSION);
        unavailable.put("elements", new JSONArray());
        unavailable.put("generation", uiGeneration);
        unavailable.put("hostUnavailable", true);
        unavailable.put("phase", "reattaching");
        unavailable.put("outcome", "stay");
        return unavailable;
    }

    private static JSONObject captureUIState(BridgeActivity host) throws Exception {
        return onUIThread(host, () -> {
            JSONObject state = new JSONObject();
            JSONArray buttons = new JSONArray();
            JSONArray controls = new JSONArray();
            JSONArray texts = new JSONArray();
            JSONArray elements = new JSONArray();
            String title = "";
            int inputCount = 0;
            int imageCount = 0;
            int credentialInputCount = 0;
            int qrImageCount = 0;
            View root = activeRoot(rootViews());
            Activity windowOwner = root == null
                    ? null
                    : activityFrom(root.getContext());
            String windowOwnerInteractionID =
                    BridgeActionActivity.interactionIDFor(windowOwner);
            if (root != null) {
                int elementOrder = 0;
                for (View view : flattened(root)) {
                    if (!view.isShown()) continue;
                    if (view instanceof EditText) {
                        inputCount++;
                        boolean credential = isCredentialInput((EditText) view);
                        if (credential) {
                            credentialInputCount++;
                        }
                        elements.put(uiElement(
                                view,
                                root,
                                credential ? "secureField" : "textField",
                                inputLabel((EditText) view),
                                "input",
                                elementOrder++
                        ));
                    } else if (view instanceof ImageView) {
                        imageCount++;
                        boolean qrCode = isQRCodeImage((ImageView) view);
                        if (qrCode) qrImageCount++;
                        String label = actionableLabelOf(view);
                        boolean imageAction = view.isClickable()
                                && view.isEnabled()
                                && !label.isEmpty();
                        elements.put(uiElement(
                                view,
                                root,
                                qrCode
                                        ? "qrCode"
                                        : imageAction ? "imageButton" : "image",
                                label,
                                imageAction ? "action" : "image",
                                elementOrder++
                        ));
                        if (imageAction) {
                            appendControl(
                                    buttons,
                                    controls,
                                    view,
                                    label,
                                    "imageButton"
                            );
                        }
                    } else if (view instanceof CompoundButton) {
                        String label = textOf((TextView) view);
                        JSONObject element = uiElement(
                                view,
                                root,
                                "toggle",
                                label,
                                view.isClickable() ? "action" : "status",
                                elementOrder++
                        );
                        element.put(
                                "checked",
                                ((CompoundButton) view).isChecked()
                        );
                        elements.put(element);
                        appendControl(buttons, controls, view, label, "toggle");
                    } else if (view instanceof Spinner) {
                        String label = selectedSpinnerLabel((Spinner) view);
                        JSONObject element = uiElement(
                                view,
                                root,
                                "picker",
                                label,
                                view.isClickable() ? "action" : "status",
                                elementOrder++
                        );
                        element.put(
                                "selectedIndex",
                                ((Spinner) view).getSelectedItemPosition()
                        );
                        elements.put(element);
                        appendControl(buttons, controls, view, label, "picker");
                    } else if (view instanceof SeekBar) {
                        JSONObject element = uiElement(
                                view,
                                root,
                                "slider",
                                contentDescriptionOf(view),
                                view.isEnabled() ? "action" : "status",
                                elementOrder++
                        );
                        element.put("value", ((SeekBar) view).getProgress());
                        element.put("maximumValue", ((SeekBar) view).getMax());
                        elements.put(element);
                    } else if (view instanceof Button) {
                        String label = textOf((TextView) view);
                        elements.put(uiElement(
                                view,
                                root,
                                "button",
                                label,
                                view.isClickable() && view.isEnabled()
                                        ? "action"
                                        : "status",
                                elementOrder++
                        ));
                        if (!label.isEmpty()
                                && view.isEnabled()
                                && view.isClickable()) {
                            String id = stableControlID(view);
                            JSONObject control = new JSONObject();
                            control.put("id", id);
                            control.put("title", label);
                            control.put("enabled", true);
                            control.put("role", "button");
                            controls.put(control);
                            buttons.put(label);
                        } else if (!label.isEmpty()) {
                            // Disabled buttons in legacy Spider dialogs are
                            // status badges (for example "停用中"), not host
                            // actions. Preserve their text without exposing a
                            // clickable SwiftUI control.
                            texts.put(label);
                        }
                    } else if (view.isClickable() && view.isEnabled()) {
                        String label = actionableLabelOf(view);
                        elements.put(uiElement(
                                view,
                                root,
                                "actionRow",
                                label,
                                "action",
                                elementOrder++
                        ));
                        if (!label.isEmpty()) {
                            String id = stableControlID(view);
                            JSONObject control = new JSONObject();
                            control.put("id", id);
                            control.put("title", label);
                            control.put("enabled", true);
                            control.put("role", "clickable");
                            controls.put(control);
                            buttons.put(label);
                        }
                    } else if (view instanceof TextView) {
                        String label = textOf((TextView) view);
                        if (label.isEmpty()) continue;
                        elements.put(uiElement(
                                view,
                                root,
                                "label",
                                label,
                                "label",
                                elementOrder++
                        ));
                        texts.put(label);
                        if (isAlertTitle(view)) title = label;
                    }
                }
            }
            boolean hasContent = inputCount > 0
                    || imageCount > 0
                    || controls.length() > 0
                    || texts.length() > 0;
            // Provider identity and action semantics are request-owned opaque
            // contract fields, never inferred from localized titles/buttons.
            String provider = "";
            boolean remoteInput = false;
            String uiRole = credentialInputCount > 0
                    ? "credentialForm"
                    : qrImageCount > 0
                    ? "qrCode"
                    : "configuration";
            boolean authorizationCandidate = "credentialForm".equals(uiRole)
                    || "qrCode".equals(uiRole);
            String phase = !hasContent
                    ? "hidden"
                    : "qrCode".equals(uiRole)
                    ? "qr"
                    : "credentialForm".equals(uiRole)
                    ? "credentials"
                    : "chooser";
            boolean credentialPush = false;
            if (title.isEmpty() && hasContent) title = "配置操作";
            boolean visible = root != null && hasContent;
            String signature = uiSignature(
                    root,
                    controls,
                    texts,
                    elements,
                    inputCount,
                    imageCount,
                    credentialInputCount,
                    qrImageCount,
                    uiRole
            );
            if (!signature.equals(lastUISignature)) {
                lastUISignature = signature;
                uiGeneration++;
            }
            state.put("visible", visible);
            state.put("title", title);
            state.put("inputCount", inputCount);
            state.put("imageCount", imageCount);
            state.put("credentialInputCount", credentialInputCount);
            state.put("qrImageCount", qrImageCount);
            state.put("uiRole", uiRole);
            state.put("authorizationCandidate", authorizationCandidate);
            state.put("buttons", buttons);
            state.put("controls", controls);
            state.put("texts", texts);
            state.put("uiSchemaVersion", UI_SCHEMA_VERSION);
            state.put("elements", elements);
            state.put("phase", phase);
            state.put("provider", provider);
            state.put("credentialPush", credentialPush);
            state.put("remoteInput", remoteInput);
            state.put("generation", uiGeneration);
            state.put("windowOwnerInteractionID", windowOwnerInteractionID);
            state.put(
                    "authenticated",
                    false
            );
            return state;
        });
    }

    private static JSONObject scopedUIState(
            String interactionID,
            JSONObject captured
    ) throws Exception {
        String id = cleanInteractionID(interactionID);
        boolean currentNonterminal = BridgeInteractionRegistry.ownsLatest(id)
                && !BridgeInteractionRegistry.terminal(id);
        boolean visible = captured.optBoolean("visible", false);
        long generation = captured.optLong("generation", 0L);
        String windowOwnerInteractionID = captured.optString(
                "windowOwnerInteractionID",
                ""
        );
        synchronized (uiOwnerLock) {
            if (visible && uiOwnerInteractionID.isEmpty()
                    && id.equals(activeInteractionID)
                    && id.equals(expectedUIInteractionID)
                    && generation >= expectedUIMinimumGeneration
                    && (windowOwnerInteractionID.isEmpty()
                    || id.equals(windowOwnerInteractionID))
                    && currentNonterminal) {
                uiOwnerInteractionID = id;
            }
            if (id.equals(uiOwnerInteractionID)) {
                return captured;
            }
        }
        return unownedUIState(generation, visible);
    }

    private static JSONObject unownedUIState(
            long generation,
            boolean foreignVisible
    ) throws Exception {
        JSONObject state = new JSONObject();
        state.put("visible", false);
        state.put("title", "");
        state.put("inputCount", 0);
        state.put("imageCount", 0);
        state.put("credentialInputCount", 0);
        state.put("qrImageCount", 0);
        state.put("uiRole", "configuration");
        state.put("authorizationCandidate", false);
        state.put("buttons", new JSONArray());
        state.put("controls", new JSONArray());
        state.put("texts", new JSONArray());
        state.put("uiSchemaVersion", UI_SCHEMA_VERSION);
        state.put("elements", new JSONArray());
        state.put("generation", generation);
        state.put("foreignUI", foreignVisible);
        state.put("phase", "hidden");
        return state;
    }

    static JSONObject submitUI(
            String text,
            String buttonText,
            String controlId,
            Integer expectedGeneration
    ) throws Exception {
        return submitUI(
                applicationContext,
                BridgeInteractionRegistry.latestID(),
                text,
                buttonText,
                controlId,
                expectedGeneration
        );
    }

    static JSONObject submitUI(
            Context context,
            String interactionID,
            String text,
            String buttonText,
            String controlId,
            Integer expectedGeneration
    ) throws Exception {
        String id = normalizedInteractionID(interactionID);
        if (!ownsCurrentCapturedUI(id)) {
            JSONObject stale = BridgeInteractionRegistry.state(id);
            stale.put("clicked", false);
            stale.put("stale", true);
            return stale;
        }
        BridgeActivity host = ensureHost(context, 2_000L);
        if (host == null) {
            JSONObject unavailable = BridgeInteractionRegistry.state(id);
            unavailable.put("clicked", false);
            unavailable.put("hostUnavailable", true);
            return unavailable;
        }
        return onUIThread(host, () -> {
            if (!ownsCurrentCapturedUI(id)) {
                JSONObject result = new JSONObject();
                result.put("clicked", false);
                result.put("stale", true);
                result.put("generation", uiGeneration);
                return result;
            }
            if (expectedGeneration != null
                    && expectedGeneration.intValue() != uiGeneration) {
                JSONObject result = new JSONObject();
                result.put("clicked", false);
                result.put("stale", true);
                result.put("generation", uiGeneration);
                return result;
            }
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
            boolean matched = false;
            for (View view : views) {
                if (!view.isShown() || !view.isClickable() || !view.isEnabled()) continue;
                boolean isButton = view instanceof Button;
                String label = isButton
                        ? textOf((Button) view)
                        : actionableLabelOf(view);
                if (label.isEmpty()) continue;
                String candidateControlID = stableControlID(view);
                if ((controlId != null && controlId.equals(candidateControlID))
                        || (controlId == null && label.equals(buttonText))) {
                    // The HTTP handler holds BridgeServer's lifecycle lease
                    // while this UI block executes. This final ownership
                    // check therefore closes the last supersede-before-click
                    // race without permitting a stale request to act on the
                    // replacement dialog.
                    if (!ownsCurrentCapturedUI(id)) {
                        JSONObject result = new JSONObject();
                        result.put("clicked", false);
                        result.put("stale", true);
                        result.put("generation", uiGeneration);
                        return result;
                    }
                    matched = true;
                    clicked = view.performClick();
                    break;
                }
            }
            JSONObject result = new JSONObject();
            result.put("clicked", clicked);
            result.put("stale", controlId != null && !matched);
            result.put("generation", uiGeneration);
            if (clicked) BridgeInteractionRegistry.submitted(id);
            JSONObject interaction = BridgeInteractionRegistry.state(id);
            result.put("interactionID", id);
            result.put("revision", interaction.optLong("revision", 0));
            result.put("phase", interaction.optString("phase", "processing"));
            result.put("outcome", interaction.optString("outcome", "stay"));
            return result;
        });
    }

    static byte[] snapshotUI() throws Exception {
        return snapshotUI(applicationContext, BridgeInteractionRegistry.latestID());
    }

    static byte[] snapshotUI(Context context, String interactionID) throws Exception {
        String id = normalizedInteractionID(interactionID);
        if (!ownsCurrentCapturedUI(id)) {
            throw new IllegalStateException("Interaction is no longer current");
        }
        BridgeActivity host = ensureHost(context, 2_000L);
        if (host == null) {
            throw new IllegalStateException("Bridge host activity is unavailable");
        }
        return onUIThread(host, () -> {
            if (!ownsCurrentCapturedUI(id)) {
                throw new IllegalStateException(
                        "Interaction is no longer current"
                );
            }
            View root = activeRoot(rootViews());
            if (root == null) throw new IllegalStateException("No visible dialog");
            View selected = null;
            int selectedArea = 0;
            for (View view : flattened(root)) {
                if (!view.isShown() || !(view instanceof ImageView)) continue;
                if (!isQRCodeImage((ImageView) view)) continue;
                int area = view.getWidth() * view.getHeight();
                if (area > selectedArea) {
                    selected = view;
                    selectedArea = area;
                }
            }
            if (selected == null) {
                throw new IllegalStateException("No visible QR code");
            }
            // The interaction may have been superseded while the view tree
            // was being inspected (QR detection can be comparatively
            // expensive). Never capture pixels from an old provider window.
            if (!ownsCurrentCapturedUI(id)) {
                throw new IllegalStateException(
                        "Interaction is no longer current"
                );
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
            if (!ownsCurrentCapturedUI(id)) {
                bitmap.recycle();
                throw new IllegalStateException(
                        "Interaction is no longer current"
                );
            }
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output);
            bitmap.recycle();
            return output.toByteArray();
        });
    }

    static JSONObject dismissUI() throws Exception {
        return dismissUI(
                applicationContext,
                BridgeInteractionRegistry.latestID()
        );
    }

    static JSONObject dismissUI(Context context, String interactionID) throws Exception {
        String id = normalizedInteractionID(interactionID);
        BridgeInteractionRegistry.cancel(id);
        boolean dismissed = BridgeServer.releaseTerminalInteraction(context, id);
        JSONObject result = BridgeInteractionRegistry.state(id);
        result.put("dismissed", dismissed);
        return result;
    }

    /**
     * Releases only the Activity/Dialog owned by {@code interactionID}.
     * BridgeServer owns the terminal state transition and calls this while
     * holding the lifecycle lock, so cleanup cannot overtake activation of a
     * newer request.
     */
    static boolean releaseTerminalUI(
            Context context,
            String interactionID
    ) throws Exception {
        String id = cleanInteractionID(interactionID);
        if (id.isEmpty()) return false;
        boolean releaseScope = ownsReleaseScope(id);
        boolean dismissedDialog = false;
        BridgeActivity host = releaseScope ? ensureHost(context, 500L) : null;
        if (releaseScope && host != null) {
            dismissedDialog = onUIThread(host, () -> {
                // Cleanup can be queued behind a newly resumed Activity. The
                // UI-thread check is intentionally repeated immediately
                // before dispatching BACK.
                if (!ownsReleaseScope(id)) return false;
                View root = activeRoot(rootViews());
                if (root == null || !hasMeaningfulContent(root)) return false;
                Activity owner = activityFrom(root.getContext());
                String ownerID = BridgeActionActivity.interactionIDFor(owner);
                if (!ownerID.isEmpty() && !id.equals(ownerID)) return false;
                // Do not send a generic BACK event to whichever root happens
                // to be topmost: if the provider never created its dialog,
                // that root is the persistent BridgeActivity and BACK would
                // tear down the bridge itself. Resolve the DecorView's Window
                // callback and dismiss only the exact Dialog owned by this
                // request. The ActionActivity itself is finished below.
                Dialog dialog = dialogFrom(root);
                if (dialog == null || !dialog.isShowing()) return false;
                dialog.dismiss();
                return true;
            });
        }

        // The disposable Activity is request-owned before the first state
        // poll captures a dialog, so every terminal path must finish it too.
        boolean dismissedActionHost = BridgeActionActivity.finishIfOwnedBy(id);
        if (dismissedActionHost) {
            BridgeActionActivity.awaitReleased(id, 2_000L);
        }
        BridgeActionActivity.releaseLaunchReservation(id);
        releaseUIOwner(id);
        BridgeActionActivity.restoreInitContext(context);
        return dismissedDialog || dismissedActionHost || releaseScope;
    }

    /**
     * Removes Dialog windows owned by a disposable provider Activity before
     * it is finished. Provider handoffs intentionally close the parent
     * chooser before opening a child QR dialog on BridgeActivity; leaving the
     * parent Dialog attached produces WindowLeaked and can suppress the child.
     */
    static void dismissVisibleDialogsOwnedBy(Activity activity) {
        if (activity == null) return;
        if (Looper.myLooper() != Looper.getMainLooper()) {
            CountDownLatch latch = new CountDownLatch(1);
            activity.runOnUiThread(() -> {
                try {
                    dismissVisibleDialogsOwnedByOnUIThread(activity);
                } finally {
                    latch.countDown();
                }
            });
            try {
                latch.await(1L, TimeUnit.SECONDS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
            return;
        }
        dismissVisibleDialogsOwnedByOnUIThread(activity);
    }

    private static void dismissVisibleDialogsOwnedByOnUIThread(
            Activity activity
    ) {
        try {
            for (View root : rootViews()) {
                if (root == null || activityFrom(root.getContext()) != activity) {
                    continue;
                }
                Dialog dialog = dialogFrom(root);
                if (dialog != null && dialog.isShowing()) {
                    dialog.dismiss();
                }
            }
        } catch (Throwable ignored) {
            // Activity.finish() must remain available even on Android builds
            // where WindowManagerGlobal reflection is restricted.
        }
    }

    static void requestHost(Context context) {
        try {
            ensureHost(context, 0L);
        } catch (Throwable ignored) {
        }
    }

    private static String normalizedInteractionID(String requested) {
        String id = requested == null ? "" : requested.trim();
        if (id.isEmpty()) id = BridgeInteractionRegistry.latestID();
        if (id.isEmpty()) {
            id = BridgeInteractionRegistry.begin("", "configuration", "legacy");
        }
        return id;
    }

    private static String cleanInteractionID(String value) {
        return value == null ? "" : value.trim();
    }

    private static boolean ownsCapturedUI(String interactionID) {
        String id = cleanInteractionID(interactionID);
        synchronized (uiOwnerLock) {
            return !id.isEmpty() && id.equals(uiOwnerInteractionID);
        }
    }

    private static boolean ownsCurrentCapturedUI(String interactionID) {
        String id = cleanInteractionID(interactionID);
        if (id.isEmpty()
                || !BridgeInteractionRegistry.ownsLatest(id)
                || BridgeInteractionRegistry.terminal(id)) {
            return false;
        }
        synchronized (uiOwnerLock) {
            return id.equals(activeInteractionID)
                    && id.equals(uiOwnerInteractionID);
        }
    }

    private static boolean ownsReleaseScope(String interactionID) {
        String id = cleanInteractionID(interactionID);
        synchronized (uiOwnerLock) {
            return !id.isEmpty()
                    && (id.equals(activeInteractionID)
                    || id.equals(expectedUIInteractionID)
                    || id.equals(uiOwnerInteractionID));
        }
    }

    private static void releaseUIOwner(String interactionID) {
        String id = cleanInteractionID(interactionID);
        synchronized (uiOwnerLock) {
            if (id.equals(uiOwnerInteractionID)) uiOwnerInteractionID = "";
            if (id.equals(expectedUIInteractionID)) {
                expectedUIInteractionID = "";
                expectedUIMinimumGeneration = Long.MAX_VALUE;
            }
            if (id.equals(activeInteractionID)) activeInteractionID = "";
        }
    }

    private static BridgeActivity ensureHost(
            Context suppliedContext,
            long timeoutMilliseconds
    ) throws InterruptedException {
        BridgeActivity activity = current.get();
        if (isUsable(activity)) return activity;
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
            if (isUsable(activity)) return activity;
            if (timeoutMilliseconds <= 0L) break;
            Thread.sleep(25L);
        } while (System.currentTimeMillis() < deadline);
        return isUsable(activity) ? activity : null;
    }

    private static boolean isUsable(BridgeActivity activity) {
        return activity != null
                && !activity.isFinishing()
                && !activity.isDestroyed();
    }

    private static Activity activityFrom(Context context) {
        Context currentContext = context;
        while (currentContext instanceof ContextWrapper) {
            if (currentContext instanceof Activity) {
                return (Activity) currentContext;
            }
            Context base = ((ContextWrapper) currentContext).getBaseContext();
            if (base == currentContext) break;
            currentContext = base;
        }
        return currentContext instanceof Activity ? (Activity) currentContext : null;
    }

    /** Returns the Dialog whose DecorView is {@code root}, if any. */
    private static Dialog dialogFrom(View root) {
        if (root == null) return null;
        try {
            Object current = root;
            Class<?> type = current.getClass();
            while (type != null) {
                try {
                    Field field = type.getDeclaredField("mWindow");
                    field.setAccessible(true);
                    Object value = field.get(current);
                    if (value instanceof Window) {
                        Window.Callback callback = ((Window) value).getCallback();
                        return callback instanceof Dialog ? (Dialog) callback : null;
                    }
                } catch (NoSuchFieldException ignored) {
                    // DecorView keeps mWindow on an implementation superclass
                    // on some Android releases.
                }
                type = type.getSuperclass();
            }
        } catch (Throwable ignored) {
            // A hidden-API restriction must degrade to finishing the precise
            // ActionActivity, never to dismissing an unrelated window.
        }
        return null;
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
        View fallback = null;
        for (int index = roots.size() - 1; index >= 0; index--) {
            View root = roots.get(index);
            if (root.getWindowVisibility() == View.VISIBLE
                    && root.isShown()
                    && root.getWidth() > 0
                    && root.getHeight() > 0) {
                if (fallback == null) fallback = root;
                if (hasMeaningfulContent(root)) return root;
            }
        }
        return fallback;
    }

    private static boolean hasMeaningfulContent(View root) {
        for (View view : flattened(root)) {
            if (!view.isShown()) continue;
            if (view instanceof EditText || view instanceof ImageView) return true;
            if (view instanceof TextView && !textOf((TextView) view).isEmpty()) return true;
            if (view.isClickable() && view.isEnabled() && !labelOf(view).isEmpty()) {
                return true;
            }
        }
        return false;
    }

    private static String stableControlID(View view) {
        String resource = resourceName(view);
        String path = hierarchyPath(view);
        if (resource.isEmpty() && path.isEmpty()) {
            return "view:" + Integer.toUnsignedString(
                    System.identityHashCode(view)
            );
        }
        return "view-v2:" + resource + ":" + path;
    }

    private static JSONObject uiElement(
            View view,
            View root,
            String type,
            String title,
            String role,
            int order
    ) throws Exception {
        JSONObject element = new JSONObject();
        element.put("id", stableControlID(view));
        element.put("type", type);
        element.put("title", title == null ? "" : title);
        element.put("role", role);
        element.put("enabled", view.isEnabled());
        element.put("clickable", view.isClickable());
        element.put("selected", view.isSelected());
        element.put("order", order);
        element.put("depth", viewDepth(view));
        element.put("resourceName", resourceName(view));
        element.put("className", view.getClass().getName());
        element.put("parentID", parentElementID(view));

        Rect frame = new Rect();
        Rect rootFrame = new Rect();
        if (view.getGlobalVisibleRect(frame)) {
            root.getGlobalVisibleRect(rootFrame);
            element.put("x", frame.left - rootFrame.left);
            element.put("y", frame.top - rootFrame.top);
            element.put("width", frame.width());
            element.put("height", frame.height());
        }
        if (view instanceof EditText) {
            EditText input = (EditText) view;
            CharSequence hint = input.getHint();
            element.put("hint", hint == null ? "" : hint.toString().trim());
            CharSequence value = input.getText();
            // Input content may be a Cookie, token or password. The host only
            // needs to know whether the field is populated; the value remains
            // inside the Android provider process.
            element.put("hasValue", value != null && value.length() > 0);
        }
        return element;
    }

    private static void appendControl(
            JSONArray buttons,
            JSONArray controls,
            View view,
            String rawLabel,
            String role
    ) throws Exception {
        String label = rawLabel == null || rawLabel.trim().isEmpty()
                ? contentDescriptionOf(view)
                : rawLabel.trim();
        if (label.isEmpty()) return;
        if (view.isEnabled() && view.isClickable()) {
            JSONObject control = new JSONObject();
            control.put("id", stableControlID(view));
            control.put("title", label);
            control.put("enabled", true);
            control.put("clickable", true);
            control.put("role", role);
            controls.put(control);
            buttons.put(label);
        }
    }

    private static String inputLabel(EditText input) {
        CharSequence hint = input.getHint();
        if (hint != null && !hint.toString().trim().isEmpty()) {
            return hint.toString().trim();
        }
        return contentDescriptionOf(input);
    }

    private static String selectedSpinnerLabel(Spinner spinner) {
        Object selected = spinner.getSelectedItem();
        if (selected != null && !selected.toString().trim().isEmpty()) {
            return selected.toString().trim();
        }
        return contentDescriptionOf(spinner);
    }

    private static String contentDescriptionOf(View view) {
        CharSequence value = view.getContentDescription();
        return value == null ? "" : value.toString().trim();
    }

    private static String parentElementID(View view) {
        ViewParent parent = view.getParent();
        return parent instanceof View ? stableControlID((View) parent) : "";
    }

    private static int viewDepth(View view) {
        int depth = 0;
        ViewParent parent = view.getParent();
        while (parent instanceof View) {
            depth++;
            parent = parent.getParent();
        }
        return depth;
    }

    private static String hierarchyPath(View view) {
        ArrayList<Integer> indices = new ArrayList<>();
        View current = view;
        ViewParent parent = current.getParent();
        while (parent instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) parent;
            indices.add(group.indexOfChild(current));
            current = group;
            parent = current.getParent();
        }
        Collections.reverse(indices);
        StringBuilder path = new StringBuilder();
        for (Integer index : indices) {
            if (path.length() > 0) path.append('.');
            path.append(index == null ? -1 : index.intValue());
        }
        return path.toString();
    }

    private static String resourceName(View view) {
        if (view == null || view.getId() == View.NO_ID) return "";
        try {
            return view.getResources().getResourceName(view.getId());
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String uiSignature(
            View root,
            JSONArray controls,
            JSONArray texts,
            JSONArray elements,
            int inputCount,
            int imageCount,
            int credentialInputCount,
            int qrImageCount,
            String uiRole
    ) {
        return (root == null ? "hidden" : Integer.toUnsignedString(
                System.identityHashCode(root)))
                + "|" + controls.toString()
                + "|" + texts.toString()
                + "|" + elements.toString()
                + "|" + inputCount
                + "|" + imageCount
                + "|" + credentialInputCount
                + "|" + qrImageCount
                + "|" + uiRole;
    }

    private static boolean isCredentialInput(EditText input) {
        if (input == null) return false;
        if (input.getTransformationMethod()
                instanceof PasswordTransformationMethod) {
            return true;
        }
        int type = input.getInputType();
        int inputClass = type & InputType.TYPE_MASK_CLASS;
        int variation = type & InputType.TYPE_MASK_VARIATION;
        if (inputClass == InputType.TYPE_CLASS_TEXT
                && (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD
                || variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)) {
            return true;
        }
        return inputClass == InputType.TYPE_CLASS_NUMBER
                && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD;
    }

    /** Returns only whether the image structurally decodes as QR data. */
    private static boolean isQRCodeImage(ImageView image) {
        Bitmap bitmap = null;
        try {
            bitmap = renderedImage(image);
            if (bitmap == null) return false;
            int width = bitmap.getWidth();
            int height = bitmap.getHeight();
            if (width < 21 || height < 21) return false;
            int[] pixels = new int[width * height];
            bitmap.getPixels(pixels, 0, width, 0, 0, width, height);
            RGBLuminanceSource source = new RGBLuminanceSource(
                    width,
                    height,
                    pixels
            );
            EnumMap<DecodeHintType, Object> hints = new EnumMap<>(
                    DecodeHintType.class
            );
            hints.put(
                    DecodeHintType.POSSIBLE_FORMATS,
                    Collections.singletonList(BarcodeFormat.QR_CODE)
            );
            hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
            new MultiFormatReader().decode(
                    new BinaryBitmap(new HybridBinarizer(source)),
                    hints
            );
            return true;
        } catch (Throwable ignored) {
            return false;
        } finally {
            if (bitmap != null && !bitmap.isRecycled()) bitmap.recycle();
        }
    }

    private static Bitmap renderedImage(ImageView image) {
        if (image == null) return null;
        Drawable drawable = image.getDrawable();
        if (drawable == null) return null;
        int width = image.getWidth();
        int height = image.getHeight();
        if (width <= 0) width = drawable.getIntrinsicWidth();
        if (height <= 0) height = drawable.getIntrinsicHeight();
        if (width <= 0 || height <= 0) return null;
        double scale = Math.min(1.0, 1024.0 / Math.max(width, height));
        width = Math.max(1, (int) Math.round(width * scale));
        height = Math.max(1, (int) Math.round(height * scale));
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.drawColor(Color.WHITE);
        int saveCount = canvas.save();
        if (image.getWidth() > 0 && image.getHeight() > 0) {
            canvas.scale(
                    width / (float) image.getWidth(),
                    height / (float) image.getHeight()
            );
            image.draw(canvas);
        } else {
            drawable.setBounds(0, 0, width, height);
            drawable.draw(canvas);
        }
        canvas.restoreToCount(saveCount);
        return bitmap;
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

    /**
     * Produces a submit-safe label for icon-only provider controls. Android
     * spiders frequently use ImageButtons for ordering; losing these controls
     * makes the corresponding Mac setting appear incomplete.
     */
    private static String actionableLabelOf(View view) {
        String label = labelOf(view);
        if (!label.isEmpty()) return label;
        label = contentDescriptionOf(view);
        if (!label.isEmpty()) return label;
        if (view == null || view.getId() == View.NO_ID) return "";
        try {
            String entry = view.getResources()
                    .getResourceEntryName(view.getId());
            String normalized = entry.toLowerCase(Locale.ROOT);
            if (normalized.contains("move_up")
                    || normalized.endsWith("_up")
                    || normalized.equals("up")) {
                return "上移";
            }
            if (normalized.contains("move_down")
                    || normalized.endsWith("_down")
                    || normalized.equals("down")) {
                return "下移";
            }
            return entry.replace('_', ' ').trim();
        } catch (Throwable ignored) {
            return "";
        }
    }


    private static <T> T onUIThread(
            BridgeActivity activity,
            ValueProvider<T> provider
    ) throws Exception {
        if (!isUsable(activity)) {
            throw new IllegalStateException("Bridge activity is unavailable");
        }
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
