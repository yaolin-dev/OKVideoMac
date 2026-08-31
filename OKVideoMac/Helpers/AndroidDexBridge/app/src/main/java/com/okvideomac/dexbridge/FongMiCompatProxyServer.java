package com.okvideomac.dexbridge;

import android.content.Context;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Android-only implementation of FongMi's CatVod {@code /proxy} contract.
 *
 * <p>The Mac RPC listener deliberately stays on 9978 and never exposes this
 * listener through adb. CatVod's process-global Proxy URL points at one of
 * 9979...9998 instead. A request is accepted only while the serialized
 * {@code playerContent} invocation that owns it holds an exact provider
 * lease. Once the result has been converted into a scoped media session, the
 * secure 9978 route calls that same owner directly.</p>
 */
final class FongMiCompatProxyServer {
    static final int FIRST_PORT = 9979;
    static final int LAST_PORT = 9998;
    private static final int MAX_BODY_BYTES = 8 * 1024 * 1024;
    private static final String TAG = "OKVideoFongMiProxy";
    private static final Object LIFECYCLE_LOCK = new Object();
    private static final ExecutorService CONNECTIONS =
            Executors.newFixedThreadPool(8);

    private static volatile Context applicationContext;
    private static volatile ServerSocket listener;
    private static volatile int port;
    private static volatile long generation;
    private static volatile Lease activeLease;

    private FongMiCompatProxyServer() {
    }

    /** Ensures the listener is bound before publishing its port to CatVod. */
    static int ensureStarted(Context context) throws IOException {
        synchronized (LIFECYCLE_LOCK) {
            applicationContext = context.getApplicationContext();
            if (readyLocked()) {
                com.github.catvod.Proxy.set(port);
                return port;
            }
            closeQuietly(listener);
            listener = null;
            port = 0;
            IOException lastError = null;
            for (int candidate = FIRST_PORT; candidate <= LAST_PORT; candidate++) {
                ServerSocket server = new ServerSocket();
                try {
                    server.setReuseAddress(true);
                    server.bind(
                            new InetSocketAddress(
                                    InetAddress.getByName("127.0.0.1"),
                                    candidate
                            ),
                            64
                    );
                    listener = server;
                    port = candidate;
                    long servingGeneration = ++generation;
                    Thread thread = new Thread(
                            () -> serve(server, servingGeneration),
                            "okvideo-fongmi-proxy-" + candidate
                    );
                    thread.setDaemon(false);
                    thread.start();
                    // Proxy.set is process-global. Publish it only after bind
                    // succeeds so a Spider can never observe a dead port.
                    com.github.catvod.Proxy.set(candidate);
                    Log.i(TAG, "Listening on 127.0.0.1:" + candidate);
                    return candidate;
                } catch (IOException error) {
                    lastError = error;
                    closeQuietly(server);
                }
            }
            throw new IOException(
                    "TVBox local proxy port is unavailable",
                    lastError
            );
        }
    }

    static Lease acquire(
            Context context,
            BridgeProviderOwnerRegistry.Binding owner
    ) throws IOException {
        if (owner == null) {
            throw new IOException("TVBox local proxy has no provider owner");
        }
        synchronized (LIFECYCLE_LOCK) {
            ensureStarted(context);
            if (activeLease != null) {
                throw new IOException("TVBox local proxy is already leased");
            }
            Lease lease = new Lease(
                    UUID.randomUUID().toString(),
                    owner,
                    generation
            );
            activeLease = lease;
            return lease;
        }
    }

    static void restart(Context context) throws IOException {
        synchronized (LIFECYCLE_LOCK) {
            activeLease = null;
            generation++;
            closeQuietly(listener);
            listener = null;
            port = 0;
            ensureStarted(context);
        }
    }

    static boolean ready() {
        synchronized (LIFECYCLE_LOCK) {
            return readyLocked();
        }
    }

    static int port() {
        return port;
    }

    static boolean owns(URI uri) {
        if (uri == null || !ready()) return false;
        String host = uri.getHost();
        String path = uri.getPath() == null ? "" : uri.getPath();
        return isLoopback(host)
                && uri.getPort() == port
                && ("/proxy".equals(path) || path.startsWith("/proxy/"));
    }

    static void stopForTests() {
        synchronized (LIFECYCLE_LOCK) {
            activeLease = null;
            generation++;
            closeQuietly(listener);
            listener = null;
            port = 0;
        }
    }

    private static boolean readyLocked() {
        return listener != null && !listener.isClosed() && port > 0;
    }

    private static void serve(ServerSocket server, long servingGeneration) {
        try {
            while (!server.isClosed()) {
                Socket socket = server.accept();
                synchronized (LIFECYCLE_LOCK) {
                    if (servingGeneration != generation || listener != server) {
                        closeQuietly(socket);
                        break;
                    }
                }
                Lease acceptedLease = activeLease;
                CONNECTIONS.execute(() -> handle(socket, acceptedLease));
            }
        } catch (Throwable error) {
            synchronized (LIFECYCLE_LOCK) {
                if (servingGeneration == generation && listener == server) {
                    Log.e(TAG, "Compatibility proxy stopped", error);
                }
            }
        } finally {
            closeQuietly(server);
            synchronized (LIFECYCLE_LOCK) {
                if (servingGeneration == generation && listener == server) {
                    listener = null;
                    port = 0;
                }
            }
        }
    }

