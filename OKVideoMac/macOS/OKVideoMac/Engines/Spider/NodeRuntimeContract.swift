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
    /// Only the common, data-only host schema is supplied. Remote companion
    /// JavaScript is intentionally not evaluated or required.
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
        guard data.count <= 1_024 * 1_024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = root["sites"] as? [String: Any],
              sites["list"] is [Any],
              let pans = root["pans"] as? [String: Any],
              pans["list"] is [Any],
              root["danmu"] is [String: Any],
              root["color"] is [Any]
        else {
            throw NodeBundleRuntimeError.configurationContractInvalid
        }
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
        profileURL: URL? = nil
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
            let config = try ContractBConfigBuilder.buildMinimumConfiguration()
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
    const invocationTTLMilliseconds = 5000;
    const originalFetch = globalThis.fetch;
    const originalHTTPRequest = http.request;
    const originalHTTPSRequest = https.request;

    function writeState(state) {
      const temporary = statePath + '.tmp-' + process.pid;
      fs.writeFileSync(temporary, JSON.stringify(state), { mode: 0o600 });
      fs.renameSync(temporary, statePath);
    }

    function validateConfig(config) {
      const list = (value) => value && Array.isArray(value.list);
      if (!config || typeof config !== 'object' || Array.isArray(config) ||
          !list(config.sites) || !list(config.pans) ||
          !config.danmu || typeof config.danmu !== 'object' ||
          !Array.isArray(config.color)) {
        throw new Error('contract-b configuration rejected');
      }
      return config;
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
      if (!value || value.action !== 'openInternalWebview' ||
          !value.opt || typeof value.opt !== 'object') {
        return null;
      }
      const url = normalizeOwnedLoopbackURL(value.opt.url);
      if (!url) return null;
      const message = { action: 'openInternalWebview', opt: { url } };
      return message;
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
      const minimumConfig = validateConfig(
        JSON.parse(fs.readFileSync(configPath, 'utf8'))
      );
      let config = minimumConfig;
      const profile = readProfile();
      try { config = validateConfig(profile); }
      catch (_) { config = minimumConfig; }
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
