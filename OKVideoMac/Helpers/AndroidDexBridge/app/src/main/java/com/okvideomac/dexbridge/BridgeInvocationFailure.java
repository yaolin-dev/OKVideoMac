package com.okvideomac.dexbridge;

import java.io.IOException;
import java.util.concurrent.CancellationException;

/** Host-owned classification; never infers a deleted movie from an empty list. */
final class BridgeInvocationFailure {
    static String kind(Throwable error) {
        // Walk wrapped provider/reflection failures without unbounded cycles.
        for (int depth = 0; error != null && depth < 16; depth++, error = error.getCause()) {
            if (error instanceof CancellationException || error instanceof InterruptedException)
                return "cancelled";
            if (error instanceof ProviderDetailRecovery.Unavailable)
                return "sourceUnavailable";
            if (error instanceof IOException) return "network";
            if (error instanceof IllegalArgumentException && error.getMessage() != null
                    && error.getMessage().contains("Expected URL scheme")) return "sourceEntry";
        }
        return "provider";
    }
}
