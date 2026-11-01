package com.okvideomac.dexbridge;

import com.google.gson.*;
import java.io.IOException;
import java.net.*;
import java.util.*;
import java.util.regex.Pattern;
import okhttp3.OkHttpClient;
import okio.ByteString;

/** Immutable, media-request-only routing. Never changes Android's global proxy. */
final class MediaRequestNetworkPolicy extends ProxySelector {
    private final JsonObject settings;

    private MediaRequestNetworkPolicy(JsonObject settings) { this.settings = settings; }

    static MediaRequestNetworkPolicy direct() { return new MediaRequestNetworkPolicy(new JsonObject()); }

    static MediaRequestNetworkPolicy decode(String encoded) throws IOException {
        if (encoded == null || encoded.isEmpty()) throw new IOException("Missing media network policy");
        try {
            if (encoded.length() > 32768) throw new IllegalArgumentException();
            ByteString decoded = ByteString.decodeBase64(encoded);
            if (decoded == null) throw new IllegalArgumentException();
            JsonObject value = JsonParser.parseString(decoded.utf8()).getAsJsonObject();
            if (!value.has("version") || value.get("version").getAsInt() != 1) throw new IllegalArgumentException();
            return new MediaRequestNetworkPolicy(value);
        } catch (RuntimeException invalid) { throw new IOException("Invalid media network policy"); }
    }

    OkHttpClient client(OkHttpClient base) {
        return base.newBuilder().proxy(null).proxySelector(this).build();
    }

    @Override public List<Proxy> select(URI uri) {
        String host = uri.getHost() == null ? "" : uri.getHost().toLowerCase(Locale.ROOT);
        if (loopback(host) || !flag("enabled") || bypasses(host)) return Collections.singletonList(Proxy.NO_PROXY);
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!("http".equals(scheme) || "https".equals(scheme))) return Collections.singletonList(Proxy.NO_PROXY);
        if (flag("unsupported")) throw new IllegalArgumentException("Unsupported media system proxy");
        JsonElement entry = settings.get(scheme);
        if (entry == null) {
            if (flag("socks")) throw new IllegalArgumentException("Unsupported media SOCKS proxy");
            return Collections.singletonList(Proxy.NO_PROXY);
        }
        try {
            JsonObject endpoint = entry.getAsJsonObject();
            String address = endpoint.get("host").getAsString();
            int port = endpoint.get("port").getAsInt();
            if (address.isEmpty() || address.length() > 253 || address.contains("/") || address.contains("@")
                    || address.chars().anyMatch(Character::isWhitespace) || port < 1 || port > 65535) throw new IllegalArgumentException();
            return Collections.singletonList(new Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(address, port)));
        } catch (RuntimeException invalid) { throw new IllegalArgumentException("Invalid media proxy endpoint"); }
    }

    private boolean flag(String key) { return settings.has(key) && settings.get(key).getAsBoolean(); }
    private boolean bypasses(String host) {
        if (flag("excludeSimple") && !host.contains(".") && !host.contains(":")) return true;
        JsonElement exceptions = settings.get("exceptions");
        if (exceptions == null || !exceptions.isJsonArray()) return false;
        for (JsonElement item : exceptions.getAsJsonArray()) {
            String rule = item.getAsString().toLowerCase(Locale.ROOT);
            if (rule.length() > 512) continue;
            if (rule.contains("/")) {
                String[] cidr = rule.split("/", -1);
                try {
                    String networkText = cidr[0];
                    while (networkText.split("\\.", -1).length < 4) networkText += ".0";
                    long address = ipv4(host), network = ipv4(networkText); int bits = Integer.parseInt(cidr[1]);
                    if (address >= 0 && network >= 0 && bits >= 0 && bits <= 32) {
                        long mask = bits == 0 ? 0 : (0xffffffffL << (32 - bits)) & 0xffffffffL;
                        if ((address & mask) == (network & mask)) return true;
                    }
                } catch (RuntimeException ignored) { }
            } else {
                StringBuilder pattern = new StringBuilder("^");
                for (int i = 0; i < rule.length(); i++) {
                    char c = rule.charAt(i);
                    pattern.append(c == '*' ? ".*" : c == '?' ? "." : Pattern.quote(String.valueOf(c)));
                }
                if (host.matches(pattern.append('$').toString())) return true;
            }
        }
        return false;
    }
    private static long ipv4(String host) {
        String[] parts = host.split("\\.", -1); if (parts.length != 4) return -1;
        long result = 0;
        for (String part : parts) { if (!part.matches("[0-9]{1,3}")) return -1; int n = Integer.parseInt(part); if (n > 255) return -1; result = result * 256 + n; }
        return result;
    }
    private static boolean loopback(String host) {
        String value = host.replace("[", "").replace("]", "");
        long address = ipv4(value.startsWith("::ffff:") ? value.substring(7) : value);
        return "localhost".equals(value) || "localhost.".equals(value) || "::1".equals(value)
                || "0:0:0:0:0:0:0:1".equals(value) || "10.0.2.2".equals(value)
                || (address >= 0 && (address >>> 24) == 127);
    }
    @Override public void connectFailed(URI uri, SocketAddress address, IOException error) { }
    @Override public boolean equals(Object value) {
        return value instanceof MediaRequestNetworkPolicy && settings.equals(((MediaRequestNetworkPolicy) value).settings);
    }
    @Override public int hashCode() { return settings.hashCode(); }
}
