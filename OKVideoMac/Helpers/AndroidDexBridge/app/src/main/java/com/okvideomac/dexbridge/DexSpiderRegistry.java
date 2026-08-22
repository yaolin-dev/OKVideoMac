package com.okvideomac.dexbridge;

import android.content.Context;

import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import dalvik.system.DexClassLoader;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

final class DexSpiderRegistry {
    private static final long PLAYBACK_HANDOFF_CACHE_MS = 30_000L;
    private static volatile DexSpiderRegistry instance;

    private final Context context;
    private final OkHttpClient httpClient;
    private final Map<String, DexClassLoader> loaders = new ConcurrentHashMap<>();
    private final Map<String, Spider> spiders = new ConcurrentHashMap<>();
    private final Map<String, Method> proxyMethods = new ConcurrentHashMap<>();
    private final Map<String, Object> spiderLocks = new ConcurrentHashMap<>();
    private final Map<String, Object> loaderLocks = new ConcurrentHashMap<>();
    private final Map<String, PlaybackLock> playbackLocks =
            new ConcurrentHashMap<>();
    private final Map<String, CachedPlayback> completedPlaybacks =
            new ConcurrentHashMap<>();

    private DexSpiderRegistry(Context context) {
        this.context = context.getApplicationContext();
        this.httpClient = new OkHttpClient.Builder()
                .followRedirects(true)
                .followSslRedirects(true)
                .build();
    }

    static DexSpiderRegistry get(Context context) {
        if (instance == null) {
            synchronized (DexSpiderRegistry.class) {
                if (instance == null) instance = new DexSpiderRegistry(context);
            }
        }
        return instance;
    }

    Object invoke(JSONObject payload) throws Exception {
        String method = requireString(payload, "method");
        JSONArray arguments = payload.optJSONArray("arguments");
        if (arguments == null) arguments = new JSONArray();
        if ("destroy".equals(method)) {
            String siteKey = requireString(payload, "siteKey");
            String key = spiderKey(payload, siteKey);
            Spider removed = spiders.remove(key);
            if (removed != null) removed.destroy();
            completedPlaybacks.keySet().removeIf(
                    item -> item.startsWith(key + "\u0000")
            );
            return JSONObject.NULL;
        }
        BridgeProviderOwnerRegistry.Binding providerOwner =
                BridgeProviderOwnerRegistry.bind(payload, jarKey(payload));
        Spider spider = spider(payload);
        if (requiresDialogHandoff(payload, method)) {
            BridgeActivity.prepareDialogHandoff(
                    context,
                    payload.optString("interactionID", "")
            );
        }
        if ("play".equals(method)) {
            return invokePlayer(payload, spider, arguments, providerOwner);
        }
        String raw;
        switch (method) {
            case "init":
                return new JSONObject();
            case "home":
                raw = spider.homeContent(arguments.optBoolean(0, true));
                break;
            case "homeVod":
                raw = spider.homeVideoContent();
                break;
            case "category":
                raw = spider.categoryContent(
                        arguments.getString(0),
                        arguments.optString(1, "1"),
                        arguments.optBoolean(2, false),
                        stringMap(arguments.optJSONObject(3))
                );
                break;
            case "detail":
                raw = spider.detailContent(stringList(arguments, 0));
                break;
            case "search":
                if (arguments.length() > 2) {
                    raw = spider.searchContent(
                            arguments.getString(0),
                            arguments.optBoolean(1, false),
                            arguments.optString(2, "1")
                    );
                } else {
                    raw = spider.searchContent(
                            arguments.getString(0),
                            arguments.optBoolean(1, false)
                    );
                }
                break;
            case "live":
                raw = spider.liveContent(arguments.getString(0));
                break;
            case "action":
                raw = spider.action(arguments.getString(0));
                break;
            default:
                throw new IllegalArgumentException("Unsupported method: " + method);
        }
        return decodeRawResult(raw);
    }

