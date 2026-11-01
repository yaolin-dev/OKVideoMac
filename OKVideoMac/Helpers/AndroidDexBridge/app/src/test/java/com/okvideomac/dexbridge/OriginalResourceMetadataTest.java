package com.okvideomac.dexbridge;

import com.google.gson.*;
import org.junit.Test;
import static org.junit.Assert.*;

public class OriginalResourceMetadataTest {
    static String file(String id, String token) {
        return "{\"flag\":\"嘟嘟盘\",\"isdir\":\"0\",\"share_id\":\"share1\",\"uk\":\"owner1\",\"fs_id\":\"" + id
            + "\",\"server_filename\":\"S01E13.mp4\",\"path\":\"%2Fsharelink0-123%2Ffolder%2FS01E13.mp4\",\"size\":1571407203,\"seKey\":\"" + token + "\"}";
    }
    @Test public void extractsOriginalFieldsWithoutPersistingAuthorization() {
        JsonObject value = OriginalResourceMetadata.extract(file("9007199254740993", "SECRET"));
        assertEquals("9007199254740993", value.get("fileID").getAsString());
        assertEquals("S01E13.mp4", value.get("originalFilename").getAsString());
        assertEquals(1571407203L, value.get("byteSize").getAsLong());
        assertFalse(value.toString().contains("SECRET"));
        assertFalse(value.has("shareRelativePath"));
        assertEquals(value, OriginalResourceMetadata.extract(file("9007199254740993", "REFRESHED")));
        assertNotEquals(value, OriginalResourceMetadata.extract(file("different-file", "SECRET")));
    }
    @Test public void ignoresUnknownFormatsAndPreservesPlaylistBytes() {
        assertNull(OriginalResourceMetadata.extract("第13集.mp4"));
        assertNull(OriginalResourceMetadata.extract("{\"file_name\":\"E13.mp4\"}"));
        JsonObject video = new JsonObject();
        String playlist = "Display only$" + file("file1", "SECRET") + "#Bad$opaque$$$Other$" + file("file2", "TOKEN");
        video.addProperty("vod_play_url", playlist);
        JsonArray list = new JsonArray(); list.add(video);
        JsonObject root = new JsonObject(); root.add("list", list);
        String raw = root.toString();
        assertEquals(raw, OriginalResourceMetadata.annotate("unknown", raw));
        JsonObject annotated = JsonParser.parseString(OriginalResourceMetadata.annotate("csp_WoGGGuard", raw)).getAsJsonObject()
            .getAsJsonArray("list").get(0).getAsJsonObject();
        assertEquals(playlist, annotated.get("vod_play_url").getAsString());
        JsonArray groups = annotated.getAsJsonArray("okvideo_original_resources");
        assertEquals(2, groups.size());
        assertTrue(groups.get(0).getAsJsonArray().get(1).isJsonNull());
        assertEquals("file2", groups.get(1).getAsJsonArray().get(0).getAsJsonObject().get("fileID").getAsString());
    }
}
