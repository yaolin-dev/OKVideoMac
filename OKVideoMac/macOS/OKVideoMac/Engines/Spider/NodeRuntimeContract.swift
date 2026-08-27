import Darwin
import Foundation

enum NodeRuntimeContractKind: String, Equatable, Sendable {
    case service = "contract-a-service"
    case hostIntegrated = "contract-b-host-integrated"
}

enum NodeRuntimeReadinessPolicy: Equatable, Sendable {
    case serviceHealthIdentity
    case hostIntegratedConfiguration
}

struct NodeRuntimeLaunchPlan: Equatable, Sendable {
    let contract: NodeRuntimeContractKind
    let launcherScript: String
    let environmentAdditions: [String: String]
    let readinessPolicy: NodeRuntimeReadinessPolicy
    let stateFileURL: URL?
    let cleanupURLs: [URL]
}

enum NodeRuntimeContractDetector {
    private static let hostIntegratedMarkers = [
        "catServerFactory",
        "catDartServerPort",
        "DEV_HTTP_PORT"
    ]

    /// Detection is deliberately static and is called only after the caller
    /// has rehashed and accepted the cached bundle for execution.
    static func detect(validatedBundleData data: Data) throws -> NodeRuntimeContractKind {
        guard let source = String(data: data, encoding: .utf8) else {
            throw NodeBundleRuntimeError.unsupportedHostContract
        }
        let matches = hostIntegratedMarkers.map(source.contains)
        if matches.allSatisfy({ $0 }) {
            return .hostIntegrated
        }
        if matches.contains(true) {
            throw NodeBundleRuntimeError.unsupportedHostContract
        }
        return .service
    }
}

enum ContractBConfigBuilder {
    /// This remains the compatibility fallback for bundles that do not ship a
    /// separately checksummed, data-only companion configuration.
    static func buildMinimumConfiguration() throws -> Data {
        let object: [String: Any] = [
            "sites": ["list": []],
            "pans": ["list": []],
            "danmu": ["urls": [], "autoPush": false],
            "color": []
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try validate(data)
        return data
    }

    static func validate(_ data: Data) throws {
        guard data.count <= 1_024 * 1_024 else {
            throw NodeBundleRuntimeError.configurationContractInvalid
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw NodeBundleRuntimeError.configurationContractInvalid
        }
        guard let root = value as? [String: Any],
              isJSONCompatible(root, depth: 0) else {
            throw NodeBundleRuntimeError.configurationContractInvalid
        }
    }

    static func mergeDefaults(_ defaults: Data, userValues: Data) throws -> Data {
        try validate(defaults)
        guard defaults.count <= 1_024 * 1_024,
              userValues.count <= 1_024 * 1_024,
              let defaultObject = try JSONSerialization.jsonObject(with: defaults)
                as? [String: Any],
              let userObject = try JSONSerialization.jsonObject(with: userValues)
                as? [String: Any]
        else {
            throw NodeBundleRuntimeError.companionConfigurationSyntaxUnsupported
        }
        let merged = merge(defaults: defaultObject, userValues: userObject)
        let data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try validate(data)
        return data
    }

    private static func merge(
        defaults: [String: Any],
        userValues: [String: Any]
    ) -> [String: Any] {
        var result = defaults
        for (key, userValue) in userValues {
            if let defaultDictionary = result[key] as? [String: Any],
               let userDictionary = userValue as? [String: Any] {
                result[key] = merge(
                    defaults: defaultDictionary,
                    userValues: userDictionary
                )
            } else {
                // Persisted user values always win, including an intentionally
                // empty list or string.
                result[key] = userValue
            }
        }
        return result
    }

    /// CatPaw's companion configuration is a publisher-owned data object, not
    /// a fixed FongMi schema. Safety validation therefore stops at a bounded
    /// plain JSON tree and deliberately does not require `sites`, `pans`,
    /// `danmu`, `color`, or any other business field.
    private static func isJSONCompatible(_ value: Any, depth: Int) -> Bool {
        guard depth <= 64 else { return false }
        switch value {
        case is NSNull, is String, is Bool:
            return true
        case let number as NSNumber:
            return number.doubleValue.isFinite
        case let values as [Any]:
            return values.allSatisfy {
                isJSONCompatible($0, depth: depth + 1)
            }
        case let values as [String: Any]:
            return values.values.allSatisfy {
                isJSONCompatible($0, depth: depth + 1)
            }
        default:
            return false
        }
    }
}

/// Extracts the static object exported by CatPaw's `index.config.js` without
/// evaluating the companion JavaScript. The accepted grammar is deliberately
/// limited to JSON-compatible literals plus JavaScript identifier keys,
/// comments, single-quoted strings, and trailing commas.
enum ContractBCompanionConfigParser {
    private static let assignmentMarkers = [
        "var index_config_default =",
        "let index_config_default =",
        "const index_config_default =",
        "export default",
        "module.exports =",
        "exports.default ="
    ]

