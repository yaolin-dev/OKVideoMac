package com.okvideomac.dexbridge;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Iterator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/** Keeps Android loopback media and its request context inside the provider VM. */
final class BridgeMediaSessionRegistry {
    private static final long SESSION_TTL_MS = 2 * 60 * 60_000L;
    private static final int MAX_SESSIONS = 512;
    private static final Map<String, Session> SESSIONS = new ConcurrentHashMap<>();

    private BridgeMediaSessionRegistry() {
    }

    static Object securePlaybackResult(Object decoded) {
        return securePlaybackResult(decoded, false, null, null);
    }

    static Object securePlaybackResult(
            Object decoded,
            boolean refreshPerformed
    ) {
        return securePlaybackResult(decoded, refreshPerformed, null, null);
    }

    /**
     * Secures a provider playback result together with the request-scoped site
     * headers that were active for the exact invocation. Result-level headers
     * remain authoritative and replace a same-named site header.
     */
    static Object securePlaybackResult(
            Object decoded,
            boolean refreshPerformed,
            JSONObject requestHeaders
    ) {
        return securePlaybackResult(
                decoded,
                refreshPerformed,
                requestHeaders,
                null
        );
    }

    static Object securePlaybackResult(
            Object decoded,
            boolean refreshPerformed,
            JSONObject requestHeaders,
            BridgeProviderOwnerRegistry.Binding owner
    ) {
        if (!(decoded instanceof JSONObject)) return decoded;
        JSONObject result = (JSONObject) decoded;
        if (result.optInt("parse", 0) != 0) return result;
        Map<String, String> headers = new LinkedHashMap<>();
        collectHeaders(requestHeaders, headers);
        collectHeaders(result.optJSONObject("header"), headers);
        collectHeaders(result.optJSONObject("headers"), headers);
        Object url = result.opt("url");
        boolean protectedAny = false;
        JSONArray metadata = new JSONArray();
        try {
            if (url instanceof String) {
                SecuredURL secured = secureURL((String) url, headers, owner);
                protectedAny = secured.protectedByBridge;
                result.put("url", secured.url);
                appendMetadata(metadata, secured);
            } else if (url instanceof JSONArray) {
                JSONArray values = (JSONArray) url;
                for (int index = 1; index < values.length(); index += 2) {
                    String original = values.optString(index, "");
                    SecuredURL secured = secureURL(original, headers, owner);
                    protectedAny = protectedAny || secured.protectedByBridge;
                    values.put(index, secured.url);
                    appendMetadata(metadata, secured);
                }
            } else if (url instanceof JSONObject) {
                JSONArray values = ((JSONObject) url).optJSONArray("values");
                if (values != null) {
                    for (int index = 0; index < values.length(); index++) {
                        JSONObject item = values.optJSONObject(index);
                        if (item != null) {
                            String original = item.optString("v", "");
                            SecuredURL secured = secureURL(
                                    original,
                                    headers,
                                    owner
                            );
                            protectedAny = protectedAny
                                    || secured.protectedByBridge;
                            item.put("v", secured.url);
                            if (secured.protectedByBridge) {
                                item.put("mediaSessionID", secured.sessionID);
                                item.put(
                                        "upstreamFingerprint",
                                        secured.upstreamFingerprint
                                );
                            }
                            appendMetadata(metadata, secured);
                        }
                    }
                }
            }
        } catch (StaleMediaSessionException error) {
            throw error;
        } catch (Throwable ignored) {
            // Return the provider result unchanged when a shape is unfamiliar.
        }
        if (protectedAny) {
            // Secrets remain attached to the provider-owned session rather
            // than being serialized to the Mac host or persisted in history.
            result.remove("header");
            result.remove("headers");
        }
        try {
            if (metadata.length() > 0) {
                JSONObject primary = metadata.getJSONObject(0);
                result.put(
                        "mediaSessionID",
                        primary.getString("mediaSessionID")
                );
                result.put(
                        "upstreamFingerprint",
                        primary.getString("upstreamFingerprint")
                );
                if (metadata.length() > 1) {
                    result.put("mediaSessions", metadata);
                }
            }
            result.put("refreshPerformed", refreshPerformed);
        } catch (Throwable ignored) {
        }
        return result;
    }

    static Session get(String id) {
        prune();
        Session session = SESSIONS.get(id == null ? "" : id.trim());
        if (session == null) return null;
        if (session.expiresAt < System.currentTimeMillis()) {
            SESSIONS.remove(session.id);
            return null;
        }
        session.expiresAt = System.currentTimeMillis() + SESSION_TTL_MS;
        return session;
    }

