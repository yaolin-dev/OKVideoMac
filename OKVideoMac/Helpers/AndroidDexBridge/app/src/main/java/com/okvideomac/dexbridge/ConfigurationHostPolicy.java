package com.okvideomac.dexbridge;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.locks.ReentrantReadWriteLock;
import java.util.function.Consumer;

/**
 * Applies one TVBox configuration's host aliases without merging them into
 * another configuration. A read lease remains held for the full Spider call,
 * so a configuration switch cannot replace the process-global CatVod DNS map
 * while an invocation is still resolving upstream hosts.
 */
final class ConfigurationHostPolicy {
    private final ReentrantReadWriteLock lock =
            new ReentrantReadWriteLock(true);
    private final Consumer<List<String>> replaceHosts;
    private String activeConfigurationID = "";
    private List<String> activeHosts = Collections.emptyList();

    ConfigurationHostPolicy(Consumer<List<String>> replaceHosts) {
        this.replaceHosts = Objects.requireNonNull(replaceHosts);
    }

    Lease acquire(JSONObject payload) {
        String configurationID = required(payload, "configurationID");
        List<String> hosts = hostMappings(payload.optJSONArray("hosts"));

        lock.readLock().lock();
        if (matches(configurationID, hosts)) {
            return new Lease(lock);
        }
        lock.readLock().unlock();

        lock.writeLock().lock();
        try {
            if (!matches(configurationID, hosts)) {
                replaceHosts.accept(hosts);
                activeConfigurationID = configurationID;
                activeHosts = hosts;
            }
            // Downgrade atomically: no different configuration can replace
            // the DNS map between applying it and starting this invocation.
            lock.readLock().lock();
            return new Lease(lock);
        } finally {
            lock.writeLock().unlock();
        }
    }

    private boolean matches(String configurationID, List<String> hosts) {
        return activeConfigurationID.equals(configurationID)
                && activeHosts.equals(hosts);
    }

    static List<String> hostMappings(JSONArray values) {
        if (values == null || values.length() == 0) {
            return Collections.emptyList();
        }
        ArrayList<String> result = new ArrayList<>(values.length());
        for (int index = 0; index < values.length(); index++) {
            Object value = values.opt(index);
            if (value instanceof String) result.add((String) value);
        }
        return Collections.unmodifiableList(result);
    }

    private static String required(JSONObject payload, String name) {
        String value = payload == null
                ? "" : payload.optString(name, "").trim();
        if (value.isEmpty()) {
            throw new IllegalArgumentException("Missing " + name);
        }
        return value;
    }

    static final class Lease implements AutoCloseable {
        private final ReentrantReadWriteLock lock;
        private boolean closed;

        private Lease(ReentrantReadWriteLock lock) {
            this.lock = lock;
        }

        @Override
        public void close() {
            if (closed) return;
            closed = true;
            lock.readLock().unlock();
        }
    }
}
