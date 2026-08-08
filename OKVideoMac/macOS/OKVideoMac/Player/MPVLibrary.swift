import Darwin
import Foundation
import OKVideoCore

typealias MPVGetProcAddress = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

typealias MPVRenderUpdateCallback = @convention(c) (
    UnsafeMutableRawPointer?
) -> Void

struct NativeMPVEvent {
    var eventID: Int32 = 0
    var error: Int32 = 0
    var replyUserdata: UInt64 = 0
    var propertyFormat: Int32 = 0
    var propertyName: UnsafePointer<CChar>?
    var stringValue: UnsafePointer<CChar>?
    var doubleValue: Double = 0
    var int64Value: Int64 = 0
    var flagValue: Int32 = 0
    var endFileReason: Int32 = 0
}

final class MPVLibrary {
    typealias Create = @convention(c) () -> OpaquePointer?
    typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
    typealias Wakeup = @convention(c) (OpaquePointer?) -> Void
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    typealias SetOptionString = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Int32
    typealias Command = @convention(c) (
        OpaquePointer?,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    typealias SetPropertyString = SetOptionString
    typealias SetPropertyDouble = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        Double
    ) -> Int32
    typealias SetPropertyFlag = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        Int32
    ) -> Int32
    typealias SetPropertyStringArray = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    typealias ObserveProperty = @convention(c) (
        OpaquePointer?,
        UInt64,
        UnsafePointer<CChar>?,
        Int32
    ) -> Int32
    typealias WaitEvent = @convention(c) (
        OpaquePointer?,
        Double,
        UnsafeMutableRawPointer?
    ) -> Int32
    typealias TrackCount = @convention(c) (OpaquePointer?) -> Int32
    typealias TrackAt = @convention(c) (
        OpaquePointer?,
        Int32,
        UnsafeMutablePointer<Int64>?,
        UnsafeMutablePointer<CChar>?,
        Int32,
        UnsafeMutablePointer<CChar>?,
        Int32,
        UnsafeMutablePointer<CChar>?,
        Int32,
        UnsafeMutablePointer<Int32>?
    ) -> Int32
    typealias ErrorString = @convention(c) (
        Int32
    ) -> UnsafePointer<CChar>?
    typealias VersionString = @convention(c) () -> UnsafePointer<CChar>?
    typealias EventSize = @convention(c) () -> Int32
    typealias RenderCreate = @convention(c) (
        OpaquePointer?,
        MPVGetProcAddress?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32
    typealias RenderSetUpdateCallback = @convention(c) (
        OpaquePointer?,
        MPVRenderUpdateCallback?,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias RenderUpdate = @convention(c) (OpaquePointer?) -> UInt64
    typealias Render = @convention(c) (
        OpaquePointer?,
        Int32,
        Int32,
        Int32,
        Int32
    ) -> Int32
    typealias RenderReportSwap = @convention(c) (OpaquePointer?) -> Void
    typealias RenderDestroy = @convention(c) (OpaquePointer?) -> Void

    let create: Create
    let initialize: Initialize
    let wakeup: Wakeup
    let destroy: Destroy
    let setOptionString: SetOptionString
    let command: Command
    let setPropertyString: SetPropertyString
    let setPropertyDouble: SetPropertyDouble
    let setPropertyFlag: SetPropertyFlag
    let setPropertyStringArray: SetPropertyStringArray
    let observeProperty: ObserveProperty
    let waitEvent: WaitEvent
    let trackCount: TrackCount
    let trackAt: TrackAt
    let nativeErrorString: ErrorString
    let nativeVersionString: VersionString
    let nativeEventSize: EventSize
    let renderCreate: RenderCreate
    let renderSetUpdateCallback: RenderSetUpdateCallback
    let renderUpdate: RenderUpdate
    let render: Render
    let renderReportSwap: RenderReportSwap
    let renderDestroy: RenderDestroy

    private let handle: UnsafeMutableRawPointer

    init(bundle: Bundle = .main) throws {
        guard let frameworksURL = bundle.privateFrameworksURL else {
            throw AppError.playback("应用包没有 Frameworks 目录")
        }
        let bridgeURL = frameworksURL.appendingPathComponent(
            "libOKMPVBridge.dylib"
        )
        guard FileManager.default.fileExists(atPath: bridgeURL.path) else {
            throw AppError.playback("应用包缺少 libOKMPVBridge.dylib")
        }
        guard let handle = dlopen(bridgeURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "未知错误"
            throw AppError.playback("无法载入 libmpv 桥：\(message)")
        }
        self.handle = handle
        do {
            create = try Self.symbol("okmpv_create", handle: handle)
            initialize = try Self.symbol("okmpv_initialize", handle: handle)
            wakeup = try Self.symbol("okmpv_wakeup", handle: handle)
            destroy = try Self.symbol("okmpv_destroy", handle: handle)
            setOptionString = try Self.symbol(
                "okmpv_set_option_string",
                handle: handle
            )
            command = try Self.symbol("okmpv_command", handle: handle)
            setPropertyString = try Self.symbol(
                "okmpv_set_property_string",
                handle: handle
            )
            setPropertyDouble = try Self.symbol(
                "okmpv_set_property_double",
                handle: handle
            )
            setPropertyFlag = try Self.symbol(
                "okmpv_set_property_flag",
                handle: handle
            )
            setPropertyStringArray = try Self.symbol(
                "okmpv_set_property_string_array",
                handle: handle
            )
            observeProperty = try Self.symbol(
                "okmpv_observe_property",
                handle: handle
            )
            waitEvent = try Self.symbol("okmpv_wait_event", handle: handle)
            trackCount = try Self.symbol("okmpv_track_count", handle: handle)
            trackAt = try Self.symbol("okmpv_track_at", handle: handle)
            nativeErrorString = try Self.symbol(
                "okmpv_error_string",
                handle: handle
            )
            nativeVersionString = try Self.symbol(
                "okmpv_client_api_version_string",
                handle: handle
            )
            nativeEventSize = try Self.symbol(
                "okmpv_event_size",
                handle: handle
            )
            renderCreate = try Self.symbol(
                "okmpv_render_create",
                handle: handle
            )
            renderSetUpdateCallback = try Self.symbol(
                "okmpv_render_set_update_callback",
                handle: handle
            )
            renderUpdate = try Self.symbol(
                "okmpv_render_update",
                handle: handle
            )
            render = try Self.symbol("okmpv_render", handle: handle)
            renderReportSwap = try Self.symbol(
                "okmpv_render_report_swap",
                handle: handle
            )
            renderDestroy = try Self.symbol(
                "okmpv_render_destroy",
                handle: handle
            )
            guard nativeEventSize() == MemoryLayout<NativeMPVEvent>.size else {
                throw AppError.playback("libmpv 桥事件 ABI 与 Swift 不匹配")
            }
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        dlclose(handle)
    }

    var version: String {
        nativeVersionString().map { String(cString: $0) } ?? "unknown"
    }

    func errorString(for code: Int32) -> String {
        nativeErrorString(code).map { String(cString: $0) }
            ?? "libmpv error \(code)"
    }

    func checked(_ code: Int32, operation: String) throws {
        guard code >= 0 else {
            throw AppError.playback("\(operation)：\(errorString(for: code))")
        }
    }

    private static func symbol<T>(
        _ name: String,
        handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw AppError.playback("libmpv 桥缺少符号 \(name)")
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

func withMPVCStringArray<Result>(
    _ values: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?) throws -> Result
) rethrows -> Result {
    let pointers = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(
        capacity: max(values.count, 1)
    )
    var allocated: [UnsafeMutablePointer<CChar>] = []
    defer {
        for pointer in allocated {
            free(pointer)
        }
        pointers.deallocate()
    }
    for (index, value) in values.enumerated() {
        let pointer = strdup(value)
        allocated.append(pointer!)
        pointers[index] = UnsafePointer(pointer)
    }
    return try body(values.isEmpty ? nil : UnsafePointer(pointers))
}