    static func normalizedConfiguration(from data: Data) throws -> Data {
        guard data.count <= 1_024 * 1_024,
              let source = String(data: data, encoding: .utf8),
              let markerRange = assignmentMarkers.compactMap({ marker in
                  source.range(of: marker).map { (range: $0, marker: marker) }
              }).min(by: { $0.range.lowerBound < $1.range.lowerBound })
        else {
            throw NodeBundleRuntimeError.configurationContractInvalid
        }
        let suffix = source[markerRange.range.upperBound...]
        var parser = StaticJavaScriptValueParser(String(suffix))
        let value = try parser.parseRootObject()
        let normalized = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try ContractBConfigBuilder.validate(normalized)
        return normalized
    }
}

private struct StaticJavaScriptValueParser {
    private let scalars: [UnicodeScalar]
    private var index = 0
    private var valueCount = 0
    private let maximumDepth = 64
    private let maximumValues = 100_000

    init(_ source: String) {
        scalars = Array(source.unicodeScalars)
    }

    mutating func parseRootObject() throws -> [String: Any] {
        skipTrivia()
        guard peek() == "{" else { throw invalid }
        let value = try parseValue(depth: 0)
        guard let object = value as? [String: Any] else { throw invalid }
        skipTrivia()
        guard peek() == ";" || peek() == nil else { throw invalid }
        return object
    }

    private var invalid: NodeBundleRuntimeError {
        .companionConfigurationSyntaxUnsupported
    }

    private mutating func parseValue(depth: Int) throws -> Any {
        guard depth <= maximumDepth, valueCount < maximumValues else {
            throw invalid
        }
        valueCount += 1
        skipTrivia()
        guard let scalar = peek() else { throw invalid }
        switch scalar {
        case "{": return try parseObject(depth: depth + 1)
        case "[": return try parseArray(depth: depth + 1)
        case "\"", "'": return try parseString()
        case "-", "0"..."9": return try parseNumber()
        default:
            let identifier = try parseIdentifier()
            switch identifier {
            case "true": return true
            case "false": return false
            case "null": return NSNull()
            default: throw invalid
            }
        }
    }

    private mutating func parseObject(depth: Int) throws -> [String: Any] {
        try consume("{")
        skipTrivia()
        var result: [String: Any] = [:]
        if consumeIf("}") { return result }
        while true {
            skipTrivia()
            let key: String
            if peek() == "\"" || peek() == "'" {
                key = try parseString()
            } else {
                key = try parseIdentifier()
            }
            guard !key.isEmpty else { throw invalid }
            skipTrivia()
            try consume(":")
            result[key] = try parseValue(depth: depth)
            skipTrivia()
            if consumeIf("}") { return result }
            try consume(",")
            skipTrivia()
            if consumeIf("}") { return result }
        }
    }

    private mutating func parseArray(depth: Int) throws -> [Any] {
        try consume("[")
        skipTrivia()
        var result: [Any] = []
        if consumeIf("]") { return result }
        while true {
            result.append(try parseValue(depth: depth))
            skipTrivia()
            if consumeIf("]") { return result }
            try consume(",")
            skipTrivia()
            if consumeIf("]") { return result }
        }
    }

