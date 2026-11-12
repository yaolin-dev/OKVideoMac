import Foundation
import CrashReporter
import CryptoKit

/// Explicit diagnostic schema. Exception text is bounded and redacted; operations are typed.
public struct CrashRecord: Codable, Equatable, Sendable {
    public struct Image: Codable, Equatable, Sendable {
        public let uuid: String
        public let base: UInt64
        public let size: UInt64
        public let name: String
        public let vmaddr: UInt64?
    }
    public struct Frame: Codable, Equatable, Sendable {
        public let pc: UInt64
        public let imageBase: UInt64?
    }
    public struct Thread: Codable, Equatable, Sendable {
        public let number: Int
        public let crashed: Bool
        public let frames: [Frame] // oldest first, as required by Sentry
    }
    public struct ExceptionInfo: Codable, Equatable, Sendable {
        public let name: String
        public let reason: String
        public let frames: [Frame] // original throw stack, oldest first; empty means unavailable
    }
    public var exception: ExceptionInfo? = nil
    public var operations: [CrashOperation]? = nil
    public var imageCount: Int? = nil
    public var omittedImageCount: Int? = nil
    public let id: String
    public let timestamp: Date
    public let version: String
    public let build: String
    public let osVersion: String
    public let architecture: String
    public let signal: String
    public let signalCode: String
    public let threads: [Thread]
    public let images: [Image]
}

public struct RunMetadata: Codable, Sendable {
    public let version: String
    public let build: String
    public let imageVMAddresses: [String: UInt64]?
    public var operations: [CrashOperation]? = nil
    var operationSession: String? = nil
    public init(version: String, build: String, imageVMAddresses: [String: UInt64]? = nil) {
        self.version = version; self.build = build; self.imageVMAddresses = imageVMAddresses
    }
}