    static boolean requiresDialogHandoff(
            JSONObject payload,
            String method
    ) {
        if (!"detail".equals(method)
                && !"action".equals(method)
                && !"play".equals(method)) {
            return false;
        }
        // The host owns action semantics and sends these request-scoped
        // signals. A monitored request is not automatically a UI request:
        // explicit command/immediate actions must be allowed to return without
        // creating a disposable Activity or entering the provider-UI grace
        // period. All other interactive kinds may hand off to provider UI.
        // Never infer this behavior from source keys, API class names,
        // domains, localized labels, or provider names.
        if (!payload.optBoolean("monitorsAuthorization", false)) return false;
        String interactionKind = payload
                .optString("interactionKind", "")
                .trim()
                .toLowerCase(Locale.ROOT);
        return !"command".equals(interactionKind)
                && !"immediate".equals(interactionKind);
    }

    private Object invokePlayer(
            JSONObject payload,
            Spider spider,
            JSONArray arguments,
            BridgeProviderOwnerRegistry.Binding providerOwner
    ) throws Exception {
        String siteKey = requireString(payload, "siteKey");
        String playbackKey = spiderKey(payload, siteKey)
                + "\u0000" + arguments.optString(0, "")
                + "\u0000" + arguments.optString(1, "");
        boolean refreshRequested = requestsPlaybackRefresh(payload);
        JSONObject siteHeaders = payload.optJSONObject("siteHeaders");
        if (refreshRequested) completedPlaybacks.remove(playbackKey);
        String cached = refreshRequested
                ? null
                : takeCompletedPlayback(playbackKey);
        if (cached != null) {
            return decodePlaybackResult(
                    cached,
                    false,
                    siteHeaders,
                    providerOwner
            );
        }

        PlaybackLock lock = retainPlaybackLock(playbackKey);
        try {
            synchronized (lock) {
                // The original Mac request remains inside playerContent while
                // an Android login dialog is visible. A non-refresh retry may
                // consume that completed handoff. A true same-resource refresh
                // always bypasses it so an expiring signature is regenerated.
                // Repeat the invalidation while holding the per-resource lock:
                // a normal invocation that was already in flight may have
                // populated the handoff cache after the optimistic removal
                // above.
                if (refreshRequested) completedPlaybacks.remove(playbackKey);
                cached = refreshRequested
                        ? null
                        : takeCompletedPlayback(playbackKey);
                if (cached != null) {
                    return decodePlaybackResult(
                            cached,
                            false,
                            siteHeaders,
                            providerOwner
                    );
                }
                String raw = spider.playerContent(
                        arguments.getString(0),
                        arguments.getString(1),
                        stringList(arguments, 2)
                );
                if (!refreshRequested && isPlayableResponse(raw)) {
                    completedPlaybacks.put(
                            playbackKey,
                            new CachedPlayback(raw == null ? "" : raw)
                    );
                }
                return decodePlaybackResult(
                        raw,
                        refreshRequested,
                        siteHeaders,
                        providerOwner
                );
            }
        } finally {
            releasePlaybackLock(playbackKey, lock);
        }
    }

    /**
     * Retains the per-resource lock before waiting on its monitor. Removing a
     * bare monitor as soon as its current owner exits lets a third caller
     * create a different monitor while a second caller is still queued on the
     * old one. The retain count keeps every waiter on the same monitor and
     * still allows unused playback keys to be reclaimed.
     */
    private PlaybackLock retainPlaybackLock(String playbackKey) {
        return playbackLocks.compute(playbackKey, (ignored, existing) -> {
            PlaybackLock retained = existing == null
                    ? new PlaybackLock()
                    : existing;
            retained.retainCount++;
            return retained;
        });
    }

    private void releasePlaybackLock(String playbackKey, PlaybackLock lock) {
        playbackLocks.compute(playbackKey, (ignored, current) -> {
            if (current != lock) return current;
            current.retainCount--;
            return current.retainCount == 0 ? null : current;
        });
    }

    static boolean requestsPlaybackRefresh(JSONObject payload) {
        return payload != null
                && (payload.optBoolean("refreshPlayback", false)
                || payload.optBoolean("bypassPlaybackCache", false)
                || payload.optBoolean("refreshRequested", false));
    }

    private static Object decodePlaybackResult(
            String raw,
            boolean refreshPerformed,
            JSONObject siteHeaders,
            BridgeProviderOwnerRegistry.Binding providerOwner
    ) {
        return BridgeMediaSessionRegistry.securePlaybackResult(
                decodeRawResult(raw),
                refreshPerformed,
                siteHeaders,
                providerOwner
        );
    }

