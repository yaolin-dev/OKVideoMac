import AppKit
import AVFoundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 640, AVVideoHeightKey: 360])
let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
    kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
writer.add(input)
guard writer.startWriting() else { fatalError("writer start \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
for frame in 0..<360 {
    let deadline = Date().addingTimeInterval(10)
    while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    guard input.isReadyForMoreMediaData else { fatalError("writer blocked") }
    var pixel: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &pixel) == kCVReturnSuccess, let pixel else { fatalError("pool") }
    CVPixelBufferLockBaseAddress(pixel, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 640, height: 360, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(NSColor(calibratedRed: 0.2, green: 0.06, blue: 0.3, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    ctx.setFillColor(NSColor.systemGreen.cgColor)
    ctx.fill(CGRect(x: (frame * 3) % 560, y: 80, width: 80, height: 200))
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(8)
    ctx.stroke(CGRect(x: 4, y: 4, width: 632, height: 352))
    if frame % 30 < 3 {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 560, y: 290, width: 60, height: 50))
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("MPV NATIVE PiP · Frame \(frame)" as NSString).draw(at: NSPoint(x: 24, y: 24),
        withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(pixel, [])
    guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { fatalError("append") }
}
input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else { fatalError("finish \(String(describing: writer.error))") }
print("Synthetic fixture generated: 640x360 H.264, 12 seconds, no network or user media")

let composition = AVMutableComposition()
let videoAsset = AVURLAsset(url: url)
let audioAsset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[2]))
let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 12, preferredTimescale: 48000))
try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: videoAsset.tracks(withMediaType: .video)[0], at: .zero)
try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: audioAsset.tracks(withMediaType: .audio)[0], at: .zero)
let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
export.outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
export.outputFileType = .mov
let done = DispatchSemaphore(value: 0)
export.exportAsynchronously { done.signal() }
guard done.wait(timeout: .now() + 30) == .success, export.status == .completed else { fatalError("fixture mux failed") }
print("Fixture muxed with synchronized quiet PCM beeps and white flashes")
