package com.okvideomac.dexbridge;

import com.google.gson.JsonElement;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.CancellationException;

/** Bounded navigation warm-up for WoGG's swallowed network/domain failures. */
final class ProviderDetailRecovery {
    interface Request { String run() throws Exception; }

    static boolean supports(String api, List<String> ids) {
        return ("csp_WoGG".equals(api) || "csp_WoGGGuard".equals(api))
                && ids.size() == 1 && ids.get(0).matches("[0-9]{1,20}");
    }

    static String load(Request detail, Request home) throws Exception {
        checkCancellation();
        try {
            String raw = detail.run();
            if (!empty(raw)) return raw;
        } catch (Exception failure) {
            if (!recoverable(failure)) throw failure;
        }
        checkCancellation();
        // Home re-resolves the source's entry domain. Do not destroy the JAR:
        // its proxy, login state and other active media sessions are shared.
        try { home.run(); }
        catch (Exception failure) {
            if (!recoverable(failure)) throw failure;
        }
        checkCancellation();
        String raw = detail.run();
        checkCancellation();
        if (empty(raw)) throw new IllegalStateException("ProviderDetailUnavailableAfterRecovery");
        return raw;
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

    private static boolean recoverable(Exception error) {
        if (error instanceof InterruptedException || error instanceof CancellationException) return false;
        if (error instanceof IOException) return true;
        // WoGG refTry can lose its domain after a reset and construct voddetail
        // as a relative URL. No arbitrary provider exceptions are retried.
        return error instanceof IllegalArgumentException && error.getMessage() != null
                && error.getMessage().contains("Expected URL scheme")
                && error.getMessage().contains("voddet");
    }

    private static void checkCancellation() throws InterruptedException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
    }
}