public enum CrashMapper {
    public static let maxRawBytes = 1_048_576
    public static let maxRecordBytes = 4_194_304
    public static func parse(_ data: Data) throws -> CrashRecord {
        try parse(data, loadOperations: { _ in nil })
    }
    static func parse(_ data: Data, loadOperations: (String) -> [CrashOperation]?) throws -> CrashRecord {
        guard data.count <= maxRawBytes else { throw CrashDiagnosticError.invalidReport }
        let report = try PLCrashReport(data: data)
        guard let rawMeta = report.customData,
              let meta = try? JSONDecoder().decode(RunMetadata.self, from: rawMeta),
              numeric(meta.version), numeric(meta.build) else { throw CrashDiagnosticError.invalidReport }
        let rawImages = report.images as? [PLCrashReportBinaryImageInfo] ?? []
        let rawThreads = Array((report.threads as? [PLCrashReportThreadInfo] ?? []).prefix(128))
        let originalFrames = report.exceptionInfo?.stackFrames as? [PLCrashReportStackFrameInfo] ?? []
        // Resolve against the complete image list BEFORE applying a payload budget.
        // A late-loaded decoder or plugin must not lose its mapping behind system frameworks.
        let pcs = originalFrames.prefix(256).map(\.instructionPointer)
            + rawThreads.flatMap { ($0.stackFrames as? [PLCrashReportStackFrameInfo] ?? []).prefix(256).map(\.instructionPointer) }
        let mappedImages: [CrashRecord.Image] = rawImages.compactMap { image in
            guard image.hasImageUUID, let uuid = uuidString(image.imageUUID), image.imageSize > 0 else { return nil }
            let basename = URL(fileURLWithPath: image.imageName).lastPathComponent
            return .init(uuid: uuid, base: image.imageBaseAddress, size: image.imageSize,
                         name: basename == "OKVideoMac" ? basename : "image-\(uuid)",
                         vmaddr: meta.imageVMAddresses?[uuid])
        }
        let images = selectImages(mappedImages, referencedPCs: pcs)
        func frames(_ raw: [PLCrashReportStackFrameInfo]) -> [CrashRecord.Frame] {
            raw.prefix(256).map { frame in
                let pc = frame.instructionPointer
                let image = images.first { pc >= $0.base && pc - $0.base < $0.size }
                return CrashRecord.Frame(pc: pc, imageBase: image?.base)
            }.reversed()
        }
        let threads = rawThreads.map { thread in
            CrashRecord.Thread(number: thread.threadNumber, crashed: thread.crashed,
                frames: frames(thread.stackFrames as? [PLCrashReportStackFrameInfo] ?? []))
        }
        guard threads.contains(where: { $0.crashed && !$0.frames.isEmpty }), !images.isEmpty else { throw CrashDiagnosticError.invalidReport }
        let digest = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let cpu = report.machineInfo?.processorInfo?.type ?? report.systemInfo.processorInfo.type
        let architecture = cpu == 0x0100000c ? "arm64" : cpu == 0x01000007 ? "x86_64" : "unknown"
        var result = CrashRecord(id: digest, timestamp: report.systemInfo.timestamp,
                     version: meta.version, build: meta.build,
                     osVersion: numeric(report.systemInfo.operatingSystemVersion) ? report.systemInfo.operatingSystemVersion : "unknown",
                     architecture: architecture,
                     signal: allowedCode(report.signalInfo.name), signalCode: allowedCode(report.signalInfo.code),
                     threads: threads, images: images)
        if let exception = report.exceptionInfo {
            result.exception = .init(name: ExceptionRedactor.name(exception.exceptionName),
                reason: ExceptionRedactor.reason(exception.exceptionReason), frames: frames(originalFrames))
        }
        result.operations = meta.operationSession.flatMap(loadOperations)
            ?? meta.operations.map { Array($0.suffix(CrashOperation.capacity)) }
        result.imageCount = mappedImages.count
        result.omittedImageCount = mappedImages.count - images.count
        guard result.isValid else { throw CrashDiagnosticError.invalidReport }
        return result
    }
    static func selectImages(_ images: [CrashRecord.Image], referencedPCs: [UInt64]) -> [CrashRecord.Image] {
        let referenced = images.filter { image in
            image.name == "OKVideoMac" || referencedPCs.contains { $0 >= image.base && $0 - image.base < image.size }
        }
        let bases = Set(referenced.map(\.base))
        return Array((referenced + images.filter { !bases.contains($0.base) }).prefix(4096))
    }
    static func numeric(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.unicodeScalars.allSatisfy { "0123456789.".unicodeScalars.contains($0) }
    }
    static func allowedCode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789")
        return value.count <= 64 && !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains) ? value : "UNKNOWN"
    }
    static func uuidString(_ input: String) -> String? {
        let hex = input.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains) else { return nil }
        let parts = [8, 4, 4, 4, 12]; var index = hex.startIndex
        let formatted = parts.map { count -> String in
            let end = hex.index(index, offsetBy: count); defer { index = end }
            return String(hex[index..<end])
        }.joined(separator: "-")
        return UUID(uuidString: formatted)?.uuidString
    }
}

extension CrashRecord {
    var isValid: Bool {
        id.count == 32 && id.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789abcdef").contains)
        && CrashMapper.numeric(version) && CrashMapper.numeric(build)
        && (osVersion == "unknown" || CrashMapper.numeric(osVersion))
        && ["arm64", "x86_64", "unknown"].contains(architecture)
        && CrashMapper.allowedCode(signal) == signal && CrashMapper.allowedCode(signalCode) == signalCode
        && timestamp.timeIntervalSince1970.isFinite
        && !images.isEmpty && images.count <= 4096 && images.allSatisfy {
            CrashMapper.uuidString($0.uuid) == $0.uuid && $0.size > 0
            && ["OKVideoMac", "image-" + $0.uuid].contains($0.name)
        }
        && (exception.map {
            $0.name == ExceptionRedactor.name($0.name) && $0.reason == ExceptionRedactor.reason($0.reason)
            && $0.frames.count <= 256
        } ?? true)
        && (operations.map { $0.count <= CrashOperation.capacity && $0.allSatisfy(\.isValid) } ?? true)
        && (imageCount.map { $0 >= images.count } ?? true)
        && (omittedImageCount.map { $0 >= 0 && $0 == (imageCount ?? images.count) - images.count } ?? true)
        && !threads.isEmpty && threads.count <= 128
        && threads.contains { $0.crashed && !$0.frames.isEmpty }
        && threads.allSatisfy { $0.number >= 0 && $0.frames.count <= 256 }
    }
}

public enum CrashDiagnosticError: Error { case invalidReport, alreadyRunning, invalidConfiguration, unavailable }
