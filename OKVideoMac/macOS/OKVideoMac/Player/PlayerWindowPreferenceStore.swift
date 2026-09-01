import AppKit
import Foundation

enum PlayerWindowMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automaticAspect
    case fixedFrame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automaticAspect: return "自动匹配画面"
        case .fixedFrame: return "固定上次大小"
        }
    }
}

struct PlayerWindowPreference: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultViewingWidth = 1_152.0
    static let defaultFixedWidth = 1_152.0
    static let defaultFixedHeight = 648.0

    var version: Int
    var mode: PlayerWindowMode
    var viewingWidth: Double
    var fixedWidth: Double
    var fixedHeight: Double
    var screenIdentifier: UInt32?
    var normalizedCenterX: Double?
    var normalizedCenterY: Double?

    static let `default` = PlayerWindowPreference(
        version: currentVersion,
        mode: .automaticAspect,
        viewingWidth: defaultViewingWidth,
        fixedWidth: defaultFixedWidth,
        fixedHeight: defaultFixedHeight,
        screenIdentifier: nil,
        normalizedCenterX: nil,
        normalizedCenterY: nil
    )
}

enum PlayerWindowPreferencePolicy {
    static let minimumContentWidth = 640.0
    static let minimumContentHeight = 360.0
    static let screenMargin = 40.0
    static let fallbackAspectRatio = 16.0 / 9.0

    static func sanitized(
        _ preference: PlayerWindowPreference
    ) -> PlayerWindowPreference {
        var result = preference
        result.version = PlayerWindowPreference.currentVersion
        result.viewingWidth = validLength(
            result.viewingWidth,
            fallback: PlayerWindowPreference.defaultViewingWidth
        )
        result.fixedWidth = validLength(
            result.fixedWidth,
            fallback: PlayerWindowPreference.defaultFixedWidth
        )
        result.fixedHeight = validLength(
            result.fixedHeight,
            fallback: PlayerWindowPreference.defaultFixedHeight
        )
        result.normalizedCenterX = normalized(result.normalizedCenterX)
        result.normalizedCenterY = normalized(result.normalizedCenterY)
        return result
    }

    static func contentSize(
        preference: PlayerWindowPreference,
        aspectRatio: Double,
        maximum: NSSize
    ) -> NSSize {
        let preference = sanitized(preference)
        let maximumWidth = max(1, Double(maximum.width))
        let maximumHeight = max(1, Double(maximum.height))

        switch preference.mode {
        case .automaticAspect:
            let ratio = validAspectRatio(aspectRatio)
                ?? fallbackAspectRatio
            let requestedWidth = max(
                minimumContentWidth,
                preference.viewingWidth
            )
            let width = min(
                requestedWidth,
                maximumWidth,
                maximumHeight * ratio
            )
            return NSSize(
                width: CGFloat(width),
                height: CGFloat(width / ratio)
            )

        case .fixedFrame:
            let requestedWidth = max(
                minimumContentWidth,
                preference.fixedWidth
            )
            let requestedHeight = max(
                minimumContentHeight,
                preference.fixedHeight
            )
            let scale = min(
                1,
                maximumWidth / requestedWidth,
                maximumHeight / requestedHeight
            )
            return NSSize(
                width: CGFloat(requestedWidth * scale),
                height: CGFloat(requestedHeight * scale)
            )
        }
    }

    static func normalizedCenter(
        frame: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint? {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else { return nil }
        return NSPoint(
            x: min(
                1,
                max(0, (frame.midX - visibleFrame.minX) / visibleFrame.width)
            ),
            y: min(
                1,
                max(0, (frame.midY - visibleFrame.minY) / visibleFrame.height)
            )
        )
    }

    static func frameOrigin(
        frameSize: NSSize,
        visibleFrame: NSRect,
        normalizedCenterX: Double?,
        normalizedCenterY: Double?
    ) -> NSPoint {
        let centerX = normalized(normalizedCenterX) ?? 0.5
        let centerY = normalized(normalizedCenterY) ?? 0.5
        let desired = NSPoint(
            x: visibleFrame.minX + visibleFrame.width * CGFloat(centerX)
                - frameSize.width / 2,
            y: visibleFrame.minY + visibleFrame.height * CGFloat(centerY)
                - frameSize.height / 2
        )
        return NSPoint(
            x: min(
                max(desired.x, visibleFrame.minX),
                visibleFrame.maxX - frameSize.width
            ),
            y: min(
                max(desired.y, visibleFrame.minY),
                visibleFrame.maxY - frameSize.height
            )
        )
    }

    static func ratiosMatch(
        _ lhs: Double?,
        _ rhs: Double,
        tolerance: Double = 0.01
    ) -> Bool {
        guard let lhs = validAspectRatio(lhs),
              let rhs = validAspectRatio(rhs) else { return false }
        return abs(lhs - rhs) / max(lhs, rhs) < tolerance
    }

    static func validAspectRatio(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              value > 0 else { return nil }
        return value
    }

    private static func validLength(
        _ value: Double,
        fallback: Double
    ) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

@MainActor
final class PlayerWindowPreferenceStore: ObservableObject {
    static let storageKey = "OKVideoMac.PlayerWindowPreference.v1"
    static let legacyFrameAutosaveName = "OKVideoMac.PlayerWindow.v2"

    @Published private(set) var preference: PlayerWindowPreference
    private(set) var hasPersistedPreference: Bool

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "OKVideoMac.PlayerWindowPreference.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
                PlayerWindowPreference.self,
                from: data
           ) {
            preference = PlayerWindowPreferencePolicy.sanitized(decoded)
            hasPersistedPreference = true
        } else {
            preference = .default
            hasPersistedPreference = false
        }
    }