    private static SecuredURL secureURL(
            String raw,
            Map<String, String> headers,
            BridgeProviderOwnerRegistry.Binding owner
    ) {
        String existingID = bridgeSessionID(raw);
        if (!existingID.isEmpty()) {
            Session existing = get(existingID);
            // A bridge capability is never an upstream media locator. If its
            // registry entry has expired, wrapping it again would create a
            // recursive /proxy/media session that can never reach the media.
            // Fail while still inside the provider process so the host can
            // perform one same-resource refresh instead.
            if (existing == null) {
                throw new StaleMediaSessionException(
                        "Media session expired or missing"
                );
            }
            if (owner != null && !owner.sameOwner(existing.owner)) {
                throw new StaleMediaSessionException(
                        "Media session belongs to a different provider owner"
                );
            }
            existing.mergeHeaders(headers);
            return new SecuredURL(
                    raw,
                    existingID,
                    existing.upstreamFingerprint,
                    true
            );
        }
        URI upstream = httpURI(raw);
        if (upstream == null) {
            return new SecuredURL(raw, "", "", false);
        }
        // Remote media must stay player-owned. libmpv can send the provider's
        // playback headers itself and is substantially better at CDN Range
        // recovery, demux probing and seeking than a second HTTP hop through
        // the Android emulator. This restores the pre-session playback path.
        // Only Android loopback media needs a scoped bridge capability because
        // the Mac cannot reach a provider-owned 127.0.0.1 port directly.
        if (!isLoopbackHost(upstream.getHost())) {
            return new SecuredURL(raw.trim(), "", "", false);
        }
        prune();
        String id = UUID.randomUUID().toString();
        Session session = new Session(id, raw.trim(), headers, owner);
        SESSIONS.put(id, session);
        return new SecuredURL(
                "http://127.0.0.1:" + BridgeServer.PORT
                        + "/proxy/media/" + id,
                id,
                session.upstreamFingerprint,
                true
        );
    }

    private static void appendMetadata(
            JSONArray metadata,
            SecuredURL secured
    ) {
        if (secured == null
                || !secured.protectedByBridge
                || secured.sessionID.isEmpty()
                || secured.upstreamFingerprint.isEmpty()) {
            return;
        }
        try {
            metadata.put(new JSONObject()
                    .put("mediaSessionID", secured.sessionID)
                    .put(
                            "upstreamFingerprint",
                            secured.upstreamFingerprint
                    ));
        } catch (Throwable ignored) {
        }
    }

