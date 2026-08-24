package com.okvideomac.dexbridge;

import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Comparator;

/**
 * Produces an opaque fingerprint of provider-owned Android preferences.
 *
 * <p>Legacy CatVod providers usually persist a successful QR authorization in
 * one of the application SharedPreferences XML files, but they do not publish
 * a completion callback and may leave the QR dialog visible forever. The
 * bridge returns only this digest; preference names and credential values
 * never leave Android. A change is a request-scoped hint that the macOS host
 * must combine with the exact account/QR context before it verifies success.</p>
 */
final class BridgeAuthorizationStorageFingerprint {
    private static final int MAX_FILES = 64;
    private static final long MAX_FILE_BYTES = 2L * 1024L * 1024L;

    private BridgeAuthorizationStorageFingerprint() {
    }

    static String capture(Context context) {
        if (context == null) return "";
        try {
            File directory = new File(
                    context.getApplicationInfo().dataDir,
                    "shared_prefs"
            );
            File[] files = directory.listFiles((ignored, name) ->
                    name != null && name.endsWith(".xml")
            );
            if (files == null) files = new File[0];
            Arrays.sort(files, Comparator.comparing(File::getName));
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[16 * 1024];
            int count = Math.min(files.length, MAX_FILES);
            for (int index = 0; index < count; index++) {
                File file = files[index];
                digest.update(file.getName().getBytes(StandardCharsets.UTF_8));
                digest.update((byte) 0);
                long remaining = Math.min(file.length(), MAX_FILE_BYTES);
                try (FileInputStream input = new FileInputStream(file)) {
                    while (remaining > 0) {
                        int read = input.read(
                                buffer,
                                0,
                                (int) Math.min(buffer.length, remaining)
                        );
                        if (read <= 0) break;
                        digest.update(buffer, 0, read);
                        remaining -= read;
                    }
                }
                digest.update((byte) 0xff);
            }
            StringBuilder value = new StringBuilder(64);
            for (byte item : digest.digest()) {
                value.append(String.format("%02x", item & 0xff));
            }
            return value.toString();
        } catch (Throwable ignored) {
            return "";
        }
    }
}
