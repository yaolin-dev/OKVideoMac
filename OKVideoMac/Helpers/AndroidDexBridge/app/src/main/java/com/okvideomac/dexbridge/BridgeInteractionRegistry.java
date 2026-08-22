package com.okvideomac.dexbridge;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Process-owned, request-scoped interaction state.
 *
 * <p>The legacy bridge exposed whichever Android dialog happened to be on
 * screen. That allowed a late callback from one configuration action to be
 * submitted by a different action. This registry gives every interaction a
 * stable identity and a monotonic revision while retaining a "latest"
 * pointer for old Mac clients.</p>
 */
final class BridgeInteractionRegistry {
    private static final int MAX_INTERACTIONS = 64;
    private static final long RETENTION_MS = 10 * 60_000L;
    private static final long DELAYED_UI_GRACE_MS = 8_000L;
    private static final Map<String, Interaction> INTERACTIONS =
            new LinkedHashMap<>();
    private static String latestID = "";

    private BridgeInteractionRegistry() {
    }

    static synchronized String begin(
            String requestedID,
            String kind,
            String method
    ) {
        prune();
        String id = clean(requestedID);
        if (id.isEmpty()) id = UUID.randomUUID().toString();
        Interaction existing = INTERACTIONS.get(id);
        if (existing != null) {
            // Retried HTTP calls may name an interaction that has already
            // been superseded or completed. Merely looking that request up
            // must never move the process-wide latest pointer backwards: the
            // old worker/UI would otherwise cancel the real current request
            // and could never legitimately reclaim its window.
            return id;
        }
        Interaction previous = INTERACTIONS.get(latestID);
        if (previous != null && !previous.terminal()) {
            previous.transition("superseded", "superseded");
        }
        Interaction interaction = new Interaction(
                id,
                clean(kind).isEmpty() ? "configuration" : clean(kind),
                clean(method)
        );
        INTERACTIONS.put(id, interaction);
        latestID = id;
        prune();
        return id;
    }

    static synchronized String latestID() {
        return latestID;
    }

    static synchronized boolean exists(String requestedID) {
        String id = resolve(requestedID);
        return !id.isEmpty() && INTERACTIONS.containsKey(id);
    }