    func setMode(_ mode: PlayerWindowMode) {
        guard preference.mode != mode else { return }
        preference.mode = mode
        persist()
    }

    func captureModeTransition(
        to mode: PlayerWindowMode,
        currentContentSize: NSSize
    ) {
        guard currentContentSize.width.isFinite,
              currentContentSize.height.isFinite,
              currentContentSize.width > 0,
              currentContentSize.height > 0 else { return }
        switch mode {
        case .automaticAspect:
            preference.viewingWidth = Double(currentContentSize.width)
        case .fixedFrame:
            preference.fixedWidth = Double(currentContentSize.width)
            preference.fixedHeight = Double(currentContentSize.height)
        }
        persist()
    }

    func saveUserFrame(
        contentSize: NSSize,
        windowFrame: NSRect,
        visibleFrame: NSRect,
        screenIdentifier: UInt32?
    ) {
        guard contentSize.width.isFinite,
              contentSize.height.isFinite,
              contentSize.width > 0,
              contentSize.height > 0 else { return }

        switch preference.mode {
        case .automaticAspect:
            preference.viewingWidth = Double(contentSize.width)
        case .fixedFrame:
            preference.fixedWidth = Double(contentSize.width)
            preference.fixedHeight = Double(contentSize.height)
        }

        preference.screenIdentifier = screenIdentifier
        if let center = PlayerWindowPreferencePolicy.normalizedCenter(
            frame: windowFrame,
            visibleFrame: visibleFrame
        ) {
            preference.normalizedCenterX = Double(center.x)
            preference.normalizedCenterY = Double(center.y)
        }
        persist()
    }

    func migrateLegacyFrame(
        contentSize: NSSize,
        windowFrame: NSRect,
        visibleFrame: NSRect,
        screenIdentifier: UInt32?
    ) {
        guard !hasPersistedPreference else {
            clearLegacyFrame()
            return
        }
        preference = .default
        preference.mode = .automaticAspect
        preference.viewingWidth = Double(contentSize.width)
        preference.fixedWidth = Double(contentSize.width)
        preference.fixedHeight = Double(contentSize.height)
        preference.screenIdentifier = screenIdentifier
        if let center = PlayerWindowPreferencePolicy.normalizedCenter(
            frame: windowFrame,
            visibleFrame: visibleFrame
        ) {
            preference.normalizedCenterX = Double(center.x)
            preference.normalizedCenterY = Double(center.y)
        }
        persist()
        clearLegacyFrame()
    }

    func ensurePersisted() {
        guard !hasPersistedPreference else { return }
        persist()
    }

    func reset() {
        preference = .default
        defaults.removeObject(forKey: storageKey)
        hasPersistedPreference = false
        clearLegacyFrame()
        persist()
    }

    func clearLegacyFrame() {
        defaults.removeObject(
            forKey: "NSWindow Frame \(Self.legacyFrameAutosaveName)"
        )
    }

    func legacyFrame() -> NSRect? {
        guard let value = defaults.string(
            forKey: "NSWindow Frame \(Self.legacyFrameAutosaveName)"
        ) else { return nil }
        let components = value
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        guard components.count >= 4,
              components[0].isFinite,
              components[1].isFinite,
              components[2].isFinite,
              components[3].isFinite,
              components[2] > 0,
              components[3] > 0 else { return nil }
        return NSRect(
            x: components[0],
            y: components[1],
            width: components[2],
            height: components[3]
        )
    }

    private func persist() {
        preference = PlayerWindowPreferencePolicy.sanitized(preference)
        if let data = try? JSONEncoder().encode(preference) {
            defaults.set(data, forKey: storageKey)
            hasPersistedPreference = true
        }
    }
}

extension NSScreen {
    var okVideoScreenIdentifier: UInt32? {
        (deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
    }
}
