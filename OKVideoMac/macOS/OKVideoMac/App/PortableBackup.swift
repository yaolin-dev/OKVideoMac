import CryptoKit
import Foundation
import OKVideoCore
import OKVideoPersistence
import UniformTypeIdentifiers

extension UTType {
    static let okVideoBackup = UTType(
        exportedAs: "com.okvideomac.backup",
        conformingTo: .json
    )
}

struct PortableBackupManifest: Codable, Equatable, Sendable {
    static let formatIdentifier = "com.okvideomac.portable-backup"
    static let currentSchemaVersion = 1

    var format: String
    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var activeConfigurationID: UUID
    var configurationCount: Int
    var historyCount: Int
}

struct PortableConfigurationRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sourceKind: StoredConfigurationSourceKind
    var sourceValue: String?
    var baseURL: URL?
    var rawData: Data
    var rawDataSHA256: String
    var updatedAt: Date

    init(_ record: StoredConfiguration) {
        id = record.id
        name = record.name
        sourceKind = record.sourceKind
        sourceValue = record.sourceValue
        baseURL = record.baseURL
        rawData = record.rawData
        rawDataSHA256 = PortableBackupCodec.sha256Hex(record.rawData)
        updatedAt = record.updatedAt
    }

    var storedConfiguration: StoredConfiguration {
        StoredConfiguration(
            id: id,
            name: name,
            sourceKind: sourceKind,
            sourceValue: sourceValue,
            baseURL: baseURL,
            rawData: rawData,
            updatedAt: updatedAt,
            isActive: true
        )
    }
}

struct PortableBackupPayload: Codable, Equatable, Sendable {
    var configuration: PortableConfigurationRecord
    var history: [HistoryRecord]
}

struct PortableBackupEnvelope: Codable, Equatable, Sendable {
    var manifest: PortableBackupManifest
    /// The payload remains a separately encoded byte sequence so its checksum
    /// verifies the exact exported bytes instead of a decoder's re-encoding.
    var payload: Data
    var payloadSHA256: String
}

struct DecodedPortableBackup: Equatable, Sendable {
    var manifest: PortableBackupManifest
    var payload: PortableBackupPayload
}

struct PortableBackupPreview: Identifiable, Equatable, Sendable {
    let id = UUID()
    var fileURL: URL
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var configurationName: String
    var historyCount: Int
}

struct PortableBackupImportSummary: Equatable, Sendable {
    var configurationName: String
    var historyCount: Int
    var changedHistoryCount: Int
    var safetyBackupURL: URL?
}

enum PortableBackupError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidDocument
    case unsupportedFormat
    case unsupportedSchema(Int)
    case checksumMismatch
    case invalidConfiguration
    case invalidHistory

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "备份文件超过允许的大小"
        case .invalidDocument:
            return "这不是有效的 OKVideoMac 备份文件"
        case .unsupportedFormat:
            return "备份文件格式不受支持"
        case .unsupportedSchema(let version):
            return "备份格式版本 \(version) 高于当前应用支持的版本"
        case .checksumMismatch:
            return "备份文件校验失败，文件可能已损坏或被修改"
        case .invalidConfiguration:
            return "备份中的点播配置不完整或校验失败"
        case .invalidHistory:
            return "备份中的历史记录不完整或包含不安全字段"
        }
    }
}

enum PortableBackupCodec {
    static let maximumArchiveByteCount = 32 * 1_024 * 1_024
    static let maximumHistoryCount = 50_000

