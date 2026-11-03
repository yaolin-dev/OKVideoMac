package com.okvideomac.dexbridge;

import com.google.gson.JsonElement;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.CancellationException;

/** Bounded navigation warm-up for WoGG's swallowed network/domain failures. */
final class ProviderDetailRecovery {
    interface Request { String run() throws Exception; }
    static final class Unavailable extends IllegalStateException {
        Unavailable() { super("ProviderDetailUnavailableAfterRecovery"); }
        Unavailable(Exception cause) { super("ProviderDetailUnavailableAfterRecovery", cause); }
    }

    static boolean supports(String api, List<String> ids) {
        return ("csp_WoGG".equals(api) || "csp_WoGGGuard".equals(api))
                && ids.size() == 1 && ids.get(0).matches("[0-9]{1,20}");
    }

    static String load(Request detail, Request home) throws Exception {
        return load(detail, home, null);
    }

    static String load(Request detail, Request home, Request recreatedDetail) throws Exception {
        checkCancellation();
        try {
            String raw = detail.run();
            checkCancellation();
            if (!empty(raw)) return raw;
        } catch (Exception failure) {
            if (!recoverable(failure)) throw failure;
        }
        checkCancellation();
        // Home re-resolves the source's entry domain. Do not destroy the JAR:
        // its proxy, login state and other active media sessions are shared.
        boolean entryUnavailable = false;
        try { entryUnavailable = !hasNavigationEntry(home.run()); }
        catch (Exception failure) {
            if (!recoverable(failure)) throw failure;
            entryUnavailable = true;
        }
        checkCancellation();
        try {
            String raw = detail.run();
            checkCancellation();
            if (!empty(raw)) return raw;
        } catch (Exception failure) {
            if (!recoverable(failure)) throw failure;
            if (!entryUnavailable || recreatedDetail == null) throw new Unavailable(failure);
        }
        // Only the supported navigation adapter may supply this callback.
        // A healthy homepage with an empty detail does NOT justify a reset.
        // The entire transaction is at most three detail calls / one new instance.
        if (entryUnavailable && recreatedDetail != null) {
            checkCancellation();
            try {
                String raw = recreatedDetail.run();
                checkCancellation();
                if (!empty(raw)) return raw;
            } catch (Exception failure) {
                if (!recoverable(failure)) throw failure;
                throw new Unavailable(failure);
            }
        }
        throw new Unavailable();
    }

    static boolean empty(String raw) {
        if (raw == null || raw.trim().isEmpty()) return true;
        try {
            JsonElement value = JsonParser.parseString(raw);
            if (value.isJsonNull()) return true;
            if (value.isJsonArray()) return value.getAsJsonArray().size() == 0;
            if (!value.isJsonObject()) return false;
            if (value.getAsJsonObject().size() == 0) return true;
            JsonElement list = value.getAsJsonObject().get("list");
            return list != null && list.isJsonArray() && list.getAsJsonArray().size() == 0;
        } catch (RuntimeException invalid) { return false; }
    }

    private static boolean hasNavigationEntry(String raw) {
        if (raw != null) {
            try {
                JsonElement value = JsonParser.parseString(raw);
                if (value.isJsonObject()) {
                    JsonElement categories = value.getAsJsonObject().get("class");
                    // A valid category catalog is enough even if there are no
                    // homepage recommendations. Do not recreate a healthy source.
                    if (categories != null && categories.isJsonArray()
                            && categories.getAsJsonArray().size() > 0) return true;
                }
            } catch (RuntimeException ignored) { }
        }
        return !empty(raw);
    }

    private static boolean recoverable(Exception error) {
        if (Thread.currentThread().isInterrupted()) return false;
        if (error instanceof InterruptedException || error instanceof CancellationException) return false;
        if (error instanceof IOException) return true;
        // WoGG refTry can lose its domain after a reset and construct voddetail
        // as a relative URL. No arbitrary provider exceptions are retried.
        return error instanceof IllegalArgumentException && error.getMessage() != null
                && error.getMessage().contains("Expected URL scheme");
    }

    private static void checkCancellation() throws InterruptedException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
    }
}