    private static String bridgeSessionID(String raw) {
        if (raw == null || raw.trim().isEmpty()) return "";
        try {
            URI uri = URI.create(raw.trim());
            if (!isHTTP(uri)
                    || !isLoopbackHost(uri.getHost())
                    || uri.getPort() != BridgeServer.PORT) {
                return "";
            }
            String path = uri.getPath();
            String prefix = path != null && path.startsWith("/proxy/media/")
                    ? "/proxy/media/"
                    : path != null && path.startsWith("/v1/media-sessions/")
                    ? "/v1/media-sessions/"
                    : "";
            if (prefix.isEmpty()) return "";
            String id = path.substring(prefix.length());
            return id.isEmpty() || id.indexOf('/') >= 0 ? "" : id;
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static URI httpURI(String raw) {
        if (raw == null || raw.trim().isEmpty()) return null;
        try {
            URI uri = URI.create(raw.trim());
            return isHTTP(uri) ? uri : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static boolean isHTTP(URI uri) {
        String scheme = uri.getScheme();
        return uri.getHost() != null
                && scheme != null
                && ("http".equalsIgnoreCase(scheme)
                || "https".equalsIgnoreCase(scheme));
    }

    private static boolean isLoopbackHost(String host) {
        if (host == null) return false;
        String normalized = host.toLowerCase(Locale.ROOT);
        return "localhost".equals(normalized)
                || "127.0.0.1".equals(normalized)
                || "::1".equals(normalized);
    }

    private static void collectHeaders(
            JSONObject object,
            Map<String, String> output
    ) {
        if (object == null) return;
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            String value = object.optString(key, "");
            if (safeHeaderName(key)
                    && value.indexOf('\r') < 0
                    && value.indexOf('\n') < 0
                    && !value.trim().isEmpty()) {
                putHeaderIgnoreCase(output, key.trim(), value);
            }
        }
    }

    /** A provider result may use both `header` and `headers` with mixed case. */
    private static void putHeaderIgnoreCase(
            Map<String, String> headers,
            String name,
            String value
    ) {
        String matched = null;
        for (String existing : headers.keySet()) {
            if (existing.equalsIgnoreCase(name)) {
                matched = existing;
                break;
            }
        }
        if (matched != null) headers.remove(matched);
        headers.put(name, value);
    }

    private static boolean safeHeaderName(String name) {
        if (name == null || name.indexOf('\r') >= 0 || name.indexOf('\n') >= 0) {
            return false;
        }
        String lower = name.trim().toLowerCase(Locale.ROOT);
        return !lower.isEmpty()
                && !"host".equals(lower)
                && !"content-length".equals(lower)
                && !"connection".equals(lower)
                && !"transfer-encoding".equals(lower);
    }

    private static String sha256(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(
                    value.getBytes(StandardCharsets.UTF_8)
            );
            StringBuilder output = new StringBuilder(digest.length * 2);
            for (byte item : digest) {
                output.append(String.format(Locale.ROOT, "%02x", item & 0xff));
            }
            return output.toString();
        } catch (Throwable ignored) {
            // SHA-256 is mandatory on Android. Keep a fixed, non-secret shape
            // even on a broken runtime rather than returning the source URL.
            return String.format(
                    Locale.ROOT,
                    "%064x",
                    (long) value.hashCode() & 0xffffffffL
            );
        }
    }

    /**
     * Fingerprints the complete upstream request contract without exposing the
     * signed URL or any header value outside this process. Header names are
     * case-insensitive and order-independent, matching HTTP merge semantics.
     */
    private static String requestContextFingerprint(
            String upstreamURL,
            Map<String, String> headers,
            BridgeProviderOwnerRegistry.Binding owner
    ) {
        List<String> names = new ArrayList<>();
        if (headers != null) {
            for (String name : headers.keySet()) {
                if (name != null) {
                    names.add(name.trim().toLowerCase(Locale.ROOT));
                }
            }
        }
        Collections.sort(names);
        StringBuilder canonical = new StringBuilder();
        appendFingerprintField(canonical, "url", upstreamURL);
        if (owner != null) {
            appendFingerprintField(canonical, "owner", owner.ownerID);
            appendFingerprintField(
                    canonical,
                    "configuration",
                    owner.configurationID
            );
            appendFingerprintField(canonical, "site", owner.siteKey);
            appendFingerprintField(
                    canonical,
                    "interaction",
                    owner.interactionID
            );
            appendFingerprintField(canonical, "jar", owner.jarKey);
        }
        for (String name : names) {
            appendFingerprintField(canonical, "header-name", name);
            appendFingerprintField(
                    canonical,
                    "header-value",
                    headerValueIgnoreCase(headers, name)
            );
        }
        return sha256(canonical.toString());
    }

    private static void appendFingerprintField(
            StringBuilder output,
            String label,
            String value
    ) {
        String safeValue = value == null ? "" : value;
        output.append(label)
                .append(':')
                .append(safeValue.length())
                .append(':')
                .append(safeValue)
                .append('\n');
    }

    private static String headerValueIgnoreCase(
            Map<String, String> headers,
            String expected
    ) {
        if (headers == null) return "";
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if (entry.getKey().equalsIgnoreCase(expected)) {
                return entry.getValue();
            }
        }
        return "";
    }

    private static void prune() {
        long now = System.currentTimeMillis();
        SESSIONS.entrySet().removeIf(entry -> entry.getValue().expiresAt < now);
        if (SESSIONS.size() <= MAX_SESSIONS) return;
        SESSIONS.values().stream()
                .sorted((left, right) -> Long.compare(left.createdAt, right.createdAt))
                .limit(SESSIONS.size() - MAX_SESSIONS)
                .forEach(session -> SESSIONS.remove(session.id));
    }

    static final class Session {
        final String id;
        final String upstreamURL;
        final BridgeProviderOwnerRegistry.Binding owner;
        final Map<String, String> headers;
        volatile String upstreamFingerprint;
        final long createdAt = System.currentTimeMillis();
        volatile long expiresAt = createdAt + SESSION_TTL_MS;

        Session(
                String id,
                String upstreamURL,
                Map<String, String> headers,
                BridgeProviderOwnerRegistry.Binding owner
        ) {
            this.id = id;
            this.upstreamURL = upstreamURL;
            this.owner = owner;
            this.headers = new ConcurrentHashMap<>();
            mergeHeaders(headers);
        }

        synchronized void mergeHeaders(Map<String, String> additional) {
            if (additional != null) {
                for (Map.Entry<String, String> entry : additional.entrySet()) {
                    putHeaderIgnoreCase(
                            headers,
                            entry.getKey(),
                            entry.getValue()
                    );
                }
            }
            upstreamFingerprint = requestContextFingerprint(
                    upstreamURL,
                    headers,
                    owner
            );
        }

        synchronized Map<String, String> headerSnapshot() {
            return new LinkedHashMap<>(headers);
        }
    }

    private static final class StaleMediaSessionException
            extends IllegalStateException {
        StaleMediaSessionException(String message) {
            super(message);
        }
    }

    private static final class SecuredURL {
        final String url;
        final String sessionID;
        final String upstreamFingerprint;
        final boolean protectedByBridge;

        SecuredURL(
                String url,
                String sessionID,
                String upstreamFingerprint,
                boolean protectedByBridge
        ) {
            this.url = url == null ? "" : url;
            this.sessionID = sessionID == null ? "" : sessionID;
            this.upstreamFingerprint = upstreamFingerprint == null
                    ? ""
                    : upstreamFingerprint;
            this.protectedByBridge = protectedByBridge;
        }
    }
}