    /**
     * Only successful handoffs may be replayed. Provider errors such as a
     * missing cloud cookie must never survive a subsequent login attempt.
     */
    static boolean isPlayableResponse(String raw) {
        if (raw == null || raw.trim().isEmpty()) return false;
        try {
            Object value = new JSONTokener(raw).nextValue();
            return isPlayableResult(value);
        } catch (Throwable ignored) {
            return false;
        }
    }

    /** Provider-neutral structural check used by the interaction lifecycle. */
    static boolean isPlayableResult(Object value) {
        if (!(value instanceof JSONObject)) return false;
        JSONObject object = (JSONObject) value;
        Object url = object.opt("url");
        if (url instanceof String) {
            return !((String) url).trim().isEmpty();
        }
        if (url instanceof JSONArray) {
            JSONArray urls = (JSONArray) url;
            // FongMi UrlAdapter uses alternating quality-name/URL pairs.
            for (int index = 1; index < urls.length(); index += 2) {
                if (!urls.optString(index, "").trim().isEmpty()) return true;
            }
        }
        if (url instanceof JSONObject) {
            JSONObject urlObject = (JSONObject) url;
            JSONArray values = urlObject.optJSONArray("values");
            if (values == null || values.length() == 0) return false;
            // A persisted position can point at an unavailable smart stream
            // while another quality (usually original) is valid.
            for (int index = 0; index < values.length(); index++) {
                JSONObject item = values.optJSONObject(index);
                if (item != null && !item.optString("v", "").trim().isEmpty()) {
                    return true;
                }
            }
        }
        return false;
    }

    private String takeCompletedPlayback(String key) {
        CachedPlayback cached = completedPlaybacks.remove(key);
        if (cached == null) return null;
        if (System.currentTimeMillis() - cached.createdAt
                > PLAYBACK_HANDOFF_CACHE_MS) {
            return null;
        }
        return cached.raw;
    }

    private static Object decodeRawResult(String raw) {
        if (raw == null || raw.trim().isEmpty()) return "";
        try {
            return new JSONTokener(raw).nextValue();
        } catch (Throwable ignored) {
            return raw;
        }
    }

    private static final class CachedPlayback {
        final String raw;
        final long createdAt;

        CachedPlayback(String raw) {
            this.raw = raw;
            this.createdAt = System.currentTimeMillis();
        }
    }

    private static final class PlaybackLock {
        // Access is serialized by ConcurrentHashMap.compute for this key.
        int retainCount;
    }

    Object[] proxy(
            BridgeProviderOwnerRegistry.Binding owner,
            Map<String, String> params
    ) {
        if (owner == null || owner.jarKey.isEmpty()) return null;
        // A proxy call is part of the provider capability that created it.
        // Never guess from the most recently used jar or probe every loaded
        // jar: both approaches can leak credentials/media across sites.
        return invokeProxy(proxyMethods.get(owner.jarKey), params);
    }

    boolean submitCloudCredential(JSONObject request) throws Exception {
        BridgeProviderOwnerRegistry.Binding owner =
                BridgeProviderOwnerRegistry.require(request);
        Map<String, String> params = credentialParameters(
                owner,
                request.optString("credential", "")
        );
        Object[] response = proxy(owner, params);
        if (response == null || response.length < 3
                || !(response[0] instanceof Integer)
                || !(response[2] instanceof InputStream)) {
            throw new IllegalStateException(
                    "No compatible cloud credential handler is active"
            );
        }
        int status = (Integer) response[0];
        try (InputStream ignored = (InputStream) response[2]) {
            boolean accepted = status >= 200 && status < 300;
            if (accepted) completedPlaybacks.clear();
            return accepted;
        }
    }

