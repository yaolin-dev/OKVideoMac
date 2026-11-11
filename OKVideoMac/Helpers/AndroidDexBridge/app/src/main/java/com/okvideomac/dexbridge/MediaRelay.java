package com.okvideomac.dexbridge;

import java.io.BufferedOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Streams one response without holding ready bytes behind the next read. */
final class MediaRelay {
    interface Observer {
        void firstByte(long elapsedNanos);
        void finished(long bytes, long elapsedNanos, long readNanos, long maxReadNanos, String termination);
    }
    static final Observer QUIET = new Observer() {
        public void firstByte(long elapsedNanos) { }
        public void finished(long bytes, long elapsedNanos, long readNanos, long maxReadNanos, String termination) { }
    };
    static final class Failure extends IOException {
        final long bytesWritten;
        final String category;
        Failure(IOException cause, long bytes, String category) {
            super("Media response ended after headers were committed", cause);
            this.bytesWritten = bytes;
            this.category = category;
        }
    }

    static void write(BufferedOutputStream output, byte[] headers, InputStream body,
                      long expectedBytes, boolean headersOnly, Observer observer) throws IOException {
        long started = System.nanoTime(), bytes = 0, reads = 0, maxRead = 0;
        String termination = "complete";
        // Own the body before writing headers: an abandoned request must close
        // its upstream even when the very first downstream write fails.
        try (InputStream stream = body) {
            output.write(headers);
            output.flush();
            if (!headersOnly) {
                byte[] buffer = new byte[64 * 1024];
                while (expectedBytes < 0 || bytes < expectedBytes) {
                    int count;
                    long readStarted = System.nanoTime();
                    try {
                        int limit = expectedBytes < 0 ? buffer.length : (int) Math.min(buffer.length, expectedBytes - bytes);
                        count = stream.read(buffer, 0, limit);
                        if (count == -1 && expectedBytes >= 0) throw new EOFException("Incomplete media range");
                    } catch (IOException error) {
                        throw new Failure(error, bytes, error instanceof ProviderMediaEpoch.Changed
                                ? "session_changed" : "truncated_upstream");
                    } finally {
                        long elapsed = System.nanoTime() - readStarted;
                        reads += elapsed;
                        maxRead = Math.max(maxRead, elapsed);
                    }
                    if (count == -1) break;
                    if (count == 0) continue;
                    output.write(Integer.toHexString(count).getBytes(StandardCharsets.US_ASCII));
                    output.write('\r'); output.write('\n');
                    output.write(buffer, 0, count);
                    output.write('\r'); output.write('\n');
                    // A provider may return a small decrypted block and then
                    // block for seconds. Deliver it and detect a closed player
                    // before requesting the next block from that old stream.
                    output.flush();
                    if (bytes == 0) observer.firstByte(System.nanoTime() - started);
                    bytes += count;
                }
                output.write("0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                output.flush();
            }
        } catch (Failure error) {
            termination = error.category;
            throw error;
        } catch (IOException error) {
            termination = "client_transport_interrupted";
            throw new Failure(error, bytes, termination);
        } finally {
            observer.finished(bytes, System.nanoTime() - started, reads, maxRead, termination);
        }
    }
}
