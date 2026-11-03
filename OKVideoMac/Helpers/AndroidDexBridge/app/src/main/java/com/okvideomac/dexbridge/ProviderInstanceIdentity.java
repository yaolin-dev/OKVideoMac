package com.okvideomac.dexbridge;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Initialization inputs, not a navigation/interaction ID, own a Spider. */
final class ProviderInstanceIdentity {
    static String key(String... inputs) {
        try {
            MessageDigest hash = MessageDigest.getInstance("SHA-256");
            for (String input : inputs) {
                byte[] bytes = input.getBytes(StandardCharsets.UTF_8);
                hash.update(ByteBuffer.allocate(4).putInt(bytes.length).array());
                hash.update(bytes);
            }
            StringBuilder output = new StringBuilder("provider-v2:");
            for (byte value : hash.digest()) output.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
            return output.toString();
        } catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
}
