package com.okvideomac.dexbridge;

import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Binds a host-issued opaque provider capability to one exact DEX request
 * owner. The opaque identifier is never used to rediscover a recently used
 * jar: every subsequent media operation must also match the configuration,
 * site, interaction, and jar recorded by the invocation.
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
        String normalizedJarKey = clean(jarKey);

        // Browse, detail and playback calls do not own an Android UI
        // interaction. Their bindings are request-scoped capabilities handed
        // directly to the compatibility proxy/media session and must not be
        // persisted under the shared empty interaction ID. Persisting them
        // made a normal browse (`configuration`) followed by playback
        // (`playback`) look like one interaction changing its contract, which
        // rejected every direct play before playerContent could run.
        if (interactionID.isEmpty()) {
            return new Binding(
                    ownerID,
                    configurationID,
                    siteKey,
                    interactionID,
                    normalizedJarKey
            );
        }
        String key = key(ownerID, configurationID, siteKey, interactionID);
        Binding existing = BINDINGS.get(key);
        if (existing != null) {
            if (!existing.jarKey.equals(normalizedJarKey)) {
                throw new IllegalStateException("Provider owner jar mismatch");
            }
            return existing;
        }
        Binding binding = new Binding(
                ownerID,
                configurationID,
                siteKey,
                interactionID,
                normalizedJarKey
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

    static final class Binding {
        final String ownerID;
        final String configurationID;
        final String siteKey;
        final String interactionID;
        final String jarKey;

        Binding(
                String ownerID,
                String configurationID,
                String siteKey,
                String interactionID,
                String jarKey
        ) {
            this.ownerID = ownerID;
            this.configurationID = configurationID;
            this.siteKey = siteKey;
            this.interactionID = interactionID;
            this.jarKey = jarKey;
        }

        JSONObject publicState() {
            JSONObject value = new JSONObject();
            try {
                value.put("providerOwnerID", ownerID);
                value.put("configurationID", configurationID);
                value.put("siteKey", siteKey);
            } catch (Throwable ignored) {
            }
            return value;
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