    static Map<String, String> credentialParameters(
            BridgeProviderOwnerRegistry.Binding owner,
            String credential
    ) throws Exception {
        if (credential == null || credential.trim().isEmpty()) {
            throw new IllegalArgumentException("Cloud credential is empty");
        }
        if (credential.getBytes(StandardCharsets.UTF_8).length > 64 * 1024) {
            throw new IllegalArgumentException("Cloud credential exceeds 64 KiB");
        }
        JSONObject submission = owner == null
                ? null
                : owner.credentialSubmission();
        if (submission == null) {
            throw new IllegalArgumentException(
                    "Interaction does not declare credential submission"
            );
        }
        String field = submission.optString("credentialField", "").trim();
        if (field.isEmpty() || field.length() > 256
                || field.indexOf('\r') >= 0 || field.indexOf('\n') >= 0) {
            throw new IllegalArgumentException("Invalid credential field");
        }
        JSONObject declared = submission.optJSONObject("parameters");
        if (declared != null && declared.length() > 32) {
            throw new IllegalArgumentException("Too many credential parameters");
        }
        Map<String, String> params = stringMap(declared);
        // FongMi's NanoHTTPD hands the Spider a decoded parameter map. This
        // bridge calls the exact owning Spider proxy directly, so retain the
        // plain request value. It is never logged or returned to the host.
        params.put(field, credential.trim());
        return params;
    }

    private Spider spider(JSONObject payload) throws Exception {
        String siteKey = requireString(payload, "siteKey");
        String key = spiderKey(payload, siteKey);
        Spider existing = spiders.get(key);
        if (existing != null) {
            return existing;
        }
        Object lock = spiderLocks.computeIfAbsent(key, ignored -> new Object());
        synchronized (lock) {
            existing = spiders.get(key);
            if (existing != null) {
                return existing;
            }
            String api = requireString(payload, "api");
            if (!api.startsWith("csp_")) {
                throw new IllegalArgumentException("Only csp_ Java/Dex APIs are allowed");
            }
            String jarKey = jarKey(payload);
            DexClassLoader loader = loader(payload, jarKey);
            Spider created;
            try {
                Class<?> type = loader.loadClass(
                        "com.github.catvod.spider." + api.substring("csp_".length())
                );
                Object value = type.getDeclaredConstructor().newInstance();
                if (!(value instanceof Spider)) {
                    throw new IllegalStateException("DEX class is not a CatVod Spider");
                }
                created = (Spider) value;
            } catch (ClassNotFoundException error) {
                // Match FongMi's JarLoader: a missing optional spider is an
                // empty provider, not a failure that poisons multi-site search.
                created = new SpiderNull();
            }
            created.siteKey = siteKey;
            created.init(hostContext(), payload.optString("ext", ""));
            spiders.put(key, created);
            return created;
        }
    }

    private DexClassLoader loader(JSONObject payload, String key) throws Exception {
        DexClassLoader existing = loaders.get(key);
        if (existing != null) return existing;
        Object lock = loaderLocks.computeIfAbsent(key, ignored -> new Object());
        synchronized (lock) {
            existing = loaders.get(key);
            if (existing != null) return existing;
            String jarURL = requireString(payload, "jarURL");
            String jarMD5 = payload.optString("jarMD5", "")
                    .trim()
                    .toLowerCase(Locale.ROOT);
            File jar = downloadJar(jarURL, jarMD5);
            File optimized = new File(context.getCodeCacheDir(), "dex");
            if (!optimized.exists() && !optimized.mkdirs()) {
                throw new IllegalStateException("Unable to create DEX cache");
            }
            DexClassLoader created = new DexClassLoader(
                    jar.getAbsolutePath(),
                    optimized.getAbsolutePath(),
                    optimized.getAbsolutePath(),
                    context.getClassLoader()
            );
            invokePackageInit(created);
            registerProxy(key, created);
            loaders.put(key, created);
            return created;
        }
    }

    private void registerProxy(String key, DexClassLoader loader) {
        try {
            Class<?> type = loader.loadClass("com.github.catvod.spider.Proxy");
            proxyMethods.put(key, type.getMethod("proxy", Map.class));
        } catch (Throwable ignored) {
            proxyMethods.remove(key);
        }
    }

