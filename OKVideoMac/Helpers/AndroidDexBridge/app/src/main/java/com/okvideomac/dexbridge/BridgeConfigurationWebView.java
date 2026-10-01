package com.okvideomac.dexbridge;

import android.app.Activity;
import android.app.Dialog;
import android.graphics.Color;
import android.net.Uri;
import android.os.Looper;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.view.Window;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** A request-owned browser: guest URLs and cookies stay inside Android. */
final class BridgeConfigurationWebView {
    private static final Pattern HTTP_LINK = Pattern.compile(
            "https?://[^\\s<>\\\"'\\p{IsHan}，。；）]+", Pattern.CASE_INSENSITIVE);

    static boolean isWebURL(String value) {
        try {
            Uri uri = Uri.parse(value);
            return ("http".equalsIgnoreCase(uri.getScheme())
                    || "https".equalsIgnoreCase(uri.getScheme()))
                    && uri.getHost() != null && !uri.getHost().isEmpty()
                    && uri.getUserInfo() == null;
        } catch (Exception ignored) { return false; }
    }

    // Extract only provider-authored explanatory text, never poster, episode,
    // cookie or arbitrary object fields. Links are suggestions, not commands;
    // opening one requires a user click in the Mac sheet or the same URL on
    // the explicitly clicked configuration card (selectedWebLink below).
    static List<String> linksFromResult(Object raw) {
        List<String> links = new ArrayList<>();
        try {
            Object value = raw instanceof String ? new JSONObject((String) raw) : raw;
            if (!(value instanceof JSONObject)) return links;
            JSONObject object = (JSONObject) value;
            collectText(object, links);
            JSONArray list = object.optJSONArray("list");
            if (list != null) {
                for (int i = 0; i < Math.min(list.length(), 16); i++) {
                    JSONObject row = list.optJSONObject(i);
                    if (row != null && row.optString("vod_play_url", "").isEmpty()) {
                        collectText(row, links);
                    }
                }
            }
        } catch (Exception ignored) { }
        return links;
    }

    /** A web entry declares its destination in the clicked card. Require the
     * exact same, unambiguous URL in the provider return; an arbitrary link in
     * a movie, login response or another settings result cannot open a page. */
    static String selectedWebLink(JSONObject payload, Object result) {
        String method = payload.optString("method", "");
        if ((!"detail".equals(method) && !"action".equals(method))
                || !DexSpiderRegistry.observesOptionalUI(payload, method)) return null;
        String text = payload.optString("configurationSelectionText", "");
        if (text.isEmpty()) return null;
        try {
            List<String> declared = linksFromResult(new JSONObject().put("content", text));
            List<String> returned = linksFromResult(result);
            return declared.size() == 1 && returned.contains(declared.get(0))
                    ? declared.get(0) : null;
        } catch (Exception ignored) { return null; }
    }

    private static void collectText(JSONObject object, List<String> links) {
        for (String key : new String[]{"vod_content", "content", "msg", "message"}) {
            String text = object.optString(key, "");
            Matcher matcher = HTTP_LINK.matcher(text.substring(0, Math.min(text.length(), 32768)));
            while (matcher.find() && links.size() < 8) {
                String url = matcher.group();
                if (isWebURL(url) && !links.contains(url)) links.add(url);
            }
        }
    }

    static void show(Activity activity, String interactionID, String url) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            activity.runOnUiThread(() -> show(activity, interactionID, url));
            return;
        }
        if (!BridgeInteractionRegistry.ownsLatest(interactionID)
                || BridgeInteractionRegistry.terminal(interactionID)
                || activity.isFinishing() || !isWebURL(url)) return;
        try {
            BridgeConfigurationProxy.prepare(activity, interactionID);
        } catch (java.io.IOException error) {
            new android.app.AlertDialog.Builder(activity).setMessage(error.getMessage())
                    .setPositiveButton(android.R.string.ok, null).show();
            return;
        }
        BridgeInteractionRegistry.expectProviderUI(interactionID);
        Dialog dialog = new Dialog(activity);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout content = new LinearLayout(activity);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setBackgroundColor(Color.WHITE);
        TextView address = new TextView(activity);
        address.setTextColor(Color.DKGRAY);
        address.setPadding(12, 8, 12, 8);
        address.setMaxLines(2);
        WebView web = new WebView(activity);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        web.setWebChromeClient(new android.webkit.WebChromeClient() {
            @Override public boolean onJsAlert(WebView view, String origin, String message,
                                               android.webkit.JsResult result) {
                new android.app.AlertDialog.Builder(activity).setMessage(message)
                        .setPositiveButton(android.R.string.ok, (d, w) -> result.confirm())
                        .setOnCancelListener(d -> result.cancel()).show();
                return true;
            }
            @Override public boolean onJsConfirm(WebView view, String origin, String message,
                                                 android.webkit.JsResult result) {
                new android.app.AlertDialog.Builder(activity).setMessage(message)
                        .setPositiveButton(android.R.string.ok, (d, w) -> result.confirm())
                        .setNegativeButton(android.R.string.cancel, (d, w) -> result.cancel())
                        .setOnCancelListener(d -> result.cancel()).show();
                return true;
            }
            @Override public boolean onJsPrompt(WebView view, String origin, String message,
                                                String initial, android.webkit.JsPromptResult result) {
                android.widget.EditText input = new android.widget.EditText(activity);
                input.setText(initial);
                new android.app.AlertDialog.Builder(activity).setMessage(message).setView(input)
                        .setPositiveButton(android.R.string.ok, (d, w) -> result.confirm(input.getText().toString()))
                        .setNegativeButton(android.R.string.cancel, (d, w) -> result.cancel())
                        .setOnCancelListener(d -> result.cancel()).show();
                return true;
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return !isWebURL(request.getUrl().toString());
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, String next) {
                return !isWebURL(next);
            }
            @Override public void onPageStarted(WebView view, String next, android.graphics.Bitmap icon) {
                // Display origin only, avoiding account tokens in the toolbar.
                Uri uri = Uri.parse(next);
                address.setText(uri.getScheme() + "://" + uri.getAuthority());
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request,
                                                   android.webkit.WebResourceError error) {
                if (request.isForMainFrame()) address.setText(error.getDescription());
            }
        });
        LinearLayout toolbar = new LinearLayout(activity);
        Button back = new Button(activity); back.setText("‹");
        back.setContentDescription("Back");
        back.setOnClickListener(v -> { if (web.canGoBack()) web.goBack(); });
        Button reload = new Button(activity); reload.setText("↻");
        reload.setContentDescription("Reload"); reload.setOnClickListener(v -> web.reload());
        Button close = new Button(activity); close.setText("×");
        close.setContentDescription("Close"); close.setOnClickListener(v -> dialog.dismiss());
        for (Button button : new Button[]{back, reload, close}) {
            toolbar.addView(button, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        }
        content.addView(address);
        content.addView(toolbar);
        content.addView(web, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        dialog.setContentView(content);
        dialog.setOnKeyListener((d, key, event) -> {
            if (key == KeyEvent.KEYCODE_BACK && event.getAction() == KeyEvent.ACTION_UP && web.canGoBack()) {
                web.goBack(); return true;
            }
            return false;
        });
        dialog.setOnDismissListener(d -> { web.stopLoading(); web.destroy(); });
        if (activity instanceof BridgeActionActivity) {
            ((BridgeActionActivity) activity).attachConfigurationWebDialog(dialog);
        }
        dialog.show();
        dialog.getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
        web.loadUrl(url);
    }
}
