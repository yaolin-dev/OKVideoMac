package com.okvideomac.dexbridge;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/** Invalidates capabilities backed by a jar's mutable proxy target. */
final class ProviderMediaEpoch {
    private static final ConcurrentHashMap<String, AtomicLong> epochs = new ConcurrentHashMap<>();
    static long current(String scope) {
        return epochs.computeIfAbsent(scope, ignored -> new AtomicLong()).get();
    }
    static long advance(String scope) {
        return epochs.computeIfAbsent(scope, ignored -> new AtomicLong()).incrementAndGet();
    }
    static void requireCurrent(String scope, long expected) {
        if (current(scope) != expected) throw new IllegalStateException("Provider media context changed during playback resolution");
    }
    static final class Changed extends IOException { Changed() { super("Provider media context changed"); } }
    static InputStream guard(InputStream input, String scope, long expected) {
        return new FilterInputStream(input) {
            private void check() throws IOException {
                if (current(scope) != expected) throw new Changed();
            }
            @Override public int read() throws IOException {
                check(); int value = in.read(); check(); return value;
            }
            @Override public int read(byte[] bytes, int offset, int length) throws IOException {
                check(); int count = in.read(bytes, offset, length); check(); return count;
            }
        };
    }
}
