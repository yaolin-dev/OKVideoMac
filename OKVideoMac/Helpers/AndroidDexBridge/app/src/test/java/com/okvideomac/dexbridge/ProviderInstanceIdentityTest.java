package com.okvideomac.dexbridge;

import org.junit.Test;
import static org.junit.Assert.*;

public class ProviderInstanceIdentityTest {
    @Test public void everyInitializationInputOwnsItsInstanceAndSecretsAreHashed() {
        String[] input = {"config", "site", "csp_Fixture", "private-token", "jar", "md5", "hosts"};
        String expected = ProviderInstanceIdentity.key(input);
        assertEquals(expected, ProviderInstanceIdentity.key(input.clone()));
        assertFalse(expected.contains("private-token"));
        for (int i = 0; i < input.length; i++) {
            String[] changed = input.clone(); changed[i] += "-changed";
            assertNotEquals("input " + i, expected, ProviderInstanceIdentity.key(changed));
        }
        assertNotEquals(ProviderInstanceIdentity.key("a:b", "c"), ProviderInstanceIdentity.key("a", "b:c"));
    }
}
