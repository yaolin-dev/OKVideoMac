package com.okvideomac.dexbridge;

import java.io.IOException;
import java.io.InputStream;
import java.net.Socket;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;

/** One downstream connection owns one current HTTP call, including redirects.
 * Opt-in clients promise not to half-close while still consuming the response.
 * No session-wide cancellation: sibling video/audio/index requests stay alive.
 */
final class MediaRequestLifetime implements AutoCloseable {
    static final int MAX_WATCHERS = 16;
    private static final ThreadPoolExecutor WATCHERS = new ThreadPoolExecutor(
            0, MAX_WATCHERS, 30, TimeUnit.SECONDS, new SynchronousQueue<>(), task -> {
                Thread thread = new Thread(task, "media-disconnect");
                thread.setDaemon(true);
                return thread;
            });
    private final Socket client;
    private boolean finished;
    private boolean disconnected;
    private boolean monitoring;
    private Runnable cancel;

    MediaRequestLifetime(Socket client, InputStream input, boolean enabled) throws IOException {
        this.client = client;
        if (!enabled) return;
        // Blocking EOF detection has no periodic idle wakeups. The owning
        // request closes/shuts down this input when its response finishes.
        client.setSoTimeout(0);
        try {
            WATCHERS.execute(() -> {
                try {
                    if (input.read() == -1) disconnect();
                    // Unexpected extra request bytes: abandon monitoring.
                    // This server closes every media connection after response.
                } catch (IOException error) { disconnect(); }
            });
            monitoring = true;
        } catch (RejectedExecutionException ignored) {
            // Bounded fallback: ordinary relay write/close error handling.
        }
    }

    void attach(Runnable action) {
        boolean abort;
        synchronized (this) {
            abort = disconnected || finished;
            if (!abort) cancel = action;
        }
        if (abort) action.run();
    }

    synchronized void checkConnected() throws IOException {
        if (disconnected || finished) throw new IOException("Media client disconnected");
    }

    private void disconnect() {
        Runnable action;
        synchronized (this) {
            if (finished || disconnected) return;
            disconnected = true;
            action = cancel;
            cancel = null;
        }
        // OkHttp Call.cancel interrupts both connect and blocked body reads.
        if (action != null) action.run();
    }

    @Override public void close() {
        synchronized (this) { finished = true; cancel = null; }
        if (monitoring) {
            try { client.shutdownInput(); } catch (IOException ignored) { }
        }
    }
}
