package com.okvideomac.dexbridge;

import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Binds a host-issued opaque provider capability to one exact DEX request
 * owner. The opaque identifier is never used to rediscover a recently used
 * jar: every subsequent credential or media operation must also match the
 * configuration, site, interaction, and jar recorded by the invocation.
 */
final class BridgeProviderOwnerRegistry {
    private static final int MAX_BINDINGS = 512;
    private static final Map<String, Binding> BINDINGS = new LinkedHashMap<>();
    private static final Map<String, String> INTERACTION_BINDINGS =
            new LinkedHashMap<>();

    private BridgeProviderOwnerRegistry() {
    }

    static synchronized Binding bind(JSONObject payload, String jarKey) {
        String ownerID = required(payload, "providerOwnerID");
        String configurationID = required(payload, "configurationID");
        String siteKey = required(payload, "siteKey");
        String interactionID = clean(payload.optString("interactionID", ""));
        JSONObject actionContract = copy(payload.optJSONObject("actionContract"));
        String key = key(ownerID, configurationID, siteKey, interactionID);
        Binding existing = BINDINGS.get(key);
        if (existing != null) {
            if (!existing.jarKey.equals(clean(jarKey))) {
                throw new IllegalStateException("Provider owner jar mismatch");
            }
            // The host may omit the contract on later non-action calls. It
            // may not silently replace a contract already bound to the same
            // request owner.
            if (actionContract != null && existing.actionContract != null
                    && !existing.actionContract.toString()
                    .equals(actionContract.toString())) {
                throw new IllegalStateException(
                        "Provider owner action contract mismatch"
                );
            }
            return existing;
        }
        Binding binding = new Binding(
                ownerID,
                configurationID,
                siteKey,
                interactionID,
                clean(jarKey),
                actionContract
        );
        BINDINGS.put(key, binding);
        if (!interactionID.isEmpty()) {
            String previous = INTERACTION_BINDINGS.put(interactionID, key);
            if (previous != null && !previous.equals(key)) {
                BINDINGS.remove(previous);
            }
        }
        prune();
        return binding;
    }

    static synchronized Binding require(JSONObject payload) {
        String ownerID = required(payload, "providerOwnerID");
        String configurationID = required(payload, "configurationID");
        String siteKey = required(payload, "siteKey");
        String interactionID = required(payload, "interactionID");
        Binding binding = BINDINGS.get(
                key(ownerID, configurationID, siteKey, interactionID)
        );
        if (binding == null) {
            throw new IllegalStateException(
                    "Provider owner is missing or no longer current"
            );
        }
        JSONObject suppliedContract = payload.optJSONObject("actionContract");
        if (suppliedContract != null && binding.actionContract != null
                && !binding.actionContract.toString()
                .equals(suppliedContract.toString())) {
            throw new IllegalStateException(
                    "Provider owner action contract mismatch"
            );
        }
        if (!BridgeInteractionRegistry.ownsLatest(interactionID)
                || BridgeInteractionRegistry.terminal(interactionID)) {
            throw new IllegalStateException(
                    "Provider interaction is stale or terminal"
            );
        }
        return binding;
    }

    static synchronized JSONObject state(String interactionID) {
        String key = INTERACTION_BINDINGS.get(clean(interactionID));
        Binding binding = key == null ? null : BINDINGS.get(key);
        return binding == null ? null : binding.publicState();
    }

    static synchronized void releaseInteraction(String interactionID) {
        String key = INTERACTION_BINDINGS.remove(clean(interactionID));
        if (key != null) BINDINGS.remove(key);
    }

    static synchronized void resetForTests() {
        BINDINGS.clear();
        INTERACTION_BINDINGS.clear();
    }

    private static String key(
            String ownerID,
            String configurationID,
            String siteKey,
            String interactionID
    ) {
        return ownerID + '\u0000' + configurationID + '\u0000'
                + siteKey + '\u0000' + interactionID;
    }

    private static void prune() {
        while (BINDINGS.size() > MAX_BINDINGS) {
            String oldest = BINDINGS.keySet().iterator().next();
            BINDINGS.remove(oldest);
            INTERACTION_BINDINGS.values().removeIf(oldest::equals);
        }
    }

    private static String required(JSONObject object, String name) {
        String value = clean(object == null ? "" : object.optString(name, ""));
        if (value.isEmpty()) throw new IllegalArgumentException("Missing " + name);
        return value;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }

    private static JSONObject copy(JSONObject value) {
        if (value == null) return null;
        try {
            return new JSONObject(value.toString());
        } catch (Throwable ignored) {
            return null;
        }
    }

    static final class Binding {
        final String ownerID;
        final String configurationID;
        final String siteKey;
        final String interactionID;
        final String jarKey;
        final JSONObject actionContract;

        Binding(
                String ownerID,
                String configurationID,
                String siteKey,
                String interactionID,
                String jarKey,
                JSONObject actionContract
        ) {
            this.ownerID = ownerID;
            this.configurationID = configurationID;
            this.siteKey = siteKey;
            this.interactionID = interactionID;
            this.jarKey = jarKey;
            this.actionContract = copy(actionContract);
        }

        JSONObject publicState() {
            JSONObject value = new JSONObject();
            try {
                value.put("providerOwnerID", ownerID);
                value.put("configurationID", configurationID);
                value.put("siteKey", siteKey);
                if (actionContract != null) {
                    value.put("actionContract", copy(actionContract));
                }
            } catch (Throwable ignored) {
            }
            return value;
        }

        JSONObject credentialSubmission() {
            return actionContract == null
                    ? null
                    : actionContract.optJSONObject("credentialSubmission");
        }

        boolean sameOwner(Binding other) {
            return other != null
                    && ownerID.equals(other.ownerID)
                    && configurationID.equals(other.configurationID)
                    && siteKey.equals(other.siteKey)
                    && interactionID.equals(other.interactionID)
                    && jarKey.equals(other.jarKey);
        }
    }
}