    private static void handle(Socket socket, Lease lease) {
        boolean providerDispatched = false;
        try (Socket client = socket;
             BufferedInputStream input = new BufferedInputStream(
                     client.getInputStream()
             );
             BufferedOutputStream output = new BufferedOutputStream(
                     client.getOutputStream()
             )) {
            client.setSoTimeout(15_000);
            String requestLine = BridgeServer.readLine(input);
            String[] request = requestLine.split(" ", 3);
            if (request.length < 2) {
                BridgeServer.writeJSON(
                        output,
                        400,
                        BridgeServer.failure("Malformed proxy request")
                );
                return;
            }
            String method = request[0].toUpperCase(Locale.ROOT);
            String target = request[1];
            String path = BridgeServer.requestPath(target);
            Map<String, String> headers = BridgeServer.readHeaders(input);
            if (!("/proxy".equals(path) || path.startsWith("/proxy/"))) {
                BridgeServer.writeJSON(
                        output,
                        404,
                        BridgeServer.failure("Not found")
                );
                return;
            }
            if (!"GET".equals(method)
                    && !"HEAD".equals(method)
                    && !"POST".equals(method)) {
                BridgeServer.writeJSON(
                        output,
                        405,
                        BridgeServer.failure("Unsupported proxy method")
                );
                return;
            }
            if (lease == null || !lease.current()) {
                BridgeServer.writeJSON(
                        output,
                        410,
                        BridgeServer.failure("TVBox local proxy is not ready")
                );
                return;
            }

            Map<String, String> params = new LinkedHashMap<>(
                    BridgeServer.parseQuery(target)
            );
            if ("POST".equals(method)) {
                collectPostParameters(input, headers, params);
            }
            // This matches FongMi's merge order: request headers are added to
            // the same parameter map after query/form data.
            params.putAll(headers);
            lease.recordRequest();
            Object[] response = DexSpiderRegistry.get(applicationContext)
                    .proxy(lease.owner, params);
            providerDispatched = true;
            if (!validProxyResponse(response)) {
                lease.recordFailure(Failure.SPIDER_INTERNAL);
                BridgeServer.writeJSON(
                        output,
                        502,
                        BridgeServer.failure("Spider internal proxy failed")
                );
                return;
            }
            BridgeServer.writeProxy(output, response, "HEAD".equals(method));
        } catch (Throwable error) {
            if (lease != null && !providerDispatched) {
                lease.recordFailure(
                        ready() ? Failure.SPIDER_INTERNAL : Failure.NOT_READY
                );
            }
            Log.w(TAG, "Compatibility proxy request failed", error);
        }
    }

    private static void collectPostParameters(
            BufferedInputStream input,
            Map<String, String> headers,
            Map<String, String> params
    ) throws IOException {
        int length = BridgeServer.parseLength(headers.get("content-length"));
        if (length < 0 || length > MAX_BODY_BYTES) {
            throw new IOException("Invalid proxy request body size");
        }
        if (length == 0) return;
        byte[] body = BridgeServer.readExactly(input, length);
        String text = new String(body, StandardCharsets.UTF_8);
        String contentType = headers.get("content-type");
        if (contentType != null && contentType.toLowerCase(Locale.ROOT)
                .startsWith("application/x-www-form-urlencoded")) {
            params.putAll(BridgeServer.parseQuery("/?" + text));
        } else {
            // NanoHTTPD exposes an unstructured POST body through the files
            // map under postData. Several CatVod cloud proxies depend on it.
            params.put("postData", text);
        }
    }

    private static boolean validProxyResponse(Object[] response) {
        return response != null
                && response.length >= 3
                && response[0] instanceof Integer
                && (Integer) response[0] >= 100
                && (Integer) response[0] <= 599
                && response[1] instanceof String
                && response[2] instanceof java.io.InputStream;
    }

    private static boolean isLoopback(String host) {
        if (host == null) return false;
        String normalized = host.toLowerCase(Locale.ROOT);
        return "localhost".equals(normalized)
                || "127.0.0.1".equals(normalized)
                || "::1".equals(normalized);
    }

    private static void closeQuietly(ServerSocket socket) {
        if (socket == null) return;
        try {
            socket.close();
        } catch (Throwable ignored) {
        }
    }

    private static void closeQuietly(Socket socket) {
        if (socket == null) return;
        try {
            socket.close();
        } catch (Throwable ignored) {
        }
    }

    enum Failure {
        NONE,
        NOT_READY,
        SPIDER_INTERNAL
    }

    static final class Lease implements AutoCloseable {
        final String id;
        final BridgeProviderOwnerRegistry.Binding owner;
        final long generation;
        private volatile Failure failure = Failure.NONE;
        private volatile int requestCount;

        Lease(
                String id,
                BridgeProviderOwnerRegistry.Binding owner,
                long generation
        ) {
            this.id = id;
            this.owner = owner;
            this.generation = generation;
        }

        boolean current() {
            return activeLease == this
                    && generation == FongMiCompatProxyServer.generation;
        }

        void recordRequest() {
            requestCount++;
        }

        void recordFailure(Failure value) {
            if (failure == Failure.NONE) failure = value;
        }

        Failure failure() {
            if (!ready()) return Failure.NOT_READY;
            return failure;
        }

        int requestCount() {
            return requestCount;
        }

        @Override
        public void close() {
            synchronized (LIFECYCLE_LOCK) {
                if (activeLease == this) activeLease = null;
            }
        }
    }
}
