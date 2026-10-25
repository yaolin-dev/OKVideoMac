package com.okvideomac.dexbridge;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.function.LongSupplier;

/** Request cancellation never destroys a Spider shared with playback. */
final class SearchRequestRegistry {
    private static final long CANCELLATION_TTL_NANOS = 60_000_000_000L;
    private static final int MAX_ACTIVE = 128;
    private static final int MAX_CANCELLED = 256;
    private final Map<String, Future<?>> active = new LinkedHashMap<>();
    private final LinkedHashMap<String, Long> cancelled = new LinkedHashMap<>();
    private final LongSupplier clock;

    SearchRequestRegistry() { this(System::nanoTime); }
    SearchRequestRegistry(LongSupplier clock) { this.clock = clock; }

    synchronized <T> Future<T> submit(String id, ExecutorService executor, Callable<T> operation) {
        validateID(id);
        prune();
        if (cancelled.containsKey(id)) throw new CancellationException("Search already cancelled");
        if (active.containsKey(id)) throw new IllegalArgumentException("Duplicate search request");
        if (active.size() >= MAX_ACTIVE) throw new IllegalStateException("Search queue is full");
        FutureTask<T> future = new FutureTask<T>(operation) {
            @Override protected void done() {
                synchronized (SearchRequestRegistry.this) { active.remove(id, this); }
            }
        };
        active.put(id, future);
        try { executor.execute(future); }
        catch (RuntimeException error) { active.remove(id, future); throw error; }
        return future;
    }

    synchronized boolean cancel(String id) {
        validateID(id);
        prune();
        // Covers cancellation arriving before /invoke is admitted.
        cancelled.put(id, clock.getAsLong());
        while (cancelled.size() > MAX_CANCELLED) {
            cancelled.remove(cancelled.keySet().iterator().next());
        }
        Future<?> future = active.get(id);
        return future != null && future.cancel(true);
    }

    private void prune() {
        long now = clock.getAsLong();
        cancelled.entrySet().removeIf(entry -> now - entry.getValue() >= CANCELLATION_TTL_NANOS);
    }

    private static void validateID(String id) {
        if (id == null || id.length() != 36 || !UUID.fromString(id).toString().equalsIgnoreCase(id)) {
            throw new IllegalArgumentException("Invalid search request ID");
        }
    }
}
