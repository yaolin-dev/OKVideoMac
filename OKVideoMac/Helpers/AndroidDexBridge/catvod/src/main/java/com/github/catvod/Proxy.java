package com.github.catvod;

import com.github.catvod.utils.Util;

public class Proxy {

    // Match OK/FongMi's CatVod host contract. A number of protected spiders
    // call Proxy.getUrl(...) during home/category work, before the host has an
    // opportunity to override the port. Returning -1 here poisons those
    // internal requests and is not a valid TCP endpoint.
    private static int port = 9978;

    public static void set(int port) {
        Proxy.port = port;
    }

    public static int getPort() {
        return port;
    }

    public static String getUrl(boolean local) {
        return "http://" + (local ? "127.0.0.1" : Util.getIp()) + ":" + getPort() + "/proxy";
    }
}
