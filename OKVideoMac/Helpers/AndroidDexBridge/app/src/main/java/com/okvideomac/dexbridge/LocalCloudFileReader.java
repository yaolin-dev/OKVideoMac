package com.okvideomac.dexbridge;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.Proxy;
import java.net.URI;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import okhttp3.Call;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/** The legacy 6677 file server shares mutable download state across requests.
 * Finish each small upstream range before another starts. Downstream readers
 * remain independent; closing one never cancels another reader's HTTP call.
 */
final class LocalCloudFileReader {
    static final int BLOCK_BYTES = 256 * 1024;
    static final int MAX_CACHE_BYTES = 16 * 1024 * 1024;
    private static final ReentrantLock TRANSFERS = new ReentrantLock(true);
    private static final LinkedHashMap<Key, byte[]> CACHE = new LinkedHashMap<>(64, .75f, true);
    private static int cacheBytes;
    private static final Pattern CONTENT_RANGE = Pattern.compile("bytes ([0-9]+)-([0-9]+)/([0-9]+)");
    private static final Pattern REQUEST_RANGE = Pattern.compile("bytes=([0-9]+)-([0-9]*)");
    private static final OkHttpClient CLIENT = new OkHttpClient.Builder()
            .proxy(Proxy.NO_PROXY).followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS).callTimeout(12, TimeUnit.SECONDS).build();

    private final String url;
    private final Map<String, String> headers;
    private final BooleanSupplier current;
    private long total = -1;
    private String mime = "application/octet-stream";
    private String validator;
    private volatile boolean failed;
    private volatile String failureDescription = "Local media context failed";

    static boolean supports(URI uri) {
        String host = uri.getHost(), path = uri.getPath();
        return "http".equalsIgnoreCase(uri.getScheme()) && uri.getPort() == 6677
                && ("127.0.0.1".equals(host) || "localhost".equalsIgnoreCase(host)
                    || "[::1]".equals(host) || "::1".equals(host))
                && uri.getRawUserInfo() == null && path != null && path.startsWith("/proxy/play/");
    }

    LocalCloudFileReader(URI uri, Map<String, String> headers, BooleanSupplier current) {
        this.url = uri.toASCIIString();
        this.headers = new LinkedHashMap<>(headers);
        this.current = current;
    }

    static final class Opened {
        final long start, end, total;
        final String mime;
        final InputStream body;
        Opened(long start, long end, long total, String mime, InputStream body) {
            this.start = start; this.end = end; this.total = total; this.mime = mime; this.body = body;
        }
    }

    static final class Unsatisfiable extends IOException {
        final long total;
        Unsatisfiable(long total) { super("Invalid local media range"); this.total = total; }
    }

    Opened open(String range) throws IOException {
        // A completed first block establishes length and container identity.
        // Never trust the legacy server's conflicting Content-Length header.
        block(0);
        long start = 0, end = total - 1;
        if (range != null && !range.trim().isEmpty()) {
            Matcher match = REQUEST_RANGE.matcher(range.trim());
            if (!match.matches()) throw new Unsatisfiable(total);
            try {
                start = Long.parseLong(match.group(1));
                if (!match.group(2).isEmpty()) end = Math.min(end, Long.parseLong(match.group(2)));
            } catch (NumberFormatException invalid) { throw new Unsatisfiable(total); }
            if (start >= total || end < start) throw new Unsatisfiable(total);
        }
        return new Opened(start, end, total, mime, new Cursor(start, end));
    }

    private void check() throws IOException {
        if (failed) throw new IOException(failureDescription);
        if (!current.getAsBoolean() || Thread.currentThread().isInterrupted())
            throw new IOException("Local media context expired or failed");
    }

    private byte[] block(long start) throws IOException {
        try { TRANSFERS.lockInterruptibly(); }
        catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt(); throw new IOException("Local media read cancelled");
        }
        try {
            check();
            Key key = new Key(this, start);
            byte[] existing = CACHE.get(key);
            if (existing != null) return existing;
            long end = total < 0 ? start + BLOCK_BYTES - 1 : Math.min(total - 1, start + BLOCK_BYTES - 1);
            if (end < start) throw new IOException("Local media offset outside file");
            Request.Builder request = new Request.Builder().url(url);
            for (Map.Entry<String, String> h : headers.entrySet()) {
                if (!h.getKey().equalsIgnoreCase("Range") && !h.getKey().equalsIgnoreCase("Accept-Encoding"))
                    request.header(h.getKey(), h.getValue());
            }
            // Its keep-alive connection can close between two completed
            // ranges. Each bounded transfer must own a fresh connection.
            request.header("Range", "bytes=" + start + "-" + end).header("Accept-Encoding", "identity")
                    .header("Connection", "close");
            Call call = CLIENT.newCall(request.build());
            byte[] bytes;
            long provenTotal;
            String provenMime, provenValidator;
            String stage = "headers";
            int expected = -1, received = 0;
            try (Response response = call.execute()) {
                stage = "identity";
                if (!(response.code() == 206 || (start == 0 && response.code() == 200)) || response.body() == null)
                    throw new IOException("Local media range rejected");
                Matcher match = CONTENT_RANGE.matcher(response.header("Content-Range", ""));
                if (!match.matches()) throw new IOException("Local media range lacks byte identity");
                long returnedStart = Long.parseLong(match.group(1));
                long returnedEnd = Long.parseLong(match.group(2));
                provenTotal = Long.parseLong(match.group(3));
                if (provenTotal <= 0 || returnedStart != start || returnedEnd != Math.min(end, provenTotal - 1)
                        || returnedEnd < start || (total >= 0 && provenTotal != total))
                    throw new IOException("Local media representation changed");
                provenValidator = response.header("ETag");
                if (total >= 0 && validator != null && !validator.equals(provenValidator))
                    throw new IOException("Local media validator changed");
                expected = (int) (returnedEnd - start + 1);
                stage = "body";
                ByteArrayOutputStream buffer = new ByteArrayOutputStream(expected);
                InputStream input = response.body().byteStream();
                byte[] scratch = new byte[16 * 1024];
                while (buffer.size() <= expected) {
                    int count = input.read(scratch, 0, Math.min(scratch.length, expected + 1 - buffer.size()));
                    if (count < 0) break;
                    if (count > 0) buffer.write(scratch, 0, count);
                    received = buffer.size();
                }
                if (buffer.size() != expected) throw new IOException("Incomplete or oversized local media range");
                bytes = buffer.toByteArray();
                provenMime = response.header("Content-Type", "application/octet-stream");
                if (provenMime.indexOf('\r') >= 0 || provenMime.indexOf('\n') >= 0) provenMime = "application/octet-stream";
            } catch (Exception error) {
                failureDescription = "Local media bounded read failed: offset=" + start + " stage=" + stage
                        + " received=" + received + " expected=" + expected + " type=" + error.getClass().getSimpleName();
                failed = true;
                // Do not retain URL-bearing OkHttp exceptions in logcat.
                throw new IOException(failureDescription);
            }
            check();
            total = provenTotal; mime = provenMime; validator = provenValidator;
            CACHE.put(key, bytes); cacheBytes += bytes.length;
            Iterator<Map.Entry<Key, byte[]>> oldest = CACHE.entrySet().iterator();
            while (cacheBytes > MAX_CACHE_BYTES && oldest.hasNext()) {
                cacheBytes -= oldest.next().getValue().length; oldest.remove();
            }
            return bytes;
        } finally { TRANSFERS.unlock(); }
    }

    private final class Cursor extends InputStream {
        private long position;
        private final long end;
        private volatile boolean closed;
        Cursor(long start, long end) { position = start; this.end = end; }
        @Override public int read() throws IOException {
            byte[] one = new byte[1]; return read(one, 0, 1) < 0 ? -1 : one[0] & 255;
        }
        @Override public int read(byte[] target, int offset, int length) throws IOException {
            if (offset < 0 || length < 0 || offset > target.length - length) throw new IndexOutOfBoundsException();
            if (closed) throw new IOException("Local media reader closed");
            check();
            if (length == 0) return 0;
            if (position > end) return -1;
            long aligned = position / BLOCK_BYTES * BLOCK_BYTES;
            byte[] bytes = block(aligned);
            if (closed) throw new IOException("Local media reader closed");
            check();
            int within = (int) (position - aligned);
            int count = (int) Math.min(Math.min(length, bytes.length - within), end - position + 1);
            if (count <= 0) throw new IOException("Local media block lacks requested bytes");
            System.arraycopy(bytes, within, target, offset, count); position += count; return count;
        }
        @Override public void close() { closed = true; }
    }

    private static final class Key {
        final LocalCloudFileReader reader;
        final long start;
        Key(LocalCloudFileReader reader, long start) { this.reader = reader; this.start = start; }
        @Override public int hashCode() { return 31 * System.identityHashCode(reader) + Long.hashCode(start); }
        @Override public boolean equals(Object other) {
            return other instanceof Key && ((Key) other).reader == reader && ((Key) other).start == start;
        }
    }
}
