package com.okvideomac.dexbridge;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import androidx.test.platform.app.InstrumentationRegistry;
import com.github.catvod.crawler.Spider;
import junit.framework.TestCase;
import org.json.JSONArray;
import org.json.JSONObject;
import java.lang.reflect.Field;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

/** Deterministic local providers: no accounts or external TVBox server needed. */
public final class TVBoxConfigurationTest extends TestCase {
    public void testOptionalUIIsLimitedToForegroundDetailsAndActions() throws Exception {
        JSONObject payload = new JSONObject().put("monitorsAuthorization", true)
                .put("observesOptionalUI", true).put("interactionKind", "immediate");
        assertTrue(DexSpiderRegistry.requiresDialogHandoff(payload, "detail"));
        assertTrue(DexSpiderRegistry.requiresDialogHandoff(payload, "action"));
        for (String method : new String[]{"home", "category", "search", "init", "live", "play"}) {
            assertFalse(method, DexSpiderRegistry.observesOptionalUI(payload, method));
        }
        payload.put("monitorsAuthorization", false);
        assertFalse(DexSpiderRegistry.requiresDialogHandoff(payload, "detail"));
    }

    public void testOptionalNoUIReturnCompletesAndObservedUIWaitsForConfirmation() throws Exception {
        String noUI = UUID.randomUUID().toString();
        BridgeInteractionRegistry.begin(noUI, "configuration", "detail");
        BridgeInteractionRegistry.observeOptionalUI(noUI);
        assertTrue(BridgeInteractionRegistry.invocationReturned(noUI).getBoolean("terminal"));
        String withUI = UUID.randomUUID().toString();
        BridgeInteractionRegistry.begin(withUI, "immediate", "detail");
        BridgeInteractionRegistry.observeOptionalUI(withUI);
        BridgeInteractionRegistry.observeUI(withUI, new JSONObject().put("visible", true)
                .put("surfaceRequestScoped", true).put("surfaceInteractionID", withUI));
        assertFalse(BridgeInteractionRegistry.invocationReturned(withUI).getBoolean("terminal"));
        assertTrue(BridgeInteractionRegistry.confirmCompleted(withUI).getBoolean("terminal"));
    }

    public void testLinksAreSuggestionsFromExplanatoryTextOnly() throws Exception {
        JSONObject result = new JSONObject().put("list", new JSONArray().put(new JSONObject()
                .put("vod_content", "配置：http://10.0.2.17:19988/config，备用 https://example.invalid/settings?a=1&b=2")
                .put("vod_pic", "https://poster.invalid/a.png"))
                .put(new JSONObject().put("vod_content", "https://media.invalid")
                        .put("vod_play_url", "Episode$https://media.invalid/movie.mp4")));
        assertEquals(Arrays.asList("http://10.0.2.17:19988/config", "https://example.invalid/settings?a=1&b=2"),
                BridgeConfigurationWebView.linksFromResult(result));
        for (String url : new String[]{"javascript:alert(1)", "file:///etc/hosts", "intent://x", "http://u:p@localhost"}) {
            assertFalse(url, BridgeConfigurationWebView.isWebURL(url));
        }
    }

    public void testWebLinksRequireObservedCurrentInteraction() throws Exception {
        String id = UUID.randomUUID().toString();
        BridgeInteractionRegistry.begin(id, "configuration", "detail");
        BridgeInteractionRegistry.observeOptionalUI(id);
        BridgeInteractionRegistry.setWebLinks(id, Arrays.asList("http://127.0.0.1:1234/config"));
        assertNull(BridgeInteractionRegistry.webLink(id, 0));
        BridgeInteractionRegistry.observeUI(id, new JSONObject().put("visible", true));
        assertEquals("http://127.0.0.1:1234/config", BridgeInteractionRegistry.webLink(id, 0));
        assertNull(BridgeInteractionRegistry.webLink(id, -1));
        assertNull(BridgeInteractionRegistry.webLink(id, 1));
        BridgeInteractionRegistry.begin(UUID.randomUUID().toString(), "configuration", "detail");
        assertNull(BridgeInteractionRegistry.webLink(id, 0));
    }

