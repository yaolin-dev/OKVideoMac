package com.okvideomac.dexbridge;

import android.content.Context;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.InetAddress;
import java.net.URI;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

final class BridgeServer {
    static final int PORT = 9978;
    private static final String TAG = "OKVideoDexBridge";
    private static final int MAX_BODY_BYTES = 8 * 1024 * 1024;
    private static final int MAX_CREDENTIAL_BODY_BYTES = 72 * 1024;
    // The Mac client can issue 20 provider calls at once. Keep additional
    // workers available for health, authorization UI, and playback proxy
    // requests so a saturated search cannot make the bridge appear dead.
    private static final int PROVIDER_THREAD_COUNT = 24;
    private static final int MEDIA_THREAD_COUNT = 12;
    // Connection/control work is isolated from provider invocations and
    // long-lived movie streams. A slow stream can no longer consume every
    // health/state/cancel worker.
    private static final ExecutorService CONNECTIONS =
            Executors.newCachedThreadPool();
    private static final ExecutorService PROVIDER_WORKERS =
            Executors.newFixedThreadPool(PROVIDER_THREAD_COUNT);
    private static final ExecutorService MEDIA_WORKERS =
            Executors.newFixedThreadPool(MEDIA_THREAD_COUNT);
    private static final Map<String, Future<?>> INTERACTION_WORKERS =
            new ConcurrentHashMap<>();
    /**
     * Serializes the registry's latest pointer, the UI owner, and the one
     * cancellable provider invocation associated with an interaction.
     *
     * <p>Those three pieces used to be updated independently. A duplicate
     * /invoke could overwrite the tracked Future while both provider calls
     * continued to run, and an A -> B race could install A's worker after B
     * had already released it. Keeping the lifecycle transition and worker
     * claim under one lock makes retry and supersede behavior deterministic.</p>
     */
    private static final Object INTERACTION_LIFECYCLE_LOCK = new Object();
    private static final OkHttpClient MEDIA_CLIENT = new OkHttpClient.Builder()
            .followRedirects(true)
            .followSslRedirects(true)
            .retryOnConnectionFailure(true)
            .connectTimeout(15, TimeUnit.SECONDS)
            // A movie stream can legitimately remain open for hours. Range
            // requests still provide bounded transfers when the player seeks.
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .build();
    // Provider-owned sessions follow redirects explicitly so credential and
    // custom provider headers can be stripped before crossing an origin
    // boundary. OkHttp's automatic redirect handling removes Authorization,
    // but intentionally retains caller-supplied Cookie/custom headers.
    private static final OkHttpClient SESSION_MEDIA_CLIENT =
            new OkHttpClient.Builder()
                    .followRedirects(false)
                    .followSslRedirects(false)
                    .retryOnConnectionFailure(true)
                    .connectTimeout(15, TimeUnit.SECONDS)
                    .readTimeout(0, TimeUnit.MILLISECONDS)
                    .writeTimeout(15, TimeUnit.SECONDS)
                    .build();
    private static final int MAX_MEDIA_REDIRECTS = 10;
    private static final String[] FORWARDED_MEDIA_REQUEST_HEADERS = {
            "range",
            "user-agent",
            "referer",
            "cookie",
            "authorization",
            "origin",
            "accept",
            "accept-language"
    };
    private static final String[] FORWARDED_MEDIA_RESPONSE_HEADERS = {
            "Content-Range",
            "Accept-Ranges",
            "Content-Disposition",
            "Cache-Control",
            "ETag",
            "Last-Modified"
    };
    /**
     * Listener lifecycle is independent from the Activity lifecycle.  In
     * particular, a failed bind must not leave the process permanently
     * looking "started": the Mac retries by delivering a new intent to the
     * already-existing BridgeActivity.
     */
    private static final Object SERVER_LIFECYCLE_LOCK = new Object();
    private static volatile boolean started;
    private static volatile boolean starting;
    private static volatile ServerSocket listener;
    private static long listenerGeneration;
    private static volatile String runtimeGeneration = "";

    private BridgeServer() {
    }

    static void start(Context context) {
        final Context application = context.getApplicationContext();
        final long generation;
        synchronized (SERVER_LIFECYCLE_LOCK) {
            ServerSocket active = listener;
            if (started && active != null && !active.isClosed()) return;
            if (starting) return;
            started = false;
            starting = true;
            generation = ++listenerGeneration;
        }
        com.github.catvod.Proxy.set(PORT);
        Thread thread = new Thread(
                () -> serve(application, generation),
                "okvideo-dex-rpc"
        );
        thread.setDaemon(false);
        thread.start();
    }

    static void setRuntimeGeneration(String generation) {
        runtimeGeneration = generation == null ? "" : generation;
    }

    private static void serve(Context context, long generation) {
        ServerSocket server = null;
        try {
            server = new ServerSocket(
                    PORT,
                    64,
                    InetAddress.getByName("127.0.0.1")
            );
            synchronized (SERVER_LIFECYCLE_LOCK) {
                if (generation != listenerGeneration) {
                    closeQuietly(server);
                    return;
                }
                listener = server;
                started = true;
                starting = false;
                SERVER_LIFECYCLE_LOCK.notifyAll();
            }
            Log.i(TAG, "Listening on 127.0.0.1:" + PORT);
            while (!server.isClosed()) {
                Socket socket = server.accept();
                synchronized (SERVER_LIFECYCLE_LOCK) {
                    if (generation != listenerGeneration) {
                        closeQuietly(socket);
                        break;
                    }
                }
                CONNECTIONS.execute(() -> handle(context, socket));
            }
        } catch (Throwable error) {
            synchronized (SERVER_LIFECYCLE_LOCK) {
                if (generation == listenerGeneration) {
                    Log.e(TAG, "RPC server stopped", error);
                }
            }
        } finally {
            closeQuietly(server);
            synchronized (SERVER_LIFECYCLE_LOCK) {
                if (generation == listenerGeneration) {
                    if (listener == server) listener = null;
                    started = false;
                    starting = false;
                    SERVER_LIFECYCLE_LOCK.notifyAll();
                }
            }
        }
    }

