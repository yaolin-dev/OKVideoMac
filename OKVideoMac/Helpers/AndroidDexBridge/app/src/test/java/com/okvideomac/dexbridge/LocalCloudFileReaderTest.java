package com.okvideomac.dexbridge;

import org.junit.Test;
import static org.junit.Assert.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class LocalCloudFileReaderTest {
    @Test public void readsAndCachesAlternatingVideoAudioAndIndexRanges() throws Exception {
        try (Backend backend = new Backend(4 * LocalCloudFileReader.BLOCK_BYTES + 31)) {
            LocalCloudFileReader reader = backend.reader(new AtomicBoolean(true));
            for (int offset : new int[]{0, 3 * LocalCloudFileReader.BLOCK_BYTES + 9, 48,
                    3 * LocalCloudFileReader.BLOCK_BYTES + 77, LocalCloudFileReader.BLOCK_BYTES - 3}) {
                assertArrayEquals(backend.slice(offset, 400), read(reader.open("bytes=" + offset + "-" + (offset + 399)).body));
            }
            assertEquals(3, backend.requests.get());
            assertEquals(backend.requests.get(), backend.closeRequests.get());
            assertEquals(1, backend.peak.get());
        }
    }

    @Test public void closingOldCursorCannotCancelNewConcurrentRange() throws Exception {
        try (Backend backend = new Backend(4 * LocalCloudFileReader.BLOCK_BYTES)) {
            LocalCloudFileReader reader = backend.reader(new AtomicBoolean(true));
            InputStream old = reader.open("bytes=0-").body;
            assertEquals(backend.bytes[0] & 255, old.read());
            ExecutorService threads = Executors.newFixedThreadPool(2);
            try {
                CountDownLatch start = new CountDownLatch(1);
                Future<byte[]> a = threads.submit(() -> { start.await(); return read(reader.open("bytes=262144-263167").body); });
                Future<byte[]> b = threads.submit(() -> { start.await(); return read(reader.open("bytes=786432-787455").body); });
                start.countDown(); old.close();
                assertArrayEquals(backend.slice(262144, 1024), a.get(5, TimeUnit.SECONDS));
                assertArrayEquals(backend.slice(786432, 1024), b.get(5, TimeUnit.SECONDS));
                assertEquals(1, backend.peak.get());
            } finally { threads.shutdownNow(); }
        }
    }

    @Test public void rejectsTruncationExtraBytesOffsetsAndRepresentationChanges() throws Exception {
        for (String fault : new String[]{"short", "extra", "offset", "total", "etag"}) {
            try (Backend backend = new Backend(3 * LocalCloudFileReader.BLOCK_BYTES)) {
                LocalCloudFileReader reader = backend.reader(new AtomicBoolean(true));
                read(reader.open("bytes=0-10").body); backend.fault = fault;
                try { read(reader.open("bytes=262144-262154").body); fail(fault); }
                catch (IOException expected) { }
                int calls = backend.requests.get();
                try { reader.open("bytes=0-1"); fail("Failed context reused cached bytes"); }
                catch (IOException expected) { }
                assertEquals(calls, backend.requests.get());
            }
        }
    }

    @Test public void rejectsRetiredOwnerBeforeServingCachedBytes() throws Exception {
        try (Backend backend = new Backend(LocalCloudFileReader.BLOCK_BYTES + 9)) {
            AtomicBoolean owner = new AtomicBoolean(true);
            LocalCloudFileReader reader = backend.reader(owner);
            InputStream body = reader.open("bytes=0-100").body;
            assertEquals(backend.bytes[0] & 255, body.read()); owner.set(false);
            try { body.read(); fail("Old owner served bytes"); } catch (IOException expected) { }
            try { reader.open("bytes=0-1"); fail("Old capability reused"); } catch (IOException expected) { }
            assertEquals(1, backend.requests.get());
        }
    }

    @Test public void clipsFinalRangeAndRejectsInvalidOrMultiRanges() throws Exception {
        try (Backend backend = new Backend(LocalCloudFileReader.BLOCK_BYTES + 31)) {
            LocalCloudFileReader reader = backend.reader(new AtomicBoolean(true));
            LocalCloudFileReader.Opened tail = reader.open("bytes=262144-999999");
            assertEquals(backend.bytes.length, tail.total); assertEquals(backend.bytes.length - 1, tail.end);
            assertArrayEquals(backend.slice(262144, 31), read(tail.body));
            for (String range : new String[]{"bytes=-20", "bytes=4-2", "bytes=999999-", "bytes=0-1,4-5", "bytes=999999999999999999999999-"}) {
                try { reader.open(range); fail(range); } catch (LocalCloudFileReader.Unsatisfiable expected) { }
            }
        }
    }

    @Test public void transportIsLimitedToLegacyLoopbackFileEndpoint() {
        assertTrue(LocalCloudFileReader.supports(URI.create("http://127.0.0.1:6677/proxy/play/%E5%8E%9F%20%E7%89%87.mp4")));
        for (String url : new String[]{"https://example.org:6677/proxy/play/file", "http://127.0.0.1:9978/proxy/play/file",
                "http://127.0.0.1:6677/proxy/playlist", "http://user@127.0.0.1:6677/proxy/play/file"})
            assertFalse(LocalCloudFileReader.supports(URI.create(url)));
    }

    static byte[] read(InputStream input) throws Exception {
        try (InputStream body = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int n;
            while ((n = body.read(buffer)) != -1) out.write(buffer, 0, n);
            return out.toByteArray();
        }
    }

    static final class Backend implements AutoCloseable {
        final byte[] bytes;
        final ServerSocket server = new ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"));
        final ExecutorService clients = Executors.newCachedThreadPool();
        final AtomicInteger requests = new AtomicInteger(), active = new AtomicInteger(), peak = new AtomicInteger();
        final AtomicInteger closeRequests = new AtomicInteger();
        volatile String fault = "";
        Backend(int length) throws IOException {
            bytes = new byte[length]; for (int i = 0; i < length; i++) bytes[i] = (byte)(i * 31 + i / 113);
            Thread accept = new Thread(() -> {
                while (!server.isClosed()) try { Socket socket = server.accept(); clients.submit(() -> serve(socket)); }
                catch (IOException ignored) { }
            }); accept.setDaemon(true); accept.start();
        }
        LocalCloudFileReader reader(AtomicBoolean owner) {
            return new LocalCloudFileReader(URI.create("http://127.0.0.1:" + server.getLocalPort() + "/proxy/play/file"), Collections.emptyMap(), owner::get);
        }
        byte[] slice(int offset, int count) { return Arrays.copyOfRange(bytes, offset, offset + count); }
        void serve(Socket connection) {
            int count = active.incrementAndGet(); peak.accumulateAndGet(count, Math::max);
            requests.incrementAndGet();
            boolean finished = false;
            try (Socket socket = connection) {
                BufferedReader input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
                String line, range = "";
                while ((line = input.readLine()) != null && !line.isEmpty()) {
                    if (line.toLowerCase(Locale.ROOT).startsWith("range:")) range = line.substring(6).trim();
                    if (line.equalsIgnoreCase("Connection: close")) closeRequests.incrementAndGet();
                }
                String[] parts = range.substring(6).split("-", -1); int start = Integer.parseInt(parts[0]), end = Math.min(bytes.length - 1, Integer.parseInt(parts[1]));
                int length = end - start + 1, bodyLength = length;
                if (fault.equals("short")) bodyLength /= 2;
                if (fault.equals("extra")) bodyLength++;
                String response = "HTTP/1.1 " + (start == 0 ? "200 OK" : "206 Partial Content") + "\r\nContent-Type: application/oct-stream\r\n"
                        + "Content-Range: bytes " + (start + (fault.equals("offset") ? 1 : 0)) + "-" + end + "/" + (bytes.length + (fault.equals("total") ? 1 : 0))
                        + "\r\nContent-Length: " + (bytes.length - start) + "\r\nETag: " + (fault.equals("etag") ? "changed" : "original")
                        + "\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
                OutputStream out = socket.getOutputStream(); out.write(response.getBytes(StandardCharsets.US_ASCII));
                out.write((Integer.toHexString(bodyLength) + "\r\n").getBytes(StandardCharsets.US_ASCII));
                out.write(bytes, start, Math.min(bodyLength, length)); if (bodyLength > length) out.write(0);
                active.decrementAndGet(); finished = true;
                out.write("\r\n0\r\n\r\n".getBytes(StandardCharsets.US_ASCII)); out.flush();
            } catch (Exception ignored) { }
            finally { if (!finished) active.decrementAndGet(); }
        }
        @Override public void close() throws IOException { server.close(); clients.shutdownNow(); }
    }
}
