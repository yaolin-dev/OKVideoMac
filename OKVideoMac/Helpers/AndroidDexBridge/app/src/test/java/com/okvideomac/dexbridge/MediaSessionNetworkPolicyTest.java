package com.okvideomac.dexbridge;

import org.junit.Test;
import java.net.URI;
import java.net.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import static org.junit.Assert.*;

public class MediaSessionNetworkPolicyTest {
    @Test public void clonedCapabilityKeepsExistingRequestsAndDashChildrenOnTheirOriginalPolicy() throws Exception {
        MediaRequestNetworkPolicy direct = MediaRequestNetworkPolicy.direct();
        MediaRequestNetworkPolicy proxied = MediaRequestNetworkPolicy.decode(Base64.getEncoder().encodeToString(
                "{\"version\":1,\"enabled\":true,\"https\":{\"host\":\"127.0.0.1\",\"port\":8800}}".getBytes(StandardCharsets.UTF_8)));
        BridgeMediaSessionRegistry.Session original = BridgeMediaSessionRegistry.remoteWithNetworkPolicy(
                "https://media.example/manifest.mpd", null, direct);
        original.mergeHeaders(Map.of("Cookie", "session-secret"));
        BridgeMediaSessionRegistry.Session next = BridgeMediaSessionRegistry.withNetworkPolicy(original.id, proxied);
        assertNotEquals(original.id, next.id);
        assertEquals(original.headerSnapshot(), next.headerSnapshot());
        assertEquals(original.upstreamFingerprint, next.upstreamFingerprint);
        URI remote = URI.create("https://media.example/segment.m4s");
        assertEquals(Proxy.NO_PROXY, original.networkPolicy.select(remote).get(0));
        assertEquals(Proxy.Type.HTTP, next.networkPolicy.select(remote).get(0).type());
        String child = next.registerDashResource(List.of(remote.toString()), next.upstreamFingerprint);
        assertTrue(child.startsWith("/proxy/media/" + next.id + "/dash/"));
        assertSame(proxied, BridgeMediaSessionRegistry.get(next.id).networkPolicy);
        assertSame(direct, BridgeMediaSessionRegistry.get(original.id).networkPolicy);
        next.mergeHeaders(Map.of("Cookie", "new-secret"));
        assertEquals("session-secret", original.headerSnapshot().get("Cookie"));
        try { BridgeMediaSessionRegistry.withNetworkPolicy("missing", proxied); fail(); }
        catch (java.io.IOException expected) { assertEquals("Media session expired or missing", expected.getMessage()); }
    }
}
