package com.okvideomac.dexbridge;

import org.junit.Test;
import java.net.*;
import java.io.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.*;
import static org.junit.Assert.*;

public class MediaRequestLifetimeTest {
    static final class Pair implements AutoCloseable {
        final ServerSocket listener = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
        final Socket player = new Socket(InetAddress.getLoopbackAddress(), listener.getLocalPort());
        final Socket bridge = listener.accept();
        Pair() throws IOException { }
        public void close() throws IOException { player.close(); bridge.close(); listener.close(); }
    }
    @Test public void disconnectCancelsBlockedHttpBodyWithoutWaitingForUpstream() throws Exception {
        try (Pair downstream = new Pair(); Pair sibling = new Pair();
             ServerSocket origin = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
             MediaRequestLifetime life = new MediaRequestLifetime(downstream.bridge, downstream.bridge.getInputStream(), true);
             MediaRequestLifetime other = new MediaRequestLifetime(sibling.bridge, sibling.bridge.getInputStream(), true)) {
            CountDownLatch body = new CountDownLatch(1), releaseOrigin = new CountDownLatch(1);
            AtomicInteger siblingCancelled = new AtomicInteger(); other.attach(siblingCancelled::incrementAndGet);
            FutureTask<Void> server = new FutureTask<>(() -> {
                try (Socket peer = origin.accept()) {
                    peer.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\na".getBytes());
                    peer.getOutputStream().flush(); releaseOrigin.await(5, TimeUnit.SECONDS);
                } return null;
            }); new Thread(server).start();
            OkHttpClient client = new OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build();
            Call call = client.newCall(new Request.Builder().url("http://127.0.0.1:" + origin.getLocalPort()).build());
            life.attach(call::cancel);
            FutureTask<Void> reader = new FutureTask<>(() -> {
                try (Response response = call.execute()) {
                    InputStream input = response.body().byteStream(); assertEquals('a', input.read()); body.countDown();
                    try { input.read(); fail("Blocked read must abort"); } catch (IOException expected) { }
                } return null;
            }); new Thread(reader).start();
            try {
                assertTrue(body.await(3, TimeUnit.SECONDS));
                downstream.player.close(); reader.get(2, TimeUnit.SECONDS);
                assertTrue(call.isCanceled()); assertEquals(0, siblingCancelled.get()); other.checkConnected();
            } finally { releaseOrigin.countDown(); server.get(3, TimeUnit.SECONDS); client.connectionPool().evictAll(); client.dispatcher().executorService().shutdownNow(); }
        }
    }
    @Test public void disconnectBeforeAttachAndRedirectReplacementAreSafe() throws Exception {
        try (Pair pair = new Pair(); MediaRequestLifetime life = new MediaRequestLifetime(pair.bridge, pair.bridge.getInputStream(), true)) {
            CountDownLatch cancelled = new CountDownLatch(1); pair.player.close();
            life.attach(cancelled::countDown); assertTrue(cancelled.await(2, TimeUnit.SECONDS));
            AtomicInteger next = new AtomicInteger(); life.attach(next::incrementAndGet); assertEquals(1, next.get());
            try { life.checkConnected(); fail(); } catch (IOException expected) { }
        }
        try (Pair pair = new Pair(); MediaRequestLifetime life = new MediaRequestLifetime(pair.bridge, pair.bridge.getInputStream(), true)) {
            AtomicInteger previous = new AtomicInteger(); CountDownLatch current = new CountDownLatch(1);
            life.attach(previous::incrementAndGet); life.attach(current::countDown); pair.player.close();
            assertTrue(current.await(2, TimeUnit.SECONDS)); assertEquals(0, previous.get());
        }
    }
    @Test public void unoptedHalfCloseAndNormalCompletionDoNotCancel() throws Exception {
        try (Pair pair = new Pair(); MediaRequestLifetime life = new MediaRequestLifetime(pair.bridge, pair.bridge.getInputStream(), false)) {
            AtomicInteger cancelled = new AtomicInteger(); life.attach(cancelled::incrementAndGet);
            pair.player.shutdownOutput(); life.checkConnected();
            pair.bridge.getOutputStream().write(42); assertEquals(42, pair.player.getInputStream().read());
            life.close(); assertEquals(0, cancelled.get());
        }
        try (Pair pair = new Pair(); MediaRequestLifetime life = new MediaRequestLifetime(pair.bridge, pair.bridge.getInputStream(), true)) {
            AtomicInteger cancelled = new AtomicInteger(); life.attach(cancelled::incrementAndGet);
            life.close(); pair.player.close(); assertEquals(0, cancelled.get());
        }
    }
    @Test public void watcherCapacityFallsBackWithoutUnboundedThreads() throws Exception {
        Pair[] pairs = new Pair[MediaRequestLifetime.MAX_WATCHERS + 8];
        MediaRequestLifetime[] lives = new MediaRequestLifetime[pairs.length];
        try {
            for (int i=0; i<pairs.length; i++) { pairs[i] = new Pair(); lives[i] = new MediaRequestLifetime(pairs[i].bridge, pairs[i].bridge.getInputStream(), true); }
            long count = Thread.getAllStackTraces().keySet().stream().filter(t -> t.isAlive() && t.getName().equals("media-disconnect")).count();
            assertTrue(count <= MediaRequestLifetime.MAX_WATCHERS);
            for (MediaRequestLifetime life : lives) life.checkConnected();
        } finally { for (MediaRequestLifetime life : lives) if (life != null) life.close(); for (Pair pair : pairs) if (pair != null) pair.close(); }
    }
}
