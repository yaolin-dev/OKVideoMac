package com.okvideomac.dexbridge;

import java.io.*;

/** One static DASH representation. Resume only bytes not yet handed to the relay.
 * No whole-file buffering, no retry on downstream cancellation, and no joining
 * representations whose identity/range cannot be established. */
final class DashResumingInputStream extends InputStream {
    interface Opener { Segment open(long offset, long end, int attempt) throws IOException; }
    interface Guard { void check() throws IOException; }
    interface Observer { void retry(int attempt, long offset, String cause); }
    static final class Segment implements Closeable {
        final long start, end, total;
        final String entity, url;
        final InputStream body;
        final Closeable owner;
        Segment(long start, long end, long total, String entity, String url, InputStream body, Closeable owner) {
            this.start=start; this.end=end; this.total=total; this.entity=entity;
            this.url=url; this.body=body; this.owner=owner;
        }
        public void close() throws IOException { try { body.close(); } finally { owner.close(); } }
    }
    static final class InvalidRange extends IOException {
        InvalidRange() { super("DASH representation or byte range changed"); }
    }
    private final Opener opener;
    private final Guard guard;
    private final Observer observer;
    private final Segment original;
    private Segment segment;
    private long offset, recoveryStarted;
    private int attempts;
    private boolean closed;
    DashResumingInputStream(Segment first, Opener opener, Guard guard, Observer observer) throws IOException {
        if (first.start < 0 || first.end < first.start || first.total <= first.end) throw new InvalidRange();
        original=first; segment=first; offset=first.start;
        this.opener=opener; this.guard=guard; this.observer=observer;
    }
    private void validate(Segment next) throws IOException {
        boolean sameURL = original.url.equals(next.url);
        boolean sameEntity = original.entity != null && original.entity.equals(next.entity);
        if (next.start != offset || next.end != original.end || next.total != original.total
                || (!sameURL && !sameEntity)
                || (original.entity != null && !sameEntity)) throw new InvalidRange();
    }
    @Override public int read() throws IOException {
        byte[] one=new byte[1]; int count=read(one,0,1); return count < 0 ? -1 : one[0]&255;
    }
    @Override public int read(byte[] bytes, int start, int length) throws IOException {
        if (start < 0 || length < 0 || start > bytes.length-length) throw new IndexOutOfBoundsException();
        if (closed) throw new IOException("DASH consumer closed");
        if (length==0) return 0;
        guard.check();
        if (offset > original.end) return -1;
        while (true) {
            try {
                if (segment==null) throw new EOFException("DASH retry pending");
                int count=segment.body.read(bytes,start,(int)Math.min(length,original.end-offset+1));
                guard.check();
                if (count < 0) throw new EOFException("Incomplete DASH range");
                if (count==0) throw new IOException("DASH read made no progress");
                offset+=count; recoveryStarted=0;
                return count;
            } catch (IOException failure) {
                guard.check(); // A replaced provider/closed player is not a network retry.
                if (failure instanceof InvalidRange) throw failure;
                closeSegment();
                if (recoveryStarted==0) recoveryStarted=System.nanoTime();
                if (attempts >= 3 || System.nanoTime()-recoveryStarted > 45_000_000_000L) throw failure;
                observer.retry(++attempts,offset,cause(failure));
                try {
                    Segment next=opener.open(offset,original.end,attempts);
                    try { guard.check(); validate(next); }
                    catch (IOException invalid) { next.close(); throw invalid; }
                    segment=next;
                } catch (InvalidRange invalid) { throw invalid; }
                catch (IOException unavailable) {
                    guard.check();
                    // The next iteration consumes the same bounded retry budget.
                    if (attempts >= 3) throw unavailable;
                }
            }
        }
    }
    static String cause(Throwable failure) {
        if (failure instanceof ProviderMediaEpoch.Changed) return "session_changed";
        if (failure instanceof java.net.SocketTimeoutException) return "read_timeout";
        if (failure instanceof EOFException) return "short_read";
        if (failure instanceof InvalidRange) return "representation_changed";
        if (failure instanceof java.net.ProtocolException) return "protocol_error";
        if (failure instanceof javax.net.ssl.SSLException) return "tls_error";
        if (failure instanceof java.net.SocketException) return "socket_error";
        return "io_error";
    }
    private void closeSegment() throws IOException {
        Segment old=segment; segment=null; if(old!=null) old.close();
    }
    @Override public void close() throws IOException { closed=true; closeSegment(); }
}
