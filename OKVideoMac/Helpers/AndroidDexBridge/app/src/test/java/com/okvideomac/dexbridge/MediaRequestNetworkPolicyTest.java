package com.okvideomac.dexbridge;

import org.junit.Test;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import okhttp3.*;
import static org.junit.Assert.*;

public class MediaRequestNetworkPolicyTest {
    private MediaRequestNetworkPolicy policy(String json) throws IOException {
        return MediaRequestNetworkPolicy.decode(Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8)));
    }
    @Test public void selectsBySchemeAndNeverProxiesLocalOrExcludedHosts() throws Exception {
        MediaRequestNetworkPolicy p = policy("{\"version\":1,\"enabled\":true,\"http\":{\"host\":\"10.0.2.2\",\"port\":8000},\"https\":{\"host\":\"10.0.2.2\",\"port\":8001},\"exceptions\":[\"*.local\",\"169.254/16\",\"192.168.0.0/16\"],\"excludeSimple\":true}");
        assertEquals(8000, ((InetSocketAddress)p.select(URI.create("http://media.example/a")).get(0).address()).getPort());
        assertEquals(8001, ((InetSocketAddress)p.select(URI.create("https://media.example/a")).get(0).address()).getPort());
        for (String host : List.of("127.0.0.1", "127.5.1.2", "localhost", "[::1]", "10.0.2.2", "nas.local", "printer", "169.254.1.2", "192.168.5.7")) {
            assertEquals(host, Proxy.NO_PROXY, p.select(URI.create("http://"+host+"/media")).get(0));
        }
    }
    @Test public void offClearsInheritedProxyAndUnsupportedCannotFallBack() throws Exception {
        MediaRequestNetworkPolicy off = policy("{\"version\":1,\"enabled\":false,\"unsupported\":true}");
        assertEquals(Proxy.NO_PROXY, off.select(URI.create("https://media.example/a")).get(0));
        for (String flag : List.of("unsupported", "socks")) {
            MediaRequestNetworkPolicy on = policy("{\"version\":1,\"enabled\":true,\""+flag+"\":true}");
            try { on.select(URI.create("https://media.example/a")); fail("No silent direct fallback"); }
            catch (IllegalArgumentException expected) { }
        }
        try { MediaRequestNetworkPolicy.decode("bad"); fail(); }
        catch (IOException expected) { assertEquals("Invalid media network policy", expected.getMessage()); }
    }
    @Test public void identicalSnapshotsReuseConnectionsAndNewPreferenceIsIsolated() throws Exception {
        String config = "{\"version\":1,\"enabled\":false}";
        assertEquals(policy(config), policy(config)); assertEquals(policy(config).hashCode(), policy(config).hashCode());
        assertNotEquals(policy(config), policy("{\"version\":1,\"enabled\":true}"));
    }
    @Test public void actualRequestsUseSelectedProxyAndOffUsesDirectOrigin() throws Exception {
        try (ServerSocket server = new ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(3000);
            FutureTask<List<String>> received = new FutureTask<>(() -> {
                List<String> lines = new ArrayList<>();
                for (int i=0;i<2;i++) try (Socket socket=server.accept()) {
                    socket.setSoTimeout(3000);
                    BufferedReader reader=new BufferedReader(new InputStreamReader(socket.getInputStream(),StandardCharsets.US_ASCII));
                    lines.add(reader.readLine());
                    String line;
                    while ((line=reader.readLine())!=null&&!line.isEmpty()) assertFalse(line.toLowerCase(Locale.ROOT).startsWith("x-okvideo-media-network"));
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".getBytes(StandardCharsets.US_ASCII));
                }
                return lines;
            });
            new Thread(received).start();
            OkHttpClient base=new OkHttpClient.Builder().proxy(new Proxy(Proxy.Type.HTTP,new InetSocketAddress("127.0.0.1",1))).build();
            MediaRequestNetworkPolicy on=policy("{\"version\":1,\"enabled\":true,\"http\":{\"host\":\"127.0.0.1\",\"port\":"+server.getLocalPort()+"}}");
            try(Response r=on.client(base).newCall(new Request.Builder().url("http://media.example/segment.ts").header("Range","bytes=100-").build()).execute()) { assertEquals("OK",r.body().string()); }
            MediaRequestNetworkPolicy off=policy("{\"version\":1,\"enabled\":false}");
            try(Response r=off.client(base).newCall(new Request.Builder().url("http://127.0.0.1:"+server.getLocalPort()+"/direct.mp4").build()).execute()) { assertEquals("OK",r.body().string()); }
            List<String> lines=received.get(5,TimeUnit.SECONDS);
            assertEquals("GET http://media.example/segment.ts HTTP/1.1",lines.get(0));
            assertEquals("GET /direct.mp4 HTTP/1.1",lines.get(1));
        }
    }
}
