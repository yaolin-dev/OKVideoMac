package com.okvideomac.dexbridge;

import org.junit.Test;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import static org.junit.Assert.*;

public class SearchRequestRegistryTest {
    @Test public void cancellationBeforeRegistrationPreventsExecution() throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            SearchRequestRegistry registry = new SearchRequestRegistry();
            String id = UUID.randomUUID().toString();
            registry.cancel(id);
            try { registry.submit(id, executor, () -> { fail("cancelled search ran"); return 0; }); fail(); }
            catch (CancellationException expected) {}
            assertEquals(Integer.valueOf(7), registry.submit(UUID.randomUUID().toString(), executor, () -> 7).get(1, TimeUnit.SECONDS));
        } finally { executor.shutdownNow(); }
    }

    @Test public void queuedCancellationSkipsWorkAndRunningCancellationInterrupts() throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor();
        CountDownLatch started = new CountDownLatch(1), exited = new CountDownLatch(1);
        try {
            SearchRequestRegistry registry = new SearchRequestRegistry();
            String first = UUID.randomUUID().toString(), queued = UUID.randomUUID().toString();
            Future<Integer> running = registry.submit(first, executor, () -> {
                started.countDown();
                try { Thread.sleep(30_000); return 0; }
                finally { exited.countDown(); }
            });
            assertTrue(started.await(1, TimeUnit.SECONDS));
            AtomicBoolean queuedRan = new AtomicBoolean();
            Future<Integer> pending = registry.submit(queued, executor, () -> { queuedRan.set(true); return 1; });
            assertTrue(registry.cancel(queued));
            assertTrue(registry.cancel(first));
            assertTrue(exited.await(1, TimeUnit.SECONDS));
            assertTrue(running.isCancelled());
            assertTrue(pending.isCancelled());
            assertEquals(Integer.valueOf(2), registry.submit(UUID.randomUUID().toString(), executor, () -> 2).get(1, TimeUnit.SECONDS));
            assertFalse(queuedRan.get());
        } finally { executor.shutdownNow(); }
    }

    @Test public void expiredTombstoneAndFailedWorkerDoNotPoisonNewWork() throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            AtomicLong clock = new AtomicLong();
            SearchRequestRegistry registry = new SearchRequestRegistry(clock::get);
            String id = UUID.randomUUID().toString();
            registry.cancel(id);
            clock.set(61_000_000_000L);
            try { registry.submit(id, executor, () -> { throw new IllegalStateException("fixture"); }).get(); fail(); }
            catch (ExecutionException expected) {}
            executor.submit(() -> {}).get(1, TimeUnit.SECONDS);
            assertEquals(Integer.valueOf(3), registry.submit(id, executor, () -> 3).get(1, TimeUnit.SECONDS));
        } finally { executor.shutdownNow(); }
    }
}
