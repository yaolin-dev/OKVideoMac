package com.okvideomac.dexbridge;

import java.io.IOException;
import java.io.InputStream;
import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import okhttp3.Call;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/** A provider may expose a prefix-stripped representation but return physical
 * Content-Range coordinates. Never assume a prefix size or identify a provider
 * by title/host. A session-local overlap read must prove the virtual coordinates.
 * No decoded bytes, URL or headers are retained in this contract. */
final class VirtualMediaRange {
    private static final Pattern RANGE = Pattern.compile("bytes ([0-9]+)-([0-9]+)/([0-9]+)");
    private static final Pattern REQUEST = Pattern.compile("bytes=([0-9]+)-([0-9]*)");
    private static final OkHttpClient PROBE = new OkHttpClient.Builder()
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .callTimeout(4, TimeUnit.SECONDS).build();
    final long length;
    final long prefix;

    private VirtualMediaRange(long length, long prefix) {
        this.length = length; this.prefix = prefix;
    }

    static long[] contentRange(String value) {
        if (value == null || value.length() > 96) return null;
        Matcher match = RANGE.matcher(value);
        if (!match.matches()) return null;
        try {
            long start = Long.parseLong(match.group(1)), end = Long.parseLong(match.group(2)), total = Long.parseLong(match.group(3));
            return start <= end && end < total ? new long[] {start, end, total} : null;
        } catch (NumberFormatException error) { return null; }
    }

    static long[] requestedRange(String value) {
        if (value == null || value.length() > 96) return null;
        Matcher match = REQUEST.matcher(value);
        if (!match.matches()) return null;
        try {
            long start = Long.parseLong(match.group(1));
            long end = match.group(2).isEmpty() ? -1 : Long.parseLong(match.group(2));
            return end == -1 || end >= start ? new long[] {start, end} : null;
        } catch (NumberFormatException error) { return null; }
    }

    static boolean candidate(Response response, String requestRange) {
        return "bytes=0-".equals(requestRange) && response.code() == 206
                && "bytes 0".equals(response.header("Content-Range"))
                && response.body() != null
                && response.header("Content-Encoding", "identity").equalsIgnoreCase("identity");
    }

    static VirtualMediaRange prove(long logicalLength, byte[] head, byte[] overlap, String overlapRange) {
        long[] range = contentRange(overlapRange);
        if (range == null || logicalLength <= 8192 || head.length != 8192 || overlap.length != 4096) return null;
        long delta = range[0] - 4096;
        if (delta <= 0 || delta > 4096 || range[1] != range[2] - 1
                || range[2] - delta != logicalLength
                || !Arrays.equals(Arrays.copyOfRange(head, 4096, 8192), overlap)
                || Arrays.equals(Arrays.copyOfRange(head, 0, 4096), overlap)) return null;
        return new VirtualMediaRange(logicalLength, delta);
    }

    /** One attempt per session. Peek does not consume the response used by mpv.
     * Both reads are bounded in bytes and time. Failure retains unknown length. */
    static VirtualMediaRange probe(Response initial, Map<String, String> headers) {
        return probe(initial, headers, MediaRequestNetworkPolicy.direct());
    }

    static VirtualMediaRange probe(Response initial, Map<String, String> headers, MediaRequestNetworkPolicy networkPolicy) {
        try {
            long length = Long.parseLong(initial.header("Content-Length"));
            if (length <= 8192 || initial.body() == null) return null;
            okio.BufferedSource source = initial.body().source();
            long previousTimeout = source.timeout().timeoutNanos();
            byte[] head;
            try {
                source.timeout().timeout(4, TimeUnit.SECONDS);
                head = source.peek().readByteArray(8192);
            } finally { source.timeout().timeout(previousTimeout, TimeUnit.NANOSECONDS); }
            Request.Builder request = new Request.Builder().url(initial.request().url());
            for (Map.Entry<String, String> h : headers.entrySet()) {
                if (!h.getKey().equalsIgnoreCase("Range") && !h.getKey().equalsIgnoreCase("Accept-Encoding"))
                    request.header(h.getKey(), h.getValue());
            }
            request.header("Range", "bytes=4096-").header("Accept-Encoding", "identity");
            Call call = networkPolicy.client(PROBE).newCall(request.build());
            try (Response response = call.execute()) {
                if (response.code() != 206 || response.body() == null
                        || !response.header("Content-Encoding", "identity").equalsIgnoreCase("identity")) return null;
                byte[] overlap = new byte[4096];
                InputStream input = response.body().byteStream();
                int offset = 0;
                while (offset < overlap.length) {
                    int n = input.read(overlap, offset, overlap.length - offset);
                    if (n < 0) return null;
                    offset += n;
                }
                return prove(length, head, overlap, response.header("Content-Range"));
            } finally { call.cancel(); }
        } catch (Exception error) { return null; }
    }

    String upstreamRange(String requested) throws IOException {
        long[] range = requestedRange(requested);
        if (range == null || range[0] >= length) throw new IOException("Invalid virtual media range");
        if (range[1] < 0) return requested;
        long end = Math.min(range[1], length - 1);
        try { return "bytes=" + range[0] + "-" + Math.addExact(end, prefix); }
        catch (ArithmeticException error) { throw new IOException("Virtual range overflow"); }
    }

    String downstreamRange(String requested, String returned) throws IOException {
        long[] request = requestedRange(requested);
        if (request == null || request[0] >= length) throw new IOException("Invalid virtual media range");
        if (!(request[0] == 0 && "bytes 0".equals(returned))) {
            long[] physical = contentRange(returned);
            if (physical == null || physical[0] - prefix != request[0]
                    || physical[2] - prefix != length) throw new IOException("Virtual representation changed");
        }
        long end = request[1] < 0 ? length - 1 : Math.min(request[1], length - 1);
        return "bytes " + request[0] + "-" + end + "/" + length;
    }
}