    private static Object[] invokeProxy(Method method, Map<String, String> params) {
        if (method == null) return null;
        try {
            Object value = method.invoke(null, params);
            return value instanceof Object[] ? (Object[]) value : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private File downloadJar(String rawURL, String expectedMD5) throws Exception {
        String jarURL = rawURL;
        int marker = rawURL.indexOf(";md5;");
        if (marker >= 0) {
            jarURL = rawURL.substring(0, marker);
            if (expectedMD5.isEmpty()) {
                expectedMD5 = rawURL.substring(marker + 5).trim().toLowerCase(Locale.ROOT);
            }
        }
        if (!jarURL.startsWith("https://") && !jarURL.startsWith("http://")) {
            throw new IllegalArgumentException("DEX package must use HTTP/HTTPS");
        }
        String fileKey = sha256(jarURL.getBytes());
        File output = new File(new File(context.getCacheDir(), "jars"), fileKey + ".jar");
        if (output.isFile() && output.length() > 0) {
            if (expectedMD5.isEmpty() || expectedMD5.equals(md5(output))) return output;
            if (!output.delete()) throw new IllegalStateException("Unable to replace DEX cache");
        }
        File parent = output.getParentFile();
        if (!parent.exists() && !parent.mkdirs()) {
            throw new IllegalStateException("Unable to create DEX package cache");
        }
        Request request = new Request.Builder().url(jarURL).get().build();
        try (Response response = httpClient.newCall(request).execute()) {
            if (!response.isSuccessful() || response.body() == null) {
                throw new IllegalStateException("DEX download HTTP " + response.code());
            }
            long maximum = 16L * 1024L * 1024L;
            try (InputStream input = response.body().byteStream();
                 FileOutputStream file = new FileOutputStream(output)) {
                byte[] buffer = new byte[16_384];
                long total = 0;
                int count;
                while ((count = input.read(buffer)) != -1) {
                    total += count;
                    if (total > maximum) {
                        throw new IllegalStateException("DEX package exceeds 16 MiB");
                    }
                    file.write(buffer, 0, count);
                }
            }
        }
        if (!expectedMD5.isEmpty() && !expectedMD5.equals(md5(output))) {
            if (!output.delete()) output.deleteOnExit();
            throw new SecurityException("DEX package MD5 mismatch");
        }
        output.setReadOnly();
        return output;
    }

    private void invokePackageInit(DexClassLoader loader) {
        try {
            Class<?> type = loader.loadClass("com.github.catvod.spider.Init");
            Method method = type.getMethod("init", Context.class);
            // This package bootstrap explicitly casts to Application. The
            // individual Spider still receives the visible Activity below so
            // account dialogs have a valid window owner.
            method.invoke(null, context);
        } catch (ClassNotFoundException ignored) {
        } catch (Throwable error) {
            throw new IllegalStateException("DEX Init failed", error);
        }
    }

    private Context hostContext() {
        Context activity = BridgeActivity.hostContext();
        return activity == null ? context : activity;
    }

    private static String jarKey(JSONObject payload) {
        String md5 = payload.optString("jarMD5", "").trim();
        return md5.isEmpty()
                ? payload.optString("jarURL", "").trim()
                : md5.toLowerCase(Locale.ROOT);
    }

    private static String spiderKey(JSONObject payload, String siteKey) {
        return jarKey(payload) + ":" + siteKey;
    }

    private static String requireString(JSONObject object, String key) {
        String value = object.optString(key, "").trim();
        if (value.isEmpty()) throw new IllegalArgumentException("Missing " + key);
        return value;
    }

    private static HashMap<String, String> stringMap(JSONObject object) {
        HashMap<String, String> values = new HashMap<>();
        if (object == null) return values;
        for (java.util.Iterator<String> keys = object.keys(); keys.hasNext(); ) {
            String key = keys.next();
            values.put(key, object.optString(key, ""));
        }
        return values;
    }

    private static List<String> stringList(JSONArray arguments, int index) {
        ArrayList<String> values = new ArrayList<>();
        Object value = arguments.opt(index);
        if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            for (int item = 0; item < array.length(); item++) {
                values.add(array.optString(item, ""));
            }
        } else if (value != null && value != JSONObject.NULL) {
            values.add(String.valueOf(value));
        }
        return values;
    }

    private static String md5(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("MD5");
        try (InputStream input = new java.io.FileInputStream(file)) {
            byte[] buffer = new byte[16_384];
            int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        return hex(digest.digest());
    }

    private static String sha256(byte[] value) throws Exception {
        return hex(MessageDigest.getInstance("SHA-256").digest(value));
    }

    private static String hex(byte[] value) {
        StringBuilder output = new StringBuilder(value.length * 2);
        for (byte item : value) output.append(String.format(Locale.ROOT, "%02x", item));
        return output.toString();
    }
}
