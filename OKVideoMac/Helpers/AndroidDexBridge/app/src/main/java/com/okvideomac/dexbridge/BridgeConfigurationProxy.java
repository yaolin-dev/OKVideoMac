package com.okvideomac.dexbridge;

import android.content.Context;
import android.webkit.CookieManager;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** A cookie capability grants one visible configuration session its exact jar.
 * The normal loopback playback lease and Mac RPC listener remain unchanged. */
final class BridgeConfigurationProxy {
    static final String COOKIE = "OKVideoConfigSession";
    private static final ExecutorService CONNECTIONS = Executors.newFixedThreadPool(4);
    private static String interactionID = "";
    private static String token = "";
    private static ServerSocket guestListener;
    private static BridgeProviderOwnerRegistry.Binding owner;

    static synchronized void prepare(Context context, String id) throws IOException {
        if (!BridgeInteractionRegistry.ownsLatest(id) || BridgeInteractionRegistry.terminal(id)) {
            throw new IOException("Configuration interaction expired");
        }
        BridgeProviderOwnerRegistry.Binding binding = BridgeProviderOwnerRegistry.binding(id);
        if (binding == null) throw new IOException("Configuration provider is unavailable");
        if (id.equals(interactionID) && owner != null) return;
        close();
        int port = FongMiCompatProxyServer.ensureStarted(context);
        String ip = com.github.catvod.utils.Util.getIp();
        InetAddress address = InetAddress.getByName(ip);
        // Bind only the actual guest address; never expose the Mac RPC server
        // or change the existing loopback playback listener's address.
        ServerSocket server = null;
        if (!address.isLoopbackAddress() && !address.isAnyLocalAddress()) {
            server = new ServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress(address, port), 16);
        }
        owner = binding;
        interactionID = id;
        token = UUID.randomUUID().toString() + UUID.randomUUID();
        guestListener = server;
        CookieManager cookies = CookieManager.getInstance();
        for (String host : new String[]{ip, "127.0.0.1", "localhost"}) {
            cookies.setCookie("http://" + host + ":" + port + "/proxy",
                    COOKIE + "=" + token + "; Path=/proxy; HttpOnly; SameSite=Strict");
        }
        if (server != null) {
            final ServerSocket serving = server;
            Thread listener = new Thread(() -> {
                try {
                    while (!serving.isClosed()) {
                        Socket client = serving.accept();
                        // Guest requests never inherit the active playback lease.
                        CONNECTIONS.execute(() -> FongMiCompatProxyServer.handle(client, null));
                    }
                } catch (IOException ignored) { }
            }, "okvideo-configuration-proxy");
            listener.setDaemon(true);
            listener.start();
        }
    }

    static boolean hasCapability(Map<String, String> headers) {
        return capability(headers) != null;
    }

    static synchronized BridgeProviderOwnerRegistry.Binding resolve(Map<String, String> headers) {
        String received = capability(headers);
        if (owner == null || received == null || !token.equals(received)
                || !BridgeInteractionRegistry.ownsLatest(interactionID)
                || BridgeInteractionRegistry.terminal(interactionID)) return null;
        return owner;
    }

    private static String capability(Map<String, String> headers) {
        String cookie = headers.get("cookie");
        if (cookie == null) return null;
        for (String entry : cookie.split(";")) {
            String part = entry.trim();
            if (part.startsWith(COOKIE + "=")) return part.substring(COOKIE.length() + 1);
        }
        return null;
    }

    static synchronized void release(String id) {
        if (id.equals(interactionID)) close();
    }

    private static void close() {
        if (guestListener != null) try { guestListener.close(); } catch (IOException ignored) { }
        guestListener = null;
        owner = null;
        token = "";
        interactionID = "";
    }
}
