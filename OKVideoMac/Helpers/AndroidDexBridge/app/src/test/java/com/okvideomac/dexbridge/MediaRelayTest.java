package com.okvideomac.dexbridge;

import org.junit.Test;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.Assert.*;

public class MediaRelayTest {
    private static final byte[] HEADERS = "HTTP/1.1 206 OK\r\nTransfer-Encoding: chunked\r\n\r\n".getBytes(StandardCharsets.US_ASCII);
    private static void write(OutputStream target, InputStream body, long expected, boolean head) throws IOException {
        MediaRelay.write(new BufferedOutputStream(target), HEADERS, body, expected, head, MediaRelay.QUIET);
    }
    @Test public void headersAndSmallBlockArriveBeforeNextUpstreamRead() throws Exception {
        CountDownLatch headers = new CountDownLatch(1), first = new CountDownLatch(1), release = new CountDownLatch(1);
        ByteArrayOutputStream received = new ByteArrayOutputStream() {
            public synchronized void flush() {
                if (size() >= HEADERS.length) headers.countDown();
                if (toString().contains("\r\n1\r\nA\r\n")) first.countDown();
            }
        };
        InputStream source = new InputStream() {
            int reads;
            public int read() { throw new AssertionError(); }
            public int read(byte[] b, int off, int len) throws IOException {
                try {
                    if (reads++ == 0) {
                        if (!headers.await(1, TimeUnit.SECONDS)) throw new IOException("Headers held behind first read");
                        b[off] = 65; return 1;
                    }
                    if (!release.await(2, TimeUnit.SECONDS)) throw new IOException("Test release missing");
                    return -1;
                } catch (InterruptedException e) { throw new IOException(e); }
            }
        };
        FutureTask<Void> worker = new FutureTask<>(() -> { write(received, source, -1, false); return null; });
        new Thread(worker).start();
        try { assertTrue("First block must not wait for the next read", first.await(1, TimeUnit.SECONDS)); }
        finally { release.countDown(); }
        worker.get(2, TimeUnit.SECONDS);
    }
    @Test public void headerFailureClosesUnreadUpstream() throws Exception {
        AtomicInteger closed = new AtomicInteger(), read = new AtomicInteger();
        InputStream source = new InputStream() {
            public int read() { read.incrementAndGet(); return 1; }
            public void close() { closed.incrementAndGet(); }
        };
        try { write(new OutputStream() { public void write(int b) throws IOException { throw new IOException("Closed client"); } }, source, -1, false); fail(); }
        catch (MediaRelay.Failure expected) { assertEquals("client_transport_interrupted", expected.category); }
        assertEquals(0, read.get()); assertEquals(1, closed.get());
    }
    @Test public void disconnectedClientStopsBeforeNextSmallBlockRead() throws Exception {
        AtomicInteger read = new AtomicInteger(), closed = new AtomicInteger();
        InputStream source = new InputStream() {
            public int read() { throw new AssertionError(); }
            public int read(byte[] b, int off, int len) { read.incrementAndGet(); b[off] = 65; return 1; }
            public void close() { closed.incrementAndGet(); }
        };
        OutputStream client = new OutputStream() {
            int bytes;
            public void write(int b) throws IOException { if (++bytes > HEADERS.length) throw new IOException("Disconnected"); }
        };
        try { write(client, source, -1, false); fail(); } catch (MediaRelay.Failure expected) { }
        assertEquals(1, read.get()); assertEquals(1, closed.get());
    }
    @Test public void rangeBoundaryTruncationHeadAndUnknownLengthKeepFraming() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        write(out, new ByteArrayInputStream(new byte[]{65,66,67}), 2, false);
        assertTrue(out.toString().endsWith("2\r\nAB\r\n0\r\n\r\n"));
        out.reset();
        try { write(out, new ByteArrayInputStream(new byte[]{65}), 2, false); fail(); }
        catch (MediaRelay.Failure expected) { assertEquals("truncated_upstream", expected.category); }
        assertFalse(out.toString().endsWith("0\r\n\r\n"));
        out.reset(); write(out, new ByteArrayInputStream(new byte[]{65}), -1, true);
        assertArrayEquals(HEADERS, out.toByteArray());
        out.reset(); write(out, new ByteArrayInputStream(new byte[]{65}), -1, false);
        assertTrue(out.toString().endsWith("1\r\nA\r\n0\r\n\r\n"));
    }
}
