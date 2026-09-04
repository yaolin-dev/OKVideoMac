package com.github.catvod.net;

import androidx.annotation.NonNull;

import com.github.catvod.bean.Doh;
import com.github.catvod.utils.Util;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.stream.Collectors;

import okhttp3.Dns;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.dnsoverhttps.DnsOverHttps;

public class OkDns implements Dns {

    private volatile Map<String, String> map;
    private DnsOverHttps doh;

    public OkDns() {
        this.map = Collections.emptyMap();
    }

    public void setDoh(Doh item) {
        if (item.getUrl().isEmpty()) return;
        this.doh = new DnsOverHttps.Builder().client(new OkHttpClient()).url(HttpUrl.get(item.getUrl())).bootstrapDnsHosts(item.getHosts()).build();
    }

    public synchronized void clear() {
        map = Collections.emptyMap();
    }

    public synchronized void addAll(List<String> hosts) {
        HashMap<String, String> updated = new HashMap<>(map);
        updated.putAll(parse(hosts));
        map = Collections.unmodifiableMap(updated);
    }

    /** Atomically replaces aliases when the active TVBox configuration changes. */
    public synchronized void replaceAll(List<String> hosts) {
        map = Collections.unmodifiableMap(parse(hosts));
    }

    private static Map<String, String> parse(List<String> hosts) {
        return hosts.stream().filter(Objects::nonNull).map(host -> host.split("=", 2)).filter(splits -> splits.length == 2).collect(Collectors.toMap(s -> s[0].trim(), s -> s[1].trim(), (oldHost, newHost) -> newHost));
    }

    private String get(String hostname) {
        Map<String, String> snapshot = map;
        String target = snapshot.get(hostname);
        if (target != null) return target;
        for (Map.Entry<String, String> entry : snapshot.entrySet()) if (Util.containOrMatch(hostname, entry.getKey())) return entry.getValue();
        return hostname;
    }

    @NonNull
    @Override
    public List<InetAddress> lookup(@NonNull String hostname) throws UnknownHostException {
        return (doh != null ? doh : Dns.SYSTEM).lookup(get(hostname));
    }
}
