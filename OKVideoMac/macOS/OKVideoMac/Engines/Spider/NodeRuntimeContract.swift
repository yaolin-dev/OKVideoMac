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
        runtimeDirectory: URL
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
                    "OKVIDEO_CONTRACT_B_STATE_PATH": stateURL.path
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
    const net = require('net');
    const bundlePath = process.env.OKVIDEO_BUNDLE_PATH;
    const configPath = process.env.OKVIDEO_CONTRACT_B_CONFIG_PATH;
    const statePath = process.env.OKVIDEO_CONTRACT_B_STATE_PATH;
    const parentPID = Number(process.env.OKVIDEO_PARENT_PID || 0);
    let runtime = null;
    let stopping = false;
    const managedListener = Symbol('okvideo-managed-listener');
    const listeners = new Set();
    const originalNetListen = net.Server.prototype.listen;

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

    globalThis.catDartServerPort = function catDartServerPort() { return 0; };
    globalThis.catServerFactory = function catServerFactory(handler) {
      if (typeof handler !== 'function') {
        throw new Error('contract-b server factory arguments rejected');
      }
      const server = http.createServer((request, response) => {
        handler(request, response);
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
      const config = validateConfig(JSON.parse(fs.readFileSync(configPath, 'utf8')));
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
