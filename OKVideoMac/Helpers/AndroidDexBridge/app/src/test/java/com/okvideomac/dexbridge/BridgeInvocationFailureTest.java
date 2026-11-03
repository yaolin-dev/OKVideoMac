package com.okvideomac.dexbridge;

import java.net.SocketException;
import java.util.concurrent.CancellationException;
import org.junit.Test;
import static org.junit.Assert.*;

public class BridgeInvocationFailureTest {
    @Test public void distinguishesExhaustedRecoveryNetworkEntryAndCancellation() {
        assertEquals("sourceUnavailable", BridgeInvocationFailure.kind(new ProviderDetailRecovery.Unavailable()));
        assertEquals("network", BridgeInvocationFailure.kind(new RuntimeException(new SocketException("reset"))));
        assertEquals("sourceEntry", BridgeInvocationFailure.kind(new IllegalArgumentException("Expected URL scheme")));
        assertEquals("cancelled", BridgeInvocationFailure.kind(new CancellationException()));
        assertEquals("cancelled", BridgeInvocationFailure.kind(new InterruptedException()));
        assertEquals("provider", BridgeInvocationFailure.kind(new IllegalStateException("empty list")));
    }
}
