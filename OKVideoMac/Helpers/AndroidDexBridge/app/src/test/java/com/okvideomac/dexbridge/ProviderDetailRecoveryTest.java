package com.okvideomac.dexbridge;

import org.junit.Test;
import java.net.SocketException;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.Assert.*;

public class ProviderDetailRecoveryTest {
    private static final String DETAIL = "{\"list\":[{\"vod_id\":\"132908\",\"vod_name\":\"Film\"}]}";

    @Test public void emptyDetailWarmsHomeThenReplaysExactlyOnce() throws Exception {
        StringBuilder calls = new StringBuilder();
        String result = ProviderDetailRecovery.load(() -> {
            calls.append('D'); return calls.length() == 1 ? "{\"list\":[]}" : DETAIL;
        }, () -> { calls.append('H'); return "{}"; });
        assertEquals("DHD", calls.toString()); assertEquals(DETAIL, result);
    }
    @Test public void socketResetAndLostDomainCanRecoverWithoutDestroy() throws Exception {
        for (Exception failure : List.of(new SocketException("Socket is closed"),
                new IllegalArgumentException("Expected URL scheme 'http' or 'https' but no scheme was found for voddetail"))) {
            AtomicInteger details = new AtomicInteger(), homes = new AtomicInteger();
            assertEquals(DETAIL, ProviderDetailRecovery.load(() -> {
                if (details.incrementAndGet() == 1) throw failure;
                return DETAIL;
            }, () -> { homes.incrementAndGet(); return ""; }));
            assertEquals(2, details.get()); assertEquals(1, homes.get());
        }
    }
    @Test public void validNonPlayableDetailsAreNotRetried() throws Exception {
        assertEquals(DETAIL, ProviderDetailRecovery.load(() -> DETAIL, () -> { fail("No warm-up needed"); return null; }));
        assertFalse(ProviderDetailRecovery.empty("not valid json"));
        assertFalse(ProviderDetailRecovery.empty("{\"error\":\"authorization required\"}"));
    }
    @Test public void repeatedEmptyIsExplicitFailureAndRetryIsBounded() throws Exception {
        AtomicInteger details = new AtomicInteger(), homes = new AtomicInteger();
        try {
            ProviderDetailRecovery.load(() -> { details.incrementAndGet(); return ""; },
                    () -> { homes.incrementAndGet(); throw new SocketException("Connection reset"); });
            fail("Should retain a source failure, not invent a missing movie");
        } catch (IllegalStateException expected) {
            assertEquals("ProviderDetailUnavailableAfterRecovery", expected.getMessage());
        }
        assertEquals(2, details.get()); assertEquals(1, homes.get());
    }
    @Test public void cancellationAndConfigurationActionsCannotReplay() throws Exception {
        assertTrue(ProviderDetailRecovery.supports("csp_WoGGGuard", List.of("132908")));
        assertFalse(ProviderDetailRecovery.supports("csp_PanConfigGuard", List.of("132908")));
        assertFalse(ProviderDetailRecovery.supports("csp_WoGGGuard", List.of("quark")));
        assertFalse(ProviderDetailRecovery.supports("csp_WoGGGuard", List.of("1", "2")));
        Thread.currentThread().interrupt();
        try {
            ProviderDetailRecovery.load(() -> { fail("Cancelled"); return null; }, () -> "");
            fail("Expected interruption");
        } catch (InterruptedException expected) { }
        finally { Thread.interrupted(); }
    }
}