    static boolean listenerReadyForTests() {
        ServerSocket active = listener;
        return started && active != null && !active.isClosed();
    }

    static boolean listenerStartingForTests() {
        return starting;
    }

    static void stopListenerForTests() {
        ServerSocket active;
        synchronized (SERVER_LIFECYCLE_LOCK) {
            listenerGeneration++;
            active = listener;
            listener = null;
            started = false;
            starting = false;
            SERVER_LIFECYCLE_LOCK.notifyAll();
        }
        closeQuietly(active);
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

    private static void handle(Context context, Socket socket) {
        try (Socket client = socket;
             BufferedInputStream input = new BufferedInputStream(client.getInputStream());
             BufferedOutputStream output = new BufferedOutputStream(client.getOutputStream())) {
            client.setSoTimeout(15_000);
            try {
                String requestLine = readLine(input);
                String[] request = requestLine.split(" ", 3);
                if (request.length < 2) {
                    writeJSON(output, 400, failure("Malformed request"));
                    return;
                }
                Map<String, String> headers = readHeaders(input);
                String method = request[0].toUpperCase(Locale.ROOT);
                String target = request[1];
                String path = requestPath(target);
                if ("GET".equals(method) && "/health".equals(path)) {
                    JSONObject health = new JSONObject();
                    health.put("ok", true);
                    health.put(
                            "version",
                            context.getPackageManager()
                                    .getPackageInfo(context.getPackageName(), 0)
                                    .versionName
                    );
                    health.put("generation", runtimeGeneration);
                    health.put("uiSchemaVersion", 2);
                    health.put(
                            "uiCapabilities",
                            new JSONArray()
                                    .put("hierarchy")
                                    .put("geometry")
                                    .put("toggleState")
                                    .put("pickerState")
                                    .put("sliderState")
                                    .put("secureInputRedaction")
                    );
                    writeJSON(output, 200, health);
                    return;
                }
                if (path.startsWith("/proxy/media/")
                        && ("GET".equals(method) || "HEAD".equals(method))) {
                    runMedia(() -> writeSessionMedia(
                                context,
                                output,
                                path.substring("/proxy/media/".length()),
                                headers,
                                "HEAD".equals(method)
                    ));
                    return;
                }
                if (path.startsWith("/v1/media-sessions/")
                        && ("GET".equals(method) || "HEAD".equals(method))) {
                    runMedia(() -> writeSessionMedia(
                                context,
                                output,
                                path.substring("/v1/media-sessions/".length()),
                                headers,
                                "HEAD".equals(method)
                    ));
                    return;
                }
                if (target.startsWith("/v1/media?")
                        && ("GET".equals(method) || "HEAD".equals(method))) {
                    runMedia(() -> writeDirectMedia(
                                output,
                                parseQuery(target).get("url"),
                                headers,
                                "HEAD".equals(method)
                    ));
                    return;
                }
                if ("POST".equals(method) && "/v1/interactions".equals(path)) {
                    JSONObject payload = readJSONPayload(input, headers, MAX_BODY_BYTES);
                    String interactionID = beginAndActivateInteraction(
                            context,
                            payload.optString("interactionID", ""),
                            payload.optString("kind", "configuration"),
                            payload.optString("method", "")
                    );
                    if (!acceptsInvocation(interactionID)) {
                        writeJSON(
                                output,
                                409,
                                staleInteraction(interactionID)
                        );
                        return;
                    }
                    writeJSON(output, 200, BridgeInteractionRegistry.state(interactionID));
                    return;
                }
                String stateInteraction = interactionID(path, "/state");
                if ("GET".equals(method) && stateInteraction != null) {
                    writeJSON(
                            output,
                            200,
                            withProviderOwner(
                                    BridgeActivity.uiState(
                                            context,
                                            stateInteraction
                                    ),
                                    stateInteraction
                            )
                    );
                    return;
                }
                String snapshotInteraction = interactionID(path, "/snapshot");
                if ("GET".equals(method) && snapshotInteraction != null) {
                    if (!acceptsInvocation(snapshotInteraction)) {
                        writeJSON(
                                output,
                                409,
                                staleInteraction(snapshotInteraction)
                        );
                        return;
                    }
                    try {
                        writeBytes(
                                output,
                                200,
                                "image/png",
                                BridgeActivity.snapshotUI(
                                        context,
                                        snapshotInteraction
                                )
                        );
                    } catch (IllegalStateException unavailable) {
                        if (!BridgeInteractionRegistry.ownsLatest(
                                snapshotInteraction
                        ) || BridgeInteractionRegistry.terminal(
                                snapshotInteraction
                        )) {
                            writeJSON(
                                    output,
                                    409,
                                    staleInteraction(snapshotInteraction)
                            );
                            return;
                        }
                        JSONObject pending = BridgeInteractionRegistry.state(
                                snapshotInteraction
                        );
                        pending.put("ok", false);
                        pending.put("error", "Interaction UI is not ready");
                        writeJSON(output, 425, pending);
                    }
                    return;
                }
                String submitInteraction = interactionID(path, "/submit");
                if ("POST".equals(method) && submitInteraction != null) {
                    JSONObject payload = readJSONPayload(input, headers, MAX_BODY_BYTES);
                    if (!acceptsInvocation(submitInteraction)) {
                        writeJSON(
                                output,
                                409,
                                staleInteraction(submitInteraction)
                        );
                        return;
                    }
                    JSONObject submitted = submitUI(
                            context,
                            submitInteraction,
                            payload
                    );
                    writeJSON(
                            output,
                            submitted.optBoolean("stale", false) ? 409 : 200,
                            submitted
                    );
                    return;
                }
                String cancelInteraction = interactionID(path, "/cancel");
                if ("POST".equals(method) && cancelInteraction != null) {
                    BridgeInteractionRegistry.cancel(cancelInteraction);
                    boolean dismissed = releaseTerminalInteraction(
                            context,
                            cancelInteraction
                    );
                    JSONObject state = BridgeInteractionRegistry.state(
                            cancelInteraction
                    );
                    state.put("dismissed", dismissed);
                    writeJSON(
                            output,
                            200,
                            state
                    );
                    return;
                }
                String verifyInteraction = interactionID(path, "/verify");
                if ("POST".equals(method) && verifyInteraction != null) {
                    JSONObject payload = readJSONPayload(
                            input,
                            headers,
                            MAX_BODY_BYTES
                    );
                    String outcome = payload.optString("outcome", "")
                            .trim()
                            .toLowerCase(Locale.ROOT);
                    boolean succeeded = payload.has("succeeded")
                            ? payload.optBoolean("succeeded", false)
                            : "completed".equals(outcome)
                            || "success".equals(outcome)
                            || "succeeded".equals(outcome);
                    Boolean refreshPerformed = payload.has("refreshPerformed")
                            && !payload.isNull("refreshPerformed")
                            ? Boolean.valueOf(
                                    payload.optBoolean("refreshPerformed", false)
                            )
                            : null;
                    JSONObject verified = BridgeInteractionRegistry.verified(
                            verifyInteraction,
                            succeeded,
                            payload.optString("error", ""),
                            refreshPerformed
                    );
                    if (verified.optBoolean("terminal", false)) {
                        releaseTerminalInteraction(context, verifyInteraction);
                    }
                    writeJSON(output, 200, verified);
                    return;
                }
                if ("GET".equals(method) && "/v1/ui/state".equals(path)) {
                    String latest = BridgeInteractionRegistry.latestID();
                    writeJSON(
                            output,
                            200,
                            withProviderOwner(
                                    BridgeActivity.uiState(context, latest),
                                    latest
                            )
                    );
                    return;
                }
                if ("GET".equals(method) && "/v1/ui/snapshot".equals(path)) {
                    writeBytes(
                            output,
                            200,
                            "image/png",
                            BridgeActivity.snapshotUI(
                                    context,
                                    BridgeInteractionRegistry.latestID()
                            )
                    );
                    return;
                }
                if ("POST".equals(method) && "/v1/ui/dismiss".equals(path)) {
                    writeJSON(
                            output,
                            200,
                            BridgeActivity.dismissUI(
                                    context,
                                    BridgeInteractionRegistry.latestID()
                            )
                    );
                    return;
                }
                if (target.startsWith("/proxy")
                        && ("GET".equals(method)
                        || "HEAD".equals(method)
                        || "POST".equals(method))) {
                    Map<String, String> params = parseQuery(target);
                    String mediaSessionID = params.remove("mediaSessionID");
                    BridgeMediaSessionRegistry.Session mediaSession =
                            BridgeMediaSessionRegistry.get(mediaSessionID);
                    if (mediaSession == null) {
                        writeJSON(
                                output,
                                410,
                                failure("Media session expired or missing")
                        );
                        return;
                    }
                    if (mediaSession.owner == null) {
                        writeJSON(
                                output,
                                409,
                                failure("Media session has no provider owner")
                        );
                        return;
                    }
                    params.putAll(headers);
                    Object[] response = runProvider(
                            () -> DexSpiderRegistry.get(context).proxy(
                                    mediaSession.owner,
                                    params
                            )
                    );
                    Log.i(
                            TAG,
                            "Spider proxy request="
                                    + UUID.randomUUID().toString().substring(0, 8)
                                    + " status="
                                    + (response != null && response.length > 0
                                            ? String.valueOf(response[0])
                                            : "missing")
                                    + " range=" + headers.containsKey("range")
                                    + " cookie=" + headers.containsKey("cookie")
                                    + " referer=" + headers.containsKey("referer")
                                    + " authorization="
                                    + headers.containsKey("authorization")
                    );
                    writeProxy(output, response, "HEAD".equals(method));
                    return;
                }
                if ("POST".equals(method) && "/v1/ui/submit".equals(path)) {
                    JSONObject payload = readJSONPayload(input, headers, MAX_BODY_BYTES);
                    String latest = BridgeInteractionRegistry.latestID();
                    if (!acceptsInvocation(latest)) {
                        writeJSON(output, 409, staleInteraction(latest));
                        return;
                    }
                    JSONObject submitted = submitUI(
                            context,
                            latest,
                            payload
                    );
                    writeJSON(
                            output,
                            submitted.optBoolean("stale", false) ? 409 : 200,
                            submitted
                    );
                    return;
                }
                if ("POST".equals(method) && "/v1/auth/push".equals(target)) {
                    String contentType = headers.get("content-type");
                    if (contentType == null
                            || !contentType.toLowerCase(Locale.ROOT)
                            .startsWith("application/json")) {
                        writeJSON(
                                output,
                                415,
                                failure("Content-Type must be application/json")
                        );
                        return;
                    }
                    int length = parseLength(headers.get("content-length"));
                    if (length <= 0 || length > MAX_CREDENTIAL_BODY_BYTES) {
                        writeJSON(output, 413, failure("Invalid request size"));
                        return;
                    }
                    JSONObject payload = new JSONObject(
                            new String(readExactly(input, length), StandardCharsets.UTF_8)
                    );
                    final boolean accepted;
                    try {
                        accepted = DexSpiderRegistry.get(context)
                                .submitCloudCredential(payload);
                    } catch (IllegalArgumentException contractError) {
                        writeJSON(output, 422, failure(contractError.getMessage()));
                        return;
                    } catch (IllegalStateException staleOwner) {
                        writeJSON(output, 409, failure(staleOwner.getMessage()));
                        return;
                    }
                    if (!accepted) {
                        writeJSON(
                                output,
                                502,
                                failure("Cloud credential handler rejected the request")
                        );
                        return;
                    }
                    JSONObject response = new JSONObject();
                    response.put("ok", true);
                    response.put("accepted", true);
                    writeJSON(output, 200, response);
                    return;
                }
                if (!"POST".equals(method) || !"/v1/invoke".equals(target)) {
                    writeJSON(output, 404, failure("Not found"));
                    return;
                }
                int length = parseLength(headers.get("content-length"));
                if (length < 0 || length > MAX_BODY_BYTES) {
                    writeJSON(output, 413, failure("Invalid request size"));
                    return;
                }
                byte[] body = readExactly(input, length);
                JSONObject payload = new JSONObject(new String(body, StandardCharsets.UTF_8));
                String interactionID = payload.optString("interactionID", "").trim();
                boolean interactive = payload.optBoolean(
                        "monitorsAuthorization",
                        false
                ) || !interactionID.isEmpty();
                if (interactive) {
                    interactionID = beginAndActivateInteraction(
                            context,
                            interactionID,
                            payload.optString(
                                    "interactionKind",
                                    payload.optString("actionType", "configuration")
                            ),
                            payload.optString("method", "")
                    );
                    if (!acceptsInvocation(interactionID)) {
                        writeJSON(
                                output,
                                409,
                                staleInteraction(interactionID)
                        );
                        return;
                    }
                    payload.put("interactionID", interactionID);
                }
                Object result;
                Future<Object> invocation = null;
                try {
                    final JSONObject invokePayload = payload;
                    if (interactive) {
                        invocation = claimInteractionWorker(
                                interactionID,
                                () -> DexSpiderRegistry.get(context).invoke(
                                        invokePayload
                                )
                        );
                        if (invocation == null) {
                            writeJSON(
                                    output,
                                    409,
                                    staleInteraction(interactionID)
                            );
                            return;
                        }
                    } else {
                        invocation = PROVIDER_WORKERS.submit(
                                () -> DexSpiderRegistry.get(context).invoke(
                                        invokePayload
                                )
                        );
                    }
                    result = await(invocation);
                    if (interactive) {
                        JSONObject returned =
                                BridgeInteractionRegistry.invocationReturned(
                                interactionID,
                                isTerminalPlaybackResult(payload, result)
                        );
                        if (returned.optBoolean("terminal", false)) {
                            releaseTerminalInteraction(context, interactionID);
                        }
                    }
                } catch (CancellationException error) {
                    if (interactive) {
                        BridgeInteractionRegistry.cancel(interactionID);
                        releaseTerminalInteraction(context, interactionID);
                    }
                    throw error;
                } catch (Throwable error) {
                    if (interactive) {
                        if (!BridgeInteractionRegistry.terminal(interactionID)) {
                            BridgeInteractionRegistry.failed(
                                    interactionID,
                                    safeMessage(error)
                            );
                        }
                        releaseTerminalInteraction(context, interactionID);
                    }
                    throw error;
                }
                JSONObject response = new JSONObject();
                response.put("ok", true);
                response.put("result", result);
                if (interactive) {
                    response.put("interactionID", interactionID);
                    response.put(
                            "interaction",
                            BridgeInteractionRegistry.state(interactionID)
                    );
                }
                writeJSON(output, 200, response);
            } catch (Throwable error) {
                Log.e(TAG, "RPC request failed", error);
                writeJSON(output, 500, failure(safeMessage(error)));
            }
        } catch (Throwable error) {
            Log.e(TAG, "RPC connection failed", error);
        }
    }

    private static JSONObject readJSONPayload(
            BufferedInputStream input,
            Map<String, String> headers,
            int maximum
    ) throws Exception {
        int length = parseLength(headers.get("content-length"));
        if (length < 0 || length > maximum) {
            throw new IOException("Invalid request size");
        }
        if (length == 0) return new JSONObject();
        return new JSONObject(
                new String(readExactly(input, length), StandardCharsets.UTF_8)
        );
    }

    static boolean isTerminalPlaybackResult(
            JSONObject payload,
            Object result
    ) {
        return payload != null
                && "play".equals(payload.optString("method", ""))
                && DexSpiderRegistry.isPlayableResult(result);
    }

    private static boolean acceptsInvocation(String interactionID) {
        return BridgeInteractionRegistry.ownsLatest(interactionID)
                && !BridgeInteractionRegistry.terminal(interactionID);
    }

    private static JSONObject staleInteraction(String interactionID) {
        JSONObject result = BridgeInteractionRegistry.state(interactionID);
        try {
            result.put("ok", false);
            result.put("error", "Interaction is no longer current");
        } catch (Throwable ignored) {
        }
        return result;
    }

    static String beginAndActivateInteraction(
            Context context,
            String requestedInteractionID,
            String kind,
            String method
    ) {
        synchronized (INTERACTION_LIFECYCLE_LOCK) {
            String previous = BridgeInteractionRegistry.latestID();
            String current = BridgeInteractionRegistry.begin(
                    requestedInteractionID,
                    kind,
                    method
            );
            if (!acceptsInvocation(current)) return current;
            if (!previous.equals(current)) {
                if (!previous.isEmpty()) {
                    releaseInteractionResourcesLocked(context, previous);
                }
                BridgeActivity.beginInteraction(current);
            }
            return current;
        }
    }

    /** Claims the one provider invocation for an interaction. */
    @SuppressWarnings("unchecked")
    static Future<Object> claimInteractionWorker(
            String interactionID,
            Callable<Object> operation
    ) {
        String id = interactionID == null ? "" : interactionID.trim();
        if (id.isEmpty() || operation == null) return null;
        synchronized (INTERACTION_LIFECYCLE_LOCK) {
            if (!acceptsInvocation(id)) return null;
            Future<?> existing = INTERACTION_WORKERS.get(id);
            if (existing != null) return (Future<Object>) existing;
            FutureTask<Object> claimed = new FutureTask<>(operation);
            INTERACTION_WORKERS.put(id, claimed);
            PROVIDER_WORKERS.execute(claimed);
            return claimed;
        }
    }

    static void trackInteractionWorker(
            String interactionID,
            Future<?> worker
    ) {
        String id = interactionID == null ? "" : interactionID.trim();
        if (!id.isEmpty() && worker != null) {
            synchronized (INTERACTION_LIFECYCLE_LOCK) {
                INTERACTION_WORKERS.putIfAbsent(id, worker);
            }
        }
    }

    static boolean cancelInteractionWorker(String interactionID) {
        String id = interactionID == null ? "" : interactionID.trim();
        synchronized (INTERACTION_LIFECYCLE_LOCK) {
            return cancelInteractionWorkerLocked(id);
        }
    }

    static boolean hasTrackedInteractionWorker(String interactionID) {
        String id = interactionID == null ? "" : interactionID.trim();
        synchronized (INTERACTION_LIFECYCLE_LOCK) {
            return !id.isEmpty() && INTERACTION_WORKERS.containsKey(id);
        }
    }

    static boolean releaseTerminalInteraction(
            Context context,
            String interactionID
    ) {
        String id = interactionID == null ? "" : interactionID.trim();
        if (id.isEmpty() || !BridgeInteractionRegistry.terminal(id)) {
            return false;
        }
        synchronized (INTERACTION_LIFECYCLE_LOCK) {
            return releaseInteractionResourcesLocked(context, id);
        }
    }

    private static boolean releaseInteractionResourcesLocked(
            Context context,
            String interactionID
    ) {
        String id = interactionID == null ? "" : interactionID.trim();
        if (id.isEmpty()) return false;
        boolean workerReleased = cancelInteractionWorkerLocked(id);
        boolean uiReleased = false;
        try {
            uiReleased = BridgeActivity.releaseTerminalUI(context, id);
        } catch (Throwable error) {
            Log.w(
                    TAG,
                    "Unable to release terminal interaction="
                            + shortHash(id)
                            + " error="
                            + error.getClass().getSimpleName()
            );
        }
        BridgeProviderOwnerRegistry.releaseInteraction(id);
        return workerReleased || uiReleased;
    }

    private static boolean cancelInteractionWorkerLocked(String id) {
        Future<?> worker = INTERACTION_WORKERS.remove(id);
        if (worker == null) return false;
        if (worker.isDone()) return true;
        return worker.cancel(true) || worker.isCancelled();
    }

    private static <T> T runProvider(ThrowingSupplier<T> operation)
            throws Exception {
        return await(PROVIDER_WORKERS.submit(operation::get));
    }

    private static void runMedia(ThrowingAction operation) throws Exception {
        await(MEDIA_WORKERS.submit(() -> {
            operation.run();
            return null;
        }));
    }

    private static <T> T await(Future<T> future) throws Exception {
        try {
            return future.get();
        } catch (InterruptedException error) {
            future.cancel(true);
            Thread.currentThread().interrupt();
            throw error;
        } catch (ExecutionException error) {
            Throwable cause = error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new IOException("Worker failed");
        }
    }

    @FunctionalInterface
    private interface ThrowingSupplier<T> {
        T get() throws Exception;
    }

    @FunctionalInterface
    private interface ThrowingAction {
        void run() throws Exception;
    }

    private static JSONObject submitUI(
            Context context,
            String interactionID,
            JSONObject payload
    ) throws Exception {
        synchronized (INTERACTION_LIFECYCLE_LOCK) {
            if (!acceptsInvocation(interactionID)) {
                JSONObject stale = staleInteraction(interactionID);
                stale.put("clicked", false);
                stale.put("stale", true);
                return stale;
            }
            return BridgeActivity.submitUI(
                    context,
                    interactionID,
                    payload.optString("text", null),
                    payload.optString("button", ""),
                    payload.has("controlID") && !payload.isNull("controlID")
                            ? payload.optString("controlID", null)
                            : null,
                    payload.has("generation") && !payload.isNull("generation")
                            ? payload.optInt("generation")
                            : null
            );
        }
    }

    private static String requestPath(String target) {
        int marker = target.indexOf('?');
        return marker < 0 ? target : target.substring(0, marker);
    }

    private static String interactionID(String path, String suffix) {
        String prefix = "/v1/interactions/";
        if (!path.startsWith(prefix) || !path.endsWith(suffix)) return null;
        String id = path.substring(prefix.length(), path.length() - suffix.length());
        if (id.isEmpty() || id.indexOf('/') >= 0) return null;
        try {
            return URLDecoder.decode(id, "UTF-8");
        } catch (Throwable ignored) {
            return id;
        }
    }

    private static Map<String, String> parseQuery(String target) {
        Map<String, String> values = new HashMap<>();
        int marker = target.indexOf('?');
        if (marker < 0 || marker + 1 >= target.length()) return values;
        String query = target.substring(marker + 1);
        for (String item : query.split("&")) {
            if (item.isEmpty()) continue;
            int separator = item.indexOf('=');
            String key = separator < 0 ? item : item.substring(0, separator);
            String value = separator < 0 ? "" : item.substring(separator + 1);
            try {
                values.put(
                        URLDecoder.decode(key, "UTF-8"),
                        URLDecoder.decode(value, "UTF-8")
                );
            } catch (Throwable ignored) {
                values.put(key, value);
            }
        }
        return values;
    }

    private static Map<String, String> readHeaders(BufferedInputStream input)
            throws IOException {
        Map<String, String> headers = new HashMap<>();
        while (true) {
            String line = readLine(input);
            if (line.isEmpty()) return headers;
            int separator = line.indexOf(':');
            if (separator <= 0) continue;
            headers.put(
                    line.substring(0, separator).trim().toLowerCase(Locale.ROOT),
                    line.substring(separator + 1).trim()
            );
        }
    }

    private static String readLine(BufferedInputStream input) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        int previous = -1;
        while (bytes.size() < 8_192) {
            int value = input.read();
            if (value == -1) throw new EOFException();
            if (previous == '\r' && value == '\n') {
                byte[] line = bytes.toByteArray();
                return new String(line, 0, Math.max(0, line.length - 1),
                        StandardCharsets.US_ASCII);
            }
            bytes.write(value);
            previous = value;
        }
        throw new IOException("Header line is too long");
    }

