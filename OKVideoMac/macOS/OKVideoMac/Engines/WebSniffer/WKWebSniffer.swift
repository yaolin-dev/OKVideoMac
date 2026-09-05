import AppKit
import Foundation
import OKVideoCore
import WebKit

@MainActor
final class WKWebSniffer: NSObject, WebSnifferClient {
    private static let messageName = "okVideoSniffer"

    private var webView: WKWebView?
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<SniffedMedia, Error>?
    private var activeRequest: WebSniffRequest?
    private var timeoutTask: Task<Void, Never>?

    func sniff(_ request: WebSniffRequest) async throws -> SniffedMedia {
        cancel()
        guard ["http", "https"].contains(request.url.scheme?.lowercased() ?? "") else {
            throw AppError.parsing("Web 嗅探只允许 HTTP/HTTPS 页面")
        }
        guard request.allowsPrivateNetworkAccess
                || !Self.isPrivateNetworkURL(request.url) else {
            throw AppError.parsing("Web 嗅探拒绝访问本机或内网地址")
        }
        activeRequest = request
        let configuration = makeConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = request.headers["User-Agent"]
        self.webView = webView
        if request.debugVisible {
            showDebugPanel(webView)
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers.dictionary {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        timeoutTask = Task { [weak self] in
            let nanoseconds = UInt64(request.timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finish(.failure(AppError.parsing("Web 嗅探超时")))
            }
        }

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    webView.load(urlRequest)
                }
            },
            onCancel: {
                Task { @MainActor in
                    self.finish(.failure(AppError.cancelled))
                }
            }
        )
    }

    func cancel() {
        guard continuation != nil || webView != nil else { return }
        finish(.failure(AppError.cancelled))
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let controller = WKUserContentController()
        controller.add(
            WeakScriptMessageHandler(owner: self),
            name: Self.messageName
        )
        controller.addUserScript(
            WKUserScript(
                source: Self.instrumentationScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    private func showDebugPanel(_ webView: WKWebView) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "OKVideoMac Web 嗅探调试"
        panel.contentView = webView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func handleCandidate(_ rawURL: String, sourcePage: String?) {
        guard let request = activeRequest,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              matches(url: url, patterns: request.mediaPatterns) else {
            return
        }

        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies {
            [weak self] cookies in
            Task { @MainActor in
                guard let self, let request = self.activeRequest else { return }
                var headers = request.headers
                if !cookies.isEmpty {
                    headers["Cookie"] = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
                }
                let sourceURL = sourcePage.flatMap(URL.init(string:))
                    ?? self.webView?.url
                    ?? request.url
                headers["Referer"] = sourceURL.absoluteString
                self.finish(
                    .success(
                        SniffedMedia(
                            url: url,
                            headers: headers,
                            sourcePageURL: sourceURL
                        )
                    )
                )
            }
        }
    }

    private func matches(url: URL, patterns: [String]) -> Bool {
        if MediaURLClassifier.isDirectMediaURL(url.absoluteString) {
            return true
        }
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return false
            }
            let value = url.absoluteString
            return regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ) != nil
        }
    }

    private static func isPrivateNetworkURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return true
        }
        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        guard parts.allSatisfy({ (0...255).contains($0) }) else { return true }
        return parts[0] == 0
            || parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 100 && (64...127).contains(parts[1]))
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || parts[0] >= 224
    }

    private func finish(_ result: Result<SniffedMedia, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageName
        )
        webView = nil
        panel?.close()
        panel = nil
        activeRequest = nil

        switch result {
        case .success(let media):
            continuation.resume(returning: media)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static let instrumentationScript = """
    (() => {
      const sent = new Set();
      const report = (value) => {
        try {
          const url = new URL(String(value), document.baseURI).href;
          if (!sent.has(url)) {
            sent.add(url);
            window.webkit.messageHandlers.okVideoSniffer.postMessage({
              url: url,
              page: document.location.href
            });
          }
        } catch (_) {}
      };

      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function(input, init) {
          report(input && input.url ? input.url : input);
          return originalFetch.apply(this, arguments);
        };
      }

      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        report(url);
        return originalOpen.apply(this, arguments);
      };

      const scan = () => {
        document.querySelectorAll('video,audio,source').forEach((node) => {
          if (node.src) report(node.src);
        });
        if (window.performance && performance.getEntriesByType) {
          performance.getEntriesByType('resource').forEach((entry) => report(entry.name));
        }
      };
      new MutationObserver(scan).observe(document.documentElement || document, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['src']
      });
      setInterval(scan, 500);
      document.addEventListener('DOMContentLoaded', scan);
    })();
    """
}

extension WKWebSniffer: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let allowsScheme = ["http", "https", "about"].contains(scheme)
        let blocksPrivateTarget = activeRequest?.allowsPrivateNetworkAccess == false
            && scheme != "about"
            && Self.isPrivateNetworkURL(url)
        decisionHandler(allowsScheme && !blocksPrivateTarget ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let script = activeRequest?.clickScript, !script.isEmpty else { return }
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                Task { @MainActor in
                    self?.finish(
                        .failure(
                            AppError.parsing(
                                "点击脚本执行失败：\(error.localizedDescription)"
                            )
                        )
                    )
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(AppError.parsing("网页加载失败：\(error.localizedDescription)")))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(AppError.parsing("网页导航失败：\(error.localizedDescription)")))
    }
}

extension WKWebSniffer: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let rawURL = body["url"] as? String else {
            return
        }
        handleCandidate(rawURL, sourcePage: body["page"] as? String)
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WKScriptMessageHandler?

    init(owner: WKScriptMessageHandler) {
        self.owner = owner
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}
