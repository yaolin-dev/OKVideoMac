// A one-shot, silent decoder. The parent owns the deadline and may terminate
// this process even if a third-party demuxer is blocked. No media URL is logged.
import Foundation
import CoreGraphics
import ImageIO
import OpenGL.GL3
import Darwin

struct Request: Decodable {
    let url: String
    let headers: [String: String]
    let timeoutSeconds: Double?
    let networkOptions: [String: String]?
    let collectTimings: Bool?
}
enum CaptureError: Error { case invalid, runtime, graphics, timeout, media }
// Layout is checked against the bundled bridge before any event is read.
struct NativeEvent {
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
let startedAt = ProcessInfo.processInfo.systemUptime
var timings: [String: Double] = [:]
var collectTimings = false
func mark(_ stage: String) { timings[stage] = ProcessInfo.processInfo.systemUptime - startedAt }
func reportTimings() {
    guard collectTimings, let data = try? JSONSerialization.data(withJSONObject: timings, options: .sortedKeys) else { return }
    FileHandle.standardError.write(Data("preview-timings: ".utf8))
    FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8))
}
typealias Handle = OpaquePointer
typealias GetProc = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

var stage = "input"
func capture() throws -> Data {
    let input = FileHandle.standardInput.readData(ofLength: 65_537)
    guard input.count <= 65_536, let request = try? JSONDecoder().decode(Request.self, from: input),
          let url = URL(string: request.url), ["http", "https", "rtsp", "rtmp", "udp", "rtp", "file"].contains(url.scheme?.lowercased() ?? ""),
          request.headers.count <= 64,
          request.headers.allSatisfy({ !$0.key.contains(where: { $0.isNewline || $0 == "\0" }) && !$0.value.contains(where: { $0.isNewline || $0 == "\0" }) }) else { throw CaptureError.invalid }
    collectTimings = request.collectTimings == true
    mark("input")
    let budget = min(25, max(1, request.timeoutSeconds ?? 12))
    guard budget.isFinite else { throw CaptureError.invalid }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget + 0.5) { _exit(2) }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let libraryURL = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Frameworks/libOKMPVBridge.dylib")
    stage = "library"
    guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { throw CaptureError.runtime }
    // Keep the library loaded until process exit; native threads can outlive a handle.
    func symbol<T>(_ name: String, _: T.Type) throws -> T {
        guard let address = dlsym(library, name) else { throw CaptureError.runtime }
        return unsafeBitCast(address, to: T.self)
    }
    let create = try symbol("okmpv_create", (@convention(c) () -> Handle?).self)
    let initialize = try symbol("okmpv_initialize", (@convention(c) (Handle?) -> Int32).self)
    let set = try symbol("okmpv_set_option_string", (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self)
    let command = try symbol("okmpv_command", (@convention(c) (Handle?, Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> Int32).self)
    let get = try symbol("okmpv_get_property_string", (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32).self)
    let renderCreate = try symbol("okmpv_render_create", (@convention(c) (Handle?, GetProc?, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Handle?>?) -> Int32).self)
    let update = try symbol("okmpv_render_update", (@convention(c) (Handle?) -> UInt64).self)
    let render = try symbol("okmpv_render", (@convention(c) (Handle?, Int32, Int32, Int32, Int32) -> Int32).self)
    let renderDestroy = try symbol("okmpv_render_destroy", (@convention(c) (Handle?) -> Void).self)
    let destroy = try symbol("okmpv_destroy", (@convention(c) (Handle?) -> Void).self)
    let waitEvent = try symbol("okmpv_wait_event", (@convention(c) (Handle?, Double, UnsafeMutableRawPointer?) -> Int32).self)
    let eventSize = try symbol("okmpv_event_size", (@convention(c) () -> Int32).self)
    guard eventSize() == MemoryLayout<NativeEvent>.size else { throw CaptureError.runtime }
    mark("library")
    stage = "client"
    guard let client = create() else { throw CaptureError.runtime }
    defer { destroy(client) }
    let options = ["config":"no", "terminal":"no", "load-scripts":"no", "idle":"yes",
                   "keep-open":"yes", "vo":"libmpv", "aid":"no", "sid":"no", "osd-level":"0",
                   "hwdec":"auto-safe", "network-timeout":String(Int(min(10, budget))), "demuxer-max-bytes":"16777216",
                   "demuxer-readahead-secs":"1",
                   "user-agent":request.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value ?? "OKVideoMac/0.3.18",
                   "referrer":request.headers.first(where: { $0.key.lowercased() == "referer" })?.value ?? ""]
    for (key, value) in options { stage = "option:" + key; let result = set(client, key, value); guard result >= 0 || (key == "load-scripts" && result == -5) else { throw CaptureError.runtime } }
    for (key, value) in request.networkOptions ?? [:] {
        guard ["http-proxy", "stream-lavf-o", "demuxer-lavf-o", "tls-verify"].contains(key),
              !value.contains("\0"), !value.contains(where: { $0.isNewline }) else { throw CaptureError.invalid }
        guard set(client, key, value) >= 0 else { throw CaptureError.runtime }
    }
    stage = "initialize"
    if !request.headers.isEmpty {
        let headerSet = try symbol("okmpv_set_property_string_array", (@convention(c) (Handle?, UnsafePointer<CChar>?, Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> Int32).self)
        // Set the native list property after initialization below, without comma escaping.
        guard initialize(client) >= 0 else { throw CaptureError.runtime }
        let fields = request.headers.sorted { $0.key < $1.key }.map { strdup($0.key + ": " + $0.value)! }
        defer { fields.forEach { free($0) } }
        let pointers = fields.map { UnsafePointer<CChar>($0) as UnsafePointer<CChar>? }
        guard headerSet(client, "http-header-fields", Int32(pointers.count), pointers) >= 0 else { throw CaptureError.runtime }
    } else { guard initialize(client) >= 0 else { throw CaptureError.runtime } }

    mark("initialized")
    stage = "graphics"
    let attributes: [CGLPixelFormatAttribute] = [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue), kCGLPFAAccelerated, CGLPixelFormatAttribute(rawValue: 0)]
    var pixelFormat: CGLPixelFormatObj?, count: GLint = 0
    guard CGLChoosePixelFormat(attributes, &pixelFormat, &count) == kCGLNoError, let pixelFormat else { throw CaptureError.graphics }
    defer { CGLDestroyPixelFormat(pixelFormat) }
    var context: CGLContextObj?
    guard CGLCreateContext(pixelFormat, nil, &context) == kCGLNoError, let context else { throw CaptureError.graphics }
    defer { CGLSetCurrentContext(nil); CGLDestroyContext(context) }
    CGLSetCurrentContext(context)
    guard let openGL = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW) else { throw CaptureError.graphics }
    let getProc: GetProc = { context, name in guard let name else { return nil }; return dlsym(context, name) }
    var renderer: Handle?
    guard renderCreate(client, getProc, openGL, 0, &renderer) >= 0, let renderer else { throw CaptureError.graphics }
    defer { renderDestroy(renderer) }
    let width: Int32 = 640, height: Int32 = 360
    var texture: GLuint = 0, framebuffer: GLuint = 0
    glGenTextures(1, &texture); glBindTexture(GLenum(GL_TEXTURE_2D), texture)
    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, width, height, 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
    glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
    glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
    guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { throw CaptureError.graphics }
    mark("graphics")
    stage = "load"
    let arguments = ["loadfile", request.url].map { (value: String) in value.withCString { strdup($0)! } }
    defer { arguments.forEach { free($0) } }
    let pointers = arguments.map { UnsafePointer<CChar>($0) as UnsafePointer<CChar>? }
    guard command(client, Int32(pointers.count), pointers) >= 0 else { throw CaptureError.runtime }
    mark("load-issued")
    let deadline = ProcessInfo.processInfo.systemUptime + budget
    while ProcessInfo.processInfo.systemUptime < deadline {
        // END_FILE/error is definitive. END_FILE/redirect (reason 5) is not:
        // playlists and redirects must be allowed to open their next entry.
        for _ in 0..<64 {
            var event = NativeEvent()
            guard waitEvent(client, 0, &event) >= 0 else { throw CaptureError.runtime }
            if event.eventID == 0 { break }
            if event.eventID == 1 || (event.eventID == 7 && (event.error < 0 || event.endFileReason == 4)) {
                mark("media-failed"); throw CaptureError.media
            }
        }
        if update(renderer) & 1 != 0 {
            guard render(renderer, Int32(framebuffer), width, height, 0) >= 0 else { throw CaptureError.graphics }
            var position = [CChar](repeating: 0, count: 64)
            var videoWidth = [CChar](repeating: 0, count: 64)
            if get(client, "time-pos", &position, 64) >= 0,
               get(client, "video-params/w", &videoWidth, 64) >= 0,
               (Int(String(cString: videoWidth)) ?? 0) > 0 {
                mark("first-frame")
                var pixels = [UInt8](repeating: 0, count: Int(width * height * 4))
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
                glReadPixels(0, 0, width, height, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixels)
                guard glGetError() == GLenum(GL_NO_ERROR),
                      let provider = CGDataProvider(data: Data(pixels) as CFData),
                      let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: Int(width * 4), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CaptureError.graphics }
                mark("pixels-read")
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw CaptureError.graphics }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CaptureError.graphics }
                mark("encoded")
                return data as Data
            }
        }
        usleep(15_000)
    }
    throw CaptureError.timeout
}

// A hard process-local deadline also covers parent crashes and native calls
// that cannot observe Swift cancellation. No worker may outlive this budget.
DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 28) { _exit(2) }
do {
    let image = try capture()
    mark("cleanup")
    reportTimings()
    FileHandle.standardOutput.write(image)
    exit(0)
} catch {
    mark("failed")
    reportTimings()
    // Only a fixed error category; never source URLs or account headers.
    FileHandle.standardError.write(Data("preview: \(stage): \(error)\n".utf8))
    exit(1)
}