    private static byte[] readExactly(BufferedInputStream input, int count)
            throws IOException {
        byte[] value = new byte[count];
        int offset = 0;
        while (offset < count) {
            int read = input.read(value, offset, count - offset);
            if (read < 0) throw new EOFException();
            offset += read;
        }
        return value;
    }

    private static int parseLength(String value) {
        try {
            return value == null ? 0 : Integer.parseInt(value);
        } catch (NumberFormatException error) {
            return -1;
        }
    }

    private static JSONObject failure(String message) {
        JSONObject value = new JSONObject();
        try {
            value.put("ok", false);
            value.put("error", message);
        } catch (Throwable ignored) {
        }
        return value;
    }

    private static JSONObject withProviderOwner(
            JSONObject state,
            String interactionID
    ) {
        JSONObject output = state == null ? new JSONObject() : state;
        JSONObject owner = BridgeProviderOwnerRegistry.state(interactionID);
        if (owner == null) return output;
        try {
            java.util.Iterator<String> keys = owner.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                output.put(key, owner.opt(key));
            }
        } catch (Throwable ignored) {
        }
        return output;
    }

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        if (message == null || message.trim().isEmpty()) {
            return error.getClass().getSimpleName();
        }
        return error.getClass().getSimpleName() + ": " + message;
    }

    private static void writeSessionMedia(
            Context context,
            BufferedOutputStream output,
            String sessionID,
            Map<String, String> clientHeaders,
            boolean headersOnly
    ) throws IOException {
        BridgeMediaSessionRegistry.Session session =
                BridgeMediaSessionRegistry.get(sessionID);
        if (session == null) {
            writeJSON(output, 410, failure("Media session expired or missing"));
            return;
        }
        String requestID = UUID.randomUUID().toString().substring(0, 8);
        LinkedHashMap<String, String> forwarded = new LinkedHashMap<>();

        // Ordinary player preferences may be inherited from the client, but
        // provider authorization remains authoritative and never leaves this
        // process. Range is intentionally client-owned for seeking.
        for (String name : FORWARDED_MEDIA_REQUEST_HEADERS) {
            String value = clientHeaders.get(name);
            if (value != null && !value.trim().isEmpty()) {
                forwarded.put(name, value);
            }
        }
        for (Map.Entry<String, String> entry
                : session.headerSnapshot().entrySet()) {
            putHeaderIgnoreCase(
                    forwarded,
                    entry.getKey(),
                    entry.getValue()
            );
        }
        String range = clientHeaders.get("range");
        if (range != null && !range.trim().isEmpty()) {
            putHeaderIgnoreCase(forwarded, "Range", range);
        }
        URI providerProxy = providerProxyURI(session.upstreamURL);
        if (providerProxy != null) {
            if (session.owner == null) {
                writeJSON(
                        output,
                        409,
                        failure("Media session has no provider owner")
                );
                return;
            }
            Map<String, String> params = parseQuery(
                    providerProxy.getRawPath()
                            + (providerProxy.getRawQuery() == null
                            ? ""
                            : "?" + providerProxy.getRawQuery())
            );
            params.putAll(forwarded);
            Object[] response;
            try {
                response = runProvider(
                        () -> DexSpiderRegistry.get(context)
                                .proxy(session.owner, params)
                );
            } catch (Exception error) {
                throw new IOException("Provider media proxy failed");
            }
            writeProxy(output, response, headersOnly);
            return;
        }
        final SessionMediaResponse mediaResponse;
        try {
            URI upstream = requireSessionMediaURI(session.upstreamURL);
            mediaResponse = executeSessionMedia(
                    upstream,
                    forwarded,
                    headersOnly
            );
        } catch (IOException | IllegalArgumentException error) {
            Log.w(
                    TAG,
                    "Media session request=" + requestID
                            + " session=" + shortHash(session.id)
                            + " status=transport_error"
                            + " error=" + error.getClass().getSimpleName()
                            + " method=" + (headersOnly ? "HEAD" : "GET")
                            + " range=" + hasHeaderIgnoreCase(forwarded, "range")
                            + " headers=" + redactedHeaderNames(forwarded)
            );
            writeJSON(output, 502, failure("Upstream media request failed"));
            return;
        }
        try (Response response = mediaResponse.response) {
            Log.i(
                    TAG,
                    "Media session request=" + requestID
                            + " session=" + shortHash(session.id)
                            + " hostHash=" + shortHash(
                                    mediaResponse.upstream.getHost()
                                            .toLowerCase(Locale.ROOT)
                            )
                            + " status=" + response.code()
                            + " redirects=" + mediaResponse.redirects
                            + " method=" + (headersOnly ? "HEAD" : "GET")
                            + " range=" + hasHeaderIgnoreCase(
                                    mediaResponse.headers,
                                    "range"
                            )
                            + " headers=" + redactedHeaderNames(
                                    mediaResponse.headers
                            )
            );
            writeMediaResponse(output, response, headersOnly);
        }
    }

    private static URI providerProxyURI(String rawURL) {
        try {
            URI value = requireHTTPMediaURI(rawURL);
            String host = value.getHost().toLowerCase(Locale.ROOT);
            boolean loopback = "localhost".equals(host)
                    || "127.0.0.1".equals(host)
                    || "::1".equals(host);
            String path = value.getPath() == null ? "" : value.getPath();
            return loopback
                    && ("/proxy".equals(path) || path.startsWith("/proxy/"))
                    && !path.startsWith("/proxy/media/")
                    ? value
                    : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static SessionMediaResponse executeSessionMedia(
            URI initialUpstream,
            Map<String, String> initialHeaders,
            boolean headersOnly
    ) throws IOException {
        URI upstream = initialUpstream;
        LinkedHashMap<String, String> headers = new LinkedHashMap<>(
                initialHeaders
        );
        int redirects = 0;
        while (true) {
            Request.Builder request = new Request.Builder()
                    .url(upstream.toString());
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                request.header(entry.getKey(), entry.getValue());
            }
            // Avoid transparent gzip conversion so range offsets always
            // describe the exact bytes delivered to the player.
            request.header("Accept-Encoding", "identity");
            if (headersOnly) request.head(); else request.get();

            Response response = SESSION_MEDIA_CLIENT.newCall(
                    request.build()
            ).execute();
            String location = response.header("Location");
            if (!isRedirect(response.code())
                    || location == null
                    || location.trim().isEmpty()) {
                return new SessionMediaResponse(
                        response,
                        upstream,
                        headers,
                        redirects
                );
            }
            if (redirects >= MAX_MEDIA_REDIRECTS) {
                response.close();
                throw new IOException("Too many upstream media redirects");
            }

            final URI redirected;
            try {
                redirected = requireSessionMediaURI(
                        upstream.resolve(location).toString()
                );
            } catch (IllegalArgumentException ignored) {
                response.close();
                // A parser exception may include the signed Location value.
                throw new IOException("Invalid upstream media redirect");
            } catch (IOException error) {
                response.close();
                throw error;
            }
            response.close();
            redirects++;
            if (!sameOrigin(initialUpstream, redirected)) {
                stripCrossOriginProviderHeaders(headers);
            }
            upstream = redirected;
        }
    }

    private static boolean isRedirect(int status) {
        return status == 300
                || status == 301
                || status == 302
                || status == 303
                || status == 307
                || status == 308;
    }

    private static boolean sameOrigin(URI left, URI right) {
        return left.getScheme().equalsIgnoreCase(right.getScheme())
                && left.getHost().equalsIgnoreCase(right.getHost())
                && effectivePort(left) == effectivePort(right);
    }

    private static int effectivePort(URI uri) {
        return uri.getPort() < 0 ? defaultPort(uri) : uri.getPort();
    }

    private static void stripCrossOriginProviderHeaders(
            Map<String, String> headers
    ) {
        headers.entrySet().removeIf(entry -> {
            String name = entry.getKey().toLowerCase(Locale.ROOT);
            // These are ordinary representation/request preferences. Referer
            // and Origin are intentionally retained because many media CDNs
            // validate the provider page across an origin boundary. Cookies,
            // Authorization and arbitrary token headers never cross it.
            return !("range".equals(name)
                    || "user-agent".equals(name)
                    || "referer".equals(name)
                    || "origin".equals(name)
                    || "accept".equals(name)
                    || "accept-language".equals(name));
        });
    }

    private static final class SessionMediaResponse {
        final Response response;
        final URI upstream;
        final Map<String, String> headers;
        final int redirects;

        SessionMediaResponse(
                Response response,
                URI upstream,
                Map<String, String> headers,
                int redirects
        ) {
            this.response = response;
            this.upstream = upstream;
            this.headers = new LinkedHashMap<>(headers);
            this.redirects = redirects;
        }
    }

    private static void writeDirectMedia(
            BufferedOutputStream output,
            String rawURL,
            Map<String, String> clientHeaders,
            boolean headersOnly
    ) throws IOException {
        URI upstream = requireRemoteMediaURI(rawURL);
        String requestID = UUID.randomUUID().toString().substring(0, 8);
        Request.Builder request = new Request.Builder().url(upstream.toString());
        StringBuilder forwardedNames = new StringBuilder();
        for (String name : FORWARDED_MEDIA_REQUEST_HEADERS) {
            String value = clientHeaders.get(name);
            if (value != null && !value.trim().isEmpty()) {
                request.header(name, value);
                if (forwardedNames.length() > 0) forwardedNames.append(',');
                forwardedNames.append(name);
            }
        }
        // Avoid OkHttp's transparent gzip conversion. Byte offsets and
        // Content-Range must describe the exact bytes libmpv receives.
        request.header("Accept-Encoding", "identity");
        if (headersOnly) {
            request.head();
        } else {
            request.get();
        }

        final Response mediaResponse;
        try {
            mediaResponse = MEDIA_CLIENT.newCall(request.build()).execute();
        } catch (IOException error) {
            Log.w(
                    TAG,
                    "Media request=" + requestID
                            + " hostHash=" + shortHash(
                                    upstream.getHost().toLowerCase(Locale.ROOT)
                            )
                            + " status=transport_error"
                            + " error=" + error.getClass().getSimpleName()
                            + " method=" + (headersOnly ? "HEAD" : "GET")
                            + " headers=" + forwardedNames
            );
            writeJSON(output, 502, failure("Upstream media request failed"));
            return;
        }
        try (Response response = mediaResponse) {
            Log.i(
                    TAG,
                    "Media request=" + requestID
                            + " hostHash=" + Integer.toHexString(
                                    upstream.getHost().toLowerCase(Locale.ROOT).hashCode()
                            )
                            + " status=" + response.code()
                            + " method=" + (headersOnly ? "HEAD" : "GET")
                            + " headers=" + forwardedNames
            );
            writeMediaResponse(output, response, headersOnly);
        }
    }

    private static void writeMediaResponse(
            BufferedOutputStream output,
            Response response,
            boolean headersOnly
    ) throws IOException {
        ResponseBody responseBody = response.body();
        String contentType = response.header(
                "Content-Type",
                "application/octet-stream"
        );
        Map<String, String> responseHeaders = new LinkedHashMap<>();
        for (String name : FORWARDED_MEDIA_RESPONSE_HEADERS) {
            String value = response.header(name);
            if (value != null && !value.trim().isEmpty()) {
                responseHeaders.put(name, value);
            }
        }
        writeProxy(
                output,
                new Object[] {
                        response.code(),
                        contentType,
                        responseBody == null
                                ? new ByteArrayInputStream(new byte[0])
                                : responseBody.byteStream(),
                        responseHeaders
                },
                headersOnly
        );
    }

    private static boolean hasHeaderIgnoreCase(
            Map<String, String> headers,
            String expected
    ) {
        for (String name : headers.keySet()) {
            if (name.equalsIgnoreCase(expected)) return true;
        }
        return false;
    }

    private static void putHeaderIgnoreCase(
            Map<String, String> headers,
            String name,
            String value
    ) {
        String matched = null;
        for (String existing : headers.keySet()) {
            if (existing.equalsIgnoreCase(name)) {
                matched = existing;
                break;
            }
        }
        if (matched != null) headers.remove(matched);
        headers.put(name, value);
    }

    private static String redactedHeaderNames(Map<String, String> headers) {
        StringBuilder output = new StringBuilder();
        for (String name : headers.keySet()) {
            if (output.length() > 0) output.append(',');
            output.append(name.toLowerCase(Locale.ROOT));
        }
        return output.toString();
    }

    private static String shortHash(String value) {
        return Integer.toHexString(value == null ? 0 : value.hashCode());
    }

    private static URI requireRemoteMediaURI(String rawURL) throws IOException {
        URI value = requireHTTPMediaURI(rawURL);
        String host = value.getHost();
        String normalizedHost = host.toLowerCase(Locale.ROOT);
        if ("localhost".equals(normalizedHost)
                || "127.0.0.1".equals(normalizedHost)
                || "::1".equals(normalizedHost)) {
            throw new IOException("Recursive loopback media URL is not allowed");
        }
        return value;
    }

    private static URI requireSessionMediaURI(String rawURL) throws IOException {
        URI value = requireHTTPMediaURI(rawURL);
        String normalizedHost = value.getHost().toLowerCase(Locale.ROOT);
        boolean loopback = "localhost".equals(normalizedHost)
                || "127.0.0.1".equals(normalizedHost)
                || "::1".equals(normalizedHost);
        if (!loopback) return value;
        int port = value.getPort() < 0 ? defaultPort(value) : value.getPort();
        String path = value.getPath() == null ? "" : value.getPath();
        if (port == PORT
                && (path.startsWith("/proxy/media/")
                || path.startsWith("/v1/media-sessions/")
                || "/v1/media".equals(path))) {
            throw new IOException("Recursive media session URL is not allowed");
        }
        return value;
    }

    private static URI requireHTTPMediaURI(String rawURL) throws IOException {
        if (rawURL == null || rawURL.trim().isEmpty()) {
            throw new IOException("Missing media URL");
        }
        final URI value;
        try {
            value = URI.create(rawURL.trim());
        } catch (IllegalArgumentException ignored) {
            // Do not retain the parser exception as a cause: its message can
            // contain the complete signed URL, which must not enter logcat.
            throw new IOException("Invalid media URL");
        }
        String scheme = value.getScheme();
        String host = value.getHost();
        if (scheme == null
                || !("http".equalsIgnoreCase(scheme)
                || "https".equalsIgnoreCase(scheme))
                || host == null
                || host.trim().isEmpty()) {
            throw new IOException("Media URL must be HTTP(S)");
        }
        return value;
    }

    private static int defaultPort(URI uri) {
        return "https".equalsIgnoreCase(uri.getScheme()) ? 443 : 80;
    }

    private static void writeProxy(
            BufferedOutputStream output,
            Object[] response,
            boolean headersOnly
    ) throws IOException {
        if (response == null || response.length < 3
                || !(response[0] instanceof Integer)
                || !(response[1] instanceof String)
                || !(response[2] instanceof java.io.InputStream)) {
            writeJSON(output, 502, failure("Invalid Spider proxy response"));
            return;
        }
        int status = (Integer) response[0];
        if (status < 100 || status > 599) status = 502;
        String mime = (String) response[1];
        java.io.InputStream body = (java.io.InputStream) response[2];
        StringBuilder rawHeaders = new StringBuilder()
                .append("HTTP/1.1 ").append(status).append(" Proxy Response\r\n")
                .append("Content-Type: ")
                .append(mime == null || mime.trim().isEmpty()
                        ? "application/octet-stream" : mime)
                .append("\r\n")
                .append("Transfer-Encoding: chunked\r\n")
                .append("Connection: close\r\n");
        if (response.length > 3 && response[3] instanceof Map) {
            for (Object entryObject : ((Map<?, ?>) response[3]).entrySet()) {
                Map.Entry<?, ?> entry = (Map.Entry<?, ?>) entryObject;
                String name = String.valueOf(entry.getKey());
                String lower = name.toLowerCase(Locale.ROOT);
                if ("content-length".equals(lower)
                        || "transfer-encoding".equals(lower)
                        || "connection".equals(lower)
                        || name.indexOf('\r') >= 0
                        || name.indexOf('\n') >= 0) {
                    continue;
                }
                String value = String.valueOf(entry.getValue());
                if (value.indexOf('\r') < 0 && value.indexOf('\n') < 0) {
                    rawHeaders.append(name).append(": ").append(value).append("\r\n");
                }
            }
        }
        rawHeaders.append("\r\n");
        output.write(rawHeaders.toString().getBytes(StandardCharsets.US_ASCII));
        try (java.io.InputStream stream = body) {
            if (!headersOnly) {
                byte[] buffer = new byte[16_384];
                int count;
                while ((count = stream.read(buffer)) != -1) {
                    if (count == 0) continue;
                    output.write(Integer.toHexString(count).getBytes(StandardCharsets.US_ASCII));
                    output.write("\r\n".getBytes(StandardCharsets.US_ASCII));
                    output.write(buffer, 0, count);
                    output.write("\r\n".getBytes(StandardCharsets.US_ASCII));
                }
            }
            output.write("0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            output.flush();
        }
    }

    private static void writeJSON(
            BufferedOutputStream output,
            int status,
            JSONObject object
    ) throws IOException {
        byte[] data = object.toString().getBytes(StandardCharsets.UTF_8);
        String reason = status == 200 ? "OK" : "Error";
        String headers = "HTTP/1.1 " + status + " " + reason + "\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n"
                + "Content-Length: " + data.length + "\r\n"
                + "Connection: close\r\n\r\n";
        output.write(headers.getBytes(StandardCharsets.US_ASCII));
        output.write(data);
        output.flush();
    }

    private static void writeBytes(
            BufferedOutputStream output,
            int status,
            String contentType,
            byte[] data
    ) throws IOException {
        String reason = status == 200 ? "OK" : "Error";
        String headers = "HTTP/1.1 " + status + " " + reason + "\r\n"
                + "Content-Type: " + contentType + "\r\n"
                + "Content-Length: " + data.length + "\r\n"
                + "Connection: close\r\n\r\n";
        output.write(headers.getBytes(StandardCharsets.US_ASCII));
        output.write(data);
        output.flush();
    }
}
