package com.okvideomac.dexbridge;

import android.content.Context;
import android.util.Log;

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
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
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
    private static final int CLIENT_THREAD_COUNT = 32;
    private static final ExecutorService CLIENTS =
            Executors.newFixedThreadPool(CLIENT_THREAD_COUNT);
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
    private static final String[] FORWARDED_MEDIA_REQUEST_HEADERS = {
            "range",
            "user-agent",
            "referer",
            "cookie",
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
    private static volatile boolean started;

    private BridgeServer() {
    }

    static synchronized void start(Context context) {
        if (started) return;
        com.github.catvod.Proxy.set(PORT);
        started = true;
        Thread thread = new Thread(
                () -> serve(context.getApplicationContext()),
                "okvideo-dex-rpc"
        );
        thread.setDaemon(false);
        thread.start();
    }

    private static void serve(Context context) {
        try (ServerSocket server = new ServerSocket(
                PORT,
                64,
                InetAddress.getByName("127.0.0.1")
        )) {
            Log.i(TAG, "Listening on 127.0.0.1:" + PORT);
            while (!server.isClosed()) {
                Socket socket = server.accept();
                CLIENTS.execute(() -> handle(context, socket));
            }
        } catch (Throwable error) {
            started = false;
            Log.e(TAG, "RPC server stopped", error);
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
                if ("GET".equals(method) && "/health".equals(target)) {
                    JSONObject health = new JSONObject();
                    health.put("ok", true);
                    health.put("version", "0.3.21");
                    health.put("contractVersion", 1);
                    writeJSON(output, 200, health);
                    return;
                }
                if (target.startsWith("/v1/media?")
                        && ("GET".equals(method) || "HEAD".equals(method))) {
                    writeDirectMedia(
                            output,
                            parseQuery(target).get("url"),
                            headers,
                            "HEAD".equals(method)
                    );
                    return;
                }
                if ("GET".equals(method) && "/v1/ui/state".equals(target)) {
                    writeJSON(output, 200, BridgeActivity.uiState());
                    return;
                }
                if ("GET".equals(method) && "/v1/ui/snapshot".equals(target)) {
                    writeBytes(output, 200, "image/png", BridgeActivity.snapshotUI());
                    return;
                }
                if (target.startsWith("/proxy")
                        && ("GET".equals(method)
                        || "HEAD".equals(method)
                        || "POST".equals(method))) {
                    Map<String, String> params = parseQuery(target);
                    params.putAll(headers);
                    Object[] response = DexSpiderRegistry.get(context).proxy(params);
                    writeProxy(output, response, "HEAD".equals(method));
                    return;
                }
                if ("POST".equals(method) && "/v1/ui/submit".equals(target)) {
                    int length = parseLength(headers.get("content-length"));
                    if (length < 0 || length > MAX_BODY_BYTES) {
                        writeJSON(output, 413, failure("Invalid request size"));
                        return;
                    }
                    JSONObject payload = new JSONObject(
                            new String(readExactly(input, length), StandardCharsets.UTF_8)
                    );
                    writeJSON(
                            output,
                            200,
                            BridgeActivity.submitUI(
                                    payload.optString("text", null),
                                    payload.optString("button", ""),
                                    payload.has("controlID")
                                            && !payload.isNull("controlID")
                                            ? payload.optString("controlID", null)
                                            : null
                            )
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
                    boolean accepted = DexSpiderRegistry.get(context)
                            .submitCloudCredential(
                                    payload.optString("provider", ""),
                                    payload.optString("credential", "")
                            );
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
                Object result = DexSpiderRegistry.get(context).invoke(payload);
                JSONObject response = new JSONObject();
                response.put("ok", true);
                response.put("result", result);
                writeJSON(output, 200, response);
            } catch (Throwable error) {
                Log.e(TAG, "RPC request failed", error);
                writeJSON(output, 500, failure(safeMessage(error)));
            }
        } catch (Throwable error) {
            Log.e(TAG, "RPC connection failed", error);
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

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        if (message == null || message.trim().isEmpty()) {
            return error.getClass().getSimpleName();
        }
        return error.getClass().getSimpleName() + ": " + message;
    }

    private static void writeDirectMedia(
            BufferedOutputStream output,
            String rawURL,
            Map<String, String> clientHeaders,
            boolean headersOnly
    ) throws IOException {
        URI upstream = requireRemoteMediaURI(rawURL);
        Request.Builder request = new Request.Builder().url(upstream.toString());
        for (String name : FORWARDED_MEDIA_REQUEST_HEADERS) {
            String value = clientHeaders.get(name);
            if (value != null && !value.trim().isEmpty()) {
                request.header(name, value);
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

        try (Response response = MEDIA_CLIENT.newCall(request.build()).execute()) {
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
    }

    private static URI requireRemoteMediaURI(String rawURL) throws IOException {
        if (rawURL == null || rawURL.trim().isEmpty()) {
            throw new IOException("Missing media URL");
        }
        final URI value;
        try {
            value = URI.create(rawURL.trim());
        } catch (IllegalArgumentException error) {
            throw new IOException("Invalid media URL", error);
        }
        String scheme = value.getScheme();
        String host = value.getHost();
        if (scheme == null
                || !("http".equalsIgnoreCase(scheme)
                || "https".equalsIgnoreCase(scheme))
                || host == null
                || host.trim().isEmpty()) {
            throw new IOException("Media URL must be remote HTTP(S)");
        }
        String normalizedHost = host.toLowerCase(Locale.ROOT);
        if ("localhost".equals(normalizedHost)
                || "127.0.0.1".equals(normalizedHost)
                || "::1".equals(normalizedHost)) {
            throw new IOException("Recursive loopback media URL is not allowed");
        }
        return value;
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
