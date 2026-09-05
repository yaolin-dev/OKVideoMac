#!/usr/bin/env swift

import AppKit
import AVFoundation
import CoreVideo
import Foundation

enum DemoVideoError: Error, CustomStringConvertible {
    case missingFrames(URL)
    case cannotDecode(URL)
    case cannotAddInput
    case cannotCreatePixelBuffer
    case writerFailed(String)

    var description: String {
        switch self {
        case .missingFrames(let url): return "No generated frames found at \(url.path)"
        case .cannotDecode(let url): return "Cannot decode frame \(url.lastPathComponent)"
        case .cannotAddInput: return "AVAssetWriter rejected the H.264 video input"
        case .cannotCreatePixelBuffer: return "Cannot allocate a video pixel buffer"
        case .writerFailed(let message): return "Video writer failed: \(message)"
        }
    }
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootURL = scriptURL.deletingLastPathComponent()
let framesURL = rootURL.appendingPathComponent("assets/video-frames", isDirectory: true)
let outputURL = rootURL.appendingPathComponent("assets/media/demo-landscape.mp4")
let fileManager = FileManager.default
try fileManager.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try? fileManager.removeItem(at: outputURL)

let frameURLs = try fileManager.contentsOfDirectory(
    at: framesURL,
    includingPropertiesForKeys: nil
).filter { $0.pathExtension.lowercased() == "jpg" }
 .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !frameURLs.isEmpty else { throw DemoVideoError.missingFrames(framesURL) }

let width = 1280
let height = 720
let fps: Int32 = 12
let repeatCount = 8
let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 1_400_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
    ],
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
guard writer.canAdd(input) else { throw DemoVideoError.cannotAddInput }
writer.add(input)

let sourceAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: sourceAttributes
)

func pixelBuffer(for imageURL: URL, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
    guard let nsImage = NSImage(contentsOf: imageURL),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw DemoVideoError.cannotDecode(imageURL)
    }
    var maybeBuffer: CVPixelBuffer?
    let result: CVReturn
    if let pool {
        result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
    } else {
        result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            sourceAttributes as CFDictionary,
            &maybeBuffer
        )
    }
    guard result == kCVReturnSuccess, let buffer = maybeBuffer else {
        throw DemoVideoError.cannotCreatePixelBuffer
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                CGImageAlphaInfo.premultipliedFirst.rawValue
          ) else {
        throw DemoVideoError.cannotCreatePixelBuffer
    }
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

guard writer.startWriting() else {
    throw DemoVideoError.writerFailed(writer.error?.localizedDescription ?? "unknown start error")
}
writer.startSession(atSourceTime: .zero)

let outputFrameCount = frameURLs.count * repeatCount
for index in 0..<outputFrameCount {
    let frameURL = frameURLs[index % frameURLs.count]
    while !input.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    let buffer = try autoreleasepool {
        try pixelBuffer(for: frameURL, pool: adaptor.pixelBufferPool)
    }
    let presentationTime = CMTime(value: CMTimeValue(index), timescale: fps)
    guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
        throw DemoVideoError.writerFailed(writer.error?.localizedDescription ?? "append failed")
    }
}

input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else {
    throw DemoVideoError.writerFailed(writer.error?.localizedDescription ?? "unknown finish error")
}

let duration = Double(outputFrameCount) / Double(fps)
print(
    "Created \(outputURL.path) from \(frameURLs.count) original landscape frames " +
    "(\(Int(duration)) seconds, repeated scenic sequence)"
)