    private mutating func parseString() throws -> String {
        guard let quote = peek(), quote == "\"" || quote == "'" else {
            throw invalid
        }
        index += 1
        var result = String.UnicodeScalarView()
        while let scalar = peek() {
            index += 1
            if scalar == quote { return String(result) }
            guard scalar != "\n" && scalar != "\r" else { throw invalid }
            guard scalar == "\\" else {
                result.append(scalar)
                continue
            }
            guard let escaped = peek() else { throw invalid }
            index += 1
            switch escaped {
            case "\"", "'", "\\", "/": result.append(escaped)
            case "b": result.append("\u{0008}")
            case "f": result.append("\u{000C}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "v": result.append("\u{000B}")
            case "x": result.append(try parseEscapedScalar(digits: 2))
            case "u": result.append(try parseEscapedScalar(digits: 4))
            default: throw invalid
            }
        }
        throw invalid
    }

    private mutating func parseEscapedScalar(digits: Int) throws -> UnicodeScalar {
        guard index + digits <= scalars.count else { throw invalid }
        let text = String(String.UnicodeScalarView(scalars[index..<(index + digits)]))
        guard let value = UInt32(text, radix: 16),
              let scalar = UnicodeScalar(value),
              !(0xD800...0xDFFF).contains(value)
        else { throw invalid }
        index += digits
        return scalar
    }

    private mutating func parseNumber() throws -> NSNumber {
        let start = index
        if consumeIf("-") {}
        guard let first = peek(), ("0"..."9").contains(first) else { throw invalid }
        if first == "0" {
            index += 1
        } else {
            while let scalar = peek(), ("0"..."9").contains(scalar) { index += 1 }
        }
        if consumeIf(".") {
            guard let digit = peek(), ("0"..."9").contains(digit) else { throw invalid }
            while let scalar = peek(), ("0"..."9").contains(scalar) { index += 1 }
        }
        if peek() == "e" || peek() == "E" {
            index += 1
            if peek() == "+" || peek() == "-" { index += 1 }
            guard let digit = peek(), ("0"..."9").contains(digit) else { throw invalid }
            while let scalar = peek(), ("0"..."9").contains(scalar) { index += 1 }
        }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let value = Double(text), value.isFinite else { throw invalid }
        if !text.contains(".") && !text.lowercased().contains("e"),
           let integer = Int64(text) {
            return NSNumber(value: integer)
        }
        return NSNumber(value: value)
    }

    private mutating func parseIdentifier() throws -> String {
        guard let first = peek(), isIdentifierStart(first) else { throw invalid }
        let start = index
        index += 1
        while let scalar = peek(), isIdentifierContinuation(scalar) { index += 1 }
        return String(String.UnicodeScalarView(scalars[start..<index]))
    }

    private func isIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || scalar == "$"
            || ("a"..."z").contains(scalar)
            || ("A"..."Z").contains(scalar)
    }

    private func isIdentifierContinuation(_ scalar: UnicodeScalar) -> Bool {
        isIdentifierStart(scalar) || ("0"..."9").contains(scalar)
    }

    private mutating func skipTrivia() {
        while index < scalars.count {
            if CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
                index += 1
                continue
            }
            guard scalars[index] == "/", index + 1 < scalars.count else { return }
            if scalars[index + 1] == "/" {
                index += 2
                while index < scalars.count,
                      scalars[index] != "\n", scalars[index] != "\r" {
                    index += 1
                }
                continue
            }
            if scalars[index + 1] == "*" {
                index += 2
                while index + 1 < scalars.count,
                      !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                if index + 1 < scalars.count { index += 2 }
                continue
            }
            return
        }
    }

    private func peek() -> UnicodeScalar? {
        index < scalars.count ? scalars[index] : nil
    }

    @discardableResult
    private mutating func consumeIf(_ expected: UnicodeScalar) -> Bool {
        guard peek() == expected else { return false }
        index += 1
        return true
    }

    private mutating func consume(_ expected: UnicodeScalar) throws {
        guard consumeIf(expected) else { throw invalid }
    }
}

enum NodeRuntimeLoopbackPortAllocator {
    static func allocate() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NodeBundleRuntimeError.portAllocationFailed
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NodeBundleRuntimeError.portAllocationFailed
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        guard nameResult == 0, (1...65_535).contains(port) else {
            throw NodeBundleRuntimeError.portAllocationFailed
        }
        return port
    }
}

enum NodeRuntimeContractFactory {
    static func makePlan(
        contract: NodeRuntimeContractKind,
        runtimeDirectory: URL,
        profileURL: URL? = nil,
        configurationData: Data? = nil
    ) throws -> NodeRuntimeLaunchPlan {
        switch contract {
        case .service:
            return NodeRuntimeLaunchPlan(
                contract: .service,
                launcherScript: contractALauncher,
                environmentAdditions: [:],
                readinessPolicy: .serviceHealthIdentity,
                stateFileURL: nil,
                cleanupURLs: []
            )
        case .hostIntegrated:
            let config = try configurationData
                ?? ContractBConfigBuilder.buildMinimumConfiguration()
            try ContractBConfigBuilder.validate(config)
            let configURL = runtimeDirectory.appendingPathComponent("contract-b-config.json")
            let stateURL = runtimeDirectory.appendingPathComponent("contract-b-state.json")
            // Runtime state remains bundle-version scoped, while credentials
            // live in a stable configuration/source/publisher namespace.
            guard let profileURL else {
                throw NodeBundleRuntimeError.configurationContractInvalid
            }
            let port = try NodeRuntimeLoopbackPortAllocator.allocate()
            do {
                try config.write(to: configURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: configURL.path
                )
                try? FileManager.default.removeItem(at: stateURL)
            } catch {
                try? FileManager.default.removeItem(at: configURL)
                try? FileManager.default.removeItem(at: stateURL)
                throw error
            }
            return NodeRuntimeLaunchPlan(
                contract: .hostIntegrated,
                launcherScript: contractBLauncher,
                environmentAdditions: [
                    "DEV_HTTP_PORT": String(port),
                    "OKVIDEO_CONTRACT_B_CONFIG_PATH": configURL.path,
                    "OKVIDEO_CONTRACT_B_STATE_PATH": stateURL.path,
                    "OKVIDEO_CONTRACT_B_PROFILE_PATH": profileURL.path
                ],
                readinessPolicy: .hostIntegratedConfiguration,
                stateFileURL: stateURL,
                cleanupURLs: [configURL, stateURL]
            )
        }
    }

