import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo

final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

final class Prototype: NSObject, NSApplicationDelegate, NSWindowDelegate,
    AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    var window: NSWindow!
    var video: VideoView!
    var pip: AVPictureInPictureController!
    var timer: Timer?
    var observation: NSKeyValueObservation?
    var timebase: CMTimebase!
    var pool: CVPixelBufferPool!
    var frameCount = 0
    var startCount = 0
    var stopCount = 0
    var paused = false
    var status = "ready"
    var lastWrite = 0.0
    var statusLabel: NSTextField!
    var events: [[String: Any]] = []
    var mode = "sample-live"
    var rangeQueries = 0
    var pauseQueries = 0
    var player: AVQueuePlayer?
    var looper: AVPlayerLooper?
    var pendingStart: UUID?
    let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    let runID = UUID().uuidString
    var evidence: URL { root.appendingPathComponent("Evidence/api-probe.json") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PiP Prototype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 800, height: 590),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OKVideo PiP Stage 0 — Public API Probe"
        window.identifier = NSUserInterfaceItemIdentifier("OKVideo.PiP.Stage0")
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        video = VideoView(frame: NSRect(x: 0, y: 140, width: 800, height: 450))
        video.autoresizingMask = [.width, .height]
        content.addSubview(video)
        let buttons: [(String, Selector)] = [
            ("Start PiP", #selector(startPiP)), ("Return to Player", #selector(stopPiP)),
            ("Play / Pause", #selector(togglePause))]
        for (index, entry) in buttons.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: entry.1)
            button.frame = NSRect(x: 16 + index * 175, y: 46, width: 165, height: 30)
            content.addSubview(button)
        }
        let modes: [(String, Selector)] = [("SampleBuffer Live", #selector(useSampleLive)),
                                           ("SampleBuffer VOD", #selector(useSampleVOD)),
                                           ("AVPlayer Control", #selector(usePlayer))]
        for (index, entry) in modes.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: entry.1)
            button.frame = NSRect(x: 16 + index * 175, y: 92, width: 165, height: 30)
            content.addSubview(button)
        }
        statusLabel = NSTextField(labelWithString: "Preparing public API")
        statusLabel.frame = NSRect(x: 20, y: 14, width: 760, height: 24)
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                       sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1)
        video.displayLayer.controlTimebase = timebase
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                  kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
                                  kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        configureSample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        window.makeKeyAndOrderFront(nil)
        record("launched")
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if mode != "avplayer-control" && (!paused || frameCount == 0) {
            var pixel: CVPixelBuffer?
            let allocation = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
            if CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, allocation, &pixel) == kCVReturnSuccess,
               let pixel {
                CVPixelBufferLockBaseAddress(pixel, [])
                if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 640, height: 360,
                                           bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    let p = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
                    context.setFillColor(NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.30, alpha: 1).cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                    context.setFillColor(NSColor.systemTeal.cgColor)
                    context.fill(CGRect(x: (p * 100).truncatingRemainder(dividingBy: 560), y: 80, width: 80, height: 200))
                    let text = "PUBLIC API · Frame \(frameCount) · \(String(format: "%.2f", p))s" as NSString
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    text.draw(at: NSPoint(x: 24, y: 24), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
                    NSGraphicsContext.restoreGraphicsState()
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTimebaseGetTime(timebase), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                if let format {
                    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
                }
                if video.displayLayer.status == .failed { video.displayLayer.flush() }
                if let sample, video.displayLayer.isReadyForMoreMediaData { video.displayLayer.enqueue(sample); frameCount += 1 }
            }
        }
        if now - lastWrite > 1 { lastWrite = now; writeEvidence() }
    }
    @objc func startPiP() {
        guard !pip.isPictureInPictureActive, pendingStart == nil else { return }
        status = "starting"
        let token = UUID()
        pendingStart = token
        pip.startPictureInPicture()
        record("start-request")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.pendingStart == token else { return }
            self.pendingStart = nil
            if !self.pip.isPictureInPictureActive {
                self.status = "unavailable (bounded 5s probe)"
                self.record("start-timeout")
            }
        }
    }
    @objc func stopPiP() { pip.stopPictureInPicture(); record("stop-request") }
    @objc func togglePause() { setPaused(!paused) }
    func setPaused(_ value: Bool) {
        paused = value
        CMTimebaseSetRate(timebase, rate: value ? 0 : 1)
        if mode == "avplayer-control" { value ? player?.pause() : player?.play() }
        pip.invalidatePlaybackState()
        record(value ? "paused" : "playing")
    }
    func record(_ event: String) {
        events.append(["event": event, "mode": mode, "uptime": ProcessInfo.processInfo.systemUptime, "frame": frameCount])
        writeEvidence()
    }
    func writeEvidence() {
        let sampleReady: Any
        if #available(macOS 14.4, *) { sampleReady = video.displayLayer.isReadyForDisplay }
        else { sampleReady = "unavailable-before-14.4" }
        let value: [String: Any] = ["mode": mode, "runID": runID, "supported": AVPictureInPictureController.isPictureInPictureSupported(),
                                   "possible": pip?.isPictureInPicturePossible ?? false, "active": pip?.isPictureInPictureActive ?? false,
                                   "suspended": pip?.isPictureInPictureSuspended ?? false, "state": status, "paused": paused,
                                   "frames": frameCount, "position": CMTimeGetSeconds(CMTimebaseGetTime(timebase)),
                                   "starts": startCount, "stops": stopCount, "windowMiniaturized": window.isMiniaturized,
                                   "sampleLayerReady": sampleReady,
                                   "timeRangeDelegateCalls": rangeQueries, "pausedDelegateCalls": pauseQueries,
                                   "playerPosition": player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0,
                                   "playerRate": player?.rate ?? 0, "playerLayerReady": video.playerLayer.isReadyForDisplay,
                                   "layerStatus": video.displayLayer.status.rawValue, "events": events]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: evidence, options: .atomic)
            try? data.write(to: root.appendingPathComponent("Evidence/run-\(runID).json"), options: .atomic)
        }
        statusLabel.stringValue = "\(mode) · \(status) · possible \(pip?.isPictureInPicturePossible ?? false) · frame \(frameCount)"
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { pendingStart = nil; startCount += 1; status = "active"; record("did-start") }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { stopCount += 1; status = "inline"; record("did-stop") }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { pendingStart = nil; status = "failed"; record("start-failed:\((error as NSError).domain):\((error as NSError).code)") }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); record("restore-request"); completionHandler(true)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) { setPaused(!playing) }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange { rangeQueries += 1; return CMTimeRange(start: .zero, duration: mode == "sample-vod" ? CMTime(seconds: 3600, preferredTimescale: 600) : .positiveInfinity) }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { pauseQueries += 1; return paused }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { record("render-size:\(newRenderSize.width)x\(newRenderSize.height)") }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); record("terminated") }
    func attachObservation() {
        pip.delegate = self
        status = "ready"
        observation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.record("possibility-changed") }
        }
    }
    func canSwitch() -> Bool {
        guard !pip.isPictureInPictureActive, pendingStart == nil else { record("mode-switch-rejected-active"); return false }
        observation = nil
        player?.pause()
        looper = nil
        player = nil
        video.playerLayer.player = nil
        return true
    }
    func configureSample() {
        video.displayLayer.isHidden = false
        video.playerLayer.isHidden = true
        pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: video.displayLayer, playbackDelegate: self))
        attachObservation()
    }
    @objc func useSampleLive() { guard canSwitch() else { return }; mode = "sample-live"; configureSample(); pip.invalidatePlaybackState(); record("mode-live") }
    @objc func useSampleVOD() { guard canSwitch() else { return }; mode = "sample-vod"; configureSample(); pip.invalidatePlaybackState(); record("mode-vod") }
    @objc func usePlayer() {
        guard canSwitch() else { return }
        mode = "avplayer-control"
        let item = AVPlayerItem(url: Bundle.main.resourceURL!.appendingPathComponent("control.mov"))
        let queue = AVQueuePlayer()
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        video.playerLayer.player = queue
        video.playerLayer.isHidden = false
        video.displayLayer.isHidden = true
        pip = AVPictureInPictureController(contentSource: .init(playerLayer: video.playerLayer))
        attachObservation()
        if !paused { queue.play() }
        record("mode-avplayer")
    }
}

let app = NSApplication.shared
let prototype = Prototype()
app.delegate = prototype
app.run()