    static func encode(
        configuration: StoredConfiguration,
        history: [HistoryRecord],
        appVersion: String,
        appBuild: String,
        createdAt: Date = Date()
    ) throws -> Data {
        guard !configuration.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              !configuration.rawData.isEmpty,
              configuration.rawData.count
                <= ConfigurationParser.maximumConfigurationSize else {
            throw PortableBackupError.invalidConfiguration
        }

        let sanitizedHistory = try normalizedHistory(
            history,
            configurationID: configuration.id
        )
        let payload = PortableBackupPayload(
            configuration: PortableConfigurationRecord(configuration),
            history: sanitizedHistory
        )
        let payloadData = try encoder().encode(payload)
        let manifest = PortableBackupManifest(
            format: PortableBackupManifest.formatIdentifier,
            schemaVersion: PortableBackupManifest.currentSchemaVersion,
            createdAt: createdAt,
            appVersion: appVersion,
            appBuild: appBuild,
            activeConfigurationID: configuration.id,
            configurationCount: 1,
            historyCount: sanitizedHistory.count
        )
        let envelope = PortableBackupEnvelope(
            manifest: manifest,
            payload: payloadData,
            payloadSHA256: sha256Hex(payloadData)
        )
        let data = try encoder().encode(envelope)
        guard data.count <= maximumArchiveByteCount else {
            throw PortableBackupError.fileTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> DecodedPortableBackup {
        guard !data.isEmpty, data.count <= maximumArchiveByteCount else {
            throw data.isEmpty
                ? PortableBackupError.invalidDocument
                : PortableBackupError.fileTooLarge
        }
        let envelope: PortableBackupEnvelope
        do {
            envelope = try decoder().decode(
                PortableBackupEnvelope.self,
                from: data
            )
        } catch {
            throw PortableBackupError.invalidDocument
        }
        guard envelope.manifest.format
            == PortableBackupManifest.formatIdentifier else {
            throw PortableBackupError.unsupportedFormat
        }
        guard envelope.manifest.schemaVersion
            <= PortableBackupManifest.currentSchemaVersion else {
            throw PortableBackupError.unsupportedSchema(
                envelope.manifest.schemaVersion
            )
        }
        guard envelope.manifest.schemaVersion > 0,
              envelope.manifest.configurationCount == 1,
              sha256Hex(envelope.payload) == envelope.payloadSHA256 else {
            throw PortableBackupError.checksumMismatch
        }

        let payload: PortableBackupPayload
        do {
            payload = try decoder().decode(
                PortableBackupPayload.self,
                from: envelope.payload
            )
        } catch {
            throw PortableBackupError.invalidDocument
        }
        let configuration = payload.configuration
        guard configuration.id == envelope.manifest.activeConfigurationID,
              !configuration.name.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !configuration.rawData.isEmpty,
              configuration.rawData.count
                <= ConfigurationParser.maximumConfigurationSize,
              sha256Hex(configuration.rawData)
                == configuration.rawDataSHA256 else {
            throw PortableBackupError.invalidConfiguration
        }
        guard payload.history.count == envelope.manifest.historyCount,
              payload.history.count <= maximumHistoryCount else {
            throw PortableBackupError.invalidHistory
        }
        let history = try normalizedHistory(
            payload.history,
            configurationID: configuration.id
        )
        guard history == payload.history else {
            throw PortableBackupError.invalidHistory
        }
        return DecodedPortableBackup(
            manifest: envelope.manifest,
            payload: payload
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedHistory(
        _ history: [HistoryRecord],
        configurationID: UUID
    ) throws -> [HistoryRecord] {
        guard history.count <= maximumHistoryCount else {
            throw PortableBackupError.invalidHistory
        }
        var newestByID: [String: HistoryRecord] = [:]
        for original in history {
            guard original.configurationID == configurationID,
                  isBounded(original.siteKey, maximum: 1_024),
                  isBounded(original.videoID, maximum: 4_096),
                  isBounded(original.title, maximum: 4_096),
                  isBounded(original.sourceKey, maximum: 4_096) else {
                throw PortableBackupError.invalidHistory
            }
            let record = original.sanitizedForPersistence()
            guard record == original else {
                throw PortableBackupError.invalidHistory
            }
            if let existing = newestByID[record.id],
               existing.watchedAt >= record.watchedAt {
                continue
            }
            newestByID[record.id] = record
        }
        return newestByID.values.sorted {
            if $0.watchedAt != $1.watchedAt {
                return $0.watchedAt > $1.watchedAt
            }
            return $0.id < $1.id
        }
    }

    private static func isBounded(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
