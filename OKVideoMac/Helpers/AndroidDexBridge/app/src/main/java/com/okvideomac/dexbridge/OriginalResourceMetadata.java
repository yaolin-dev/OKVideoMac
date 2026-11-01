package com.okvideomac.dexbridge;

import com.google.gson.*;

/** A narrow adapter for verified WoGG cloud-file payloads. Never persists tokens. */
final class OriginalResourceMetadata {
    private OriginalResourceMetadata() {}

    static String annotate(String api, String raw) {
        if (!("csp_WoGGGuard".equals(api) || "csp_WoGG".equals(api)) || raw == null) return raw;
        try {
            JsonObject root = JsonParser.parseString(raw).getAsJsonObject();
            JsonArray list = root.getAsJsonArray("list");
            if (list == null) return raw;
            for (JsonElement item : list) {
                if (!item.isJsonObject()) continue;
                JsonObject video = item.getAsJsonObject();
                String playlist = text(video, "vod_play_url");
                if (playlist == null) continue;
                JsonArray groups = new JsonArray();
                for (String group : playlist.split("\\$\\$\\$", -1)) {
                    JsonArray files = new JsonArray();
                    for (String episode : group.split("#", -1)) {
                        if (episode.isEmpty()) continue;
                        int split = episode.indexOf('$');
                        String token = split >= 0 ? episode.substring(split + 1) : episode;
                        if (token.isEmpty()) continue;
                        JsonObject metadata = extract(token);
                        files.add(metadata == null ? JsonNull.INSTANCE : metadata);
                    }
                    // Mirror PlayListParser's omission of empty sources.
                    if (files.size() > 0) groups.add(files);
                }
                video.add("okvideo_original_resources", groups);
            }
            return root.toString();
        } catch (RuntimeException invalid) { return raw; }
    }

    static JsonObject extract(String token) {
        try {
            if (token.length() > 32768 || !token.startsWith("{")) return null;
            JsonObject input = JsonParser.parseString(token).getAsJsonObject();
            JsonObject output = new JsonObject();
            String flag = text(input, "flag");
            if ("嘟嘟盘".equals(flag) && "0".equals(text(input, "isdir"))) {
                if (!identity(output, input, "shareID", "share_id")
                        || !identity(output, input, "ownerID", "uk")
                        || !identity(output, input, "fileID", "fs_id")) return null;
                output.addProperty("provider", "baidu");
                output.addProperty("provenance", "wogg-baidu-detail");
                copy(output, input, "originalFilename", "server_filename");
                // The sharelink prefix is provider-generated. Keep the raw
                // value; do not invent a canonical share-relative path.
                copy(output, input, "providerPath", "path");
            } else if ("夸父盘".equals(flag)) {
                if (!identity(output, input, "shareID", "sId")
                        || !identity(output, input, "fileID", "fid")) return null;
                output.addProperty("provider", "quark");
                output.addProperty("provenance", "wogg-quark-detail");
                copy(output, input, "originalFilename", "file_name");
            } else return null;
            output.addProperty("schemaVersion", 1);
            output.addProperty("adapterVersion", 1);
            String size = text(input, "size");
            if (size != null && size.matches("[0-9]{1,18}")) output.addProperty("byteSize", Long.parseLong(size));
            return output;
        } catch (RuntimeException invalid) { return null; }
    }

    private static boolean identity(JsonObject out, JsonObject in, String target, String key) {
        String value = text(in, key);
        if (value == null || !value.matches("[a-zA-Z0-9_.-]{1,512}")) return false;
        out.addProperty(target, value); return true;
    }
    private static void copy(JsonObject out, JsonObject in, String target, String key) {
        String value = text(in, key);
        if (value != null && !value.isEmpty() && value.length() <= 8192 && !value.contains("://") && value.indexOf('\0') < 0)
            out.addProperty(target, value);
    }
    private static String text(JsonObject object, String key) {
        JsonElement value = object.get(key);
        return value != null && value.isJsonPrimitive() ? value.getAsString() : null;
    }
}
