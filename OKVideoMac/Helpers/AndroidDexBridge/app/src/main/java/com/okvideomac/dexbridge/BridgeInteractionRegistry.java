package com.okvideomac.dexbridge;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Process-owned, request-scoped interaction state.
 *
 * <p>The legacy bridge exposed whichever Android dialog happened to be on
 * screen. This registry now exposes only a request identity, provider return,
 * lifecycle-owned full-display surface, and event channel.</p>
 */
final class BridgeInteractionRegistry {
    private static final int MAX_INTERACTIONS = 64;
    private static final int MAX_EVENTS_PER_INTERACTION = 32;
    private static final long RETENTION_MS = 10 * 60_000L;
    private static final long DELAYED_UI_GRACE_MS = 8_000L;
    private static final long CLOSED_UI_GRACE_MS = 750L;
    private static final long PLAYBACK_UI_GRACE_MS = 1_500L;
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
            previous.discardPendingReturn();
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
        // A terminal/superseded action retains its final request-owned surface
        // snapshot for diagnostics, but a late poll must never attach whatever
        // Android window happens to be visible now.
        if (!id.equals(latestID) || interaction.terminal()) {
            return interaction.jsonWithUI();
        }
        long now = System.currentTimeMillis();
        boolean visible = ui != null && ui.optBoolean("visible", false);
        boolean surfaceRequestScoped = visible || (ui != null
                && ui.optBoolean("surfaceRequestScoped", false)
                && id.equals(ui.optString("surfaceInteractionID", "")));
        boolean surfaceActive = surfaceRequestScoped && (visible || (ui != null
                && ui.optBoolean("surfaceActive", false)));
        boolean surfaceDelegated = surfaceRequestScoped
                && !visible
                && ui != null
                && ui.optBoolean("surfaceDelegated", false);
        if (ui != null) {
            try {
                ui.put("surfaceRequestScoped", surfaceRequestScoped);
                ui.put("surfaceActive", surfaceActive);
                ui.put("surfaceDelegated", surfaceDelegated);
                ui.put(
                        "surfaceInteractionID",
                        surfaceRequestScoped ? id : ""
                );
                ui.put(
                        "surfaceMode",
                        surfaceActive
                                ? ui.optString("surfaceMode", "actionActivity")
                                : "none"
                );
                if (!ui.has("surfaceHostLifecycle")) {
                    ui.put("surfaceHostLifecycle", "none");
                }
            } catch (Throwable ignored) {
            }
        }
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
            } else if (surfaceDelegated && interaction.expectsProviderUI) {
                // A delegated/browser/full-screen lifecycle pauses the
                // translucent ActionActivity and hides every request-owned
                // WindowManager root in this process. Keep that exact request
                // alive without inferring any provider business outcome from
                // presentation activity. HOME/lock may produce the same
                // conservative lifecycle signal.
                interaction.uiVisible = false;
                interaction.delayedUIDeadline = 0L;
                interaction.phase = "awaitingExternalSurface";
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
                // A normal provider return is the business result. The
                // request-owned window lifecycle only keeps its Android
                // surface alive long enough for a Dialog handoff/rebuild; it
                // never classifies authorization or manufactures a result.
                if (interaction.uiVisible
                        || interaction.delayedUIDeadline <= 0L) {
                    interaction.delayedUIDeadline =
                            now + (interaction.sawUI
                                    ? CLOSED_UI_GRACE_MS
                                    : DELAYED_UI_GRACE_MS);
                }
                interaction.uiVisible = false;
                if (now >= interaction.delayedUIDeadline) {
                    interaction.transition("completed", "completed");
                } else {
                    interaction.phase = interaction.sawUI
                            ? "closingSurface"
                            : "awaitingProviderUI";
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
        if (!id.equals(latestID) || interaction.terminal()) {
            interaction.discardPendingReturn();
            JSONObject discarded = interaction.json();
            try {
                discarded.put("returnAccepted", false);
            } catch (Throwable ignored) {
            }
            return discarded;
        }
        interaction.invocationReturned = true;
        interaction.invocationReturnedAt = System.currentTimeMillis();
        interaction.returnState = "returned";
        if (completedWithProviderResult
                && "playback".equals(interaction.declaredKind)) {
            // playerContent is the authoritative playback result. Once it
            // yields a usable address, presentation pixels cannot delay or
            // overwrite it.
            interaction.playbackResultReady = true;
            interaction.uiVisible = false;
            interaction.transition("completed", "completed");
        } else if (completedWithProviderResult) {
            interaction.playbackResultReady = true;
            interaction.delayedUIDeadline =
                    interaction.invocationReturnedAt + PLAYBACK_UI_GRACE_MS;
            interaction.transition("awaitingProviderUI", "stay");
        } else if (interaction.expectsProviderUI
                && interaction.lastUI != null
                && interaction.lastUI.optBoolean("surfaceDelegated", false)
                && interaction.lastUI.optBoolean(
                        "surfaceRequestScoped",
                        false
                )
                && id.equals(interaction.lastUI.optString(
                        "surfaceInteractionID",
                        ""
                ))) {
            interaction.delayedUIDeadline = 0L;
            interaction.transition("awaitingExternalSurface", "stay");
        } else if (interaction.expectsProviderUI
                && !interaction.uiVisible) {
            interaction.delayedUIDeadline =
                    interaction.invocationReturnedAt + DELAYED_UI_GRACE_MS;
            interaction.transition("awaitingProviderUI", "stay");
        } else if (interaction.expectsProviderUI
                && interaction.uiVisible) {
            interaction.transition("awaitingUser", "stay");
        } else {
            // A normal return from the provider worker is the provider-owned
            // completion event. UI visibility is presentation state only and
            // must never manufacture (or delay) a successful outcome.
            interaction.transition("completed", "completed");
        }
        JSONObject returned = interaction.json();
        try {
            returned.put("returnAccepted", true);
        } catch (Throwable ignored) {
        }
        return returned;
    }

    static synchronized JSONObject expectProviderUI(String requestedID) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        if (id.equals(latestID) && !interaction.terminal()) {
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
        if (id.equals(latestID) && !interaction.terminal()) {
            interaction.failure = clean(reason);
            interaction.returnState = "failed";
            interaction.invocationReturned = true;
            interaction.invocationReturnedAt = System.currentTimeMillis();
            interaction.transition("failed", "failed");
        } else {
            interaction.discardPendingReturn();
        }
        return interaction.json();
    }

    static synchronized JSONObject failedProviderMessage(
            String requestedID,
            String message
    ) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        boolean accepted = id.equals(latestID) && !interaction.terminal();
        if (accepted) {
            interaction.failure = clean(message);
            interaction.failureKind = "providerMessage";
            interaction.returnState = "returned";
            interaction.invocationReturned = true;
            interaction.invocationReturnedAt = System.currentTimeMillis();
            interaction.transition("failed", "failed");
        } else {
            interaction.discardPendingReturn();
        }
        JSONObject result = interaction.json();
        try {
            result.put("returnAccepted", accepted);
        } catch (Throwable ignored) {
        }
        return result;
    }

    /**
     * Records an ephemeral provider event without merging it into the native
     * surface text. Toast-like messages and action return values therefore
     * cannot become persistent labels on a later Dialog.
     */
    static synchronized JSONObject recordEvent(
            String requestedID,
            String type,
            String message
    ) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        boolean accepted = id.equals(latestID) && !interaction.terminal();
        if (accepted) interaction.addEvent(clean(type), clean(message));
        JSONObject result = interaction.eventState(0L);
        try {
            result.put("eventAccepted", accepted);
        } catch (Throwable ignored) {
        }
        return result;
    }

    /** Returns the request-owned event channel after the supplied sequence. */
    static synchronized JSONObject events(String requestedID, long after) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        return interaction == null
                ? missing(id)
                : interaction.eventState(Math.max(0L, after));
    }

    static synchronized JSONObject cancel(String requestedID) {
        String id = resolve(requestedID);
        Interaction interaction = INTERACTIONS.get(id);
        if (interaction == null) return missing(id);
        if (!interaction.terminal()) {
            interaction.discardPendingReturn();
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
            value.put("returnState", "missing");
            value.put("channels", emptyChannels());
            putSurfaceFields(value, emptyUI(), true);
        } catch (Throwable ignored) {
        }
        return value;
    }

    private static JSONObject emptyUI() {
        JSONObject value = new JSONObject();
        try {
            value.put("visible", false);
            value.put("generation", 0L);
            value.put("hostUnavailable", false);
            value.put("surfaceActive", false);
            value.put("surfaceRequestScoped", false);
            value.put("surfaceDelegated", false);
            value.put("surfaceInteractionID", "");
            value.put("surfaceMode", "none");
            value.put("surfaceHostLifecycle", "none");
        } catch (Throwable ignored) {
        }
        return value;
    }

    private static JSONObject emptyChannels() {
        JSONObject channels = new JSONObject();
        try {
            JSONObject providerReturn = new JSONObject();
            providerReturn.put("state", "missing");
            providerReturn.put("returnedAt", 0L);
            channels.put("return", providerReturn);

            JSONObject surface = new JSONObject();
            surface.put("owner", "actionSession");
            surface.put("visible", false);
            surface.put("active", false);
            surface.put("requestScoped", false);
            surface.put("delegated", false);
            surface.put("interactionID", "");
            surface.put("mode", "none");
            surface.put("hostLifecycle", "none");
            surface.put("generation", 0L);
            channels.put("surface", surface);

            JSONObject events = new JSONObject();
            events.put("latestSequence", 0L);
            channels.put("events", events);
        } catch (Throwable ignored) {
        }
        return channels;
    }

    private static void putSurfaceFields(
            JSONObject destination,
            JSONObject ui,
            boolean terminal
    ) {
        try {
            JSONObject source = ui == null ? emptyUI() : ui;
            boolean requestScoped = !terminal
                    && source.optBoolean("surfaceRequestScoped", false);
            boolean active = requestScoped
                    && source.optBoolean("surfaceActive", false);
            boolean delegated = active
                    && source.optBoolean("surfaceDelegated", false);
            destination.put("surfaceActive", active);
            destination.put("surfaceRequestScoped", requestScoped);
            destination.put("surfaceDelegated", delegated);
            destination.put(
                    "surfaceInteractionID",
                    requestScoped
                            ? source.optString("surfaceInteractionID", "")
                            : ""
            );
            destination.put(
                    "surfaceMode",
                    active ? source.optString("surfaceMode", "none") : "none"
            );
            destination.put(
                    "surfaceHostLifecycle",
                    requestScoped
                            ? source.optString("surfaceHostLifecycle", "none")
                            : "none"
            );
            destination.put("generation", source.optLong("generation", 0L));
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
        String failureKind = "";
        String uiSignature = "";
        JSONObject lastUI = emptyUI();
        boolean sawUI;
        boolean uiVisible;
        boolean expectsProviderUI;
        boolean invocationReturned;
        boolean playbackResultReady;
        long invocationReturnedAt;
        long delayedUIDeadline;
        String returnState = "pending";
        long eventSequence;
        final List<InteractionEvent> events = new ArrayList<>();

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

        void discardPendingReturn() {
            if ("pending".equals(returnState)) {
                returnState = "discarded";
            }
        }

        void addEvent(String type, String message) {
            if (message.isEmpty()) return;
            events.add(new InteractionEvent(
                    ++eventSequence,
                    type.isEmpty() ? "providerMessage" : type,
                    message,
                    System.currentTimeMillis()
            ));
            while (events.size() > MAX_EVENTS_PER_INTERACTION) {
                events.remove(0);
            }
            revision++;
            updatedAt = System.currentTimeMillis();
        }

        JSONObject eventState(long after) {
            JSONObject value = new JSONObject();
            JSONArray emitted = new JSONArray();
            try {
                for (InteractionEvent event : events) {
                    if (event.sequence <= after) continue;
                    emitted.put(event.json());
                }
                value.put("ok", true);
                value.put("interactionID", id);
                value.put("latestSequence", eventSequence);
                value.put("events", emitted);
                value.put("terminal", terminal());
            } catch (Throwable ignored) {
            }
            return value;
        }

        JSONObject channels() {
            JSONObject channels = new JSONObject();
            try {
                JSONObject providerReturn = new JSONObject();
                providerReturn.put("state", returnState);
                providerReturn.put("returnedAt", invocationReturnedAt);
                channels.put("return", providerReturn);

                JSONObject surface = new JSONObject();
                JSONObject ui = lastUI == null ? emptyUI() : lastUI;
                boolean requestScoped = !terminal()
                        && ui.optBoolean("surfaceRequestScoped", false);
                boolean active = requestScoped
                        && ui.optBoolean("surfaceActive", false);
                boolean delegated = active
                        && ui.optBoolean("surfaceDelegated", false);
                surface.put("owner", "actionSession");
                surface.put("visible", uiVisible && !terminal());
                surface.put(
                        "lastCapturedVisible",
                        ui.optBoolean("visible", false)
                );
                surface.put("active", active);
                surface.put("requestScoped", requestScoped);
                surface.put("delegated", delegated);
                surface.put(
                        "interactionID",
                        requestScoped
                                ? ui.optString("surfaceInteractionID", "")
                                : ""
                );
                surface.put(
                        "mode",
                        active ? ui.optString("surfaceMode", "none") : "none"
                );
                surface.put(
                        "hostLifecycle",
                        requestScoped
                                ? ui.optString("surfaceHostLifecycle", "none")
                                : "none"
                );
                surface.put("generation", ui.optLong("generation", 0L));
                channels.put("surface", surface);

                JSONObject eventChannel = new JSONObject();
                eventChannel.put("latestSequence", eventSequence);
                channels.put("events", eventChannel);
            } catch (Throwable ignored) {
            }
            return channels;
        }

        JSONObject json() {
            JSONObject value = new JSONObject();
            try {
                value.put("ok", true);
                value.put("interactionID", id);
                value.put("revision", revision);
                value.put("kind", kind);
                value.put("declaredKind", declaredKind);
                value.put("method", method);
                value.put("phase", phase);
                value.put("outcome", outcome);
                value.put("createdAt", createdAt);
                value.put("updatedAt", updatedAt);
                value.put("terminal", terminal());
                value.put("workerReturned", invocationReturned);
                value.put("returnState", returnState);
                value.put("channels", channels());
                value.put("expectsProviderUI", expectsProviderUI);
                value.put("uiObserved", sawUI);
                value.put("uiVisible", uiVisible);
                putSurfaceFields(
                        value,
                        lastUI == null ? emptyUI() : lastUI,
                        terminal()
                );
                if (delayedUIDeadline > 0L && !terminal()) {
                    value.put("graceDeadline", delayedUIDeadline);
                }
                if (!failure.isEmpty()) value.put("error", failure);
                if (!failureKind.isEmpty()) {
                    value.put("failureKind", failureKind);
                }
            } catch (Throwable ignored) {
            }
            return value;
        }

        JSONObject jsonWithUI() {
            JSONObject value = json();
            try {
                JSONObject ui = lastUI == null ? emptyUI() : lastUI;
                putSurfaceFields(value, ui, terminal());
                value.put("phase", phase);
                value.put("outcome", outcome);
                value.put("revision", revision);
                value.put("interactionID", id);
            } catch (Throwable ignored) {
            }
            return value;
        }
    }

    private static final class InteractionEvent {
        final long sequence;
        final String type;
        final String message;
        final long createdAt;

        InteractionEvent(
                long sequence,
                String type,
                String message,
                long createdAt
        ) {
            this.sequence = sequence;
            this.type = type;
            this.message = message;
            this.createdAt = createdAt;
        }

        JSONObject json() {
            JSONObject value = new JSONObject();
            try {
                value.put("sequence", sequence);
                value.put("type", type);
                value.put("message", message);
                value.put("createdAt", createdAt);
            } catch (Throwable ignored) {
            }
            return value;
        }
    }
}