    public void testWebEntryRequiresMatchingClickedCardURLAndForegroundScope() throws Exception {
        String url = "http://127.0.0.1:19988/config";
        JSONObject payload = new JSONObject().put("method", "detail")
                .put("monitorsAuthorization", true).put("observesOptionalUI", true)
                .put("configurationSelectionText", url);
        JSONObject result = new JSONObject().put("list", new JSONArray().put(new JSONObject()
                .put("vod_content", "Open configuration: " + url)));
        assertEquals(url, BridgeConfigurationWebView.selectedWebLink(payload, result));
        payload.put("method", "action");
        assertEquals(url, BridgeConfigurationWebView.selectedWebLink(payload, result));
        payload.put("method", "play");
        assertNull(BridgeConfigurationWebView.selectedWebLink(payload, result));
        payload.put("method", "detail").remove("configurationSelectionText");
        assertNull(BridgeConfigurationWebView.selectedWebLink(payload, result));
        payload.put("configurationSelectionText", "http://127.0.0.1:19988/unrelated");
        assertNull(BridgeConfigurationWebView.selectedWebLink(payload, result));
        payload.put("configurationSelectionText", url + " https://example.invalid/ambiguous");
        assertNull(BridgeConfigurationWebView.selectedWebLink(payload, result));
        payload.put("configurationSelectionText", url).put("monitorsAuthorization", false);
        assertNull(BridgeConfigurationWebView.selectedWebLink(payload, result));
    }

