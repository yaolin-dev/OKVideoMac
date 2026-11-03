package com.okvideomac.dexbridge;

import android.content.Context;
import androidx.test.platform.app.InstrumentationRegistry;
import com.github.catvod.crawler.Spider;
import dalvik.system.DexClassLoader;
import junit.framework.TestCase;
import org.json.JSONArray;
import org.json.JSONObject;
import java.lang.reflect.Field;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Exercises the production registry + HTTP path, not only the retry helper. */
public final class HistoryRecoveryProtocolTest extends TestCase {
    private static final String DETAIL = "{\"list\":[{\"vod_id\":\"132883\",\"vod_name\":\"Original\",\"vod_play_url\":\"File$stable-file\"}]}";
    public static class FreshSpider extends Spider {
        static final AtomicInteger constructions = new AtomicInteger();
        public FreshSpider() { constructions.incrementAndGet(); }
        @Override public String detailContent(List<String> ids) {
            assertEquals("132883", ids.get(0)); return DETAIL;
        }
    }

    public void testBrokenSourceRecreatesOnceThroughHTTPAndKeepsOtherSources() throws Exception {
        AtomicInteger details = new AtomicInteger(), homes = new AtomicInteger(), destroys = new AtomicInteger();
        try (Fixture fixture = new Fixture(new Spider() {
            @Override public String detailContent(List<String> ids) { details.incrementAndGet(); return ""; }
            @Override public String homeContent(boolean filter) { homes.incrementAndGet(); return ""; }
            @Override public void destroy() { destroys.incrementAndGet(); }
        })) {
            long epoch = ProviderMediaEpoch.current(fixture.jar);
            JSONObject response = post(fixture.payload);
            assertTrue(response.toString(), response.getBoolean("ok"));
            assertEquals("132883", response.getJSONObject("result").getJSONArray("list").getJSONObject(0).getString("vod_id"));
            assertEquals(2, details.get()); assertEquals(1, homes.get());
            assertEquals(1, FreshSpider.constructions.get()); assertEquals(0, destroys.get());
            assertEquals(epoch, ProviderMediaEpoch.current(fixture.jar));
            assertSame(fixture.other, fixture.spiders.get(fixture.otherKey));
            assertTrue(post(fixture.payload).getBoolean("ok"));
            assertEquals(1, FreshSpider.constructions.get());
        }
    }

    public void testConcurrentRecoveryUsesRepairedInstanceInsteadOfRepeatingReset() throws Exception {
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger details = new AtomicInteger();
        try (Fixture fixture = new Fixture(new Spider() {
            @Override public String detailContent(List<String> ids) throws Exception {
                if (details.incrementAndGet() == 1) { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)); }
                return "";
            }
            @Override public String homeContent(boolean filter) { return ""; }
        })) {
            FutureTask<JSONObject> first = new FutureTask<>(() -> post(fixture.payload));
            FutureTask<JSONObject> second = new FutureTask<>(() -> post(fixture.payload));
            new Thread(first).start(); assertTrue(entered.await(5, TimeUnit.SECONDS));
            new Thread(second).start(); release.countDown();
            assertTrue(first.get(10, TimeUnit.SECONDS).getBoolean("ok"));
            assertTrue(second.get(10, TimeUnit.SECONDS).getBoolean("ok"));
            assertEquals(2, details.get()); assertEquals(1, FreshSpider.constructions.get());
        } finally { release.countDown(); }
    }

    public void testHealthyHomeWithEmptyDetailFailsWithoutDestroyOrRecreation() throws Exception {
        try (Fixture fixture = new Fixture(new Spider() {
            @Override public String detailContent(List<String> ids) { return "{\"list\":[]}"; }
            @Override public String homeContent(boolean filter) { return "{\"class\":[{\"type_id\":\"1\"}],\"list\":[]}"; }
        })) {
            JSONObject result = post(fixture.payload);
            assertFalse(result.getBoolean("ok"));
            assertEquals("sourceUnavailable", result.getString("failureKind"));
            assertEquals(0, FreshSpider.constructions.get());
        }
    }

    public void testConfigurationAPIExtensionAndJarChangesCannotReuseCachedInstance() throws Exception {
        try (Fixture fixture = new Fixture(new FreshSpider())) {
            String original = DexSpiderRegistry.spiderKey(fixture.payload, "history");
            for (String field : new String[]{"configurationID", "api", "ext", "jarURL", "jarMD5", "hosts"}) {
                JSONObject changed = new JSONObject(fixture.payload.toString());
                if (field.equals("hosts")) changed.put(field, new JSONArray().put("example.invalid=127.0.0.1"));
                else changed.put(field, changed.optString(field) + "changed");
                String key = DexSpiderRegistry.spiderKey(changed, "history");
                assertFalse(field, original.equals(key)); assertNull(fixture.spiders.get(key));
            }
        }
    }

    private static JSONObject post(JSONObject payload) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL("http://127.0.0.1:9978/v1/invoke").openConnection();
        connection.setConnectTimeout(2000); connection.setReadTimeout(10000);
        connection.setRequestMethod("POST"); connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        try {
            connection.getOutputStream().write(payload.toString().getBytes(StandardCharsets.UTF_8));
            java.io.InputStream stream = connection.getResponseCode() == 200 ? connection.getInputStream() : connection.getErrorStream();
            return new JSONObject(new String(stream.readAllBytes(), StandardCharsets.UTF_8));
        } finally { connection.disconnect(); }
    }

    private static final class Fixture implements AutoCloseable {
        final String jar = "https://fixture.invalid/" + UUID.randomUUID() + ".jar";
        final JSONObject payload;
        final Map<String, Spider> spiders;
        final Map<String, DexClassLoader> loaders;
        final String key, otherKey;
        final Spider other = new Spider() {};
        @SuppressWarnings("unchecked") Fixture(Spider initial) throws Exception {
            FreshSpider.constructions.set(0);
            Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
            BridgeServer.start(context);
            payload = new JSONObject().put("configurationID", UUID.randomUUID().toString())
                    .put("siteKey", "history").put("providerOwnerID", UUID.randomUUID().toString())
                    .put("api", "csp_WoGG").put("jarURL", jar).put("method", "detail")
                    .put("arguments", new JSONArray().put(new JSONArray().put("132883")));
            DexSpiderRegistry registry = DexSpiderRegistry.get(context);
            Field field = DexSpiderRegistry.class.getDeclaredField("spiders"); field.setAccessible(true);
            spiders = (Map<String, Spider>) field.get(registry);
            field = DexSpiderRegistry.class.getDeclaredField("loaders"); field.setAccessible(true);
            loaders = (Map<String, DexClassLoader>) field.get(registry);
            key = DexSpiderRegistry.spiderKey(payload, "history");
            otherKey = DexSpiderRegistry.spiderKey(payload, "unrelated");
            spiders.put(key, initial); spiders.put(otherKey, other);
            loaders.put(jar, new DexClassLoader(context.getApplicationInfo().sourceDir,
                    context.getCodeCacheDir().getPath(), null, context.getClassLoader()) {
                @Override public Class<?> loadClass(String name) throws ClassNotFoundException {
                    if (name.equals("com.github.catvod.spider.WoGG")) return FreshSpider.class;
                    return super.loadClass(name);
                }
            });
        }
        @Override public void close() { spiders.remove(key); spiders.remove(otherKey); loaders.remove(jar); }
    }
}
