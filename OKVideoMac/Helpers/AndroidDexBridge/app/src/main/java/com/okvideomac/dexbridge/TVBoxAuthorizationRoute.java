package com.okvideomac.dexbridge;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Versioned PanConfig protocol adapter, not a source-name/title heuristic. */
final class TVBoxAuthorizationRoute {
    private static final Pattern AUTH = Pattern.compile("^\\[([a-zA-Z0-9_.-]+)\\]\\(auth\\).*$", Pattern.DOTALL);

    static String realm(Object result) {
        Matcher matcher = AUTH.matcher(DexSpiderRegistry.providerMessage(result));
        return matcher.matches() ? matcher.group(1) : "";
    }

    static boolean supports(String api) {
        return "csp_PanConfig".equals(api) || "csp_PanConfigGuard".equals(api);
    }

    static JSONObject candidate(JSONObject payload) throws Exception {
        JSONArray sites = payload.optJSONArray("authorizationSites");
        JSONObject match = null;
        if (sites == null || sites.length() > 16) return null;
        for (int i = 0; i < sites.length(); i++) {
            JSONObject site = sites.optJSONObject(i);
            if (site == null || !supports(site.optString("api")) || site.optString("siteKey").isEmpty()) continue;
            // Ambiguous account contexts must not choose the first account.
            if (match != null) return null;
            match = site;
        }
        return match;
    }

    static boolean advertisesLogin(String realm, Object value) {
        if (realm.isEmpty() || !(value instanceof JSONObject)) return false;
        JSONArray rows = ((JSONObject) value).optJSONArray("list");
        if (rows == null || rows.length() > 100) return false;
        int login = 0;
        boolean manual = false, clear = false;
        for (int i = 0; i < rows.length(); i++) {
            JSONObject row = rows.optJSONObject(i);
            if (row == null || !row.optString("vod_play_url").isEmpty()) return false;
            String id = row.optString("vod_id");
            if (realm.equals(id)) login++;
            manual |= (realm + "manual").equals(id);
            clear |= (realm + "clear").equals(id);
        }
        // This adapter's verified contract distinguishes login from register,
        // manual input and removal. Unknown shapes are never executed.
        return login == 1 && manual && clear;
    }
}