    public void testExplicitWebEntryOpensOwnedBrowserBeforeWorkerCanComplete() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        String url = "http://127.0.0.1:9978/health";
        JSONObject result = invokeFixture(new Spider() {
            @Override public String detailContent(List<String> ids) throws Exception {
                calls.incrementAndGet();
                return new JSONObject().put("list", new JSONArray().put(new JSONObject()
                        .put("vod_name", "Fallback instruction").put("vod_content", "Open " + url))).toString();
            }
        }, "configuration", "detail", url);
        String id = result.getString("interactionID");
        try {
            assertTrue(result.toString(), result.getBoolean("ok"));
            assertFalse(result.toString(), result.getJSONObject("interaction").getBoolean("terminal"));
            assertTrue(result.getJSONObject("interaction").getBoolean("expectsProviderUI"));
            Activity activity = BridgeActionActivity.currentActivity();
            Field dialog = BridgeActionActivity.class.getDeclaredField("configurationWebDialog");
            dialog.setAccessible(true);
            assertNotNull(dialog.get(activity));
            assertEquals(1, calls.get());
            assertTrue(request("/v1/interactions/" + id + "/complete", new JSONObject()).getBoolean("terminal"));
            assertEquals(1, calls.get());
        } finally { request("/v1/interactions/" + id + "/cancel", new JSONObject()); }
    }

    public void testExistingProviderDialogIsNotReplacedByWebFallback() throws Exception {
        String url = "http://127.0.0.1:9978/health";
        JSONObject result = invokeFixture(new Spider() {
            @Override public String detailContent(List<String> ids) throws Exception {
                Activity activity = (Activity) com.github.catvod.Init.context();
                activity.runOnUiThread(() -> new AlertDialog.Builder(activity)
                        .setTitle("Original provider UI").setPositiveButton("OK", null).show());
                return new JSONObject().put("list", new JSONArray().put(new JSONObject()
                        .put("vod_content", "Fallback: " + url))).toString();
            }
        }, "configuration", "detail", url);
        String id = result.getString("interactionID");
        try {
            assertFalse(result.toString(), result.getJSONObject("interaction").getBoolean("terminal"));
            assertTrue(result.getJSONObject("interaction").getBoolean("uiObserved"));
            Field dialog = BridgeActionActivity.class.getDeclaredField("configurationWebDialog");
            dialog.setAccessible(true);
            assertNull(dialog.get(BridgeActionActivity.currentActivity()));
        } finally { request("/v1/interactions/" + id + "/cancel", new JSONObject()); }
    }

    public void testDelayedConfigurationDialogIsNotRetiredAsImmediateSuccess() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        JSONObject result = invokeFixture(new Spider() {
            @Override public String detailContent(List<String> ids) throws Exception {
                calls.incrementAndGet();
                Activity activity = (Activity) com.github.catvod.Init.context();
                new Handler(Looper.getMainLooper()).postDelayed(
                        () -> new AlertDialog.Builder(activity)
                                .setTitle("Deferred source action")
                                .setPositiveButton("OK", null).show(), 750L);
                return "{\"list\":[{\"vod_name\":\"Refresh settings after completion\"}]}";
            }
        }, "configuration", "detail", "");
        String id = result.getString("interactionID");
        try {
            assertTrue(result.toString(), result.getBoolean("ok"));
            assertFalse(result.toString(), result.getJSONObject("interaction").getBoolean("terminal"));
            assertTrue(result.getJSONObject("interaction").getBoolean("uiObserved"));
            assertEquals(1, calls.get());
        } finally { request("/v1/interactions/" + id + "/cancel", new JSONObject()); }
    }

    public void testOrdinaryMovieRPCCompletesWithoutUIOrReplay() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        JSONObject result = invokeFixture(new Spider() {
            @Override public String detailContent(List<String> ids) throws Exception {
                calls.incrementAndGet();
                return new JSONObject().put("list", new JSONArray().put(new JSONObject()
                        .put("vod_id", "movie").put("vod_name", "Fixture Film")
                        .put("vod_play_from", "fixture").put("vod_play_url", "1$https://example.invalid/film.mp4"))).toString();
            }
        }, "configuration");
        assertTrue(result.toString(), result.getBoolean("ok"));
        assertEquals("completed", result.getJSONObject("interaction").getString("phase"));
        assertFalse(result.getJSONObject("interaction").getBoolean("expectsProviderUI"));
        assertEquals(1, calls.get());
    }

    public void testDetailDialogAndImmediateActionStayOwnedUntilConfirmed() throws Exception {
        for (String kind : new String[]{"configuration", "immediate"}) {
            AtomicInteger calls = new AtomicInteger();
            JSONObject result = invokeFixture(new Spider() {
                @Override public String detailContent(List<String> ids) throws Exception {
                    calls.incrementAndGet();
                    Activity activity = (Activity) com.github.catvod.Init.context();
                    new Handler(Looper.getMainLooper()).post(() -> {
                        activity.finish();
                        new Handler(Looper.getMainLooper()).postDelayed(() -> new AlertDialog.Builder(activity)
                                .setTitle("Fixture settings").setMessage("Choose an option")
                                .setPositiveButton("OK", null).show(), 80);
                    });
                    return new JSONObject().put("list", new JSONArray().put(new JSONObject()
                            .put("vod_id", "settings").put("vod_name", "Configured")
                            .put("vod_content", "http://127.0.0.1:1234/config"))).toString();
                }
            }, kind);
            String id = result.getString("interactionID");
            try {
                assertFalse(result.toString(), result.getJSONObject("interaction").getBoolean("terminal"));
                assertEquals(1, result.getJSONObject("interaction").getJSONArray("webLinks").length());
                assertTrue(request("/v1/interactions/" + id + "/complete", new JSONObject())
                        .getBoolean("terminal"));
                assertEquals(1, calls.get());
            } finally { request("/v1/interactions/" + id + "/cancel", new JSONObject()); }
        }
    }

    public void testAsyncPlaybackAuthorizationResumesSameEpisodeOnce() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        JSONObject result = invokeFixture(new Spider() {
            @Override public String playerContent(String flag, String id, List<String> vip) throws Exception {
                assertEquals("line", flag); assertEquals("episode", id);
                if (calls.incrementAndGet() == 1) {
                    Activity activity = (Activity) com.github.catvod.Init.context();
                    new Handler(Looper.getMainLooper()).postDelayed(() -> {
                        AlertDialog dialog = new AlertDialog.Builder(activity).setMessage("Fixture login").create();
                        dialog.show();
                        new Handler(Looper.getMainLooper()).postDelayed(dialog::dismiss, 900L);
                    }, 50L);
                    return "{\"msg\":\"Login required\"}";
                }
                return "{\"parse\":0,\"url\":\"https://example.invalid/authorized.mp4\"}";
            }
        }, "playback", "play");
        assertTrue(result.toString(), result.getBoolean("ok"));
        assertEquals("completed", result.getJSONObject("interaction").getString("phase"));
        assertEquals(2, calls.get());
        assertTrue(result.getJSONObject("result").getString("url").contains("authorized.mp4"));
    }

    public void testBlockingPlaybackAuthorizationReturnsOriginalResultWithoutReplay() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        JSONObject result = invokeFixture(new Spider() {
            @Override public String playerContent(String flag, String id, List<String> vip) throws Exception {
                calls.incrementAndGet();
                Activity activity = (Activity) com.github.catvod.Init.context();
                java.util.concurrent.CountDownLatch authorized = new java.util.concurrent.CountDownLatch(1);
                new Handler(Looper.getMainLooper()).post(() -> {
                    AlertDialog dialog = new AlertDialog.Builder(activity).setMessage("Fixture blocking login").create();
                    dialog.show();
                    new Handler(Looper.getMainLooper()).postDelayed(() -> { dialog.dismiss(); authorized.countDown(); }, 500L);
                });
                assertTrue(authorized.await(3, java.util.concurrent.TimeUnit.SECONDS));
                return "{\"parse\":0,\"url\":\"https://example.invalid/original.mp4\"}";
            }
        }, "playback", "play");
        assertTrue(result.toString(), result.getBoolean("ok"));
        assertEquals("completed", result.getJSONObject("interaction").getString("phase"));
        assertEquals(1, calls.get());
    }

    public void testFailedPlaybackAuthorizationDoesNotLoopOrClaimSuccess() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        JSONObject result = invokeFixture(new Spider() {
            @Override public String playerContent(String flag, String id, List<String> vip) throws Exception {
                if (calls.incrementAndGet() == 1) {
                    Activity activity = (Activity) com.github.catvod.Init.context();
                    new Handler(Looper.getMainLooper()).post(() -> {
                        AlertDialog dialog = new AlertDialog.Builder(activity).setMessage("Fixture cancelled login").create();
                        dialog.show();
                        new Handler(Looper.getMainLooper()).postDelayed(dialog::dismiss, 500L);
                    });
                }
                return "{\"msg\":\"Still not authorized\"}";
            }
        }, "playback", "play");
        assertFalse(result.toString(), result.getBoolean("ok"));
        assertEquals(2, calls.get());
    }

    public static final class AuthorizationPageSpider extends Spider {
        final AtomicInteger calls = new AtomicInteger();
        @Override public String playerContent(String flag, String id, List<String> vip) {
            if (calls.incrementAndGet() == 1) return "{\"msg\":\"[fixture](auth) login required\"}";
            return "{\"parse\":0,\"url\":\"https://example.invalid/config-authorized.mp4\"}";
        }
    }

    public static final class AuthorizationPageProxy {
        public static Object[] proxy(Map<String, String> params) {
            if (!"pan".equals(params.get("do")) || !"config".equals(params.get("action"))) return null;
            String page = "<!doctype html><html><body>Fixture account configuration</body></html>";
            return new Object[]{200, "text/html; charset=utf-8", new java.io.ByteArrayInputStream(page.getBytes(StandardCharsets.UTF_8))};
        }
    }

    public void testGenericConfigurationHTMLIsNotAnAuthorizationDestination() throws Exception {
        AuthorizationPageSpider spider = new AuthorizationPageSpider();
        JSONObject result = invokeFixture(spider, "playback", "play");
        assertEquals("failed", result.getJSONObject("interaction").getString("phase"));
        assertFalse(result.getJSONObject("interaction").getBoolean("uiObserved"));
        assertEquals(1, spider.calls.get());
    }

    public void testFinishOnlyActionReturnsWithoutWaitingForNonexistentWindow() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        JSONObject result = invokeFixture(new Spider() {
            @Override public String detailContent(List<String> ids) throws Exception {
                calls.incrementAndGet();
                Activity activity = (Activity) com.github.catvod.Init.context();
                activity.runOnUiThread(activity::finish);
                return "{\"list\":[{\"vod_id\":\"clear\",\"vod_name\":\"Updated\"}]}";
            }
        }, "configuration");
        assertTrue(result.toString(), result.getBoolean("ok"));
        assertTrue(result.getJSONObject("interaction").getBoolean("terminal"));
        assertFalse(result.getJSONObject("interaction").getBoolean("uiObserved"));
        assertEquals("providerFinished", result.getString("selectionEffect"));
        assertEquals(1, calls.get());
    }

    public void testAuthContractRejectsRegistrationAndAmbiguousCandidates() throws Exception {
        assertEquals("quark", TVBoxAuthorizationRoute.realm(new JSONObject().put("msg", "[quark](auth) required")));
        assertFalse(TVBoxAuthorizationRoute.advertisesLogin("quark", new JSONObject().put("list",
            new JSONArray().put(new JSONObject().put("vod_id", "qkregister").put("vod_name", "夸克扫码登录")))));
        JSONObject candidate = new JSONObject().put("siteKey", "random").put("api", "csp_PanConfigGuard");
        assertNull(TVBoxAuthorizationRoute.candidate(new JSONObject().put("authorizationSites",
            new JSONArray().put(candidate).put(candidate))));
        assertNull(TVBoxAuthorizationRoute.candidate(new JSONObject().put("authorizationSites",
            new JSONArray().put(new JSONObject().put("siteKey", "random").put("api", "csp_Unrelated")))));
    }

    private static final class NativeLoginSpider extends Spider {
        final AtomicInteger calls = new AtomicInteger();
        volatile boolean loggedIn;
        volatile boolean repeatedBeforeLogin;
        @Override public String playerContent(String flag, String id, List<String> vip) {
            assertEquals("line", flag); assertEquals("episode", id);
            if (calls.incrementAndGet() > 1 && !loggedIn) repeatedBeforeLogin = true;
            return loggedIn ? "{\"url\":\"https://example.invalid/verified.mp4\",\"parse\":0}"
                : "{\"msg\":\"[quark](auth) login required\"}";
        }
    }

    public void testTargetedNativeLoginKeepsParentOwnerAndDoesNotPollPlayback() throws Exception {
        NativeLoginSpider spider = new NativeLoginSpider();
        JSONObject result = invokeFixture(spider, "playback", "play");
        assertTrue(result.toString(), result.getBoolean("ok"));
        assertTrue(spider.loggedIn);
        assertFalse(spider.repeatedBeforeLogin);
        assertEquals(2, spider.calls.get());
    }

    public void testLocalizedCookieErrorIsNotAnAuthorizationProtocol() throws Exception {
        assertTrue(!TVBoxAuthorizationRoute.realm(new JSONObject().put("msg", "[any-realm](auth) credential required")).isEmpty());
        assertFalse(!TVBoxAuthorizationRoute.realm(new JSONObject().put("msg", "缺少 Cookie，请登录")).isEmpty());
        assertFalse(!TVBoxAuthorizationRoute.realm(new JSONObject().put("msg", "[fixture](network) unavailable")).isEmpty());
    }

    public void testCancelledPlaybackAuthorizationDoesNotRetry() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        JSONObject result = invokeFixture(new Spider() {
            @Override public String playerContent(String flag, String id, List<String> vip) {
                calls.incrementAndGet();
                Activity activity = (Activity) com.github.catvod.Init.context();
                String interaction = BridgeInteractionRegistry.latestID();
                new Handler(Looper.getMainLooper()).post(() -> {
                    new AlertDialog.Builder(activity).setMessage("Fixture login").show();
                    new Handler(Looper.getMainLooper()).postDelayed(() -> {
                        BridgeInteractionRegistry.cancel(interaction);
                        BridgeServer.releaseTerminalInteraction(activity, interaction);
                    }, 500L);
                });
                return "{\"msg\":\"Login required\"}";
            }
        }, "playback", "play");
        assertFalse(result.toString(), result.getBoolean("ok"));
        assertEquals(1, calls.get());
    }

    public static final class ProxyFixture {
        static Map<String, String> last;
        public static Object[] proxy(Map<String, String> params) {
            last = new java.util.LinkedHashMap<>(params);
            return new Object[]{200, "text/plain", new java.io.ByteArrayInputStream("saved".getBytes(StandardCharsets.UTF_8))};
        }
    }

    @SuppressWarnings("unchecked")
    public void testConfigurationProxyPreservesFormAndRejectsExpiredOrAnonymousRequests() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        String id = UUID.randomUUID().toString();
        String jar = "https://fixture.invalid/config-" + id;
        BridgeInteractionRegistry.begin(id, "configuration", "detail");
        BridgeProviderOwnerRegistry.bind(new JSONObject().put("configurationID", id)
                .put("providerOwnerID", id).put("siteKey", "form").put("interactionID", id), jar);
        Field field = DexSpiderRegistry.class.getDeclaredField("proxyMethods"); field.setAccessible(true);
        Map<String, java.lang.reflect.Method> methods = (Map<String, java.lang.reflect.Method>) field.get(DexSpiderRegistry.get(context));
        methods.put(jar, ProxyFixture.class.getMethod("proxy", Map.class));
        try {
            BridgeConfigurationProxy.prepare(context, id);
            String endpoint = "http://127.0.0.1:" + FongMiCompatProxyServer.port() + "/proxy?do=fixture";
            String cookie = android.webkit.CookieManager.getInstance().getCookie(endpoint);
            assertNotNull(cookie);
            assertEquals(200, proxyRequest(endpoint, cookie));
            assertEquals("fixture", ProxyFixture.last.get("do"));
            assertEquals("one two", ProxyFixture.last.get("value"));
            assertEquals(410, proxyRequest(endpoint, null));
            assertEquals(410, proxyRequest(endpoint, BridgeConfigurationProxy.COOKIE + "=wrong"));
            String guest = "http://" + com.github.catvod.utils.Util.getIp() + ":" + FongMiCompatProxyServer.port() + "/proxy?do=fixture";
            assertEquals(200, proxyRequest(guest, android.webkit.CookieManager.getInstance().getCookie(guest)));
            BridgeInteractionRegistry.begin(UUID.randomUUID().toString(), "configuration", "detail");
            assertEquals(410, proxyRequest(endpoint, cookie));
        } finally {
            BridgeConfigurationProxy.release(id);
            BridgeProviderOwnerRegistry.releaseInteraction(id);
            methods.remove(jar);
        }
    }

    private int proxyRequest(String endpoint, String cookie) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(endpoint).openConnection();
        connection.setConnectTimeout(3000); connection.setReadTimeout(3000);
        connection.setRequestMethod("POST"); connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
        if (cookie != null) connection.setRequestProperty("Cookie", cookie);
        try {
            connection.getOutputStream().write("value=one+two".getBytes(StandardCharsets.UTF_8));
            return connection.getResponseCode();
        } finally { connection.disconnect(); }
    }

    @SuppressWarnings("unchecked")
    private JSONObject invokeFixture(Spider spider, String kind) throws Exception {
        return invokeFixture(spider, kind, "detail");
    }

    @SuppressWarnings("unchecked")
    private JSONObject invokeFixture(Spider spider, String kind, String method) throws Exception {
        return invokeFixture(spider, kind, method, null);
    }

    @SuppressWarnings("unchecked")
    private JSONObject invokeFixture(Spider spider, String kind, String method, String selectionText) throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        BridgeServer.start(context);
        String id = UUID.randomUUID().toString();
        String jar = "https://fixture.invalid/" + id + ".jar";
        DexSpiderRegistry registry = DexSpiderRegistry.get(context);
        Field field = DexSpiderRegistry.class.getDeclaredField("spiders"); field.setAccessible(true);
        Map<String, Spider> spiders = (Map<String, Spider>) field.get(registry);
        spiders.put(jar + ":fixture", spider);
        Field proxyField = DexSpiderRegistry.class.getDeclaredField("proxyMethods"); proxyField.setAccessible(true);
        Map<String, java.lang.reflect.Method> proxies = (Map<String, java.lang.reflect.Method>) proxyField.get(registry);
        if (spider instanceof AuthorizationPageSpider) proxies.put(jar, AuthorizationPageProxy.class.getMethod("proxy", Map.class));
        JSONArray candidates = new JSONArray();
        if (spider instanceof NativeLoginSpider) {
            NativeLoginSpider playback = (NativeLoginSpider) spider;
            candidates.put(new JSONObject().put("siteKey", "settings").put("api", "csp_PanConfigGuard"));
            spiders.put(jar + ":settings", new Spider() {
                @Override public String categoryContent(String realm, String page, boolean filter, java.util.HashMap<String,String> ext) {
                    assertEquals("quark", realm);
                    return "{\"list\":[{\"vod_id\":\"qkregister\"},{\"vod_id\":\"quark\"},{\"vod_id\":\"quarkmanual\"},{\"vod_id\":\"quarkclear\"}]}";
                }
                @Override public String detailContent(List<String> ids) {
                    assertEquals(java.util.Collections.singletonList("quark"), ids);
                    assertEquals("fixture", BridgeProviderOwnerRegistry.binding(id).siteKey);
                    Activity activity = (Activity) com.github.catvod.Init.context();
                    activity.runOnUiThread(() -> {
                        AlertDialog dialog = new AlertDialog.Builder(activity).setTitle("Quark login").setMessage("Scan to authorize").create();
                        dialog.show();
                        new Handler(Looper.getMainLooper()).postDelayed(() -> {
                            playback.loggedIn = true; dialog.dismiss();
                        }, 3500L);
                    });
                    return "{\"list\":[{}]}";
                }
            });
        }
        try {
            return request("/v1/invoke", new JSONObject().put("configurationID", id)
                    .put("authorizationSites", candidates)
                    .put("configurationSelectionText", selectionText)
                    .put("providerOwnerID", id).put("siteKey", "fixture").put("jarURL", jar)
                    .put("api", "csp_Fixture").put("method", method)
                    .put("arguments", "play".equals(method)
                            ? new JSONArray().put("line").put("episode").put(new JSONArray())
                            : new JSONArray().put(new JSONArray().put("id")))
                    .put("monitorsAuthorization", true).put("observesOptionalUI", true)
                    .put("interactionID", id).put("interactionKind", kind));
        } finally { spiders.remove(jar + ":fixture"); spiders.remove(jar + ":settings"); proxies.remove(jar); }
    }

    private JSONObject request(String path, JSONObject body) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL("http://127.0.0.1:9978" + path).openConnection();
        connection.setConnectTimeout(5000); connection.setReadTimeout(10000);
        connection.setRequestMethod("POST"); connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        try {
            connection.getOutputStream().write(body.toString().getBytes(StandardCharsets.UTF_8));
            java.io.InputStream stream = connection.getResponseCode() == 200
                    ? connection.getInputStream() : connection.getErrorStream();
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[4096]; int length;
            while ((length = stream.read(buffer)) != -1) out.write(buffer, 0, length);
            return new JSONObject(out.toString("UTF-8"));
        } finally { connection.disconnect(); }
    }
}