    private static let contractALauncher = #"""
    'use strict';
    const bundlePath = process.env.OKVIDEO_BUNDLE_PATH;
    const parentPID = Number(process.env.OKVIDEO_PARENT_PID || 0);
    let runtime = null;
    let stopping = false;

    async function shutdown(code) {
      if (stopping) return;
      stopping = true;
      try {
        if (runtime && typeof runtime.stop === 'function') await runtime.stop();
      } catch (_) {}
      process.exit(code);
    }

    process.on('SIGTERM', () => { void shutdown(0); });
    process.on('SIGINT', () => { void shutdown(0); });
    setInterval(() => {
      if (!parentPID) return;
      try { process.kill(parentPID, 0); }
      catch (_) { void shutdown(0); }
    }, 1000);

    try {
      runtime = require(bundlePath);
      Promise.resolve(runtime.start()).catch((error) => {
        console.error(error);
        void shutdown(1);
      });
    } catch (error) {
      console.error(error);
      void shutdown(1);
    }
    """#

    private static let contractBLauncher = #"""
    'use strict';
    const fs = require('fs');
    const http = require('http');
    const https = require('https');
    const net = require('net');
    const crypto = require('crypto');
    const { AsyncLocalStorage } = require('async_hooks');
    const bundlePath = process.env.OKVIDEO_BUNDLE_PATH;
    const configPath = process.env.OKVIDEO_CONTRACT_B_CONFIG_PATH;
    const statePath = process.env.OKVIDEO_CONTRACT_B_STATE_PATH;
    const profilePath = process.env.OKVIDEO_CONTRACT_B_PROFILE_PATH;
    const parentPID = Number(process.env.OKVIDEO_PARENT_PID || 0);
    let runtime = null;
    let stopping = false;
    const managedListener = Symbol('okvideo-managed-listener');
    const listeners = new Set();
    const originalNetListen = net.Server.prototype.listen;
    const invocationStorage = new AsyncLocalStorage();
    const invocations = new Map();
    const pendingHostReplies = new Map();
    const invocationTTLMilliseconds = 65000;
    const originalFetch = globalThis.fetch;
    const originalHTTPRequest = http.request;
    const originalHTTPSRequest = https.request;

    function writeState(state) {
      const temporary = statePath + '.tmp-' + process.pid;
      fs.writeFileSync(temporary, JSON.stringify(state), { mode: 0o600 });
      fs.renameSync(temporary, statePath);
    }

    function validateConfig(config) {
      const validValue = (value, depth) => {
        if (depth > 64) return false;
        if (value === null || typeof value === 'string' ||
            typeof value === 'boolean') return true;
        if (typeof value === 'number') return Number.isFinite(value);
        if (Array.isArray(value)) {
          return value.every((item) => validValue(item, depth + 1));
        }
        if (!isPlainObject(value)) return false;
        return Object.values(value).every((item) =>
          validValue(item, depth + 1)
        );
      };
      if (!isPlainObject(config) || !validValue(config, 0)) {
        throw new Error('contract-b configuration rejected');
      }
      return config;
    }

    function mergeConfig(defaults, overrides) {
      const result = Object.assign({}, defaults);
      for (const [key, value] of Object.entries(overrides)) {
        if (isPlainObject(result[key]) && isPlainObject(value)) {
          result[key] = mergeConfig(result[key], value);
        } else {
          result[key] = value;
        }
      }
      return result;
    }

    function loopbackListen(server, args) {
      let callback = null;
      if (typeof args[args.length - 1] === 'function') callback = args.pop();
      let options;
      if (args.length === 1 && args[0] && typeof args[0] === 'object') {
        if (!Object.prototype.hasOwnProperty.call(args[0], 'port')) {
          return callback
            ? originalNetListen.apply(server, args.concat(callback))
            : originalNetListen.apply(server, args);
        }
        options = Object.assign({}, args[0], { host: '127.0.0.1' });
      } else {
        if (typeof args[0] === 'string' && !/^\d+$/.test(args[0])) {
          return callback
            ? originalNetListen.apply(server, args.concat(callback))
            : originalNetListen.apply(server, args);
        }
        const port = Number(args[0]);
        if (!Number.isInteger(port) || port < 0 || port > 65535) {
          throw new Error('contract-b TCP port rejected');
        }
        options = { port, host: '127.0.0.1' };
        if (typeof args[2] === 'number') options.backlog = args[2];
        else if (typeof args[1] === 'number') options.backlog = args[1];
      }
      listeners.add(server);
      server.once('close', () => listeners.delete(server));
      server.once('listening', () => {
        const address = server.address();
        if (!address || typeof address === 'string' || address.address !== '127.0.0.1') {
          void shutdown(1);
          return;
        }
        if (server[managedListener]) {
          writeState({
            contract: 'contract-b-host-integrated',
            phase: 'listener-observed',
            host: address.address,
            family: address.family,
            port: address.port
          });
        }
      });
      return callback
        ? originalNetListen.call(server, options, callback)
        : originalNetListen.call(server, options);
    }

