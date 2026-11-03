package com.okvideomac.dexbridge;

import org.junit.Test;
import static org.junit.Assert.*;

public final class ProxyOriginPortCheckTest {
    @Test public void onlyExactDataFreeGetIsAccepted() {
        assertTrue(ProxyOriginPortCheck.accepts("GET", "/proxy?do=ck"));
        for (String method : new String[] {"POST", "HEAD", "PUT", "get", "", null}) {
            assertFalse(ProxyOriginPortCheck.accepts(method, "/proxy?do=ck"));
        }
        for (String target : new String[] {"/proxy", "/proxy?do=play", "/proxy?do=ck&url=https://example.invalid",
                "/proxy?do=play&do=ck", "/proxy?do=ck&do=play", "/proxy?do=ck&mediaSessionID=missing",
                "/proxy/media/ck", "/proxy/?do=ck", "http://127.0.0.1:9978/proxy?do=ck", "", null}) {
            assertFalse(ProxyOriginPortCheck.accepts("GET", target));
        }
    }
}
