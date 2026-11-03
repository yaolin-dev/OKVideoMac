package com.okvideomac.dexbridge;

/** The public, data-free CatVod ProxyOrigin port probe, not a proxy capability. */
final class ProxyOriginPortCheck {
    private ProxyOriginPortCheck() { }

    static boolean accepts(String method, String target) {
        // Match the captured protocol literally. Extra/duplicate parameters,
        // absolute targets and other methods must use normal session checks.
        return "GET".equals(method) && "/proxy?do=ck".equals(target);
    }
}