    net.Server.prototype.listen = function controlledListen(...args) {
      return loopbackListen(this, args);
    };

    function isPrivateOrLoopbackIPv4(hostname) {
      if (hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1') {
        return true;
      }
      const parts = hostname.split('.').map(Number);
      if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
        return false;
      }
      return parts[0] === 10 ||
        (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
        (parts[0] === 192 && parts[1] === 168);
    }

    function normalizeOwnedLoopbackURL(rawValue) {
      if (typeof rawValue !== 'string' || rawValue.length === 0 || rawValue.length > 2048) {
        return null;
      }
      let parsed;
      try { parsed = new URL(rawValue); }
      catch (_) { return null; }
      if (parsed.protocol !== 'http:' || !isPrivateOrLoopbackIPv4(parsed.hostname)) {
        return null;
      }
      const port = Number(parsed.port || 80);
      const ownsPort = Array.from(listeners).some((listener) => {
        const address = listener.address();
        return address && typeof address !== 'string' && address.port === port;
      });
      if (!ownsPort) return null;
      parsed.hostname = '127.0.0.1';
      return parsed.toString();
    }

    function acceptHostMessage(value) {
      if (!value || !value.opt || typeof value.opt !== 'object') {
        return null;
      }
      if (value.action === 'openInternalWebview') {
        const url = normalizeOwnedLoopbackURL(value.opt.url);
        if (!url) return null;
        return { action: 'openInternalWebview', opt: { url } };
      }
      if (value.action !== 'sniff') return null;
      if (typeof value.opt.url !== 'string' || value.opt.url.length === 0 ||
          value.opt.url.length > 8192) return null;
      let parsed;
      try { parsed = new URL(value.opt.url); }
      catch (_) { return null; }
      const hostname = parsed.hostname.toLowerCase();
      if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') ||
          isPrivateOrLoopbackIPv4(hostname) || hostname.endsWith('.local') ||
          hostname.includes(':')) return null;
      const headers = {};
      if (value.opt.headers && typeof value.opt.headers === 'object' &&
          !Array.isArray(value.opt.headers)) {
        for (const [name, headerValue] of Object.entries(value.opt.headers).slice(0, 64)) {
          if (typeof name === 'string' && name.length <= 128 &&
              typeof headerValue === 'string' && headerValue.length <= 8192) {
            headers[name] = headerValue;
          }
        }
      }
      let rule = value.opt.rule;
      if (typeof rule !== 'string' && !Array.isArray(rule)) rule = [];
      if (typeof rule === 'string') rule = rule.slice(0, 4096);
      else rule = rule.filter((item) => typeof item === 'string')
        .slice(0, 32).map((item) => item.slice(0, 4096));
      const timeout = Math.max(1000, Math.min(Number(value.opt.timeout) || 15000, 60000));
      return {
        action: 'sniff',
        requestID: crypto.randomUUID(),
        opt: { url: parsed.toString(), timeout, rule, headers }
      };
    }

    function pendingHostReplyKey(invocationID, requestID) {
      return invocationID + ':' + requestID;
    }

    function completePendingHostReply(entry, result) {
      if (!entry || entry.completed) return;
      entry.completed = true;
      clearTimeout(entry.timer);
      pendingHostReplies.delete(entry.key);
      if (entry.response.destroyed || entry.response.writableEnded) return;
      entry.response.statusCode = 200;
      entry.response.setHeader('Content-Type', 'application/json; charset=utf-8');
      entry.response.end(JSON.stringify(result === undefined ? null : result));
    }

    function receiveHostMessageReply(request, response, invocationID, requestID) {
      const key = pendingHostReplyKey(invocationID, requestID);
      const entry = pendingHostReplies.get(key);
      if (!entry) {
        response.statusCode = 404;
        response.end();
        return;
      }
      let body = '';
      let exceededLimit = false;
      request.setEncoding('utf8');
      request.on('data', (chunk) => {
        if (exceededLimit) return;
        body += chunk;
        if (Buffer.byteLength(body, 'utf8') > 64 * 1024) {
          exceededLimit = true;
          body = '';
        }
      });
      request.on('end', () => {
        let result = null;
        if (!exceededLimit) {
          try { result = JSON.parse(body); }
          catch (_) {}
        }
        completePendingHostReply(entry, result);
        response.statusCode = exceededLimit ? 413 : 200;
        response.setHeader('Content-Type', 'application/json; charset=utf-8');
        response.end(exceededLimit ? '{"ok":false}' : '{"ok":true}');
      });
    }

    function normalizedInvocationID(value) {
      if (Array.isArray(value)) value = value[0];
      if (typeof value !== 'string' || value.length < 8 || value.length > 128 ||
          !/^[A-Za-z0-9._-]+$/.test(value)) {
        return null;
      }
      return value;
    }

    function invocationIDFromRequest(request) {
      return normalizedInvocationID(request.headers['x-okvideo-invocation-id']);
    }

    function scheduleInvocationRemoval(context) {
      if (context.removalTimer) clearTimeout(context.removalTimer);
      context.removalTimer = setTimeout(() => {
        if (invocations.get(context.id) !== context) return;
        invocations.delete(context.id);
        for (const waiter of context.waiters.splice(0)) waiter(null);
      }, invocationTTLMilliseconds);
      if (typeof context.removalTimer.unref === 'function') context.removalTimer.unref();
    }

    function deliverHostMessage(response, message) {
      response.setHeader('Content-Type', 'application/json; charset=utf-8');
      response.statusCode = 200;
      response.end(JSON.stringify(message));
    }

    function publishHostMessage(context, message) {
      if (!context || context.hostMessage || context.consumed) return false;
      context.hostMessage = message;
      for (const waiter of context.waiters.splice(0)) waiter(message);
      return true;
    }

    function pollHostMessage(request, response, invocationID, waitMilliseconds) {
      const context = invocations.get(invocationID);
      if (!context || context.consumed) {
        response.statusCode = 404;
        response.end();
        return;
      }
      if (context.hostMessage) {
        const message = context.hostMessage;
        context.consumed = true;
        deliverHostMessage(response, message);
        scheduleInvocationRemoval(context);
        return;
      }
      const boundedWait = Math.max(0, Math.min(waitMilliseconds, 2000));
      if (boundedWait === 0) {
        response.statusCode = 204;
        response.end();
        return;
      }
      let completed = false;
      const finish = (message) => {
        if (completed || response.destroyed) return;
        completed = true;
        clearTimeout(timer);
        const index = context.waiters.indexOf(finish);
        if (index >= 0) context.waiters.splice(index, 1);
        if (message) {
          context.consumed = true;
          deliverHostMessage(response, message);
        } else {
          response.statusCode = 204;
          response.end();
        }
        scheduleInvocationRemoval(context);
      };
      const timer = setTimeout(() => finish(null), boundedWait);
      context.waiters.push(finish);
      response.once('close', () => finish(null));
    }

    function correlatedRequest(originalRequest, defaultProtocol) {
      return function requestWithInvocation(...args) {
        const invocationID = invocationStorage.getStore();
        if (!invocationID) return originalRequest.apply(this, args);
        let parsed = null;
        let optionsIndex = 0;
        try {
          if (typeof args[0] === 'string' || args[0] instanceof URL) {
            parsed = new URL(args[0]);
            optionsIndex = 1;
          } else if (args[0] && typeof args[0] === 'object') {
            const options = args[0];
            const host = options.hostname || options.host;
            if (host) {
              parsed = new URL(
                (options.protocol || defaultProtocol) + '//' + host +
                (options.path || '/')
              );
            }
          }
        } catch (_) {}
        if (!parsed || parsed.pathname !== '/msg' ||
            !isPrivateOrLoopbackIPv4(parsed.hostname)) {
          return originalRequest.apply(this, args);
        }
        const existing = args[optionsIndex];
        const options = existing && typeof existing === 'object' &&
          !(existing instanceof URL)
          ? Object.assign({}, existing)
          : {};
        const headers = Object.assign({}, options.headers || {});
        for (const name of Object.keys(headers)) {
          if (name.toLowerCase() === 'x-okvideo-invocation-id') delete headers[name];
        }
        headers['X-OKVideo-Invocation-ID'] = invocationID;
        options.headers = headers;
        if (optionsIndex === 0) args[0] = options;
        else if (existing && typeof existing === 'object' &&
                 !(existing instanceof URL)) args[optionsIndex] = options;
        else args.splice(optionsIndex, 0, options);
        return originalRequest.apply(this, args);
      };
    }

    http.request = correlatedRequest(originalHTTPRequest, 'http:');
    https.request = correlatedRequest(originalHTTPSRequest, 'https:');

    if (typeof originalFetch === 'function') {
      globalThis.fetch = function correlatedFetch(input, init) {
        const invocationID = invocationStorage.getStore();
        if (!invocationID) return originalFetch(input, init);
        let parsed = null;
        try {
          const raw = typeof input === 'string' || input instanceof URL
            ? input
            : input && input.url;
          parsed = new URL(raw);
        } catch (_) {}
        if (!parsed || parsed.pathname !== '/msg' ||
            !isPrivateOrLoopbackIPv4(parsed.hostname)) {
          return originalFetch(input, init);
        }
        const options = Object.assign({}, init || {});
        const headers = new Headers(
          options.headers || (input && input.headers) || undefined
        );
        headers.set('X-OKVideo-Invocation-ID', invocationID);
        options.headers = headers;
        return originalFetch(input, options);
      };
    }

    function isPlainObject(value) {
      if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
      const prototype = Object.getPrototypeOf(value);
      return prototype === Object.prototype || prototype === null;
    }

    function readProfile() {
      try {
        const stat = fs.statSync(profilePath);
        if (!stat.isFile() || stat.size > 1024 * 1024) return {};
        const value = JSON.parse(fs.readFileSync(profilePath, 'utf8'));
        return isPlainObject(value) ? value : {};
      } catch (_) {
        return {};
      }
    }

    function writeProfile(value) {
      if (!isPlainObject(value)) return false;
      const encoded = JSON.stringify(value);
      if (Buffer.byteLength(encoded, 'utf8') > 1024 * 1024) return false;
      const temporary = profilePath + '.tmp-' + process.pid;
      try {
        fs.writeFileSync(temporary, encoded, { mode: 0o600 });
        fs.renameSync(temporary, profilePath);
        return true;
      } catch (_) {
        try { fs.unlinkSync(temporary); } catch (_) {}
        return false;
      }
    }

    function receiveHostMessage(request, response) {
      let body = '';
      let exceededLimit = false;
      request.setEncoding('utf8');
      request.on('data', (chunk) => {
        if (exceededLimit) return;
        body += chunk;
        if (Buffer.byteLength(body, 'utf8') > 1024 * 1024) {
          exceededLimit = true;
          body = '';
        }
      });
      request.on('end', () => {
        let value = null;
        if (!exceededLimit) {
          try { value = JSON.parse(body); }
          catch (_) {}
        }
        response.setHeader('Content-Type', 'application/json; charset=utf-8');

        if (value && value.action === 'queryProfile') {
          response.statusCode = 200;
          response.end(JSON.stringify(readProfile()));
          return;
        }
        if (value && value.action === 'saveProfile') {
          const saved = writeProfile(value.opt);
          response.statusCode = saved ? 200 : 400;
          response.end(saved ? '{"ok":true}' : '{"ok":false}');
          return;
        }

        let accepted = acceptHostMessage(value);
        const invocationID = invocationIDFromRequest(request);
        const context = invocationID ? invocations.get(invocationID) : null;
        if (!accepted || !publishHostMessage(context, accepted)) accepted = null;
        if (accepted && accepted.action === 'sniff') {
          const key = pendingHostReplyKey(invocationID, accepted.requestID);
          const entry = {
            key,
            response,
            completed: false,
            timer: null
          };
          const timeout = Math.max(1000, Math.min(
            Number(accepted.opt.timeout) || 15000,
            60000
          ));
          entry.timer = setTimeout(
            () => completePendingHostReply(entry, null),
            timeout + 1000
          );
          if (typeof entry.timer.unref === 'function') entry.timer.unref();
          pendingHostReplies.set(key, entry);
          response.once('close', () => {
            if (!entry.completed && response.destroyed) {
              entry.completed = true;
              clearTimeout(entry.timer);
              pendingHostReplies.delete(key);
            }
          });
          return;
        }
        response.statusCode = accepted ? 200 : 400;
        response.end(accepted ? '{"ok":true}' : '{"ok":false}');
      });
    }

    function attachHostMessageHeader(context) {
      if (context.response.headersSent || !context.hostMessage || context.attached) return;
      const encoded = Buffer.from(JSON.stringify(context.hostMessage), 'utf8').toString('base64');
      context.attached = true;
      context.consumed = true;
      context.response.setHeader('X-OKVideo-Host-Message', encoded);
    }

    globalThis.catDartServerPort = function catDartServerPort() {
      return Number(process.env.DEV_HTTP_PORT || 0);
    };
    globalThis.catServerFactory = function catServerFactory(handler) {
      if (typeof handler !== 'function') {
        throw new Error('contract-b server factory arguments rejected');
      }
      const server = http.createServer((request, response) => {
        if (request.method === 'POST' && request.url === '/msg') {
          receiveHostMessage(request, response);
          return;
        }
        const requestURL = new URL(request.url || '/', 'http://127.0.0.1');
        const replyPrefix = '/__okvideo/host-message-reply/';
        if (request.method === 'POST' && requestURL.pathname.startsWith(replyPrefix)) {
          const parts = requestURL.pathname.slice(replyPrefix.length).split('/');
          const invocationID = normalizedInvocationID(
            decodeURIComponent(parts[0] || '')
          );
          const requestID = normalizedInvocationID(
            decodeURIComponent(parts[1] || '')
          );
          if (!invocationID || !requestID || parts.length !== 2) {
            response.statusCode = 400;
            response.end();
            return;
          }
          receiveHostMessageReply(
            request,
            response,
            invocationID,
            requestID
          );
          return;
        }
        const pollPrefix = '/__okvideo/host-message/';
        if (request.method === 'GET' && requestURL.pathname.startsWith(pollPrefix)) {
          const invocationID = normalizedInvocationID(
            decodeURIComponent(requestURL.pathname.slice(pollPrefix.length))
          );
          if (!invocationID) {
            response.statusCode = 400;
            response.end();
            return;
          }
          pollHostMessage(
            request,
            response,
            invocationID,
            Number(requestURL.searchParams.get('wait') || 0)
          );
          return;
        }
        const invocationID = invocationIDFromRequest(request) || crypto.randomUUID();
        const context = {
          id: invocationID,
          response,
          hostMessage: null,
          attached: false,
          consumed: false,
          waiters: [],
          removalTimer: null
        };
        invocations.set(invocationID, context);
        response.setHeader('X-OKVideo-Invocation-ID', invocationID);
        response.once('finish', () => scheduleInvocationRemoval(context));
        response.once('close', () => scheduleInvocationRemoval(context));
        const originalWriteHead = response.writeHead;
        const originalEnd = response.end;
        response.writeHead = function controlledWriteHead(...args) {
          attachHostMessageHeader(context);
          return originalWriteHead.apply(response, args);
        };
        response.end = function controlledEnd(...args) {
          attachHostMessageHeader(context);
          return originalEnd.apply(response, args);
        };
        invocationStorage.run(invocationID, () => handler(request, response));
      });
      server[managedListener] = true;
      return server;
    };

    async function shutdown(code) {
      if (stopping) return;
      stopping = true;
      try {
        if (runtime && typeof runtime.stop === 'function') await runtime.stop();
      } catch (_) {}
      try {
        await Promise.all(Array.from(listeners, (listener) =>
          listener.listening
            ? new Promise((resolve) => listener.close(resolve))
            : Promise.resolve()
        ));
      } catch (_) {}
      process.exit(code);
    }

    process.on('SIGTERM', () => { void shutdown(0); });
    process.on('SIGINT', () => { void shutdown(0); });
    // The verified host contract keeps its Node runtime alive after an
    // unhandled route rejection. Do not log the rejected value because it may
    // contain third-party URLs, headers, or credentials.
    process.on('unhandledRejection', () => {
      console.error('CONTRACT_B_UNHANDLED_REJECTION');
    });
    setInterval(() => {
      if (!parentPID) return;
      try { process.kill(parentPID, 0); }
      catch (_) { void shutdown(0); }
    }, 1000);

    try {
      const publisherConfig = validateConfig(
        JSON.parse(fs.readFileSync(configPath, 'utf8'))
      );
      let config = publisherConfig;
      const profile = readProfile();
      try {
        config = validateConfig(mergeConfig(publisherConfig, profile));
      } catch (_) {
        config = publisherConfig;
      }
      runtime = require(bundlePath);
      if (!runtime || typeof runtime.start !== 'function' || typeof runtime.stop !== 'function') {
        throw new Error('contract-b lifecycle exports rejected');
      }
      Promise.resolve(runtime.start(config)).catch((error) => {
        console.error(error);
        void shutdown(1);
      });
    } catch (error) {
      console.error(error);
      void shutdown(1);
    }
    """#
}

struct ContractBListenerState: Codable, Equatable, Sendable {
    let contract: String
    let phase: String
    let host: String
    let family: String
    let port: Int

    static func readValidated(from url: URL) -> ContractBListenerState? {
        guard let data = try? Data(contentsOf: url), data.count <= 4_096,
              let state = try? JSONDecoder().decode(Self.self, from: data),
              state.contract == NodeRuntimeContractKind.hostIntegrated.rawValue,
              state.phase == "listener-observed",
              state.host == "127.0.0.1",
              (1...65_535).contains(state.port)
        else { return nil }
        return state
    }
}