    static synchronized JSONObject state(String requestedID) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        return interaction.json();
    }

    static synchronized JSONObject observeUI(
            String requestedID,
            JSONObject ui
    ) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        if (!interaction.terminal()
                && shouldPromoteAuthorization(interaction, ui)) {
            interaction.kind = "authorization";
            interaction.authorizationPromoted = true;
            interaction.revision++;
        }
        boolean visible = ui != null && ui.optBoolean("visible", false);
        String signature = ui == null ? "" : ui.toString();
        if (!signature.equals(interaction.uiSignature)) {
            interaction.uiSignature = signature;
            interaction.revision++;
        }
        interaction.lastUI = ui == null ? emptyUI() : ui;
        interaction.updatedAt = System.currentTimeMillis();
        if (!interaction.terminal()) {
            if (visible) {
                interaction.sawUI = true;
                interaction.uiVisible = true;
                interaction.delayedUIDeadline = 0L;
                interaction.phase = "awaitingUser";
                interaction.outcome = "stay";
            } else if (ui != null
                    && ui.optBoolean("hostUnavailable", false)) {
                // Losing the disposable Activity is not a provider outcome.
                // Keep the interaction pending while the persistent host is
                // reattached instead of reporting either success or failure.
                interaction.phase = "reattaching";
                interaction.outcome = "stay";
            } else if (interaction.invocationReturned
                    && interaction.expectsProviderUI) {
                long now = System.currentTimeMillis();
                // UI can briefly disappear while BridgeActionActivity hands
                // the request back to the persistent host. Start a fresh
                // grace period for every visible -> hidden transition rather
                // than treating the provider worker's earlier return as a
                // terminal event.
                if (interaction.uiVisible
                        || interaction.delayedUIDeadline <= 0L) {
                    interaction.delayedUIDeadline =
                            now + DELAYED_UI_GRACE_MS;
                }
                interaction.uiVisible = false;
                if (now >= interaction.delayedUIDeadline) {
                    if (interaction.sawUI) {
                        // Dismissing provider UI is presentation state, not a
                        // successful provider outcome. In particular, closing
                        // a QR window does not prove that the credential was
                        // accepted. Only verified(true) or another explicit
                        // provider terminal result may complete the request.
                        interaction.failure = "providerOutcomeUnverified";
                        interaction.transition("failed", "failed");
                    } else {
                        // Merely returning from a worker that explicitly
                        // requested UI is not success. Treating an absent UI as
                        // completed caused configuration actions to report
                        // success even though no dialog/QR was ever usable.
                        interaction.failure = "providerUIUnavailable";
                        interaction.transition("failed", "failed");
                    }
                } else {
                    interaction.phase = interaction.sawUI
                            ? "awaitingVerification"
                            : (interaction.submitted
                                    ? "processing"
                                    : "awaitingProviderUI");
                    interaction.outcome = "stay";
                }
            } else {
                interaction.uiVisible = false;
                interaction.phase = "processing";
                interaction.outcome = "stay";
            }
        }
        return interaction.jsonWithUI();
    }

    static synchronized JSONObject submitted(String requestedID) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        if (!interaction.terminal()) {
            interaction.submitted = true;
            interaction.transition("processing", "stay");
        }
        return interaction.json();
    }

    static synchronized JSONObject invocationReturned(String requestedID) {
        return invocationReturned(requestedID, false);
    }

    static synchronized JSONObject invocationReturned(
            String requestedID,
            boolean completedWithProviderResult
    ) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        interaction.invocationReturned = true;
        interaction.invocationReturnedAt = System.currentTimeMillis();
        if (!interaction.terminal() && completedWithProviderResult) {
            // A structurally valid playback response is the provider's
            // explicit terminal event. Do not impose the delayed-dialog grace
            // on every successful movie start merely because playback is
            // capable of showing an authorization prompt on failure.
            interaction.transition("completed", "completed");
        } else if (!interaction.terminal()
                && interaction.expectsProviderUI
                && !interaction.uiVisible) {
            interaction.delayedUIDeadline =
                    interaction.invocationReturnedAt + DELAYED_UI_GRACE_MS;
            interaction.transition(
                    interaction.submitted
                            ? "processing"
                            : "awaitingProviderUI",
                    "stay"
            );
        } else if (!interaction.terminal()
                && interaction.expectsProviderUI
                && interaction.uiVisible) {
            interaction.transition("awaitingUser", "stay");
        } else if (!interaction.terminal()) {
            // A normal return from the provider worker is the provider-owned
            // completion event. UI visibility is presentation state only and
            // must never manufacture (or delay) a successful outcome.
            interaction.transition("completed", "completed");
        }
        return interaction.json();
    }

    static synchronized JSONObject expectProviderUI(String requestedID) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        if (!interaction.terminal()) {
            // Request-scoped prepareDialogHandoff is the lifecycle authority.
            // Semantic labels such as "ordering" or "toggle" describe the
            // operation, but legacy providers may still present native UI for
            // any of them.
            interaction.expectsProviderUI = true;
            interaction.transition("awaitingProviderUI", "stay");
        }
        return interaction.json();
    }

    static synchronized JSONObject failed(String requestedID, String reason) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        interaction.failure = clean(reason);
        interaction.transition("failed", "failed");
        return interaction.json();
    }

    /** Records an explicit provider-state verification performed by the host. */
    static synchronized JSONObject verified(
            String requestedID,
            boolean succeeded,
            String reason,
            Boolean refreshPerformed
    ) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        if (!interaction.terminal()) {
            interaction.verificationPerformed = true;
            interaction.refreshPerformed = refreshPerformed;
            interaction.failure = succeeded ? "" : clean(reason);
            interaction.transition(
                    succeeded ? "completed" : "failed",
                    succeeded ? "completed" : "failed"
            );
        }
        return interaction.json();
    }

    static synchronized JSONObject cancel(String requestedID) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        if (!interaction.terminal()) {
            interaction.transition("cancelled", "cancelled");
        }
        return interaction.json();
    }

    static synchronized boolean ownsLatest(String requestedID) {
        String id = resolve(requestedID);
        return !id.isEmpty() && id.equals(latestID);
    }

    static synchronized boolean terminal(String requestedID) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        return interaction == null || interaction.terminal();
    }

    private static String resolve(String requestedID) {
        String id = clean(requestedID);
        return id.isEmpty() ? latestID : id;
    }

    private static JSONObject missing(String id) {
        JSONObject value = new JSONObject();
        try {
            value.put("ok", false);
            value.put("interactionID", id);
            value.put("revision", 0);
            value.put("phase", "missing");
            value.put("outcome", "failed");
            value.put("kind", "configuration");
            value.put("declaredKind", "configuration");
            value.put("method", "");
            value.put("createdAt", 0L);
            value.put("updatedAt", 0L);
            value.put("terminal", true);
            putUIFields(value, emptyUI());
        } catch (Throwable ignored) {
        }
        return value;
    }

    private static JSONObject emptyUI() {
        JSONObject value = new JSONObject();
        try {
            value.put("visible", false);
            value.put("title", "");
            value.put("inputCount", 0);
            value.put("imageCount", 0);
            value.put("credentialInputCount", 0);
            value.put("qrImageCount", 0);
            value.put("uiRole", "configuration");
            value.put("authorizationCandidate", false);
            value.put("buttons", new JSONArray());
            value.put("controls", new JSONArray());
            value.put("texts", new JSONArray());
            value.put("generation", 0L);
            value.put("hostUnavailable", false);
        } catch (Throwable ignored) {
        }
        return value;
    }

    private static void putUIFields(JSONObject destination, JSONObject ui) {
        try {
            destination.put("visible", ui.optBoolean("visible", false));
            destination.put("title", ui.optString("title", ""));
            destination.put("inputCount", ui.optInt("inputCount", 0));
            destination.put("imageCount", ui.optInt("imageCount", 0));
            destination.put(
                    "credentialInputCount",
                    ui.optInt("credentialInputCount", 0)
            );
            destination.put("qrImageCount", ui.optInt("qrImageCount", 0));
            destination.put(
                    "uiRole",
                    ui.optString("uiRole", "configuration")
            );
            destination.put(
                    "authorizationCandidate",
                    ui.optBoolean("authorizationCandidate", false)
            );
            destination.put(
                    "buttons",
                    ui.optJSONArray("buttons") == null
                            ? new JSONArray()
                            : ui.optJSONArray("buttons")
            );
            destination.put(
                    "controls",
                    ui.optJSONArray("controls") == null
                            ? new JSONArray()
                            : ui.optJSONArray("controls")
            );
            destination.put(
                    "texts",
                    ui.optJSONArray("texts") == null
                            ? new JSONArray()
                            : ui.optJSONArray("texts")
            );
            destination.put("generation", ui.optLong("generation", 0L));
            destination.put(
                    "hostUnavailable",
                    ui.optBoolean("hostUnavailable", false)
            );
        } catch (Throwable ignored) {
        }
    }

    private static void prune() {
        long cutoff = System.currentTimeMillis() - RETENTION_MS;
        Iterator<Map.Entry<String, Interaction>> iterator =
                INTERACTIONS.entrySet().iterator();
        while (iterator.hasNext()) {
            Map.Entry<String, Interaction> entry = iterator.next();
            if (!entry.getKey().equals(latestID)
                    && entry.getValue().updatedAt < cutoff) {
                iterator.remove();
            }
        }
        iterator = INTERACTIONS.entrySet().iterator();
        while (INTERACTIONS.size() > MAX_INTERACTIONS && iterator.hasNext()) {
            Map.Entry<String, Interaction> entry = iterator.next();
            if (!entry.getKey().equals(latestID)) iterator.remove();
        }
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    /**
     * Legacy Spider packages often predate the structured action-kind field.
     * Promote only a generic configuration action whose request-owned UI has
     * supplied a structural authorization role. Provider/title strings are
     * deliberately excluded: an ordering dialog or an ordinary image must
     * retain its declared semantics even when its text resembles a login.
     */
    private static boolean shouldPromoteAuthorization(
            Interaction interaction,
            JSONObject ui
    ) {
        if (interaction == null || ui == null) return false;
        if (!"configuration".equals(interaction.declaredKind)) return false;
        if (!"configuration".equals(interaction.kind)) return false;
        if (!("action".equals(interaction.method)
                || "detail".equals(interaction.method))) {
            return false;
        }
        if (!ui.optBoolean("visible", false)
                || ui.optBoolean("remoteInput", false)
                || !ui.optBoolean("authorizationCandidate", false)) {
            return false;
        }
        String role = ui.optString("uiRole", "");
        return "qrCode".equals(role) || "credentialForm".equals(role);
    }

    private static final class Interaction {
        final String id;
        final String declaredKind;
        String kind;
        final String method;
        final long createdAt = System.currentTimeMillis();
        long updatedAt = createdAt;
        long revision = 1;
        String phase = "started";
        String outcome = "none";
        String failure = "";
        String uiSignature = "";
        JSONObject lastUI = emptyUI();
        boolean sawUI;
        boolean uiVisible;
        boolean submitted;
        boolean expectsProviderUI;
        boolean invocationReturned;
        boolean verificationPerformed;
        boolean authorizationPromoted;
        Boolean refreshPerformed;
        long invocationReturnedAt;
        long delayedUIDeadline;

        Interaction(String id, String kind, String method) {
            this.id = id;
            this.declaredKind = kind;
            this.kind = kind;
            this.method = method;
        }

        void transition(String nextPhase, String nextOutcome) {
            if (!nextPhase.equals(phase) || !nextOutcome.equals(outcome)) {
                phase = nextPhase;
                outcome = nextOutcome;
                revision++;
            }
            updatedAt = System.currentTimeMillis();
        }

        boolean terminal() {
            return "completed".equals(phase)
                    || "failed".equals(phase)
                    || "cancelled".equals(phase)
                    || "superseded".equals(phase);
        }

        JSONObject json() {
            JSONObject value = new JSONObject();
            try {
                value.put("ok", true);
                value.put("interactionID", id);
                value.put("revision", revision);
                value.put("kind", kind);
                value.put("declaredKind", declaredKind);
                if (authorizationPromoted) {
                    value.put("authorizationPromoted", true);
                }
                value.put("method", method);
                value.put("phase", phase);
                value.put("outcome", outcome);
                value.put("createdAt", createdAt);
                value.put("updatedAt", updatedAt);
                value.put("terminal", terminal());
                if (verificationPerformed) {
                    value.put("verificationPerformed", true);
                }
                if (refreshPerformed != null) {
                    value.put("refreshPerformed", refreshPerformed.booleanValue());
                }
                value.put("workerReturned", invocationReturned);
                value.put("expectsProviderUI", expectsProviderUI);
                value.put("uiObserved", sawUI);
                value.put("uiVisible", uiVisible);
                if (delayedUIDeadline > 0L && !terminal()) {
                    value.put("graceDeadline", delayedUIDeadline);
                }
                if (!failure.isEmpty()) value.put("error", failure);
            } catch (Throwable ignored) {
            }
            return value;
        }

        JSONObject jsonWithUI() {
            JSONObject value = json();
            try {
                if (lastUI != null) {
                    Iterator<String> keys = lastUI.keys();
                    while (keys.hasNext()) {
                        String key = keys.next();
                        if (!"phase".equals(key) && !"outcome".equals(key)) {
                            value.put(key, lastUI.opt(key));
                        }
                    }
                }
                putUIFields(value, lastUI == null ? emptyUI() : lastUI);
                value.put("phase", phase);
                value.put("outcome", outcome);
                value.put("revision", revision);
                value.put("interactionID", id);
            } catch (Throwable ignored) {
            }
            return value;
        }
    }
}
