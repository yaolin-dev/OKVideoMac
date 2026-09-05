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

enum NodeRuntimePortAllocator {
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
        // CatPawOpen publishes its configuration website to the LAN. Reserve
        // the runtime port on every IPv4 interface so a loopback-only socket
        // on another process cannot collide when the managed listener starts.
        address.sin_addr = in_addr(s_addr: inet_addr("0.0.0.0"))
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
        configurationData: Data? = nil,
        transferEnvironment: [String: String] = [:]
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
            let port = try NodeRuntimePortAllocator.allocate()
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
                    "DEV_HTTP_HOST": "0.0.0.0",
                    "DEV_HTTP_PORT": String(port),
                    "OKVIDEO_CONTRACT_B_CONFIG_PATH": configURL.path,
                    "OKVIDEO_CONTRACT_B_STATE_PATH": stateURL.path,
                    "OKVIDEO_CONTRACT_B_PROFILE_PATH": profileURL.path
                ].merging(transferEnvironment) { _, transfer in transfer },
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
    const { Readable } = require('stream');
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
    const runtimeHostMessages = [];
    const runtimeHostWaiters = [];
    const invocationTTLMilliseconds = 65000;
    const authorizationInvocationTTLMilliseconds = 5 * 60 * 1000;
    const runtimeHostMessageTTLMilliseconds = 15000;
    const runtimeHostMessageLimit = 16;
    const proxyErrorCaptureLimitBytes = 4 * 1024;
    const baiduMediaSessionTTLMilliseconds = 8 * 60 * 60 * 1000;
    const baiduMediaSessionLimit = 32;
    const baiduMediaSessions = new Map();
    let hostBridgeServer = null;
    let hostBridgePort = 0;
    const originalFetch = globalThis.fetch;
    const originalHTTPRequest = http.request;
    const originalHTTPSRequest = https.request;
    const runtimeGeneration = crypto.randomUUID();
    const playbackContexts = new Map();
    const playbackContextTTLMilliseconds = 15 * 60 * 1000;
    const playbackContextLimit = 64;
    const playbackQueryKeys = {
      requestID: '__okvideo_playback_request',
      generation: '__okvideo_playback_generation',
      challengeID: '__okvideo_authorization_challenge'
    };

    function normalizedUUID(value) {
      if (Array.isArray(value)) value = value[0];
      if (typeof value !== 'string' ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
        return null;
      }
      return value.toLowerCase();
    }

    function normalizedGeneration(value) {
      if (Array.isArray(value)) value = value[0];
      if (typeof value !== 'string' || !/^[1-9][0-9]{0,19}$/.test(value)) {
        return null;
      }
      const number = Number(value);
      return Number.isSafeInteger(number) && number > 0 ? number : null;
    }

    function boundedIdentity(value, maximumLength) {
      if (Array.isArray(value)) value = value[0];
      if (typeof value !== 'string') return null;
      const normalized = value.trim();
      return normalized.length > 0 && normalized.length <= maximumLength
        ? normalized
        : null;
    }

    function prunePlaybackContexts(now) {
      for (const [key, context] of playbackContexts) {
        if (now - context.createdAt > playbackContextTTLMilliseconds) {
          playbackContexts.delete(key);
        }
      }
      while (playbackContexts.size > playbackContextLimit) {
        playbackContexts.delete(playbackContexts.keys().next().value);
      }
    }

    function playbackContextKey(requestID, generation, challengeID) {
      return `${requestID}:${generation}:${challengeID}`;
    }

    function registerPlaybackContext(request, pathname) {
      if (request.method !== 'POST' || !pathname.endsWith('/play') ||
          !runtimeModulePath(pathname)) return null;
      const requestID = normalizedUUID(
        request.headers['x-okvideo-transfer-request-id']
      );
      const generation = normalizedGeneration(
        request.headers['x-okvideo-transfer-generation']
      );
      const challengeID = normalizedUUID(
        request.headers['x-okvideo-authorization-challenge-id']
      );
      if (!requestID || !generation || !challengeID) return null;
      const context = {
        challengeID,
        playbackRequestID: requestID,
        requestGeneration: generation,
        configurationID: boundedIdentity(
          request.headers['x-okvideo-configuration-id'], 128
        ),
        semanticRevision: boundedIdentity(
          request.headers['x-okvideo-semantic-revision'], 256
        ),
        runtimeGeneration,
        siteIdentity: boundedIdentity(
          request.headers['x-okvideo-site-identity'], 256
        ),
        runtimeModulePath: runtimeModulePath(pathname),
        profileRevisionBefore: boundedIdentity(
          request.headers['x-okvideo-profile-revision'], 256
        ),
        createdAt: Date.now()
      };
      prunePlaybackContexts(context.createdAt);
      playbackContexts.set(
        playbackContextKey(requestID, generation, challengeID),
        context
      );
      return context;
    }

    function consumePlaybackContextFromProxy(request, requestURL) {
      if (request.method !== 'GET' && request.method !== 'HEAD') return null;
      const requestID = normalizedUUID(
        requestURL.searchParams.get(playbackQueryKeys.requestID)
      );
      const generation = normalizedGeneration(
        requestURL.searchParams.get(playbackQueryKeys.generation)
      );
      const challengeID = normalizedUUID(
        requestURL.searchParams.get(playbackQueryKeys.challengeID)
      );
      if (!requestID || !generation || !challengeID) return null;
      const key = playbackContextKey(requestID, generation, challengeID);
      prunePlaybackContexts(Date.now());
      const context = playbackContexts.get(key) || null;
      if (!context) return null;
      const rawRequestURL = request.url || '';
      const questionMarker = `?${playbackQueryKeys.requestID}=`;
      const ampersandMarker = `&${playbackQueryKeys.requestID}=`;
      const questionIndex = rawRequestURL.lastIndexOf(questionMarker);
      const ampersandIndex = rawRequestURL.lastIndexOf(ampersandMarker);
      const markerIndex = Math.max(questionIndex, ampersandIndex);
      if (markerIndex >= 0) {
        // Swift appends the three private fields as the final raw query tail.
        // Strip that exact tail without decoding or re-encoding any provider-
        // signed nested URL that precedes it.
        request.url = rawRequestURL.slice(0, markerIndex);
      } else {
        requestURL.searchParams.delete(playbackQueryKeys.requestID);
        requestURL.searchParams.delete(playbackQueryKeys.generation);
        requestURL.searchParams.delete(playbackQueryKeys.challengeID);
        request.url = requestURL.pathname + requestURL.search;
      }
      return context;
    }

    function optionsWithPlaybackContext(context, options, phase) {
      const playback = context && context.playbackContext;
      if (!playback) return Object.assign({}, options);
      const identity = {
        challengeID: playback.challengeID,
        playbackRequestID: playback.playbackRequestID,
        requestGeneration: playback.requestGeneration,
        runtimeGeneration: playback.runtimeGeneration,
        runtimeModulePath: playback.runtimeModulePath,
        phase
      };
      for (const key of [
        'configurationID', 'semanticRevision', 'siteIdentity',
        'profileRevisionBefore'
      ]) {
        if (playback[key]) identity[key] = playback[key];
      }
      return Object.assign({}, options, identity);
    }

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

    function scopedListen(server, args) {
      let callback = null;
      if (typeof args[args.length - 1] === 'function') callback = args.pop();
      let options;
      if (args.length === 1 && args[0] && typeof args[0] === 'object') {
        if (!Object.prototype.hasOwnProperty.call(args[0], 'port')) {
          return callback
            ? originalNetListen.apply(server, args.concat(callback))
            : originalNetListen.apply(server, args);
        }
        options = Object.assign({}, args[0]);
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
        options = { port };
        if (typeof args[2] === 'number') options.backlog = args[2];
        else if (typeof args[1] === 'number') options.backlog = args[1];
      }
      const declaredRuntimePort = Number(process.env.DEV_HTTP_PORT || 0);
      const exposesConfigurationWebsite = Boolean(server[managedListener]) &&
        Number(options.port) === declaredRuntimePort;
      options.host = exposesConfigurationWebsite ? '0.0.0.0' : '127.0.0.1';
      listeners.add(server);
      server.once('close', () => listeners.delete(server));
      server.once('listening', () => {
        const address = server.address();
        const expectedAddress = exposesConfigurationWebsite
          ? '0.0.0.0'
          : '127.0.0.1';
        if (!address || typeof address === 'string' ||
            address.address !== expectedAddress) {
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
      return scopedListen(this, args);
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

    const legacyWebAssetReplacements = new Map([
      [
        'https://lib.baomitu.com/react/18.2.0/umd/react.production.min.js',
        'https://cdn.jsdelivr.net/npm/react@18.2.0/umd/react.production.min.js'
      ],
      [
        'https://lib.baomitu.com/react-dom/18.2.0/umd/react-dom.production.min.js',
        'https://cdn.jsdelivr.net/npm/react-dom@18.2.0/umd/react-dom.production.min.js'
      ],
      [
        'https://lib.baomitu.com/axios/0.26.0/axios.min.js',
        'https://cdn.jsdelivr.net/npm/axios@0.26.0/dist/axios.min.js'
      ],
      [
        'https://lib.baomitu.com/dayjs/1.10.8/dayjs.min.js',
        'https://cdn.jsdelivr.net/npm/dayjs@1.10.8/dayjs.min.js'
      ],
      [
        'https://lib.baomitu.com/antd/5.25.0/antd.min.js',
        'https://cdn.jsdelivr.net/npm/antd@5.25.0/dist/antd.min.js'
      ],
      [
        'https://lib.baomitu.com/antd/5.25.0/reset.min.css',
        'https://cdn.jsdelivr.net/npm/antd@5.25.0/dist/reset.css'
      ]
    ]);

    function repairLegacyWebAssetURLs(value) {
      let repaired = value;
      for (const [legacyURL, replacementURL] of legacyWebAssetReplacements) {
        repaired = repaired.split(legacyURL).join(replacementURL);
      }
      return repaired;
    }

    function acceptHostMessage(value, invocationID) {
      if (!value || !value.opt || typeof value.opt !== 'object') {
        return null;
      }
      if (value.action === 'toast') {
        const opt = {};
        for (const key of ['message', 'msg', 'text', 'title']) {
          if (typeof value.opt[key] === 'string' &&
              value.opt[key].length > 0 && value.opt[key].length <= 1024) {
            opt[key] = value.opt[key];
          }
        }
        if (!Object.keys(opt).length) return null;
        if (Number.isFinite(Number(value.opt.duration))) {
          opt.duration = Math.max(0, Math.min(Number(value.opt.duration), 60000));
        }
        return { action: 'toast', opt };
      }
      if (value.action === 'authorizationRequired') {
        const provider = typeof value.opt.provider === 'string'
          ? value.opt.provider.trim().toLowerCase() : '';
        const reasonCode = typeof value.opt.reasonCode === 'string'
          ? value.opt.reasonCode.trim() : '';
        const phase = typeof value.opt.phase === 'string'
          ? value.opt.phase.trim().toLowerCase() : '';
        const message = typeof value.opt.message === 'string'
          ? value.opt.message.trim() : '';
        if (!/^[a-z0-9-]{1,64}$/.test(provider) ||
            !['missingCredential', 'expiredCredential',
              'unauthorizedHTTP', 'providerDeclared'].includes(reasonCode) ||
            (phase !== 'play' && phase !== 'proxy') ||
            !message || message.length > 1024) return null;
        const opt = { provider, reasonCode, phase, message };
        const upstreamStatus = Number(value.opt.upstreamStatus);
        if (Number.isInteger(upstreamStatus) &&
            upstreamStatus >= 100 && upstreamStatus <= 599) {
          opt.upstreamStatus = upstreamStatus;
        }
        return { action: 'authorizationRequired', opt };
      }
      if (value.action === 'openInternalWebview') {
        const url = normalizeOwnedLoopbackURL(value.opt.url);
        if (!url) return null;
        const opt = { url };
        for (const key of ['challengeID', 'requestID', 'provider', 'profileRevision', 'transport']) {
          if (typeof value.opt[key] === 'string' && value.opt[key].length <= 256) {
            opt[key] = value.opt[key];
          }
        }
        if (opt.requestID && opt.requestID !== invocationID) return null;
        if (invocationID) opt.requestID = invocationID;
        return { action: 'openInternalWebview', opt };
      }
      if (value.action === 'authorizationCompleted') {
        const opt = {};
        for (const key of ['challengeID', 'requestID', 'provider', 'profileRevision']) {
          if (typeof value.opt[key] === 'string' && value.opt[key].length <= 256) {
            opt[key] = value.opt[key];
          }
        }
        if (opt.requestID && opt.requestID !== invocationID) return null;
        if (invocationID) opt.requestID = invocationID;
        return { action: 'authorizationCompleted', opt };
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
      }, context.authorizationChallenge
        ? authorizationInvocationTTLMilliseconds
        : invocationTTLMilliseconds);
      if (typeof context.removalTimer.unref === 'function') context.removalTimer.unref();
    }

    function deliverHostMessage(response, message) {
      response.setHeader('Content-Type', 'application/json; charset=utf-8');
      response.statusCode = 200;
      response.end(JSON.stringify(message));
    }

    function publishHostMessage(context, message) {
      if (!context || context.hostMessages.length >= 8) return false;
      if (message.action === 'toast' ||
          message.action === 'authorizationRequired' ||
          message.action === 'openInternalWebview' ||
          message.action === 'authorizationCompleted') {
        message = Object.assign({}, message, {
          opt: optionsWithPlaybackContext(
            context,
            message.opt,
            context.proxyRequest ? 'proxy' : 'play'
          )
        });
      }
      if (message.action === 'openInternalWebview' ||
          message.action === 'authorizationRequired') {
        context.authorizationChallenge = true;
      }
      const waiter = context.waiters.shift();
      if (waiter) {
        // Keep one invocation-scoped copy for the response header. The HTTP
        // response and the concurrent host-message monitor can complete in
        // either order; without this copy, cancelling the losing monitor can
        // consume and discard the only structured authorization event.
        if (message.action === 'toast' ||
            message.action === 'authorizationRequired') {
          context.hostMessages.push(message);
        }
        waiter(message);
      } else {
        context.hostMessages.push(message);
      }
      return true;
    }

    function runtimeModulePath(pathname) {
      if (typeof pathname !== 'string' || pathname.length > 2048) return null;
      const parts = pathname.split('/').filter(Boolean);
      if (parts.length < 3 || parts[0].toLowerCase() !== 'spider') return null;
      const normalized = parts.slice(0, 3).map((part) => {
        try { return encodeURIComponent(decodeURIComponent(part)); }
        catch (_) { return null; }
      });
      if (normalized.some((part) => !part || part.length > 256)) return null;
      return '/' + normalized.join('/');
    }

    function pruneRuntimeHostMessages(now) {
      while (runtimeHostMessages.length > 0 &&
             now - runtimeHostMessages[0].createdAt >
               runtimeHostMessageTTLMilliseconds) {
        runtimeHostMessages.shift();
      }
    }

    function runtimeHostMessageMatches(
      entry,
      modulePath,
      notBefore,
      playbackRequestID,
      requestGeneration,
      challengeID
    ) {
      const sourceMatches = entry.modulePath === modulePath ||
        (entry.modulePath === null &&
          entry.message.action === 'proxyAuthorizationRequired');
      if (!sourceMatches || entry.createdAt < notBefore) return false;
      const opt = entry.message.opt || {};
      if (playbackRequestID && opt.playbackRequestID !== playbackRequestID) {
        return false;
      }
      if (requestGeneration && opt.requestGeneration !== requestGeneration) {
        return false;
      }
      if (challengeID && opt.challengeID !== challengeID) return false;
      return true;
    }

    function takeRuntimeHostMessage(
      modulePath,
      notBefore,
      playbackRequestID,
      requestGeneration,
      challengeID
    ) {
      const now = Date.now();
      pruneRuntimeHostMessages(now);
      const index = runtimeHostMessages.findIndex((entry) =>
        runtimeHostMessageMatches(
          entry,
          modulePath,
          notBefore,
          playbackRequestID,
          requestGeneration,
          challengeID
        )
      );
      if (index < 0) return null;
      return runtimeHostMessages.splice(index, 1)[0];
    }

    function finishRuntimeHostWaiter(waiter, entry) {
      if (!waiter || waiter.completed) return;
      waiter.completed = true;
      clearTimeout(waiter.timer);
      const index = runtimeHostWaiters.indexOf(waiter);
      if (index >= 0) runtimeHostWaiters.splice(index, 1);
      if (waiter.response.destroyed || waiter.response.writableEnded) return;
      if (!entry) {
        waiter.response.statusCode = 204;
        waiter.response.end();
        return;
      }
      deliverHostMessage(waiter.response, entry.message);
    }

    function publishRuntimeHostMessage(context, message) {
      if (!context ||
          (message.action !== 'toast' &&
            message.action !== 'authorizationRequired' &&
            message.action !== 'proxyAuthorizationRequired')) return false;
      const modulePath = runtimeModulePath(context.requestPath);
      if (!modulePath && message.action !== 'proxyAuthorizationRequired') {
        return false;
      }
      const createdAt = Date.now();
      const event = {
        action: message.action,
        opt: Object.assign(
          optionsWithPlaybackContext(
            context,
            message.opt,
            context.proxyRequest ? 'proxy' : 'play'
          ),
          modulePath ? {runtimeModulePath: modulePath} : {},
          {runtimeEventAtMilliseconds: createdAt}
        )
      };
      const entry = { message: event, modulePath, createdAt };
      const waiterIndex = runtimeHostWaiters.findIndex((waiter) =>
        runtimeHostMessageMatches(
          entry,
          waiter.modulePath,
          waiter.notBefore,
          waiter.playbackRequestID,
          waiter.requestGeneration,
          waiter.challengeID
        )
      );
      if (waiterIndex >= 0) {
        const waiter = runtimeHostWaiters[waiterIndex];
        finishRuntimeHostWaiter(waiter, entry);
        return true;
      }
      pruneRuntimeHostMessages(createdAt);
      runtimeHostMessages.push(entry);
      while (runtimeHostMessages.length > runtimeHostMessageLimit) {
        runtimeHostMessages.shift();
      }
      return true;
    }

    function pollRuntimeHostMessage(
      response,
      modulePath,
      notBefore,
      waitMilliseconds,
      playbackRequestID,
      requestGeneration,
      challengeID
    ) {
      const entry = takeRuntimeHostMessage(
        modulePath,
        notBefore,
        playbackRequestID,
        requestGeneration,
        challengeID
      );
      if (entry) {
        deliverHostMessage(response, entry.message);
        return;
      }
      const boundedWait = Math.max(0, Math.min(waitMilliseconds, 2000));
      if (boundedWait === 0) {
        response.statusCode = 204;
        response.end();
        return;
      }
      if (runtimeHostWaiters.length >= runtimeHostMessageLimit) {
        response.statusCode = 429;
        response.end();
        return;
      }
      const waiter = {
        response,
        modulePath,
        notBefore,
        playbackRequestID,
        requestGeneration,
        challengeID,
        completed: false,
        timer: null
      };
      waiter.timer = setTimeout(
        () => finishRuntimeHostWaiter(waiter, null),
        boundedWait
      );
      runtimeHostWaiters.push(waiter);
      response.once('close', () => finishRuntimeHostWaiter(waiter, null));
    }

    function proxyRequestDescriptor(pathname) {
      if (typeof pathname !== 'string' || pathname.length > 2048) return null;
      const parts = pathname.split('/').filter(Boolean);
      const modulePath = runtimeModulePath(pathname);
      const proxyIndex = parts[0]?.toLowerCase() === 'proxy'
        ? 0
        : modulePath && parts[3]?.toLowerCase() === 'proxy'
          ? 3
          : -1;
      if (proxyIndex < 0) return null;
      let provider = '';
      try { provider = decodeURIComponent(parts[proxyIndex + 1] || ''); }
      catch (_) { provider = ''; }
      provider = provider.replace(/[^\p{L}\p{N}._-]/gu, '').slice(0, 64);
      return {modulePath, provider};
    }

    function captureProxyResponseChunk(context, chunk, encoding) {
      if (!context.proxyRequest || context.proxyResponseBytes >= proxyErrorCaptureLimitBytes ||
          chunk === undefined || chunk === null) return;
      let buffer;
      try {
        if (typeof chunk === 'string') {
          buffer = Buffer.from(chunk, typeof encoding === 'string' ? encoding : 'utf8');
        } else if (Buffer.isBuffer(chunk)) {
          buffer = chunk;
        } else if (ArrayBuffer.isView(chunk)) {
          buffer = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
        } else {
          return;
        }
      } catch (_) {
        return;
      }
      const remaining = proxyErrorCaptureLimitBytes - context.proxyResponseBytes;
      if (remaining <= 0) return;
      const captured = buffer.subarray(0, remaining);
      if (captured.length === 0) return;
      context.proxyResponseChunks.push(Buffer.from(captured));
      context.proxyResponseBytes += captured.length;
    }

    function normalizedProxyErrorMessage(context) {
      if (context.proxyResponseChunks.length === 0) return '';
      return Buffer.concat(context.proxyResponseChunks)
        .toString('utf8')
        .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ' ')
        .replace(/\s+/g, ' ')
        .trim()
        .slice(0, 1024);
    }

    function isExplicitProxyAuthorizationFailure(statusCode, message) {
      if (statusCode === 401 || statusCode === 403) return true;
      return /无法获取\s*(?:下载链接|转码信息)[\s\S]{0,128}(?:请)?检查授权/.test(
        message
      );
    }

    function publishProxyAuthorizationFailure(context) {
      if (!context.proxyRequest || context.proxyAuthorizationPublished) return;
      const statusCode = Number(context.response.statusCode || 0);
      const message = normalizedProxyErrorMessage(context);
      if (!isExplicitProxyAuthorizationFailure(statusCode, message)) return;
      const published = publishRuntimeHostMessage(context, {
        action: 'proxyAuthorizationRequired',
        opt: {
          statusCode,
          provider: context.proxyRequest.provider,
          message: message || `网盘代理返回 HTTP ${statusCode}，请检查授权`,
          transport: 'proxy'
        }
      });
      if (published) context.proxyAuthorizationPublished = true;
    }

    function pollHostMessage(request, response, invocationID, waitMilliseconds) {
      const context = invocations.get(invocationID);
      if (!context) {
        response.statusCode = 404;
        response.end();
        return;
      }
      if (context.hostMessages.length > 0) {
        const message = context.hostMessages.shift();
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

        const invocationID = invocationIDFromRequest(request);
        const context = invocationID ? invocations.get(invocationID) : null;
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

        const accepted = acceptHostMessage(value, invocationID);
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
          // Register the reply slot before the message becomes visible to the
          // host. Otherwise a fast host can POST its result while this key is
          // still absent and receive a false 404.
          pendingHostReplies.set(key, entry);
          if (!publishHostMessage(context, accepted)) {
            entry.completed = true;
            clearTimeout(entry.timer);
            pendingHostReplies.delete(key);
            response.statusCode = 400;
            response.end('{"ok":false}');
            return;
          }
          response.once('close', () => {
            if (!entry.completed && response.destroyed) {
              entry.completed = true;
              clearTimeout(entry.timer);
              pendingHostReplies.delete(key);
            }
          });
          return;
        }
        // A toast emitted while the request-scoped /play invocation is still
        // active belongs in that invocation's mailbox. Proxy requests cannot
        // be polled by libmpv, so their events use the filtered runtime queue.
        const published = accepted &&
          (accepted.action === 'toast' ||
           accepted.action === 'authorizationRequired'
          ? (context && context.playbackContext && !context.proxyRequest
              ? publishHostMessage(context, accepted)
              : publishRuntimeHostMessage(context, accepted))
          : publishHostMessage(context, accepted));
        response.statusCode = published ? 200 : 400;
        response.end(published ? '{"ok":true}' : '{"ok":false}');
      });
    }

    function attachHostMessageHeader(context) {
      if (context.response.headersSent || context.hostMessages.length === 0 || context.attached) return;
      const message = context.hostMessages.shift();
      const encoded = Buffer.from(JSON.stringify(message), 'utf8').toString('base64');
      context.attached = true;
      context.response.setHeader('X-OKVideo-Host-Message', encoded);
    }

    function startHostBridge() {
      if (hostBridgeServer && hostBridgePort > 0) return Promise.resolve();
      return new Promise((resolve, reject) => {
        const bridge = http.createServer((request, response) => {
          if (request.method === 'POST' && request.url === '/msg') {
            receiveHostMessage(request, response);
            return;
          }
          response.statusCode = 404;
          response.end();
        });
        const fail = (error) => {
          if (hostBridgeServer === bridge) hostBridgeServer = null;
          hostBridgePort = 0;
          reject(error);
        };
        bridge.once('error', fail);
        // CatPawOpen defines catDartServerPort() as a separate native-host
        // endpoint. Keep this listener outside the Runtime-owned listener set
        // so it can never attest itself as web content.
        originalNetListen.call(
          bridge,
          { port: 0, host: '127.0.0.1' },
          () => {
            bridge.removeListener('error', fail);
            const address = bridge.address();
            if (!address || typeof address === 'string' ||
                address.address !== '127.0.0.1' || address.port <= 0) {
              bridge.close();
              fail(new Error('contract-b host bridge listener rejected'));
              return;
            }
            hostBridgeServer = bridge;
            hostBridgePort = address.port;
            resolve();
          }
        );
      });
    }

    globalThis.catDartServerPort = function catDartServerPort() {
      return hostBridgePort;
    };
    function isLoopbackPeer(address) {
      return address === '127.0.0.1' || address === '::1' ||
        address === '::ffff:127.0.0.1';
    }
    function isConfigurationWebsitePath(pathname) {
      return pathname === '/website' || pathname.startsWith('/website/');
    }

    function pruneBaiduMediaSessions(now = Date.now()) {
      for (const [token, session] of baiduMediaSessions) {
        if (!session || session.expiresAt <= now) baiduMediaSessions.delete(token);
      }
      while (baiduMediaSessions.size > baiduMediaSessionLimit) {
        const oldest = baiduMediaSessions.keys().next().value;
        if (!oldest) break;
        baiduMediaSessions.delete(oldest);
      }
    }

    function normalizedBaiduMediaSession(value) {
      if (!value || typeof value !== 'object' || Array.isArray(value) ||
          typeof value.url !== 'string' || value.url.length > 16 * 1024) {
        return null;
      }
      let upstream;
      try { upstream = new URL(value.url); }
      catch (_) { return null; }
      if (upstream.protocol !== 'https:' ||
          upstream.hostname.toLowerCase() !== 'd.pcs.baidu.com') {
        return null;
      }
      const publishedHeaders = value.headers && typeof value.headers === 'object' &&
        !Array.isArray(value.headers) ? value.headers : {};
      let userAgent = '';
      let referer = '';
      for (const [name, headerValue] of Object.entries(publishedHeaders)) {
        if (typeof headerValue !== 'string' || headerValue.length > 8 * 1024 ||
            /[\r\n\0]/.test(headerValue)) continue;
        const normalizedName = String(name).toLowerCase();
        if (normalizedName === 'user-agent') userAgent = headerValue.trim();
        if (normalizedName === 'referer') referer = headerValue.trim();
      }
      // CatPawOpen's App-share dlink is issued for its exact netdisk identity.
      // Keep that provider-published User-Agent unchanged on every Range.
      if (!userAgent) return null;
      const headers = {'User-Agent': userAgent, 'Accept-Encoding': 'identity'};
      if (referer) headers.Referer = referer;
      return {
        // URL parsing above is validation only. Re-serializing a signed dlink
        // may percent-encode signature-covered bytes such as `devuid`.
        url: value.url,
        headers,
        expiresAt: Date.now() + baiduMediaSessionTTLMilliseconds
      };
    }

    function registerBaiduMediaSession(request, response) {
      let body = '';
      let exceededLimit = false;
      request.setEncoding('utf8');
      request.on('data', (chunk) => {
        if (exceededLimit) return;
        body += chunk;
        if (Buffer.byteLength(body, 'utf8') > 32 * 1024) {
          exceededLimit = true;
          body = '';
        }
      });
      request.on('end', () => {
        if (exceededLimit) {
          response.statusCode = 413;
          response.end();
          return;
        }
        let value = null;
        try { value = JSON.parse(body); }
        catch (_) {}
        const session = normalizedBaiduMediaSession(value);
        if (!session) {
          response.statusCode = 400;
          response.end();
          return;
        }
        pruneBaiduMediaSessions();
        const token = crypto.randomUUID();
        baiduMediaSessions.set(token, session);
        pruneBaiduMediaSessions();
        const port = Number(request.socket?.localPort || 0);
        if (!Number.isInteger(port) || port <= 0 || port > 65535) {
          baiduMediaSessions.delete(token);
          response.statusCode = 500;
          response.end();
          return;
        }
        response.statusCode = 201;
        response.setHeader('Content-Type', 'application/json; charset=utf-8');
        response.setHeader('Cache-Control', 'no-store');
        response.end(JSON.stringify({
          url: `http://127.0.0.1:${port}/__okvideo/baidu-media/${token}`
        }));
      });
    }

    async function proxyBaiduMediaSession(
      request,
      response,
      token,
      playbackContext
    ) {
      pruneBaiduMediaSessions();
      const session = baiduMediaSessions.get(token);
      if (!session) {
        response.statusCode = 404;
        response.end();
        return;
      }
      const headers = Object.assign({}, session.headers);
      const range = String(request.headers.range || '');
      if (range && range.length <= 256 && /^bytes=\d*-\d*(?:,\d*-\d*)*$/.test(range)) {
        headers.Range = range;
      }
      const ifRange = String(request.headers['if-range'] || '');
      if (ifRange && ifRange.length <= 512 && !/[\r\n\0]/.test(ifRange)) {
        headers['If-Range'] = ifRange;
      }
      const abortController = new AbortController();
      request.once('aborted', () => abortController.abort());
      response.once('close', () => {
        if (!response.writableEnded) abortController.abort();
      });
      let upstream;
      try {
        upstream = await originalFetch(session.url, {
          method: request.method === 'HEAD' ? 'HEAD' : 'GET',
          headers,
          redirect: 'follow',
          signal: abortController.signal
        });
      } catch (_) {
        if (!response.headersSent) response.statusCode = 502;
        if (!response.writableEnded) response.end();
        return;
      }
      response.statusCode = upstream.status;
      if ((upstream.status === 401 || upstream.status === 403) &&
          playbackContext) {
        publishRuntimeHostMessage({
          requestPath: playbackContext.runtimeModulePath,
          proxyRequest: {
            modulePath: playbackContext.runtimeModulePath,
            provider: 'baidu'
          },
          playbackContext
        }, {
          action: 'proxyAuthorizationRequired',
          opt: {
            statusCode: upstream.status,
            provider: 'baidu',
            message: `百度网盘代理返回 HTTP ${upstream.status}，请检查授权`,
            transport: 'proxy'
          }
        });
      }
      for (const name of [
        'accept-ranges', 'cache-control', 'content-disposition',
        'content-length', 'content-range', 'content-type', 'etag',
        'last-modified'
      ]) {
        const value = upstream.headers.get(name);
        if (value) response.setHeader(name, value);
      }
      response.setHeader('Cache-Control', 'no-store');
      if (request.method === 'HEAD' || !upstream.body) {
        response.end();
        return;
      }
      const stream = Readable.fromWeb(upstream.body);
      stream.once('error', () => {
        if (!response.headersSent) response.statusCode = 502;
        if (!response.writableEnded) response.end();
      });
      stream.pipe(response);
    }

    globalThis.catServerFactory = function catServerFactory(handler) {
      if (typeof handler !== 'function') {
        throw new Error('contract-b server factory arguments rejected');
      }
      const server = http.createServer((request, response) => {
        const requestURL = new URL(request.url || '/', 'http://127.0.0.1');
        const playbackContext = consumePlaybackContextFromProxy(
          request,
          requestURL
        ) || registerPlaybackContext(request, requestURL.pathname);
        // CatPawOpen intentionally publishes /website to the local network so
        // its QR code can be opened by a phone. Keep Spider, bridge and host
        // capability routes loopback-only even though the managed listener is
        // bound to every IPv4 interface.
        if (!isLoopbackPeer(request.socket?.remoteAddress) &&
            !isConfigurationWebsitePath(requestURL.pathname)) {
          response.statusCode = 403;
          response.end();
          return;
        }
        if (request.method === 'POST' && request.url === '/msg') {
          receiveHostMessage(request, response);
          return;
        }
        if (request.method === 'POST' &&
            requestURL.pathname === '/__okvideo/baidu-media') {
          registerBaiduMediaSession(request, response);
          return;
        }
        const baiduMediaPrefix = '/__okvideo/baidu-media/';
        if ((request.method === 'GET' || request.method === 'HEAD') &&
            requestURL.pathname.startsWith(baiduMediaPrefix)) {
          const token = requestURL.pathname.slice(baiduMediaPrefix.length);
          if (!/^[0-9a-f-]{36}$/i.test(token)) {
            response.statusCode = 404;
            response.end();
            return;
          }
          void proxyBaiduMediaSession(
            request,
            response,
            token,
            playbackContext
          );
          return;
        }
        if (request.method === 'GET' &&
            requestURL.pathname === '/__okvideo/owned-loopback') {
          const normalized = normalizeOwnedLoopbackURL(
            requestURL.searchParams.get('url') || ''
          );
          const allowsAnyInternalPath =
            requestURL.searchParams.get('purpose') === 'internal-webview';
          let isConfigurationWebsite = false;
          if (normalized) {
            try {
              const normalizedURL = new URL(normalized);
              isConfigurationWebsite = normalizedURL.pathname === '/website' ||
                normalizedURL.pathname === '/website/';
            } catch (_) {}
          }
          if (!normalized || (!allowsAnyInternalPath && !isConfigurationWebsite)) {
            response.statusCode = 404;
            response.end();
            return;
          }
          response.statusCode = 200;
          response.setHeader('Content-Type', 'application/json; charset=utf-8');
          response.end(JSON.stringify({url: normalized}));
          return;
        }
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
        if (request.method === 'GET' &&
            requestURL.pathname === '/__okvideo/runtime-host-message') {
          const requestedModulePath = requestURL.searchParams.get('source') || '';
          const modulePath = runtimeModulePath(requestedModulePath);
          if (!modulePath || modulePath !== requestedModulePath) {
            response.statusCode = 400;
            response.end();
            return;
          }
          const now = Date.now();
          const requestedNotBefore = Number(
            requestURL.searchParams.get('notBefore') || 0
          );
          const notBefore = Number.isFinite(requestedNotBefore)
            ? Math.max(now - runtimeHostMessageTTLMilliseconds,
                Math.min(requestedNotBefore, now + 1000))
            : now;
          const requestedPlaybackRequestID = normalizedUUID(
            requestURL.searchParams.get('playbackRequestID')
          );
          const requestedGeneration = normalizedGeneration(
            requestURL.searchParams.get('requestGeneration')
          );
          const requestedChallengeID = normalizedUUID(
            requestURL.searchParams.get('challengeID')
          );
          const hasPlaybackFilter = requestURL.searchParams.has(
            'playbackRequestID'
          ) || requestURL.searchParams.has('requestGeneration') ||
            requestURL.searchParams.has('challengeID');
          if (hasPlaybackFilter && (!requestedPlaybackRequestID ||
              !requestedGeneration || !requestedChallengeID)) {
            response.statusCode = 400;
            response.end();
            return;
          }
          pollRuntimeHostMessage(
            response,
            modulePath,
            notBefore,
            Number(requestURL.searchParams.get('wait') || 0),
            requestedPlaybackRequestID,
            requestedGeneration,
            requestedChallengeID
          );
          return;
        }
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
          requestPath: requestURL.pathname,
          playbackContext,
          proxyRequest: proxyRequestDescriptor(requestURL.pathname),
          proxyResponseChunks: [],
          proxyResponseBytes: 0,
          proxyAuthorizationPublished: false,
          hostMessages: [],
          attached: false,
          authorizationChallenge: false,
          waiters: [],
          removalTimer: null
        };
        invocations.set(invocationID, context);
        response.setHeader('X-OKVideo-Invocation-ID', invocationID);
        response.once('finish', () => scheduleInvocationRemoval(context));
        response.once('close', () => scheduleInvocationRemoval(context));
        const originalWriteHead = response.writeHead;
        const originalWrite = response.write;
        const originalEnd = response.end;
        response.writeHead = function controlledWriteHead(...args) {
          attachHostMessageHeader(context);
          return originalWriteHead.apply(response, args);
        };
        response.write = function controlledWrite(...args) {
          captureProxyResponseChunk(context, args[0], args[1]);
          return originalWrite.apply(response, args);
        };
        response.end = function controlledEnd(...args) {
          captureProxyResponseChunk(context, args[0], args[1]);
          if (!response.headersSent && args.length > 0 &&
              (typeof args[0] === 'string' || Buffer.isBuffer(args[0])) &&
              !response.hasHeader('Content-Encoding')) {
            const contentType = String(response.getHeader('Content-Type') || '')
              .toLowerCase();
            const isWebsitePage = requestURL.pathname === '/website' ||
              requestURL.pathname.startsWith('/website/');
            if (isWebsitePage && contentType.includes('text/html')) {
              const originalBody = Buffer.isBuffer(args[0])
                ? args[0].toString('utf8')
                : args[0];
              const repairedBody = repairLegacyWebAssetURLs(originalBody);
              if (repairedBody !== originalBody) {
                args[0] = Buffer.from(repairedBody, 'utf8');
                response.setHeader('Content-Length', args[0].length);
              }
            }
          }
          publishProxyAuthorizationFailure(context);
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
        const closing = Array.from(listeners, (listener) =>
          listener.listening
            ? new Promise((resolve) => listener.close(resolve))
            : Promise.resolve()
        );
        if (hostBridgeServer && hostBridgeServer.listening) {
          closing.push(
            new Promise((resolve) => hostBridgeServer.close(resolve))
          );
        }
        await Promise.all(closing);
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
      startHostBridge().then(() => runtime.start(config)).catch((error) => {
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
              state.host == "0.0.0.0",
              (1...65_535).contains(state.port)
        else { return nil }
        return state
    }
}
