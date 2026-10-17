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
    ctx.setFillColor(NSColor.systemOrange.cgColor)
    ctx.fill(CGRect(x: (frame * 3) % 560, y: 80, width: 80, height: 200))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("AVPLAYER CONTROL · Frame \(frame)" as NSString).draw(at: NSPoint(x: 24, y: 24),
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
