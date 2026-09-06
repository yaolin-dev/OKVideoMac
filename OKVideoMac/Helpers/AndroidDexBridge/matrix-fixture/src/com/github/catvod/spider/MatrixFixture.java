package com.github.catvod.spider;

import android.content.Context;

import com.github.catvod.crawler.Spider;

/**
 * Deterministic, network-independent Spider used only by the managed Runtime
 * candidate matrix. It proves that the candidate can download a JAR from the
 * Mac host, load its DEX, construct a CatVod Spider, supply a real Android
 * Context, invoke it, and return structured data through BridgeServer.
 */
public final class MatrixFixture extends Spider {
    private String runtimeAPI = "missing";

    @Override
    public void init(Context context, String extend) {
        if (context == null) {
            throw new IllegalStateException("Matrix fixture received no Context");
        }
        runtimeAPI = String.valueOf(android.os.Build.VERSION.SDK_INT);
    }

    @Override
    public String homeContent(boolean filter) {
        return "{"
                + "\"class\":[{\"type_id\":\"matrix\","
                + "\"type_name\":\"Runtime Matrix\"}],"
                + "\"list\":[{\"vod_id\":\"api-" + runtimeAPI + "\","
                + "\"vod_name\":\"OKVideoMac Matrix PASS\","
                + "\"vod_remarks\":\"DEX invoked\"}]"
                + "}";
    }
}
