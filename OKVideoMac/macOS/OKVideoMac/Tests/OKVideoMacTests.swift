import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

final class OKVideoMacTests: XCTestCase {
    func testConfigurationActivationTrackerLatestRequestWinsABC() {
        var tracker = ConfigurationActivationRequestTracker()
        let configurationA = UUID()
        let configurationB = UUID()
        let configurationC = UUID()

        let tokenA = tracker.begin(configurationA)
        let tokenB = tracker.begin(configurationB)
        let tokenC = tracker.begin(configurationC)

        XCTAssertFalse(tracker.owns(tokenA))
        XCTAssertFalse(tracker.owns(tokenB))
        XCTAssertTrue(tracker.owns(tokenC))
        XCTAssertEqual(tracker.requestedConfigurationID, configurationC)

        tracker.finish(tokenA)
        tracker.finish(tokenB)
        XCTAssertEqual(tracker.requestedConfigurationID, configurationC)
        tracker.finish(tokenC)
        XCTAssertNil(tracker.requestedConfigurationID)
    }

    func testConfigurationActivationTrackerLatestRequestWinsABA() {
        var tracker = ConfigurationActivationRequestTracker()
        let configurationA = UUID()
        let configurationB = UUID()

        let firstA = tracker.begin(configurationA)
        let tokenB = tracker.begin(configurationB)
        let finalA = tracker.begin(configurationA)

        XCTAssertFalse(tracker.owns(firstA))
        XCTAssertFalse(tracker.owns(tokenB))
        XCTAssertTrue(tracker.owns(finalA))

        tracker.finish(firstA)
        tracker.finish(tokenB)
        XCTAssertEqual(tracker.requestedConfigurationID, configurationA)
        tracker.finish(finalA)
        XCTAssertNil(tracker.requestedConfigurationID)
    }

    func testConfigurationActivationTrackerLatestRequestWinsBAB() {
        var tracker = ConfigurationActivationRequestTracker()
        let configurationA = UUID()
        let configurationB = UUID()

        let firstB = tracker.begin(configurationB)
        let tokenA = tracker.begin(configurationA)
        let finalB = tracker.begin(configurationB)

        XCTAssertFalse(tracker.owns(firstB))
        XCTAssertFalse(tracker.owns(tokenA))
        XCTAssertTrue(tracker.owns(finalB))
        XCTAssertEqual(tracker.requestedConfigurationID, configurationB)
    }

    func testConfigurationActivationTrackerLatestRequestWinsABCAC() {
        var tracker = ConfigurationActivationRequestTracker()
        let configurationA = UUID()
        let configurationB = UUID()
        let configurationC = UUID()

        let tokens = [
            tracker.begin(configurationA),
            tracker.begin(configurationB),
            tracker.begin(configurationC),
            tracker.begin(configurationA),
            tracker.begin(configurationC)
        ]

        XCTAssertTrue(tokens.dropLast().allSatisfy { !tracker.owns($0) })
        XCTAssertTrue(tracker.owns(tokens[4]))
        XCTAssertEqual(tracker.requestedConfigurationID, configurationC)
    }

    func testConfigurationActivationErrorPolicySilencesExpectedCancellation() {
        XCTAssertFalse(
            ConfigurationActivationErrorPolicy.shouldPresent(
                CancellationError(),
                ownsCurrentRequest: true
            )
        )
        XCTAssertFalse(
            ConfigurationActivationErrorPolicy.shouldPresent(
                AppError.configuration("stale failure"),
                ownsCurrentRequest: false
            )
        )
    }

    func testConfigurationActivationErrorPolicyPresentsLatestRealFailure() {
        XCTAssertTrue(
            ConfigurationActivationErrorPolicy.shouldPresent(
                AppError.configuration("latest failure"),
                ownsCurrentRequest: true
            )
        )
    }

    func testConfigurationSwitchFeedbackOnlyLatestRequestCanComplete() {
        var tracker = ConfigurationActivationRequestTracker()
        let tokenA = tracker.begin(UUID())
        let tokenB = tracker.begin(UUID())
        var feedback = ConfigurationSwitchFeedbackPolicy.switching(
            token: tokenB,
            targetName: "Source B"
        )

        feedback = ConfigurationSwitchFeedbackPolicy.success(
            current: feedback,
            token: tokenA,
            targetName: "Source A",
            ownsCurrentRequest: tracker.owns(tokenA)
        )
        XCTAssertEqual(
            feedback,
            .switching(tokenB, targetName: "Source B")
        )

        feedback = ConfigurationSwitchFeedbackPolicy.success(
            current: feedback,
            token: tokenB,
            targetName: "Source B",
            ownsCurrentRequest: tracker.owns(tokenB)
        )
        XCTAssertEqual(feedback, .success(tokenB, targetName: "Source B"))
        XCTAssertTrue(
            ConfigurationSwitchFeedbackPolicy.shouldDismiss(
                feedback,
                token: tokenB
            )
        )
        XCTAssertFalse(
            ConfigurationSwitchFeedbackPolicy.shouldDismiss(
                feedback,
                token: tokenA
            )
        )
    }

    func testConfigurationSwitchFeedbackReportsLatestFailureWithoutModalState() {
        var tracker = ConfigurationActivationRequestTracker()
        let token = tracker.begin(UUID())
        let switching = ConfigurationSwitchFeedbackPolicy.switching(
            token: token,
            targetName: "Broken Source"
        )

        let failure = ConfigurationSwitchFeedbackPolicy.failure(
                current: switching,
                token: token,
                targetName: "Broken Source",
                message: "Unable to load home",
                ownsCurrentRequest: tracker.owns(token)
            )
        XCTAssertEqual(
            failure,
            .failure(
                token,
                targetName: "Broken Source",
                message: "Unable to load home"
            )
        )
        XCTAssertTrue(
            ConfigurationSwitchFeedbackPolicy.shouldDismiss(
                failure,
                token: token
            )
        )
    }

    func testConfigurationSwitchFeedbackClearPolicyClearsStaleFeedback() {
        let token = ConfigurationActivationToken(
            generation: 1,
            configurationID: UUID()
        )

        XCTAssertTrue(
            ConfigurationSwitchFeedbackPolicy.shouldClear(
                .success(token, targetName: "Source A"),
                hasActiveActivationRequest: false
            )
        )
        XCTAssertTrue(
            ConfigurationSwitchFeedbackPolicy.shouldClear(
                .failure(
                    token,
                    targetName: "Source A",
                    message: "Unable to load"
                ),
                hasActiveActivationRequest: false
            )
        )
        XCTAssertTrue(
            ConfigurationSwitchFeedbackPolicy.shouldClear(
                .switching(token, targetName: "Orphaned Source"),
                hasActiveActivationRequest: false
            )
        )
        XCTAssertFalse(
            ConfigurationSwitchFeedbackPolicy.shouldClear(
                .idle,
                hasActiveActivationRequest: false
            )
        )
    }

    func testConfigurationSwitchFeedbackClearPolicyPreservesActiveRequest() {
        let token = ConfigurationActivationToken(
            generation: 2,
            configurationID: UUID()
        )
        for feedback in [
            ConfigurationSwitchFeedback.switching(
                token,
                targetName: "Source B"
            ),
            .success(token, targetName: "Source B"),
            .failure(
                token,
                targetName: "Source B",
                message: "Latest failure"
            )
        ] {
            XCTAssertFalse(
                ConfigurationSwitchFeedbackPolicy.shouldClear(
                    feedback,
                    hasActiveActivationRequest: true
                )
            )
        }
    }

    func testConfigurationActivationRuntimeCleanupIsOwnedByLatestNonNodeTarget() {
        XCTAssertTrue(
            ConfigurationActivationRuntimePolicy.shouldStopNodeRuntime(
                targetEndpoint: nil,
                ownsCurrentRequest: true
            )
        )
        XCTAssertFalse(
            ConfigurationActivationRuntimePolicy.shouldStopNodeRuntime(
                targetEndpoint: nil,
                ownsCurrentRequest: false
            )
        )
        XCTAssertFalse(
            ConfigurationActivationRuntimePolicy.shouldStopNodeRuntime(
                targetEndpoint: URL(string: "http://127.0.0.1:12345"),
                ownsCurrentRequest: true
            )
        )
    }

    func testImportURLNormalizationOnlyTrimsEdges() throws {
        let exact = "https://user:pass@example.invalid/a%20b/config.js.md5?q=x%2By#fragment"
        let raw = " \t\n\(exact)\r\n "

        XCTAssertEqual(ImportURLInput.normalized(raw), exact)
        XCTAssertEqual(
            try XCTUnwrap(ImportURLInput.httpURL(from: raw)).absoluteString,
            exact
        )
    }

    func testImportURLValidationUsesNormalizedValueWithoutInternalRewrite() {
        XCTAssertNil(ImportURLInput.httpURL(from: "  file:///tmp/config.json  "))
        XCTAssertEqual(
            ImportURLInput.normalized("\nhttps://example.invalid/a?x=one two\t"),
            "https://example.invalid/a?x=one two"
        )
    }

    @MainActor
    func testImportURLTextFieldSynchronizesNativeChangesImmediately() {
        var value = ""
        let field = NSTextField(string: "https://example.invalid/config.json")
        let coordinator = ImportURLTextField.Coordinator(
            text: Binding(
                get: { value },
                set: { value = $0 }
            )
        )

        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )

        XCTAssertEqual(value, "https://example.invalid/config.json")
        XCTAssertNotNil(ImportURLInput.httpURL(from: value))
    }

    func testImportProgressMessagesDescribeActualCommitStage() {
        XCTAssertEqual(
            ConfigurationImportPhase.downloadingAndParsing.title,
            "正在下载并解析…"
        )
        XCTAssertEqual(
            ConfigurationImportPhase.startingNodeRuntime.title,
            "正在启动 Node Runtime…"
        )
        XCTAssertEqual(
            ConfigurationImportPhase.activating.title,
            "正在启用配置…"
        )
        XCTAssertEqual(
            LiveSourceImportPhase.publishing.title,
            "正在发布到直播列表…"
        )
    }

    func testNativePlayerSurfaceMountsOnlyWhilePlayerIsVisible() {
        XCTAssertFalse(
            PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: false,
                hasRenderPlayer: true
            )
        )
        XCTAssertFalse(
            PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: true,
                hasRenderPlayer: false
            )
        )
        XCTAssertTrue(
            PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: true,
                hasRenderPlayer: true
            )
        )
    }

    func testPlayerBackdropDoesNotWaitForNativeRenderClient() {
        XCTAssertFalse(
            PlayerSurfaceBackdropPolicy.shouldShow(
                isPlayerPresented: false
            )
        )
        XCTAssertTrue(
            PlayerSurfaceBackdropPolicy.shouldShow(
                isPlayerPresented: true
            )
        )
    }

    func testMPVRenderSafetyRejectsWindowResizeAndInvalidGeometry() {
        XCTAssertNil(
            MPVRenderSafetyPolicy.framebufferSize(
                backingBounds: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
                isInLiveResize: true,
                isAttachedToWindow: true
            )
        )
        XCTAssertNil(
            MPVRenderSafetyPolicy.framebufferSize(
                backingBounds: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
                isInLiveResize: false,
                isAttachedToWindow: false
            )
        )
        XCTAssertNil(
            MPVRenderSafetyPolicy.framebufferSize(
                backingBounds: NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat.infinity,
                    height: 1
                ),
                isInLiveResize: false,
                isAttachedToWindow: true
            )
        )
        let valid = MPVRenderSafetyPolicy.framebufferSize(
            backingBounds: NSRect(x: 0, y: 0, width: 1_919.6, height: 1_079.6),
            isInLiveResize: false,
            isAttachedToWindow: true
        )
        XCTAssertEqual(valid?.width, 1_920)
        XCTAssertEqual(valid?.height, 1_080)
    }

    func testRenderSurfaceReadinessRequiresAttachedUsableDrawable() {
        XCTAssertTrue(
            MPVRenderSurfaceReadinessPolicy.isReady(
                isAttachedToWindow: true,
                hasSuperview: true,
                hasOpenGLContext: true,
                hasRenderContext: true,
                drawableWidth: 1_920,
                drawableHeight: 1_080
            )
        )
        XCTAssertFalse(
            MPVRenderSurfaceReadinessPolicy.isReady(
                isAttachedToWindow: true,
                hasSuperview: true,
                hasOpenGLContext: true,
                hasRenderContext: true,
                drawableWidth: 0,
                drawableHeight: 1_080
            )
        )
        XCTAssertFalse(
            MPVRenderSurfaceReadinessPolicy.isReady(
                isAttachedToWindow: false,
                hasSuperview: true,
                hasOpenGLContext: true,
                hasRenderContext: true,
                drawableWidth: 1_920,
                drawableHeight: 1_080
            )
        )
    }

    @MainActor
    func testRenderSurfaceGateReleasesPendingRequestOnceReady() async throws {
        let gate = PlayerRenderSurfaceReadinessGate()
        let requestID = UUID()
        let renderOwnerID = UUID()
        let wait = Task { @MainActor in
            try await gate.waitUntilReady(
                requestID: requestID,
                renderOwnerID: renderOwnerID
            )
        }
        await Task.yield()

        XCTAssertEqual(gate.pendingRequestID, requestID)
        gate.markReady(renderOwnerID: renderOwnerID)
        try await wait.value
        XCTAssertNil(gate.pendingRequestID)

        // An already-ready surface passes immediately and repeated ready events
        // cannot consume or replay the completed request.
        try await gate.waitUntilReady(
            requestID: UUID(),
            renderOwnerID: renderOwnerID
        )
        gate.markReady(renderOwnerID: renderOwnerID)
        XCTAssertNil(gate.pendingRequestID)
    }

    @MainActor
    func testRenderSurfaceGateUsesLatestPendingRequest() async throws {
        let gate = PlayerRenderSurfaceReadinessGate()
        let renderOwnerID = UUID()
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let first = Task { @MainActor in
            try await gate.waitUntilReady(
                requestID: firstRequestID,
                renderOwnerID: renderOwnerID
            )
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await gate.waitUntilReady(
                requestID: secondRequestID,
                renderOwnerID: renderOwnerID
            )
        }
        await Task.yield()

        XCTAssertEqual(gate.pendingRequestID, secondRequestID)
        do {
            try await first.value
            XCTFail("Superseded request unexpectedly reached loadfile")
        } catch is CancellationError {
            // Expected: latest request wins.
        }
        gate.markReady(renderOwnerID: renderOwnerID)
        try await second.value
    }

    @MainActor
    func testRenderSurfaceGateResetsAfterTeardown() async throws {
        let gate = PlayerRenderSurfaceReadinessGate()
        let renderOwnerID = UUID()
        gate.markReady(renderOwnerID: renderOwnerID)
        XCTAssertEqual(gate.readyRenderOwnerID, renderOwnerID)

        gate.markUnavailable(renderOwnerID: renderOwnerID)
        XCTAssertNil(gate.readyRenderOwnerID)

        let requestID = UUID()
        let wait = Task { @MainActor in
            try await gate.waitUntilReady(
                requestID: requestID,
                renderOwnerID: renderOwnerID
            )
        }
        await Task.yield()
        XCTAssertEqual(gate.pendingRequestID, requestID)
        gate.reset()
        do {
            try await wait.value
            XCTFail("Reset request unexpectedly reached loadfile")
        } catch is CancellationError {
            // Expected: close/shutdown cancels the pending request.
        }
    }

    func testPlayerTeardownModeUsesEnvironmentThenDefaults() {
        let suiteName = "OKVideoMacTests.PlayerTeardownMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            PlayerTeardownMode.configured(
                environment: [:],
                defaults: defaults
            ),
            .fullDestroy
        )

        defaults.set(
            PlayerTeardownMode.warmStop.rawValue,
            forKey: PlayerTeardownMode.defaultsKey
        )
        XCTAssertEqual(
            PlayerTeardownMode.configured(
                environment: [:],
                defaults: defaults
            ),
            .warmStop
        )

        XCTAssertEqual(
            PlayerTeardownMode.configured(
                environment: [
                    PlayerTeardownMode.environmentKey:
                        PlayerTeardownMode.fullDestroy.rawValue
                ],
                defaults: defaults
            ),
            .fullDestroy
        )

        defaults.set("invalid", forKey: PlayerTeardownMode.defaultsKey)
        XCTAssertEqual(
            PlayerTeardownMode.configured(
                environment: [:],
                defaults: defaults
            ),
            .fullDestroy
        )
    }

    @MainActor
    func testPlayerLifecycleControllerPreservesOrRecreatesNativeClient()
        async throws {
        let warm = PlayerLifecycleController(mode: .warmStop)
        guard let warmPlayer = warm.renderPlayer else {
            throw XCTSkip("libmpv is unavailable in this test environment")
        }
        let warmID = warmPlayer.renderOwnerID
        await warm.closeAfterPlayback(requestID: UUID())
        XCTAssertEqual(warm.renderPlayer?.renderOwnerID, warmID)
        await warm.shutdown()

        let full = PlayerLifecycleController(mode: .fullDestroy)
        guard let original = full.renderPlayer else {
            throw XCTSkip("libmpv is unavailable in this test environment")
        }
        let originalID = original.renderOwnerID
        await full.closeAfterPlayback(requestID: UUID())
        XCTAssertNil(full.renderPlayer)

        let replacement = try await full.prepareForPlayback(
            requestID: UUID()
        )
        XCTAssertNotEqual(replacement.renderOwnerID, originalID)
        await full.shutdown()
    }

    func testLiveSwitchKeepsPreviousFrameFreeOfLoadingOverlays() {
        XCTAssertTrue(
            LiveSwitchLoadingIndicatorPolicy.shouldKeepPreviousFrameClean(
                isLivePlayback: true,
                holdsPreviousFrame: true,
                status: .loading
            )
        )
        XCTAssertTrue(
            LiveSwitchLoadingIndicatorPolicy.shouldKeepPreviousFrameClean(
                isLivePlayback: true,
                holdsPreviousFrame: true,
                status: .buffering
            )
        )
        XCTAssertFalse(
            LiveSwitchLoadingIndicatorPolicy.shouldKeepPreviousFrameClean(
                isLivePlayback: true,
                holdsPreviousFrame: true,
                status: .playing
            )
        )
        XCTAssertFalse(
            LiveSwitchLoadingIndicatorPolicy.shouldKeepPreviousFrameClean(
                isLivePlayback: true,
                holdsPreviousFrame: true,
                status: .failed("连接失败")
            )
        )
        XCTAssertFalse(
            LiveSwitchLoadingIndicatorPolicy.shouldKeepPreviousFrameClean(
                isLivePlayback: true,
                holdsPreviousFrame: false,
                status: .loading
            )
        )
        XCTAssertFalse(
            LiveSwitchLoadingIndicatorPolicy.shouldKeepPreviousFrameClean(
                isLivePlayback: false,
                holdsPreviousFrame: true,
                status: .loading
            )
        )
    }

    func testLiveChannelNavigationMovesAndWrapsInVisibleOrder() throws {
        let channels = try [
            makeLiveChannel(name: "CCTV-1", streamPath: "cctv1"),
            makeLiveChannel(name: "CCTV-2", streamPath: "cctv2"),
            makeLiveChannel(name: "CCTV-3", streamPath: "cctv3")
        ]

        XCTAssertEqual(
            LiveChannelNavigationPolicy.adjacentChannel(
                in: channels,
                currentChannelID: channels[1].id,
                offset: -1
            )?.id,
            channels[0].id
        )
        XCTAssertEqual(
            LiveChannelNavigationPolicy.adjacentChannel(
                in: channels,
                currentChannelID: channels[2].id,
                offset: 1
            )?.id,
            channels[0].id
        )
        XCTAssertEqual(
            LiveChannelNavigationPolicy.adjacentChannel(
                in: channels,
                currentChannelID: channels[0].id,
                offset: -1
            )?.id,
            channels[2].id
        )
    }

    func testLiveChannelNavigationNormalizesDuplicateAndUnavailableChannels() throws {
        let current = try makeLiveChannel(name: "CCTV-1", streamPath: "cctv1")
        let duplicate = try makeLiveChannel(name: "CCTV-1", streamPath: "backup")
        let unavailable = LiveChannel(
            groupName: "央视频道",
            name: "CCTV-2",
            streams: []
        )
        let appended = try makeLiveChannel(name: "CCTV-3", streamPath: "cctv3")

        let normalized = LiveChannelNavigationPolicy.normalizedChannels(
            [current, duplicate, unavailable],
            including: appended
        )

        XCTAssertEqual(normalized.map(\.id), [current.id, appended.id])
        XCTAssertNil(
            LiveChannelNavigationPolicy.adjacentChannel(
                in: [current],
                currentChannelID: current.id,
                offset: 1
            )
        )
    }

    func testDeletedLiveChannelIdentifiersArePersistentAndSourceScoped()
        throws {
        let sourceA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sourceB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let channel = try makeLiveChannel(
            name: "失效频道",
            streamPath: "offline"
        )
        let identifier = LiveChannelDeletionPolicy.identifier(
            sourceID: sourceA,
            channelID: channel.id
        )
        let values: Set<String> = [identifier]

        XCTAssertTrue(
            LiveChannelDeletionPolicy.contains(
                values,
                sourceID: sourceA,
                channelID: channel.id
            )
        )
        XCTAssertFalse(
            LiveChannelDeletionPolicy.contains(
                values,
                sourceID: sourceB,
                channelID: channel.id
            )
        )
        XCTAssertEqual(
            LiveChannelDeletionPolicy.removingSource(
                sourceB,
                from: values
            ),
            values
        )
        XCTAssertTrue(
            LiveChannelDeletionPolicy.removingSource(
                sourceA,
                from: values
            ).isEmpty
        )
    }

    func testLivePlaybackRecoveryTriesBackupLineBeforeNextChannel() throws {
        let primary = try XCTUnwrap(
            URL(string: "https://example.com/cctv1-primary.m3u8")
        )
        let backup = try XCTUnwrap(
            URL(string: "https://example.com/cctv1-backup.m3u8")
        )
        let current = LiveChannel(
            groupName: "央视频道",
            name: "CCTV-1",
            streams: [
                LiveStream(name: "主线", url: primary),
                LiveStream(name: "备线", url: backup)
            ]
        )
        let next = try makeLiveChannel(
            name: "CCTV-2",
            streamPath: "cctv2"
        )

        let candidates = LivePlaybackRecoveryPolicy.candidates(
            channels: [current, next],
            startingChannel: current,
            startingStream: current.streams[0]
        )

        XCTAssertEqual(
            candidates.map { "\($0.channel.name)::\($0.stream.name)" },
            ["CCTV-1::主线", "CCTV-1::备线", "CCTV-2::默认"]
        )
    }

    func testLivePlaybackRecoveryExcludesAttemptedAndDuplicateURLs() throws {
        let sharedURL = try XCTUnwrap(
            URL(string: "https://example.com/shared.m3u8")
        )
        let current = LiveChannel(
            groupName: "央视频道",
            name: "CCTV-1",
            streams: [LiveStream(name: "主线", url: sharedURL)]
        )
        let duplicate = LiveChannel(
            groupName: "央视频道",
            name: "CCTV-2",
            streams: [LiveStream(name: "重复", url: sharedURL)]
        )
        let attempted = LivePlaybackCandidate(
            channel: current,
            stream: current.streams[0]
        ).identifier

        let candidates = LivePlaybackRecoveryPolicy.candidates(
            channels: [current, duplicate],
            startingChannel: current,
            startingStream: current.streams[0],
            excluding: [attempted]
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testLiveSourceValidationRequiresEveryLineToBeDefinitivelyUnavailable() {
        XCTAssertTrue(
            LiveSourceValidationPolicy.shouldRemoveChannel(
                streamResults: [
                    .definitivelyUnavailable,
                    .definitivelyUnavailable
                ]
            )
        )
        XCTAssertFalse(
            LiveSourceValidationPolicy.shouldRemoveChannel(
                streamResults: [.definitivelyUnavailable, .inconclusive]
            )
        )
        XCTAssertFalse(
            LiveSourceValidationPolicy.shouldRemoveChannel(
                streamResults: [.definitivelyUnavailable, .reachable]
            )
        )
        XCTAssertFalse(
            LiveSourceValidationPolicy.shouldRemoveChannel(streamResults: [])
        )
    }

    func testLiveSourceValidationUsesConservativeHTTPClassification() {
        XCTAssertEqual(
            LiveSourceValidationPolicy.result(forHTTPStatus: 206),
            .reachable
        )
        XCTAssertEqual(
            LiveSourceValidationPolicy.result(forHTTPStatus: 404),
            .definitivelyUnavailable
        )
        XCTAssertEqual(
            LiveSourceValidationPolicy.result(forHTTPStatus: 503),
            .inconclusive
        )
    }

    func testLivePlaybackUsesShorterLoadTimeoutThanOnDemandVideo() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/live.m3u8"))
        let live = ResolvedMedia(
            url: url,
            headers: [:],
            siteKey: "live",
            sourceName: "直播",
            episodeName: "默认"
        )
        var video = live
        video.siteKey = "vod"

        XCTAssertEqual(PlayerLoadTimeoutPolicy.seconds(for: live), 8)
        XCTAssertEqual(PlayerLoadTimeoutPolicy.seconds(for: video), 30)
    }

    func testSearchSiteScopeSettingRoundTrip() throws {
        let scope = SearchSiteScope(
            mode: .custom,
            selectedSiteKeys: ["site-c", "site-a"]
        )
        let fingerprint = "renamed-configuration-fingerprint"

        XCTAssertEqual(
            SearchSiteScope(
                setting: scope.settingValue(
                    configurationFingerprint: fingerprint
                ),
                expectedConfigurationFingerprint: fingerprint
            ),
            scope
        )
        XCTAssertEqual(
            SearchSiteScope(
                setting: scope.settingValue(
                    configurationFingerprint: fingerprint
                ),
                expectedConfigurationFingerprint: "changed-sites"
            ),
            scope
        )
    }

    func testLegacySearchSiteScopePreservesCustomSelection() {
        let legacy = JSONValue.object([
            "mode": .string("custom"),
            "selectedSiteKeys": .array([.string("old-selected-site")])
        ])

        XCTAssertEqual(
            SearchSiteScope(
                setting: legacy,
                expectedConfigurationFingerprint: "current-sites"
            ),
            SearchSiteScope(
                mode: .custom,
                selectedSiteKeys: ["old-selected-site"]
            )
        )
    }

    private func makeLiveChannel(
        name: String,
        streamPath: String
    ) throws -> LiveChannel {
        let url = try XCTUnwrap(URL(string: "https://example.com/\(streamPath).m3u8"))
        return LiveChannel(
            groupName: "央视频道",
            name: name,
            streams: [LiveStream(name: "默认", url: url, format: "hls")]
        )
    }

    func testSearchSiteScopeDefaultsToEverySearchableSite() {
        let options = [
            SearchScopeSiteOption(key: "a", name: "A", unavailableReason: nil),
            SearchScopeSiteOption(key: "b", name: "B", unavailableReason: nil),
            SearchScopeSiteOption(
                key: "disabled",
                name: "Disabled",
                unavailableReason: "站点声明不支持搜索"
            )
        ]

        XCTAssertEqual(
            SearchSiteScopePolicy.effectiveSiteKeys(scope: .all, options: options),
            ["a", "b"]
        )
    }

    func testCustomSearchSiteScopeOnlySelectsRequestedAvailableSites() {
        let options = [
            SearchScopeSiteOption(key: "a", name: "A", unavailableReason: nil),
            SearchScopeSiteOption(key: "b", name: "B", unavailableReason: nil),
            SearchScopeSiteOption(key: "c", name: "C", unavailableReason: nil)
        ]
        let scope = SearchSiteScope(
            mode: .custom,
            selectedSiteKeys: ["a", "c", "missing"]
        )

        XCTAssertEqual(
            SearchSiteScopePolicy.effectiveSiteKeys(scope: scope, options: options),
            ["a", "c"]
        )
    }

    func testCustomSearchScopeDoesNotFallBackWhenAllSelectionsAreUnavailable() {
        let options = [
            SearchScopeSiteOption(
                key: "a",
                name: "A",
                unavailableReason: "当前运行环境不支持"
            ),
            SearchScopeSiteOption(key: "b", name: "B", unavailableReason: nil)
        ]
        let scope = SearchSiteScope(mode: .custom, selectedSiteKeys: ["a"])

        XCTAssertTrue(
            SearchSiteScopePolicy.effectiveSiteKeys(scope: scope, options: options).isEmpty
        )
    }

    func testAllSearchScopeAutomaticallyIncludesNewSites() {
        let original = [
            SearchScopeSiteOption(key: "a", name: "A", unavailableReason: nil)
        ]
        let refreshed = original + [
            SearchScopeSiteOption(key: "new", name: "New", unavailableReason: nil)
        ]

        XCTAssertEqual(
            SearchSiteScopePolicy.effectiveSiteKeys(scope: .all, options: original),
            ["a"]
        )
        XCTAssertEqual(
            SearchSiteScopePolicy.effectiveSiteKeys(scope: .all, options: refreshed),
            ["a", "new"]
        )
    }

    func testDiscoveryFallbackSearchesEveryStructurallySearchableSite() {
        let options = [
            SearchScopeSiteOption(
                key: "renamed-content-a",
                name: "Arbitrary A",
                unavailableReason: nil
            ),
            SearchScopeSiteOption(
                key: "renamed-content-b",
                name: "Arbitrary B",
                unavailableReason: nil
            ),
            SearchScopeSiteOption(
                key: "renamed-action-site",
                name: "Arbitrary Utility",
                unavailableReason: "站点声明不支持搜索"
            )
        ]
        let manualSubset = SearchSiteScope(
            mode: .custom,
            selectedSiteKeys: ["renamed-content-a"]
        )

        XCTAssertEqual(
            SearchProviderSelectionPolicy.effectiveSiteKeys(
                context: .manual,
                scope: manualSubset,
                options: options
            ),
            ["renamed-content-a"]
        )
        XCTAssertEqual(
            SearchProviderSelectionPolicy.effectiveSiteKeys(
                context: .discoveryFallback,
                scope: manualSubset,
                options: options
            ),
            ["renamed-content-a", "renamed-content-b"]
        )
    }

    func testHomeLandingUsesStructuralIndexMetadataAfterAllLabelsChange() {
        let utility = SiteConfiguration(
            key: "opaque-utility-key",
            name: "Completely Renamed Utility",
            type: 3,
            api: "https://changed.invalid/runtime/a",
            indexs: 0,
            searchable: 0
        )
        let content = SiteConfiguration(
            key: "opaque-content-key",
            name: "Completely Renamed Content",
            type: 3,
            api: "https://different.invalid/runtime/b",
            indexs: 1
        )

        XCTAssertEqual(
            HomeLandingSitePolicy.defaultSiteKey(from: [utility, content]),
            content.key
        )
    }

    func testOnlyMediaHomeCanBecomePersistedLandingSite() {
        let actionHome = SiteHome(
            categories: [
                VideoCategory(
                    id: "opaque-operation",
                    name: "Renamed Operation",
                    contentKind: .action
                )
            ],
            recommendations: [],
            actionItems: [
                SiteActionItem(
                    siteKey: "opaque-site",
                    siteName: "Renamed Site",
                    itemID: "opaque-action",
                    title: "Renamed Action"
                )
            ]
        )
        let contentHome = SiteHome(
            categories: [
                VideoCategory(id: "opaque-media", name: "Renamed Category")
            ],
            recommendations: []
        )

        XCTAssertFalse(HomeSiteRolePolicy.isContentHome(actionHome))
        XCTAssertTrue(HomeSiteRolePolicy.isContentHome(contentHome))
    }

    @MainActor
    func testSearchScopeSettingKeysAreIsolatedByConfiguration() {
        let first = UUID()
        let second = UUID()

        XCTAssertNotEqual(
            AppState.searchScopeSettingKey(for: first),
            AppState.searchScopeSettingKey(for: second)
        )
        XCTAssertTrue(
            AppState.searchScopeSettingKey(for: first)
                .hasSuffix(first.uuidString.lowercased())
        )
    }

    @MainActor
    func testDecodedImageCacheCostUsesBitmapBackingSize() throws {
        let representation = try makeBitmapRepresentation(width: 20, height: 30)
        let image = NSImage(size: NSSize(width: 10, height: 15))
        image.addRepresentation(representation)

        XCTAssertEqual(
            DecodedImageCacheCost.cost(for: image),
            representation.bytesPerRow * representation.pixelsHigh
        )
    }

    @MainActor
    func testDecodedImageCacheCostScalesWithPixelDimensions() throws {
        let small = NSImage(size: NSSize(width: 10, height: 10))
        small.addRepresentation(try makeBitmapRepresentation(width: 20, height: 20))
        let large = NSImage(size: NSSize(width: 10, height: 10))
        large.addRepresentation(try makeBitmapRepresentation(width: 200, height: 300))

        XCTAssertGreaterThan(
            DecodedImageCacheCost.cost(for: large),
            DecodedImageCacheCost.cost(for: small)
        )
    }

    @MainActor
    func testDecodedImageCacheCostUsesPixelFallbackAndHandlesInvalidDimensions() {
        XCTAssertEqual(
            DecodedImageCacheCost.cost(
                bytesPerRow: 0,
                pixelsWide: 200,
                pixelsHigh: 300
            ),
            200 * 300 * 4
        )
        XCTAssertEqual(
            DecodedImageCacheCost.cost(
                bytesPerRow: 0,
                pixelsWide: 0,
                pixelsHigh: 300
            ),
            DecodedImageCacheCost.unknownRepresentationCost
        )
        XCTAssertGreaterThan(
            DecodedImageCacheCost.cost(
                bytesPerRow: Int.max,
                pixelsWide: Int.max,
                pixelsHigh: Int.max
            ),
            0
        )
    }

    @MainActor
    func testDecodedImageCacheCostExceedsCompressedDataSize() throws {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        let representation = try makeBitmapRepresentation(width: 512, height: 512)
        image.addRepresentation(representation)
        let compressedData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )

        XCTAssertGreaterThan(
            DecodedImageCacheCost.cost(for: image),
            compressedData.count
        )
    }

    @MainActor
    func testSectionNavigationDoesNotInvalidateWholeAppState() {
        let state = AppState.bootstrap()
        var appStateUpdateCount = 0
        var navigationUpdateCount = 0
        let appStateObservation = state.objectWillChange.sink {
            appStateUpdateCount += 1
        }
        let navigationObservation = state.navigation.objectWillChange.sink {
            navigationUpdateCount += 1
        }

        state.selectSection(.live)

        XCTAssertEqual(state.selectedSection, .live)
        XCTAssertEqual(appStateUpdateCount, 0)
        XCTAssertEqual(navigationUpdateCount, 1)
        withExtendedLifetime((appStateObservation, navigationObservation)) {}
    }

    func testHomeContentPolicyPreservesSameConfigurationAndSite() {
        let identity = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: "site-a"
        )

        XCTAssertFalse(
            HomeContentPublicationPolicy.shouldDiscard(
                currentIdentity: identity,
                targetIdentity: identity
            )
        )
    }

    func testHomeContentPolicyDiscardsContentWhenSiteChanges() {
        let configurationID = UUID()
        let current = HomeContentIdentity(
            configurationID: configurationID,
            siteKey: "site-a"
        )
        let target = HomeContentIdentity(
            configurationID: configurationID,
            siteKey: "site-b"
        )

        XCTAssertTrue(
            HomeContentPublicationPolicy.shouldDiscard(
                currentIdentity: current,
                targetIdentity: target
            )
        )
    }

    func testHomeContentPolicyDiscardsContentWhenConfigurationChanges() {
        let current = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: "shared-key"
        )
        let target = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: "shared-key"
        )

        XCTAssertTrue(
            HomeContentPublicationPolicy.shouldDiscard(
                currentIdentity: current,
                targetIdentity: target
            )
        )
    }

    func testHomeContentPolicySkipsPublishingEqualSnapshot() {
        let identity = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: "site-a"
        )
        let home = SiteHome(
            categories: [VideoCategory(id: "movie", name: "电影")],
            recommendations: []
        )

        XCTAssertFalse(
            HomeContentPublicationPolicy.shouldPublish(
                currentHome: home,
                currentIdentity: identity,
                incomingHome: home,
                incomingIdentity: identity
            )
        )
        XCTAssertTrue(
            HomeContentPublicationPolicy.shouldPublish(
                currentHome: nil,
                currentIdentity: nil,
                incomingHome: home,
                incomingIdentity: identity
            )
        )
    }

    func testHomePresentationUsesRealFeedAsRecommendationDefault() {
        let home = SiteHome(
            categories: [VideoCategory(id: "movie", name: "电影")],
            recommendations: [
                VideoSummary(
                    siteKey: "site",
                    siteName: "站点",
                    videoID: "featured",
                    title: "首页推荐"
                )
            ]
        )

        XCTAssertEqual(
            HomePresentationPolicy.selection(for: home, preserving: nil),
            .recommendation
        )
    }

    func testHomePresentationFallsBackToFirstMediaCategoryWithoutFeed() {
        let home = SiteHome(
            categories: [
                VideoCategory(
                    id: "settings",
                    name: "配置",
                    contentKind: .action
                ),
                VideoCategory(id: "movie", name: "电影"),
                VideoCategory(id: "series", name: "剧集")
            ],
            recommendations: []
        )

        XCTAssertEqual(
            HomePresentationPolicy.selection(for: home, preserving: nil),
            .category("movie")
        )
    }

    func testHomePresentationPreservesValidSelectionAndFallsBackWhenRemoved() {
        let original = SiteHome(
            categories: [
                VideoCategory(id: "movie", name: "电影"),
                VideoCategory(id: "series", name: "剧集")
            ],
            recommendations: [
                VideoSummary(
                    siteKey: "site",
                    siteName: "站点",
                    videoID: "featured",
                    title: "首页推荐"
                )
            ]
        )
        XCTAssertEqual(
            HomePresentationPolicy.selection(
                for: original,
                preserving: "series"
            ),
            .category("series")
        )

        let refreshed = SiteHome(
            categories: [VideoCategory(id: "movie", name: "电影")],
            recommendations: [
                VideoSummary(
                    siteKey: "site",
                    siteName: "站点",
                    videoID: "featured",
                    title: "首页推荐"
                )
            ]
        )
        XCTAssertEqual(
            HomePresentationPolicy.selection(
                for: refreshed,
                preserving: "series"
            ),
            .recommendation
        )
    }

    func testHomePresentationUsesActionsWithoutPretendingTheyAreMovies() {
        let home = SiteHome(
            categories: [
                VideoCategory(
                    id: "settings",
                    name: "配置",
                    contentKind: .action
                )
            ],
            recommendations: [],
            actionItems: [
                SiteActionItem(
                    siteKey: "site",
                    siteName: "站点",
                    itemID: "danmaku",
                    title: "弹幕服务"
                )
            ]
        )

        XCTAssertEqual(
            HomePresentationPolicy.selection(for: home, preserving: nil),
            .actions
        )
    }

    func testHomePresentationLoadsStructuralActionCategoryWhenItemsAreNotInline() {
        let home = SiteHome(
            categories: [
                VideoCategory(
                    id: "settings",
                    name: "配置",
                    contentKind: .action
                )
            ],
            recommendations: []
        )

        XCTAssertEqual(
            HomePresentationPolicy.selection(for: home, preserving: nil),
            .actions
        )
        XCTAssertEqual(
            HomePresentationPolicy.firstActionCategory(in: home)?.id,
            "settings"
        )
    }

    func testActionCategoryPageInheritsStructuralActionSemantics() {
        let category = VideoCategory(
            id: "settings",
            name: "配置",
            contentKind: .action
        )
        let page = VideoPage(
            items: [
                VideoSummary(
                    siteKey: "site",
                    siteName: "站点",
                    videoID: "action-item",
                    title: "功能入口",
                    contentKind: .action
                ),
                VideoSummary(
                    siteKey: "site",
                    siteName: "站点",
                    videoID: "movie-item",
                    title: "普通影片",
                    contentKind: .media
                ),
                VideoSummary(
                    siteKey: "site",
                    siteName: "站点",
                    videoID: "unsupported-item",
                    title: "不可用入口",
                    contentKind: .unsupported
                )
            ],
            pagination: Pagination(page: 1, pageCount: 1)
        )

        XCTAssertEqual(
            HomePresentationPolicy.actionItems(
                from: page,
                inheritedFrom: category
            ).map(\.itemID),
            ["action-item", "movie-item"]
        )
    }

    func testEmptyActionCategoryKeepsGenericSelectableFallback() {
        let category = VideoCategory(
            id: "settings-entry",
            name: "配置入口",
            contentKind: .action
        )
        let fallback = SiteActionItem(
            siteKey: "site",
            siteName: "站点",
            itemID: category.id,
            title: category.name
        )

        XCTAssertEqual(
            HomePresentationPolicy.actionItems(
                from: VideoPage(
                    items: [],
                    pagination: Pagination(page: 1, pageCount: 1)
                ),
                inheritedFrom: category,
                fallback: fallback
            ),
            [fallback]
        )
    }

    func testCachedActionHomeRestoresSelectableFallbackBeforeNetworkLoad() {
        let cached = SiteHome(
            categories: [
                VideoCategory(
                    id: "settings-entry",
                    name: "配置入口",
                    contentKind: .action
                )
            ],
            recommendations: []
        )

        let restored = HomePresentationPolicy.addingActionCategoryFallback(
            to: cached,
            siteKey: "site",
            siteName: "站点"
        )

        XCTAssertEqual(restored.actionItems.count, 1)
        XCTAssertEqual(restored.actionItems.first?.itemID, "settings-entry")
        XCTAssertEqual(restored.actionItems.first?.title, "配置入口")
        XCTAssertEqual(
            HomePresentationPolicy.selection(for: restored, preserving: nil),
            .actions
        )
    }

    func testSingletonEmptyCategoryPromotesByStructureWithoutNamesOrIDs() {
        let home = SiteHome(
            categories: [
                VideoCategory(
                    id: "opaque-entry-741",
                    name: "Arbitrary provider entry"
                )
            ],
            recommendations: []
        )
        let page = VideoPage(
            items: [],
            pagination: Pagination(page: 1, pageCount: 1)
        )

        let promoted = HomePresentationPolicy
            .promotingSingletonEmptyCategoryToAction(
                in: home,
                categoryID: "opaque-entry-741",
                page: page
            )

        XCTAssertEqual(
            promoted?.categories.first?.resolvedContentKind,
            .action
        )
    }

    func testEmptyMediaCategoryDoesNotPromoteWhenHomeHasOtherContent() {
        let home = SiteHome(
            categories: [
                VideoCategory(id: "empty", name: "空分类"),
                VideoCategory(id: "movies", name: "电影")
            ],
            recommendations: []
        )
        let page = VideoPage(
            items: [],
            pagination: Pagination(page: 1, pageCount: 1)
        )

        XCTAssertNil(
            HomePresentationPolicy.promotingSingletonEmptyCategoryToAction(
                in: home,
                categoryID: "empty",
                page: page
            )
        )
    }

    func testMDriveHomeContractSeparatesConfigurationFromAuthorizedMedia() {
        let site = SiteConfiguration(
            key: "renamed-drive",
            name: "Renamed Drive",
            type: 3,
            api: "csp_MyDriveGuard"
        )
        let home = SiteHome(
            categories: [
                VideoCategory(id: "peizhi", name: "Arbitrary host action"),
                VideoCategory(id: "夸父", name: "Arbitrary media provider")
            ],
            recommendations: []
        )

        let normalized = AndroidDexSpiderSiteProvider.applyingHomeContract(
            to: home,
            site: site
        )

        XCTAssertEqual(
            normalized.categories.map(\.resolvedContentKind),
            [.action, .media]
        )
        XCTAssertEqual(
            HomePresentationPolicy.selection(for: normalized, preserving: nil),
            .category("夸父")
        )
        XCTAssertTrue(
            AndroidDexSpiderSiteProvider.homeConfirmsAuthorization(
                normalized,
                site: site
            )
        )
    }

    func testMDriveHomeContractKeepsPreAuthorizationConfigurationAction() {
        let site = SiteConfiguration(
            key: "drive",
            name: "Drive",
            type: 3,
            api: "csp_MyDriveGuard"
        )
        let home = SiteHome(
            categories: [VideoCategory(id: "peizhi", name: "云盘配置")],
            recommendations: [],
            actionItems: [
                SiteActionItem(
                    siteKey: "drive",
                    siteName: "Drive",
                    itemID: "clear",
                    title: "Clear",
                    action: "ucClean"
                )
            ]
        )

        let normalized = AndroidDexSpiderSiteProvider.applyingHomeContract(
            to: home,
            site: site
        )

        XCTAssertEqual(
            normalized.categories.first?.resolvedContentKind,
            .action
        )
        XCTAssertEqual(
            HomePresentationPolicy.selection(for: normalized, preserving: nil),
            .actions
        )
        XCTAssertEqual(normalized.actionItems.first?.tag, "command")
        XCTAssertFalse(
            AndroidDexSpiderSiteProvider.homeConfirmsAuthorization(
                normalized,
                site: site
            )
        )
    }

    func testMDriveActionContractClassifiesStableActionIdentifiers() {
        XCTAssertEqual(
            MyDriveGuardActionContract.tag(for: "LoginShow"),
            "authorization"
        )
        XCTAssertEqual(
            MyDriveGuardActionContract.tag(for: "pushCkShow"),
            "authorization"
        )
        for action in ["ucClean", "quarkClean", "BdClean", "aliClean"] {
            XCTAssertEqual(
                MyDriveGuardActionContract.tag(for: action),
                "command"
            )
        }
        for action in ["panSortShow", "panSourceSortShow"] {
            XCTAssertEqual(
                MyDriveGuardActionContract.tag(for: action),
                "order"
            )
        }
        XCTAssertNil(MyDriveGuardActionContract.tag(for: "unknownAction"))
    }

    func testMDriveActionContractPreservesExplicitUpstreamTag() {
        let explicit = SiteActionItem(
            siteKey: "MDrive",
            siteName: "Drive",
            itemID: "sort",
            title: "Sort",
            tag: "toggle",
            action: "panSortShow"
        )
        let inferred = SiteActionItem(
            siteKey: "MDrive",
            siteName: "Drive",
            itemID: "clear",
            title: "Clear",
            action: "quarkClean"
        )

        XCTAssertEqual(
            MyDriveGuardActionContract.applying(to: explicit).tag,
            "toggle"
        )
        XCTAssertEqual(
            MyDriveGuardActionContract.applying(to: inferred).tag,
            "command"
        )
    }

    func testGenericDexHomeDoesNotInferActionFromMDriveCategoryIdentifier() {
        let site = SiteConfiguration(
            key: "generic",
            name: "Generic",
            type: 3,
            api: "csp_UnrelatedProvider"
        )
        let home = SiteHome(
            categories: [VideoCategory(id: "peizhi", name: "云盘配置")],
            recommendations: []
        )

        let normalized = AndroidDexSpiderSiteProvider.applyingHomeContract(
            to: home,
            site: site
        )

        XCTAssertEqual(
            normalized.categories.first?.resolvedContentKind,
            .media
        )
        XCTAssertFalse(
            AndroidDexSpiderSiteProvider.homeConfirmsAuthorization(
                normalized,
                site: site
            )
        )
    }

    func testHomePresentationIsEmptyWhenEveryCategoryIsUnsupported() {
        let home = SiteHome(
            categories: [
                VideoCategory(
                    id: "unsupported",
                    name: "不可用入口",
                    contentKind: .unsupported
                )
            ],
            recommendations: []
        )

        XCTAssertEqual(
            HomePresentationPolicy.selection(for: home, preserving: nil),
            .empty
        )
    }

    func testCategoryLoadResultRejectsStaleConfigurationResponse() {
        let siteKey = "shared-site"
        let oldIdentity = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: siteKey
        )
        let currentIdentity = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: siteKey
        )
        let session = UUID()

        XCTAssertFalse(
            CategoryLoadResultPolicy.shouldAccept(
                requestSessionID: session,
                currentSessionID: session,
                requestedSiteKey: siteKey,
                currentSiteKey: siteKey,
                requestedIdentity: oldIdentity,
                currentIdentity: currentIdentity
            )
        )
    }

    func testAutomaticHomeRefreshWaitsForStartupCompletion() {
        XCTAssertFalse(
            HomeAutomaticRefreshPolicy.allowsRefresh(
                hasCompletedStartup: false,
                selectedSection: .home,
                isHomeSearchPresented: false
            )
        )
        XCTAssertTrue(
            HomeAutomaticRefreshPolicy.allowsRefresh(
                hasCompletedStartup: true,
                selectedSection: .home,
                isHomeSearchPresented: false
            )
        )
        XCTAssertFalse(
            HomeAutomaticRefreshPolicy.allowsRefresh(
                hasCompletedStartup: true,
                selectedSection: .live,
                isHomeSearchPresented: false
            )
        )
        XCTAssertFalse(
            HomeAutomaticRefreshPolicy.allowsRefresh(
                hasCompletedStartup: true,
                selectedSection: .home,
                isHomeSearchPresented: true
            )
        )
    }

    func testNodeAuthorizationRetryRemainsBoundToOriginalSourceIdentity() {
        let configurationID = UUID()
        let original = HomeContentIdentity(
            configurationID: configurationID,
            siteKey: "source-before-rename"
        )
        let anotherSource = HomeContentIdentity(
            configurationID: configurationID,
            siteKey: "source-after-switch"
        )

        XCTAssertTrue(
            NodeAuthorizationRetryPolicy.shouldRetry(
                pendingIdentity: original,
                presentationIdentity: original,
                activeConfigurationID: configurationID,
                selectedSiteKey: original.siteKey,
                requiresSelectedHomeSource: true,
                availableSiteKeys: [original.siteKey, anotherSource.siteKey]
            )
        )
        XCTAssertFalse(
            NodeAuthorizationRetryPolicy.shouldRetry(
                pendingIdentity: original,
                presentationIdentity: original,
                activeConfigurationID: configurationID,
                selectedSiteKey: anotherSource.siteKey,
                requiresSelectedHomeSource: true,
                availableSiteKeys: [original.siteKey, anotherSource.siteKey]
            )
        )
        XCTAssertFalse(
            NodeAuthorizationRetryPolicy.shouldRetry(
                pendingIdentity: original,
                presentationIdentity: anotherSource,
                activeConfigurationID: configurationID,
                selectedSiteKey: original.siteKey,
                requiresSelectedHomeSource: false,
                availableSiteKeys: [original.siteKey, anotherSource.siteKey]
            )
        )
        XCTAssertFalse(
            NodeAuthorizationRetryPolicy.shouldRetry(
                pendingIdentity: original,
                presentationIdentity: original,
                activeConfigurationID: UUID(),
                selectedSiteKey: original.siteKey,
                requiresSelectedHomeSource: false,
                availableSiteKeys: [original.siteKey]
            )
        )
    }

    func testCloudAuthorizationRetryRemainsBoundToOriginalSourceIdentity() {
        let configurationID = UUID()
        let original = HomeContentIdentity(
            configurationID: configurationID,
            siteKey: "provider-key-before-rename"
        )
        let renamedKey = "provider-key-after-rename"

        XCTAssertTrue(
            CloudAuthorizationRetryPolicy.isCurrent(
                sourceIdentity: original,
                activeConfigurationID: configurationID,
                availableSiteKeys: [original.siteKey, renamedKey]
            )
        )
        XCTAssertFalse(
            CloudAuthorizationRetryPolicy.isCurrent(
                sourceIdentity: original,
                activeConfigurationID: UUID(),
                availableSiteKeys: [original.siteKey]
            )
        )
        XCTAssertFalse(
            CloudAuthorizationRetryPolicy.isCurrent(
                sourceIdentity: original,
                activeConfigurationID: configurationID,
                availableSiteKeys: [renamedKey]
            )
        )
    }

    func testCloudInteractionCompletionNeverInfersSuccessFromPresentationState() {
        XCTAssertFalse(
            CloudAuthorizationCompletionPolicy.shouldComplete(
                authenticated: false,
                interactionKind: .configuration,
                hasObservedPrompt: false,
                hasObservedQRCode: false,
                hiddenPollCount: 600
            )
        )
        XCTAssertFalse(
            CloudAuthorizationCompletionPolicy.shouldComplete(
                authenticated: false,
                interactionKind: .configuration,
                hasObservedPrompt: true,
                hasObservedQRCode: false,
                hiddenPollCount: 2
            )
        )
        XCTAssertFalse(
            CloudAuthorizationCompletionPolicy.shouldComplete(
                authenticated: false,
                interactionKind: .configuration,
                hasObservedPrompt: true,
                hasObservedQRCode: false,
                hiddenPollCount: 3
            )
        )
        XCTAssertFalse(
            CloudAuthorizationCompletionPolicy.shouldComplete(
                authenticated: true,
                interactionKind: .authorization,
                hasObservedPrompt: true,
                hasObservedQRCode: false,
                hiddenPollCount: 0
            )
        )
        XCTAssertFalse(
            CloudAuthorizationCompletionPolicy.shouldComplete(
                authenticated: false,
                interactionKind: .authorization,
                hasObservedPrompt: true,
                hasObservedQRCode: false,
                hiddenPollCount: 600
            )
        )
        XCTAssertFalse(
            CloudAuthorizationCompletionPolicy.shouldComplete(
                authenticated: false,
                interactionKind: .authorization,
                hasObservedPrompt: true,
                hasObservedQRCode: true,
                hiddenPollCount: 6
            )
        )
    }

    func testConfigurationCoordinatorRejectsSupersededAndCancelledCallbacks() {
        let identity = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: "site"
        )
        var coordinator = ConfigurationInteractionCoordinator()
        let first = coordinator.begin(
            sourceIdentity: identity,
            semantic: .command,
            transport: .native,
            title: "First"
        )
        let second = coordinator.begin(
            sourceIdentity: identity,
            semantic: .choice,
            transport: .native,
            title: "Second"
        )

        XCTAssertFalse(coordinator.owns(first.interactionID))
        XCTAssertFalse(
            coordinator.transition(first.interactionID, to: .completed)
        )
        XCTAssertTrue(coordinator.owns(second.interactionID))
        XCTAssertTrue(
            coordinator.transition(second.interactionID, to: .processing)
        )
        XCTAssertTrue(
            coordinator.cancel(second.interactionID, reason: .user)
        )
        XCTAssertFalse(
            coordinator.transition(second.interactionID, to: .completed)
        )
        XCTAssertFalse(coordinator.hasActiveRequest)
    }

    func testOnlyExplicitLoginQRCodeUsesAuthorizationSemantics() {
        let state = AndroidBridgeUIState(
            interactionID: nil,
            revision: nil,
            kind: nil,
            method: nil,
            visible: true,
            title: "Configure",
            inputCount: 0,
            imageCount: 1,
            buttons: [],
            controls: [],
            texts: [],
            phase: "qr",
            provider: nil,
            authenticated: false,
            credentialPush: false,
            remoteInput: false,
            generation: 1,
            outcome: nil,
            terminal: nil,
            hostUnavailable: nil,
            verificationPerformed: nil,
            refreshPerformed: nil,
            error: nil
        )
        func interaction(
            actionKind: ConfigurationInteraction.ActionKind,
            qrRole: ConfigurationInteraction.QRRole
        ) -> ConfigurationInteraction {
            ConfigurationInteraction(
                id: UUID(),
                actionKind: actionKind,
                phase: .qrCode,
                outcome: .pending,
                title: "Configure",
                provider: nil,
                generation: 1,
                controls: [],
                qrRole: qrRole,
                qrImage: nil
            )
        }

        XCTAssertEqual(
            ConfigurationInteractionClassificationPolicy.nativeSemantic(
                interaction: interaction(
                    actionKind: .authorization,
                    qrRole: .login
                ),
                hasVerifiedQRCode: true,
                credentialPush: false,
                state: state
            ),
            .qrAuthorization
        )
        for candidate in [
            interaction(actionKind: .configuration, qrRole: .login),
            interaction(actionKind: .authorization, qrRole: .remoteInputHelper),
            interaction(actionKind: .authorization, qrRole: .candidate)
        ] {
            let semantic = ConfigurationInteractionClassificationPolicy
                .nativeSemantic(
                    interaction: candidate,
                    hasVerifiedQRCode: true,
                    credentialPush: false,
                    state: state
                )
            XCTAssertFalse(semantic.isAuthorization)
            XCTAssertEqual(
                ConfigurationInteractionClassificationPolicy.interactionKind(
                    for: semantic
                ),
                .configuration
            )
        }
    }

    func testConfigurationVerificationRequiresOwnedScopedState() {
        let interactionID = UUID()
        func state(_ rawID: String?) -> AndroidBridgeUIState {
            AndroidBridgeUIState(
                interactionID: rawID,
                revision: 1,
                kind: "configuration",
                method: "choice",
                visible: true,
                title: "Configure",
                inputCount: 0,
                imageCount: 0,
                buttons: ["OK"],
                controls: [],
                texts: [],
                phase: "awaitingUser",
                provider: nil,
                authenticated: nil,
                credentialPush: false,
                remoteInput: false,
                generation: 1,
                outcome: "pending",
                terminal: false,
                hostUnavailable: false,
                verificationPerformed: false,
                refreshPerformed: nil,
                error: nil
            )
        }

        XCTAssertTrue(
            ConfigurationInteractionVerificationPolicy.accepts(
                state(interactionID.uuidString),
                interactionID: interactionID,
                requiresScopedIdentity: true
            )
        )
        XCTAssertFalse(
            ConfigurationInteractionVerificationPolicy.accepts(
                state(UUID().uuidString),
                interactionID: interactionID,
                requiresScopedIdentity: true
            )
        )
        XCTAssertFalse(
            ConfigurationInteractionVerificationPolicy.accepts(
                state(nil),
                interactionID: interactionID,
                requiresScopedIdentity: true
            )
        )
        XCTAssertTrue(
            ConfigurationInteractionVerificationPolicy.accepts(
                state(nil),
                interactionID: interactionID,
                requiresScopedIdentity: false
            )
        )
    }

    func testConfigurationVerificationUsesExplicitProviderEvidenceOnly() {
        func state(
            authenticated: Bool? = nil,
            terminal: Bool? = false,
            outcome: String? = "pending",
            hostUnavailable: Bool? = false,
            verificationPerformed: Bool? = false,
            refreshPerformed: Bool? = nil,
            error: String? = nil
        ) -> AndroidBridgeUIState {
            AndroidBridgeUIState(
                interactionID: UUID().uuidString,
                revision: 1,
                kind: "configuration",
                method: "choice",
                visible: false,
                title: "Configure",
                inputCount: 0,
                imageCount: 0,
                buttons: [],
                controls: [],
                texts: [],
                phase: "processing",
                provider: nil,
                authenticated: authenticated,
                credentialPush: false,
                remoteInput: false,
                generation: 1,
                outcome: outcome,
                terminal: terminal,
                hostUnavailable: hostUnavailable,
                verificationPerformed: verificationPerformed,
                refreshPerformed: refreshPerformed,
                error: error
            )
        }

        XCTAssertEqual(
            ConfigurationInteractionVerificationPolicy.decision(
                for: state(authenticated: true),
                semantic: .command
            ),
            .pending
        )
        XCTAssertEqual(
            ConfigurationInteractionVerificationPolicy.decision(
                for: state(authenticated: true, hostUnavailable: true),
                semantic: .qrAuthorization
            ),
            .pending
        )
        XCTAssertEqual(
            ConfigurationInteractionVerificationPolicy.decision(
                for: state(authenticated: true, verificationPerformed: true),
                semantic: .qrAuthorization
            ),
            .pending
        )
        XCTAssertEqual(
            ConfigurationInteractionVerificationPolicy.decision(
                for: state(authenticated: true, refreshPerformed: true),
                semantic: .qrAuthorization
            ),
            .verifySucceeded(refreshPerformed: true)
        )
        XCTAssertEqual(
            ConfigurationInteractionVerificationPolicy.decision(
                for: state(authenticated: false, error: "invalid token"),
                semantic: .credentialAuthorization
            ),
            .verifyFailed("invalid token")
        )
        XCTAssertEqual(
            ConfigurationInteractionVerificationPolicy.decision(
                for: state(terminal: true, outcome: "cancelled"),
                semantic: .command
            ),
            .terminalCancelled
        )
        XCTAssertEqual(
            ConfigurationInteractionVerificationPolicy.decision(
                for: state(terminal: true, outcome: "completed"),
                semantic: .choice
            ),
            .terminalSucceeded
        )
    }

    func testCancellationIsNeverPresentedAsAnOperationFailure() {
        XCTAssertFalse(
            UserVisibleAsyncErrorPolicy.shouldPresent(
                CancellationError(),
                ownsSession: true
            )
        )
        XCTAssertFalse(
            UserVisibleAsyncErrorPolicy.shouldPresent(
                URLError(.cancelled),
                ownsSession: true
            )
        )
        XCTAssertFalse(
            UserVisibleAsyncErrorPolicy.shouldPresent(
                NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCancelled
                ),
                ownsSession: true
            )
        )
        XCTAssertTrue(
            UserVisibleAsyncErrorPolicy.shouldPresent(
                NSError(domain: "test", code: 1),
                ownsSession: true
            )
        )
    }

    func testBlankImageIsNotPublishedAsQRCode() {
        XCTAssertNil(
            AndroidBridgeQRCodePolicy.validatedSnapshot(
                Data(repeating: 0xFF, count: 1_024)
            )
        )
        XCTAssertNil(AndroidBridgeQRCodePolicy.validatedSnapshot(nil))
    }

    func testPosterlessHomeItemsUseCompactPresentation() {
        let posterless = VideoSummary(
            siteKey: "site",
            siteName: "Site",
            videoID: "config",
            title: "通用配置"
        )
        let poster = VideoSummary(
            siteKey: "site",
            siteName: "Site",
            videoID: "movie",
            title: "Movie",
            posterURL: URL(string: "https://example.invalid/poster.jpg")
        )
        XCTAssertTrue(HomeItemPresentationPolicy.prefersCompactCards([posterless]))
        XCTAssertFalse(HomeItemPresentationPolicy.prefersCompactCards([posterless, poster]))
        XCTAssertFalse(HomeItemPresentationPolicy.prefersCompactCards([]))
    }

    func testCloudAuthorizationHiddenPollingHasBoundedTimeout() {
        XCTAssertFalse(
            CloudAuthorizationPollingPolicy.shouldTimeOut(
                hiddenPollCount: 39,
                maximumHiddenPollCount: 40
            )
        )
        XCTAssertTrue(
            CloudAuthorizationPollingPolicy.shouldTimeOut(
                hiddenPollCount: 40,
                maximumHiddenPollCount: 40
            )
        )
    }

    func testCloudAuthorizationSubmittedControlMustAdvanceItsUIGeneration() {
        XCTAssertFalse(
            CloudAuthorizationPollingPolicy.shouldFailUnchangedSubmission(
                elapsed: 7.9,
                submittedGeneration: 12,
                currentGeneration: 12,
                hasObservedTransition: false,
                isVisible: true
            )
        )
        XCTAssertTrue(
            CloudAuthorizationPollingPolicy.shouldFailUnchangedSubmission(
                elapsed: 8,
                submittedGeneration: 12,
                currentGeneration: 12,
                hasObservedTransition: false,
                isVisible: true
            )
        )
        XCTAssertFalse(
            CloudAuthorizationPollingPolicy.shouldFailUnchangedSubmission(
                elapsed: 20,
                submittedGeneration: 12,
                currentGeneration: 13,
                hasObservedTransition: true,
                isVisible: true
            )
        )
    }

    func testQRCodeExitRequestsVerificationEvenWhenParentUIRemainsVisible() {
        XCTAssertTrue(
            CloudAuthorizationPollingPolicy.shouldVerifyAfterQRCodeExit(
                hasObservedQRCode: true,
                currentStateIsQRCode: false,
                actionKind: .authorization
            )
        )
        XCTAssertFalse(
            CloudAuthorizationPollingPolicy.shouldVerifyAfterQRCodeExit(
                hasObservedQRCode: true,
                currentStateIsQRCode: true,
                actionKind: .authorization
            )
        )
        XCTAssertFalse(
            CloudAuthorizationPollingPolicy.shouldVerifyAfterQRCodeExit(
                hasObservedQRCode: true,
                currentStateIsQRCode: false,
                actionKind: .ordering
            )
        )
    }

    func testAcceptedStructuredControlClicksAreTerminalMutations() {
        for semantic in [
            ConfigurationInteractionSemantic.command,
            .toggle,
            .order
        ] {
            XCTAssertTrue(
                ConfigurationControlSubmissionPolicy.acceptedClickCompletes(
                    semantic: semantic
                )
            )
        }
        XCTAssertFalse(
            ConfigurationControlSubmissionPolicy.acceptedClickCompletes(
                semantic: .choice
            )
        )
        XCTAssertFalse(
            ConfigurationControlSubmissionPolicy.acceptedClickCompletes(
                semantic: .qrAuthorization
            )
        )
        XCTAssertEqual(
            ConfigurationControlSubmissionPolicy.completionStatus(
                semantic: .order
            ),
            "排序已更新"
        )
    }

    @MainActor
    func testImageRepositoryExposesMemoryHitWithoutActorHop() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let sourceImage = NSImage(size: NSSize(width: 2, height: 2))
        sourceImage.lockFocus()
        NSColor.systemIndigo.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
        sourceImage.unlockFocus()
        let imageData = try XCTUnwrap(sourceImage.tiffRepresentation)
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/poster"))
        let client = NodeProviderStubHTTPClient { request in
            HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "image/tiff"],
                body: imageData
            )
        }
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        let loaded = try await repository.image(for: url)

        XCTAssertTrue(repository.cachedImage(for: url) === loaded)
        try await repository.clear()
        XCTAssertNil(repository.cachedImage(for: url))
    }

    @MainActor
    func testImageRepositoryDeduplicatesDataAndImageCreation() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let imageData = try makeTestImageData()
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/shared"))
        let client = ImageRepositoryHTTPClientProbe(
            body: imageData,
            delayNanoseconds: 100_000_000
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        let tasks = (0..<10).map { _ in
            Task { @MainActor in
                ObjectIdentifier(try await repository.image(for: url))
            }
        }
        var identifiers: [ObjectIdentifier] = []
        for task in tasks {
            identifiers.append(try await task.value)
        }

        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(Set(identifiers).count, 1)
    }

    @MainActor
    func testImageRepositoryUsesMemoryCacheAfterFirstLoad() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/memory"))
        let client = ImageRepositoryHTTPClientProbe(body: try makeTestImageData())
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        let first = try await repository.image(for: url)
        let second = try await repository.image(for: url)

        XCTAssertTrue(first === second)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testNodeImageProxyCacheIdentityIgnoresLocalPortAndCacheLifetime() throws {
        let firstURL = try makeNodeImageProxyURL(
            host: "127.0.0.1",
            port: 58_799,
            cacheLifetime: 86_400,
            targetURL: "https://images.example.invalid/poster.jpg?size=large",
            customHeaders: #"{"Referer":"https://example.invalid","User-Agent":"OKVideo"}"#
        )
        let secondURL = try makeNodeImageProxyURL(
            host: "localhost",
            port: 61_008,
            cacheLifetime: 60,
            targetURL: "https://images.example.invalid/poster.jpg?size=large",
            customHeaders: #"{"User-Agent":"OKVideo","Referer":"https://example.invalid"}"#
        )
        let differentPosterURL = try makeNodeImageProxyURL(
            host: "127.0.0.1",
            port: 61_008,
            cacheLifetime: 86_400,
            targetURL: "https://images.example.invalid/other.jpg",
            customHeaders: #"{"Referer":"https://example.invalid","User-Agent":"OKVideo"}"#
        )

        XCTAssertEqual(
            ImageCacheIdentity(url: firstURL),
            ImageCacheIdentity(url: secondURL)
        )
        XCTAssertNotEqual(
            ImageCacheIdentity(url: firstURL),
            ImageCacheIdentity(url: differentPosterURL)
        )
    }

    @MainActor
    func testImageRepositoryReusesMemoryCacheWhenNodeProxyPortChanges() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let firstURL = try makeNodeImageProxyURL(port: 58_799)
        let secondURL = try makeNodeImageProxyURL(port: 61_008)
        let client = ImageRepositoryHTTPClientProbe(body: try makeTestImageData())
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        let first = try await repository.image(for: firstURL)
        let second = try await repository.image(for: secondURL)

        XCTAssertTrue(first === second)
        XCTAssertTrue(repository.cachedImage(for: secondURL) === first)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testImageRepositoryRestoresImageFromDiskCache() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/disk"))
        let firstClient = ImageRepositoryHTTPClientProbe(body: try makeTestImageData())
        let firstRepository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: firstClient
        )
        _ = try await firstRepository.image(for: url)

        let secondClient = ImageRepositoryHTTPClientProbe(
            error: HTTPClientError.statusCode(500)
        )
        let secondRepository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: secondClient
        )
        _ = try await secondRepository.image(for: url)

        let firstRequestCount = await firstClient.requestCount()
        let secondRequestCount = await secondClient.requestCount()
        XCTAssertEqual(firstRequestCount, 1)
        XCTAssertEqual(secondRequestCount, 0)
    }

    @MainActor
    func testImageRepositoryRestoresNodeProxyImageFromDiskAfterPortChanges() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let firstURL = try makeNodeImageProxyURL(port: 58_799)
        let secondURL = try makeNodeImageProxyURL(port: 61_008)
        let firstClient = ImageRepositoryHTTPClientProbe(body: try makeTestImageData())
        let firstRepository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: firstClient
        )
        _ = try await firstRepository.image(for: firstURL)

        let secondClient = ImageRepositoryHTTPClientProbe(
            error: HTTPClientError.statusCode(500)
        )
        let secondRepository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: secondClient
        )
        _ = try await secondRepository.image(for: secondURL)

        let firstRequestCount = await firstClient.requestCount()
        let secondRequestCount = await secondClient.requestCount()
        XCTAssertEqual(firstRequestCount, 1)
        XCTAssertEqual(secondRequestCount, 0)
    }

    @MainActor
    func testImageRepositoryMigratesLegacyNodeProxyDiskCache() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let legacyURL = try makeNodeImageProxyURL(port: 58_799)
        let legacyDigest = SHA256.hash(data: Data(legacyURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try makeTestImageData().write(
            to: cacheDirectory.appendingPathComponent(legacyDigest + ".image")
        )
        let client = ImageRepositoryHTTPClientProbe(
            error: HTTPClientError.statusCode(500)
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        _ = try await repository.image(for: legacyURL)

        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).count,
            2
        )
    }

    func testRemoteImageLoadingPolicyPreservesOldImageWhileReplacementLoads() throws {
        let replacementURL = try XCTUnwrap(
            URL(string: "https://images.example.invalid/replacement.jpg")
        )

        XCTAssertFalse(
            RemoteImageLoadingPolicy.shouldClearCurrentImage(for: replacementURL)
        )
        XCTAssertTrue(RemoteImageLoadingPolicy.shouldClearCurrentImage(for: nil))
        XCTAssertFalse(
            RemoteImageLoadingPolicy.shouldShowFailure(hasCurrentImage: true)
        )
        XCTAssertTrue(
            RemoteImageLoadingPolicy.shouldShowFailure(hasCurrentImage: false)
        )
    }

    func testNodeRuntimeHomepageReloadPolicyRequiresEndpointReplacement() throws {
        let first = try XCTUnwrap(URL(string: "http://127.0.0.1:58001/"))
        let replacement = try XCTUnwrap(URL(string: "http://127.0.0.1:58002/"))

        XCTAssertFalse(
            NodeRuntimeHomepageReloadPolicy.shouldReload(
                previousReadyEndpoint: nil,
                currentReadyEndpoint: first,
                usesNodeRuntime: true,
                hasActiveConfiguration: true,
                isConfigurationImportInProgress: false
            )
        )
        XCTAssertFalse(
            NodeRuntimeHomepageReloadPolicy.shouldReload(
                previousReadyEndpoint: first,
                currentReadyEndpoint: first,
                usesNodeRuntime: true,
                hasActiveConfiguration: true,
                isConfigurationImportInProgress: false
            )
        )
        XCTAssertTrue(
            NodeRuntimeHomepageReloadPolicy.shouldReload(
                previousReadyEndpoint: first,
                currentReadyEndpoint: replacement,
                usesNodeRuntime: true,
                hasActiveConfiguration: true,
                isConfigurationImportInProgress: false
            )
        )
        XCTAssertFalse(
            NodeRuntimeHomepageReloadPolicy.shouldReload(
                previousReadyEndpoint: first,
                currentReadyEndpoint: replacement,
                usesNodeRuntime: false,
                hasActiveConfiguration: true,
                isConfigurationImportInProgress: false
            )
        )
        XCTAssertFalse(
            NodeRuntimeHomepageReloadPolicy.shouldReload(
                previousReadyEndpoint: first,
                currentReadyEndpoint: replacement,
                usesNodeRuntime: true,
                hasActiveConfiguration: true,
                isConfigurationImportInProgress: true
            )
        )
    }

    func testEndpointReplacementRejectsStaleHomepageResult() {
        let configurationID = UUID()
        let identity = HomeContentIdentity(
            configurationID: configurationID,
            siteKey: "node-site"
        )
        let staleSession = UUID()
        let replacementSession = UUID()

        XCTAssertFalse(
            HomeLoadResultPolicy.shouldAccept(
                requestSessionID: staleSession,
                currentSessionID: replacementSession,
                requestedSiteKey: "node-site",
                currentSiteKey: "node-site",
                requestedIdentity: identity,
                currentIdentity: identity
            )
        )
        XCTAssertTrue(
            HomeLoadResultPolicy.shouldAccept(
                requestSessionID: replacementSession,
                currentSessionID: replacementSession,
                requestedSiteKey: "node-site",
                currentSiteKey: "node-site",
                requestedIdentity: identity,
                currentIdentity: identity
            )
        )
    }

    @MainActor
    func testImageRepositoryRetriesTemporaryFailureWithoutFailureCache() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/transient"))
        let client = ImageRepositoryHTTPClientProbe(
            body: try makeTestImageData(),
            failuresBeforeSuccess: 1
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        do {
            _ = try await repository.image(for: url)
            XCTFail("首次临时失败不应返回图片")
        } catch {
            XCTAssertNil(repository.cachedImage(for: url))
        }
        _ = try await repository.image(for: url)

        XCTAssertNotNil(repository.cachedImage(for: url))
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testImageRepositoryDoesNotJoinStaleNodeProxyEndpointFailure() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let staleURL = try makeNodeImageProxyURL(port: 58_799)
        let readyURL = try makeNodeImageProxyURL(port: 61_008)
        let client = NodeProxyEndpointTransitionHTTPClient(
            stalePort: 58_799,
            imageData: try makeTestImageData()
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        let staleTask = Task { @MainActor in
            _ = try? await repository.image(for: staleURL)
        }
        var staleRequestStarted = false
        for _ in 0..<10_000 {
            if await client.requestCount() == 1 {
                staleRequestStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(staleRequestStarted)

        let readyImage = try await repository.image(for: readyURL)
        await staleTask.value

        XCTAssertTrue(repository.cachedImage(for: readyURL) === readyImage)
        let requestCount = await client.requestCount()
        let requestedPorts = await client.requestedPorts()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(Set(requestedPorts), [58_799, 61_008])
    }

    @MainActor
    func testImageRepositoryRejectsInvalidDataWithoutCaching() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/invalid"))
        let client = ImageRepositoryHTTPClientProbe(body: Data("not-image".utf8))
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        do {
            _ = try await repository.image(for: url)
            XCTFail("无效图片应该解码失败")
        } catch {
            XCTAssertNil(repository.cachedImage(for: url))
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).isEmpty
            )
        }
    }

    @MainActor
    func testImageRepositoryHTTPFailureDoesNotPolluteCaches() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/failure"))
        let client = ImageRepositoryHTTPClientProbe(
            error: HTTPClientError.statusCode(503)
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        do {
            _ = try await repository.image(for: url)
            XCTFail("HTTP 失败不应返回图片")
        } catch {
            XCTAssertNil(repository.cachedImage(for: url))
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).isEmpty
            )
            let requestCount = await client.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    @MainActor
    func testImageRepositoryRetriesRejectedRemoteImageWithSameOriginReferer() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(
            URL(string: "https://assets.changed.example.test/poster.webp")
        )
        let client = ImageRefererFallbackHTTPClient(
            imageData: try makeTestImageData(),
            initialStatus: 418
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        _ = try await repository.image(for: url)

        let requests = await client.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].headers["Referer"])
        XCTAssertEqual(
            requests[1].headers["Referer"],
            "https://assets.changed.example.test/"
        )
    }

    @MainActor
    func testImageRepositoryDoesNotOverrideExplicitReferer() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(
            URL(
                string: "https://images.renamed.example.test/poster.webp"
                    + "@Referer=https://origin.changed.example.test/"
            )
        )
        let client = ImageRefererFallbackHTTPClient(
            imageData: try makeTestImageData(),
            initialStatus: 418
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        _ = try await repository.image(for: url)

        let requests = await client.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].headers["Referer"],
            "https://origin.changed.example.test/"
        )
    }

    @MainActor
    func testImageRepositoryRefererFallbackPreservesSecondHTTPStatus() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(
            URL(string: "https://media.unrelated.example.test/poster.webp")
        )
        let client = ImageRefererFallbackHTTPClient(
            imageData: try makeTestImageData(),
            initialStatus: 418,
            fallbackStatus: 403
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )

        do {
            _ = try await repository.image(for: url)
            XCTFail("第二次 HTTP 拒绝必须原样抛出")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .statusCode(403))
        }
        let requests = await client.capturedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    @MainActor
    func testImageRepositoryCancellationDoesNotCancelSharedLoad() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/cancel"))
        let client = ImageRepositoryHTTPClientProbe(
            body: try makeTestImageData(),
            delayNanoseconds: 150_000_000
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )
        let cancelledWaiter = Task { @MainActor in
            _ = try await repository.image(for: url)
        }
        let activeWaiter = Task { @MainActor in
            _ = try await repository.image(for: url)
        }

        cancelledWaiter.cancel()
        _ = try? await cancelledWaiter.value
        try await activeWaiter.value

        XCTAssertNotNil(repository.cachedImage(for: url))
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testImageRepositoryExplicitCancellationAllowsFreshReload() async throws {
        let cacheDirectory = temporaryImageCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let url = try XCTUnwrap(URL(string: "https://images.example.invalid/quiesce"))
        let client = ImageRepositoryHTTPClientProbe(
            body: try makeTestImageData(),
            delayNanoseconds: 150_000_000
        )
        let repository = try makeImageRepository(
            cacheDirectory: cacheDirectory,
            httpClient: client
        )
        let cancelledLoad = Task<Void, Error> { @MainActor in
            _ = try await repository.image(for: url)
        }

        var requestStarted = false
        for _ in 0..<10_000 {
            if await client.requestCount() == 1 {
                requestStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(requestStarted)

        await repository.cancelInFlightLoads()
        do {
            try await cancelledLoad.value
            XCTFail("显式静默图片工作后，旧任务不应完成")
        } catch is CancellationError {
            // Expected: playback startup explicitly quiesced the old load.
        } catch let error as HTTPClientError {
            XCTAssertEqual(error, .cancelled)
        }

        _ = try await repository.image(for: url)

        XCTAssertNotNil(repository.cachedImage(for: url))
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    private func temporaryImageCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @MainActor
    private func makeTestImageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.tiffRepresentation)
    }

    @MainActor
    private func makeBitmapRepresentation(
        width: Int,
        height: Int
    ) throws -> NSBitmapImageRep {
        try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            )
        )
    }

    @MainActor
    private func makeImageRepository<Client: HTTPClient>(
        cacheDirectory: URL,
        httpClient: Client
    ) throws -> ImageRepository {
        ImageRepository(
            dataRepository: try ImageDataRepository(
                cacheDirectory: cacheDirectory,
                httpClient: httpClient
            )
        )
    }

    private func makeNodeImageProxyURL(
        host: String = "127.0.0.1",
        port: Int,
        cacheLifetime: Int = 86_400,
        targetURL: String = "https://images.example.invalid/poster.jpg",
        customHeaders: String = #"{"Referer":"https://example.invalid"}"#
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/imageProxy"
        components.queryItems = [
            URLQueryItem(name: "url", value: targetURL),
            URLQueryItem(name: "cache", value: String(cacheLifetime)),
            URLQueryItem(name: "customHeaders", value: customHeaders)
        ]
        return try XCTUnwrap(components.url)
    }

    func testEpisodeNameParserUsesRealSeasonAndEpisodeNumber() {
        let episode = PlayEpisode(
            name: "[1.3GB]Nirvana.in.Fire.S01E14.2015.2160p.mkv",
            url: "https://media.example.invalid/episode-14.mkv"
        )

        let presentation = EpisodeNameParser.presentation(for: episode)

        XCTAssertEqual(presentation.seasonNumber, 1)
        XCTAssertEqual(presentation.episodeNumber, 14)
        XCTAssertEqual(presentation.displayName, "第 1 季 · 第 14 集")
    }

    func testDetailEpisodeButtonUsesAnchoredOriginalNamePopover() {
        let presentation = EpisodeNameParser.presentation(
            for: PlayEpisode(
                name: "[2.4GB]03.mp4【铁拳教育】",
                url: "https://media.example.invalid/episode-03.mp4"
            )
        )
        let button = DetailEpisodeButton(
            presentation: presentation,
            onPlay: { _ in }
        )
        XCTAssertEqual(button.originalNamePresentationMode, .anchoredPopover)
        XCTAssertEqual(presentation.displayName, "第 3 集")
    }

    func testDetailEpisodeOriginalNameCanBeCopiedFromContextMenuAction() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("OKVideoMacTests.\(UUID().uuidString)")
        )
        let originalName = "[2.4GB]03.mp4【铁拳教育】"

        DetailEpisodeOriginalNameActions.copy(originalName, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), originalName)
    }

    func testLargeEpisodeRangePickerUsesCompactNavigation() {
        XCTAssertEqual(
            EpisodeRangePickerPolicy.presentationMode(optionCount: 8),
            .chips
        )
        XCTAssertEqual(
            EpisodeRangePickerPolicy.presentationMode(optionCount: 9),
            .compactMenu
        )

        let options = (0..<12).map { index in
            EpisodeRangeOption(
                id: "range-\(index)",
                title: "\(index * 20 + 1)–\((index + 1) * 20) 集",
                episodeIDs: []
            )
        }
        XCTAssertEqual(
            EpisodeRangePickerPolicy.adjacentID(
                options: options,
                selectedID: nil,
                offset: 1
            ),
            "range-0"
        )
        XCTAssertEqual(
            EpisodeRangePickerPolicy.adjacentID(
                options: options,
                selectedID: "range-4",
                offset: 1
            ),
            "range-5"
        )
        XCTAssertFalse(
            EpisodeRangePickerPolicy.canMove(
                options: options,
                selectedID: "range-11",
                offset: 1
            )
        )
    }

    func testPlayerEpisodeButtonUsesPanelInspectorWithoutHoverOverlay() {
        let presentation = EpisodeNameParser.presentation(
            for: PlayEpisode(
                name: "[1.8GB]S02E31.mkv【魔神英雄传】",
                url: "https://media.example.invalid/episode-31.mkv"
            )
        )
        let button = PlayerEpisodeButton(
            presentation: presentation,
            displayName: presentation.displayName,
            selected: false,
            accentColor: .blue,
            onPlay: {},
            onInspect: {}
        )

        XCTAssertEqual(
            button.originalNamePresentationMode,
            .panelInspector
        )
    }

    func testPlayerEpisodeOriginalNameCanBeCopied() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("OKVideoMacTests.\(UUID().uuidString)")
        )
        let originalName = "[1.8GB]S02E31.mkv【魔神英雄传】"

        PlayerEpisodeOriginalNameActions.copy(originalName, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), originalName)
    }

    func testPlayerEpisodeInspectorReservesSpaceWithoutGrowingPanel() {
        XCTAssertEqual(
            PlayerEpisodePanelLayoutPolicy.gridHeight(
                episodeCount: 241,
                showsInspector: false
            ),
            286
        )
        XCTAssertEqual(
            PlayerEpisodePanelLayoutPolicy.gridHeight(
                episodeCount: 241,
                showsInspector: true
            ),
            196
        )
        XCTAssertEqual(
            PlayerEpisodePanelLayoutPolicy.gridHeight(
                episodeCount: 3,
                showsInspector: true
            ),
            54
        )
    }

    func testLargeEpisodeDetailDefaultsToRecentRange() {
        XCTAssertFalse(
            EpisodeInitialRangePolicy.shouldSelectRecentRange(
                episodeCount: 200,
                rangeCount: 10
            )
        )
        XCTAssertTrue(
            EpisodeInitialRangePolicy.shouldSelectRecentRange(
                episodeCount: 1_141,
                rangeCount: 58
            )
        )
    }

    func testPlayerEpisodePagesBoundRenderedButtonsAndLocateCurrentEpisode() {
        let presentations = (1...1_141).map { number in
            EpisodePresentation(
                episode: PlayEpisode(
                    name: "E\(number)",
                    url: "https://media.example.invalid/\(number).m3u8"
                ),
                displayName: "第 \(number) 集",
                originalName: "E\(number)",
                seasonNumber: nil,
                episodeNumber: number,
                isSpecial: false,
                sourceIndex: number - 1
            )
        }

        XCTAssertEqual(
            PlayerEpisodePagePolicy.pageCount(
                episodeCount: presentations.count
            ),
            23
        )
        let currentID = presentations[516].id
        let pageIndex = PlayerEpisodePagePolicy.pageIndex(
            presentations: presentations,
            selectedEpisodeID: currentID
        )
        XCTAssertEqual(pageIndex, 10)
        let page = PlayerEpisodePagePolicy.page(
            presentations,
            pageIndex: pageIndex
        )
        XCTAssertEqual(page.count, 50)
        XCTAssertTrue(page.contains(where: { $0.id == currentID }))
        XCTAssertEqual(
            PlayerEpisodePagePolicy.title(
                presentations: presentations,
                pageIndex: pageIndex
            ),
            "501–550 集"
        )
        XCTAssertEqual(
            PlayerEpisodePagePolicy.page(
                presentations,
                pageIndex: 22
            ).count,
            41
        )

        let visiblePage = PlayerEpisodePagePolicy.page(
            presentations,
            pageIndex: pageIndex
        )
        let firstGrid = PlayerEpisodeGrid(
            presentations: visiblePage,
            selectedEpisodeID: currentID,
            accentColor: .blue,
            displayName: { $0.displayName },
            onPlay: { _ in },
            onInspect: { _ in }
        )
        let unchangedGrid = PlayerEpisodeGrid(
            presentations: visiblePage,
            selectedEpisodeID: currentID,
            accentColor: .blue,
            displayName: { $0.displayName },
            onPlay: { _ in },
            onInspect: { _ in }
        )
        let changedSelectionGrid = PlayerEpisodeGrid(
            presentations: visiblePage,
            selectedEpisodeID: visiblePage.first?.id,
            accentColor: .blue,
            displayName: { $0.displayName },
            onPlay: { _ in },
            onInspect: { _ in }
        )
        XCTAssertEqual(firstGrid, unchangedGrid)
        XCTAssertNotEqual(firstGrid, changedSelectionGrid)
    }

    func testEpisodeNameParserDoesNotInferNumberFromSourcePosition() {
        let episodes = [
            PlayEpisode(name: "S01E14", url: "episode-14"),
            PlayEpisode(name: "幕后制作", url: "behind-the-scenes"),
            PlayEpisode(name: "S01E15", url: "episode-15")
        ]

        let values = EpisodeListPresentation.presentations(
            from: episodes,
            query: "",
            sortOrder: .sourceOrder
        )

        XCTAssertEqual(values.map(\.episodeNumber), [14, nil, 15])
        XCTAssertEqual(values[1].displayName, "幕后制作")
        XCTAssertFalse(values[1].displayName.contains("第 2 集"))
    }

    func testSingleEpisodeUsesFeatureLabelAndPreservesOriginalName() {
        let values = EpisodeListPresentation.presentations(
            from: [
                PlayEpisode(
                    name: "后来的我们.1080p.HD中字.mp4【后来的我们】",
                    url: "https://media.example.invalid/movie.mp4"
                )
            ],
            query: "",
            sortOrder: .sourceOrder
        )

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].displayName, "正片")
        XCTAssertEqual(
            values[0].originalName,
            "后来的我们.1080p.HD中字.mp4【后来的我们】"
        )
        XCTAssertNil(values[0].episodeNumber)
    }

    func testEpisodeNameParserRecognizesFilenameSuffixAndPreservesSpecials() {
        let numbered = EpisodeNameParser.presentation(
            for: PlayEpisode(name: "琅琊榜_23.mp4", url: "episode-23")
        )
        let special = EpisodeNameParser.presentation(
            for: PlayEpisode(name: "琅琊榜.SP01.花絮.mkv", url: "special")
        )

        XCTAssertEqual(numbered.episodeNumber, 23)
        XCTAssertEqual(numbered.displayName, "第 23 集")
        XCTAssertNil(special.episodeNumber)
        XCTAssertTrue(special.isSpecial)
        XCTAssertEqual(special.displayName, "琅琊榜.SP01.花絮")
    }

    func testEpisodeNameParserPrefersFileNumberOverSeriesEpisodeCount() {
        let fifth = EpisodeNameParser.presentation(
            for: PlayEpisode(
                name: "[1.6GB]05.mp4【[国产剧]你好，旧时光.全30集.国语中字.2017.4K】",
                url: "episode-05"
            )
        )
        let aggregateOnly = EpisodeNameParser.presentation(
            for: PlayEpisode(name: "你好，旧时光 全30集", url: "series-summary")
        )

        XCTAssertEqual(fifth.episodeNumber, 5)
        XCTAssertEqual(fifth.displayName, "第 5 集")
        XCTAssertNil(aggregateOnly.episodeNumber)
        XCTAssertEqual(aggregateOnly.displayName, "你好，旧时光 全30集")
    }

    func testEpisodeNameParserIgnoresSlashInAppendedFolderDescription() {
        let standard = EpisodeNameParser.presentation(
            for: PlayEpisode(
                name: "[703.4MB]S01E01.mp4【L - 凛冬下的罪恶/4K】",
                url: "standard-episode-01"
            )
        )
        let hdr = EpisodeNameParser.presentation(
            for: PlayEpisode(
                name: "[1.4GB]HDR.10bit.DDP5.1.S01E02.mkv【L - 凛冬下的罪恶/4K高码率 [HDR]】",
                url: "hdr-episode-02"
            )
        )

        XCTAssertEqual(standard.seasonNumber, 1)
        XCTAssertEqual(standard.episodeNumber, 1)
        XCTAssertEqual(standard.displayName, "第 1 季 · 第 1 集")
        XCTAssertEqual(hdr.seasonNumber, 1)
        XCTAssertEqual(hdr.episodeNumber, 2)
        XCTAssertEqual(hdr.displayName, "第 1 季 · 第 2 集")
    }

    func testEpisodeListPrefersProgressingEPFieldOverSharedSeriesCount() {
        let sharedDescription = "【029069-何以笙箫默 (36集) 钟汉良＆唐嫣】"
        let episodes = [
            PlayEpisode(
                name: "[1.6GB]何以笙箫默 My Sunshine EP01.1080P.WEB-DL.mp4\(sharedDescription)",
                url: "episode-01"
            ),
            PlayEpisode(
                name: "[1.6GB]何以笙箫默 My Sunshine EP02.1080P.WEB-DL.mp4\(sharedDescription)",
                url: "episode-02"
            ),
            PlayEpisode(
                name: "[1.7GB]何以笙箫默 My Sunshine EP03.1080P.WEB-DL.mp4\(sharedDescription)",
                url: "episode-03"
            ),
            PlayEpisode(
                name: "[3.8GB]何以笙箫默 You Are My Sunshine.1080P电影.mp4\(sharedDescription)",
                url: "movie"
            )
        ]

        let values = EpisodeListPresentation.presentations(
            from: episodes,
            query: "",
            sortOrder: .sourceOrder
        )

        XCTAssertEqual(values.map(\.episodeNumber), [1, 2, 3, nil])
        XCTAssertEqual(values.map(\.displayName).prefix(3), [
            "第 1 集", "第 2 集", "第 3 集"
        ])
        XCTAssertFalse(values[3].displayName.contains("第 36 集"))
    }

    func testEpisodeListInfersProgressingFilenameFieldAroundNumericNoise() {
        let episodes = [1, 2, 3, 4].map { number in
            PlayEpisode(
                name: "[1.\(number)GB]Show.2026.1080p.\(String(format: "%02d", number))-4K.H265.mp4【全36集】",
                url: "episode-\(number)"
            )
        }

        let values = EpisodeListPresentation.presentations(
            from: episodes,
            query: "",
            sortOrder: .sourceOrder
        )

        XCTAssertEqual(values.map(\.episodeNumber), [1, 2, 3, 4])
    }

    func testEpisodeListRecognizesStableDescendingFilenameSequence() {
        let episodes = [12, 11, 10, 9].map { number in
            PlayEpisode(
                name: "[900MB]\(String(format: "%02d", number)).4K.SDR.60fps.mp4【剧集 2026】",
                url: "episode-\(number)"
            )
        }

        let values = EpisodeListPresentation.presentations(
            from: episodes,
            query: "",
            sortOrder: .sourceOrder
        )

        XCTAssertEqual(values.map(\.episodeNumber), [12, 11, 10, 9])
    }

    func testSingleFilenameStillUsesLocalEpisodeFallback() {
        let parsed = EpisodeNameParser.presentation(
            for: PlayEpisode(
                name: "[1.6GB]05.mp4【剧名 2026 全36集 4K】",
                url: "episode-05"
            )
        )

        XCTAssertEqual(parsed.episodeNumber, 5)
        XCTAssertEqual(parsed.displayName, "第 5 集")
    }

    func testEpisodeNameParserDoesNotTreatOrdinaryTrailingNumberAsEpisode() {
        let presentation = EpisodeNameParser.presentation(
            for: PlayEpisode(name: "Mader - Pa's Kitchen 1", url: "track")
        )

        XCTAssertNil(presentation.episodeNumber)
        XCTAssertEqual(presentation.displayName, "Mader - Pa's Kitchen 1")
    }

    func testEpisodeNameParserDoesNotTreatFilenameYearAsEpisode() {
        let presentation = EpisodeNameParser.presentation(
            for: PlayEpisode(name: "The.Movie.2026.mp4", url: "movie")
        )

        XCTAssertNil(presentation.episodeNumber)
        XCTAssertEqual(presentation.displayName, "The.Movie.2026")
    }

    func testEpisodeNameParserPreservesNamedSpecialEvenWithEpisodeCode() {
        let presentation = EpisodeNameParser.presentation(
            for: PlayEpisode(name: "S01E14 特别篇.mkv", url: "special")
        )

        XCTAssertNil(presentation.episodeNumber)
        XCTAssertTrue(presentation.isSpecial)
        XCTAssertEqual(presentation.displayName, "S01E14 特别篇")
    }

    func testEpisodeSortingKeepsUnknownResourcesInSourceOrder() {
        let episodes = [
            PlayEpisode(name: "E15", url: "15"),
            PlayEpisode(name: "预告片", url: "preview"),
            PlayEpisode(name: "E14", url: "14"),
            PlayEpisode(name: "幕后花絮", url: "behind")
        ]

        let sorted = EpisodeListPresentation.presentations(
            from: episodes,
            query: "",
            sortOrder: .episodeAscending
        )

        XCTAssertEqual(sorted.map(\.episodeNumber), [14, 15, nil, nil])
        XCTAssertEqual(Array(sorted.suffix(2).map(\.originalName)), ["预告片", "幕后花絮"])
    }

    func testEpisodeRangesUseActualEpisodeNumbers() {
        let episodes = (14...54).map {
            PlayEpisode(name: "E\($0)", url: "episode-\($0)")
        }
        let values = EpisodeListPresentation.presentations(
            from: episodes,
            query: "",
            sortOrder: .sourceOrder
        )

        let ranges = EpisodeListPresentation.rangeOptions(from: values)

        XCTAssertEqual(ranges.first?.title, "14–33 集")
        XCTAssertFalse(ranges.first?.title.contains("1–20") ?? true)
    }

    func testPlayerSeekPolicyKeepsProgressTargetInMediaBounds() {
        XCTAssertEqual(
            PlayerSeekPolicy.target(requested: 90, duration: 120),
            90
        )
        XCTAssertEqual(
            PlayerSeekPolicy.target(requested: 150, duration: 120),
            120
        )
        XCTAssertEqual(
            PlayerSeekPolicy.target(requested: 90, duration: 0),
            90
        )
        XCTAssertNil(
            PlayerSeekPolicy.target(requested: -.infinity, duration: 120)
        )
        XCTAssertNil(
            PlayerSeekPolicy.target(requested: -1, duration: 120)
        )
    }

    func testNothingToPlayErrorUsesActionableLocalizedMessage() {
        XCTAssertEqual(
            MPVPlaybackErrorPolicy.userFacingMessage(
                nativeMessage: "no audio or video data played"
            ),
            "该线路没有返回可播放的音视频数据"
        )
        XCTAssertEqual(
            MPVPlaybackErrorPolicy.userFacingMessage(
                nativeMessage: "fixture error"
            ),
            "fixture error"
        )
    }

    func testPlaybackStartupRequiresFileLoadedAndCompletesOnlyOnce() {
        let requestID = UUID()
        let playerID = UUID()
        let store = PlayerStartupTraceStore.shared
        store.begin(requestID: requestID, mode: .warmStop)
        store.markClientReady(requestID: requestID, playerID: playerID)
        store.markLoadfileIssued(requestID: requestID, playerID: playerID)

        XCTAssertNil(store.markFirstRenderSwap(playerID: playerID))

        store.markFileLoaded(requestID: requestID, playerID: playerID)
        store.markFileLoaded(requestID: requestID, playerID: playerID)
        XCTAssertEqual(
            store.markFirstRenderSwap(playerID: playerID),
            requestID
        )
        XCTAssertNil(store.markFirstRenderSwap(playerID: playerID))
        XCTAssertNil(store.markTimelineProgress(playerID: playerID))
    }

    func testTimelineProgressCanConfirmAudioOnlyPlayback() {
        let requestID = UUID()
        let playerID = UUID()
        let store = PlayerStartupTraceStore.shared
        store.begin(requestID: requestID, mode: .warmStop)
        store.markClientReady(requestID: requestID, playerID: playerID)
        store.markLoadfileIssued(requestID: requestID, playerID: playerID)
        store.markFileLoaded(requestID: requestID, playerID: playerID)

        XCTAssertEqual(
            store.markTimelineProgress(playerID: playerID),
            requestID
        )
        XCTAssertNil(store.markFirstRenderSwap(playerID: playerID))
    }

    func testPlaybackStartSignalResetsIndependentlyOfTracing() {
        let signal = PlayerPlaybackStartSignal()
        let failedCandidateRequestID = UUID()
        let fallbackRequestID = UUID()

        signal.reset(requestID: failedCandidateRequestID)
        XCTAssertNil(signal.claimPlaybackStarted())
        signal.cancel()

        signal.reset(requestID: fallbackRequestID)
        signal.markFileLoaded()
        XCTAssertEqual(signal.claimPlaybackStarted(), fallbackRequestID)
        XCTAssertNil(signal.claimPlaybackStarted())
    }

    func testMPVTimelinePropertiesAreTheOnlyRateLimitedSnapshots() {
        XCTAssertTrue(MPVPlayerClient.isTimelineProperty("time-pos"))
        XCTAssertTrue(
            MPVPlayerClient.isTimelineProperty("cache-buffering-state")
        )
        XCTAssertTrue(MPVPlayerClient.isTimelineProperty("cache-speed"))
        XCTAssertFalse(MPVPlayerClient.isTimelineProperty("pause"))
        XCTAssertFalse(MPVPlayerClient.isTimelineProperty("volume"))
    }

    func testRenderUpdateGateResetsWhenSchedulingFinishesWithoutADraw() {
        let gate = PlayerDisplayUpdateGate()
        XCTAssertTrue(gate.requestUpdate())
        for _ in 0..<1_000 {
            XCTAssertFalse(gate.requestUpdate())
        }
        XCTAssertTrue(gate.finishScheduling())
        XCTAssertFalse(gate.finishScheduling())
        XCTAssertTrue(gate.requestUpdate())
    }

    func testRenderUpdateGateDropsFramesDuringLiveWindowResize() {
        let gate = PlayerDisplayUpdateGate()
        XCTAssertTrue(gate.requestUpdate())

        gate.setSuspended(true)
        XCTAssertFalse(gate.requestUpdate())
        XCTAssertFalse(gate.finishScheduling())

        gate.setSuspended(false)
        XCTAssertTrue(gate.requestUpdate())
        XCTAssertFalse(gate.finishScheduling())
    }

    func testUnavailablePlayerPlaceholderDoesNotOverlapStatusOverlay() {
        XCTAssertTrue(
            PlayerUnavailablePlaceholderPolicy.shouldShow(
                hasEmbeddedPlayer: false,
                showsStatusOverlay: false
            )
        )
        XCTAssertFalse(
            PlayerUnavailablePlaceholderPolicy.shouldShow(
                hasEmbeddedPlayer: false,
                showsStatusOverlay: true
            )
        )
        XCTAssertFalse(
            PlayerUnavailablePlaceholderPolicy.shouldShow(
                hasEmbeddedPlayer: true,
                showsStatusOverlay: false
            )
        )
    }

    func testAutomaticEpisodeAdvanceOnlyReturnsAnExistingNextEpisode() {
        let episodes = [
            PlayEpisode(name: "第1集", url: "episode-1"),
            PlayEpisode(name: "第2集", url: "episode-2")
        ]

        XCTAssertEqual(
            PlayerEpisodeAdvancePolicy.nextEpisode(
                in: episodes,
                currentEpisodeID: episodes[0].id,
                enabled: true
            )?.id,
            episodes[1].id
        )
        XCTAssertNil(
            PlayerEpisodeAdvancePolicy.nextEpisode(
                in: episodes,
                currentEpisodeID: episodes[0].id,
                enabled: false
            )
        )
        XCTAssertNil(
            PlayerEpisodeAdvancePolicy.nextEpisode(
                in: episodes,
                currentEpisodeID: episodes[1].id,
                enabled: true
            )
        )
        XCTAssertNil(
            PlayerEpisodeAdvancePolicy.nextEpisode(
                in: episodes,
                currentEpisodeID: "missing",
                enabled: true
            )
        )
    }

    func testMouseMoveRatePolicyDropsRedundantTrackingEvents() {
        XCTAssertTrue(
            PlayerInteractionRatePolicy.shouldForwardMouseMove(
                lastForwardedAt: 0,
                now: 10
            )
        )
        XCTAssertFalse(
            PlayerInteractionRatePolicy.shouldForwardMouseMove(
                lastForwardedAt: 10,
                now: 10.04
            )
        )
        XCTAssertTrue(
            PlayerInteractionRatePolicy.shouldForwardMouseMove(
                lastForwardedAt: 10,
                now: 10.09
            )
        )
    }

    func testAppSectionsHaveUniqueNamesAndIcons() {
        XCTAssertEqual(Set(AppSection.allCases.map(\.rawValue)).count, AppSection.allCases.count)
        XCTAssertFalse(AppSection.allCases.contains { $0.systemImage.isEmpty })
        XCTAssertEqual(
            AppSection.allCases.map(\.rawValue),
            ["首页", "直播", "收藏", "历史", "设置"]
        )
    }

    func testLiveChannelLogoResolverNormalizesCommonChineseChannelNames() throws {
        XCTAssertEqual(LiveChannelLogoResolver.lookupKey("CCTV-1"), "CCTV1")
        XCTAssertEqual(LiveChannelLogoResolver.lookupKey("CCTV-5+"), "CCTV5+")
        XCTAssertEqual(
            LiveChannelLogoResolver.lookupKey("030 CCTV4K超高清"),
            "CCTV4K"
        )
        XCTAssertEqual(
            LiveChannelLogoResolver.lookupKey("湖南卫视高清"),
            "湖南卫视"
        )

        let explicit = try XCTUnwrap(URL(string: "https://example.com/logo.png"))
        let streamURL = try XCTUnwrap(URL(string: "https://example.com/live.m3u8"))
        let channel = LiveChannel(
            groupName: "央视频道",
            name: "CCTV-1",
            logoURL: explicit,
            streams: [LiveStream(name: "线路 1", url: streamURL)]
        )
        let urls = LiveChannelLogoResolver.urls(for: channel)
        XCTAssertEqual(urls.first, explicit)
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "CCTV1.png" })
    }

    func testHTTPConfigurationSourcesAreAllowedByAppTransportSecurity() {
        let policy = Bundle.main.object(
            forInfoDictionaryKey: "NSAppTransportSecurity"
        ) as? [String: Any]
        XCTAssertEqual(policy?["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    func testBundledMPVClientInitializesAndShutsDownIdempotently() async throws {
        let client = try MPVPlayerClient()
        XCTAssertTrue(client.runtimeDescription.contains("libmpv"))
        await client.shutdown()
        await client.shutdown()
        do {
            try await client.play()
            XCTFail("播放器 shutdown 后不应再接受命令")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已关闭"))
        }
    }

    func testMPVSubtitleTrackTypeMapsToAppSubtitleType() {
        XCTAssertEqual(
            MPVPlayerClient.mediaTrackType(forMPVValue: "sub"),
            .subtitle
        )
        XCTAssertEqual(
            MPVPlayerClient.mediaTrackType(forMPVValue: "audio"),
            .audio
        )
        XCTAssertEqual(
            MPVPlayerClient.mediaTrackType(forMPVValue: "video"),
            .video
        )
        XCTAssertNil(MPVPlayerClient.mediaTrackType(forMPVValue: "unknown"))
    }

    func testSubtitlePreferencePersistsAndMatchesEquivalentTrack() throws {
        let original = MediaTrack(
            id: 8,
            type: .subtitle,
            title: "Simplified Chinese",
            language: "zh-Hans"
        )
        let preference = PlayerSubtitleTrackPreference(track: original)
        XCTAssertEqual(
            PlayerSubtitleTrackPreference(setting: preference.settingValue),
            preference
        )

        let tracks = [
            MediaTrack(
                id: 2,
                type: .subtitle,
                title: "English",
                language: "en"
            ),
            MediaTrack(
                id: 3,
                type: .subtitle,
                title: "简体中文",
                language: "zh-hans"
            )
        ]
        XCTAssertEqual(
            PlayerSubtitleTrackPreference.matchingTrack(
                in: tracks,
                preference: preference
            )?.id,
            3
        )
    }

    func testNaturalPlaybackEndRecognizesEOFPropertyAndEndFileEvent() {
        XCTAssertTrue(
            MPVPlaybackEndPolicy.isNaturalEnd(
                endFileReason: 0,
                isReplacingMedia: false
            )
        )
        XCTAssertTrue(
            MPVPlaybackEndPolicy.isNaturalEnd(
                eofReached: true,
                isReplacingMedia: false
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                endFileReason: 2,
                isReplacingMedia: false
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                eofReached: true,
                isReplacingMedia: true
            )
        )
    }

    func testOnlyNewestPlaybackRequestCanCommitEvents() {
        let requestA = UUID()
        let requestB = UUID()
        let requestC = UUID()

        XCTAssertFalse(
            PlaybackRequestOwnershipPolicy.accepts(
                requestID: requestA,
                activeRequestID: requestC
            )
        )
        XCTAssertFalse(
            PlaybackRequestOwnershipPolicy.accepts(
                requestID: requestB,
                activeRequestID: requestC
            )
        )
        XCTAssertTrue(
            PlaybackRequestOwnershipPolicy.accepts(
                requestID: requestC,
                activeRequestID: requestC
            )
        )
        XCTAssertFalse(
            PlaybackRequestOwnershipPolicy.accepts(
                requestID: nil,
                activeRequestID: requestC
            )
        )
    }

    func testSystemMenuTitlesAreTranslatedToChinese() {
        XCTAssertEqual(MainMenuChineseLocalization.title(for: "File"), "文件")
        XCTAssertEqual(MainMenuChineseLocalization.title(for: "Edit"), "编辑")
        XCTAssertEqual(
            MainMenuChineseLocalization.title(for: "About OKVideoMac"),
            "关于 OKVideoMac"
        )
        XCTAssertEqual(
            MainMenuChineseLocalization.title(for: "Bring All to Front"),
            "前置全部窗口"
        )
        XCTAssertEqual(
            MainMenuChineseLocalization.title(for: "自定义菜单"),
            "自定义菜单"
        )
    }

    func testMPVPrefersFullSimplifiedChineseSubtitleOverForcedEnglish() throws {
        let tracks = [
            MediaTrack(
                id: 1,
                type: .subtitle,
                title: "Forced",
                language: "en",
                isSelected: true
            ),
            MediaTrack(
                id: 2,
                type: .subtitle,
                title: "subtitle 2",
                language: "en"
            ),
            MediaTrack(
                id: 3,
                type: .subtitle,
                title: "Simplified Chinese",
                language: "cmn-Hans"
            ),
            MediaTrack(
                id: 4,
                type: .subtitle,
                title: "Traditional Chinese",
                language: "cmn-Hant"
            )
        ]

        XCTAssertEqual(
            MPVPlayerClient.preferredSubtitleTrack(in: tracks)?.id,
            3
        )
    }

    func testMPVPrefersNormalSubtitleWhenOnlyEnglishTracksExist() {
        let tracks = [
            MediaTrack(
                id: 1,
                type: .subtitle,
                title: "Forced",
                language: "en",
                isSelected: true
            ),
            MediaTrack(
                id: 2,
                type: .subtitle,
                title: "English",
                language: "en"
            )
        ]

        XCTAssertEqual(
            MPVPlayerClient.preferredSubtitleTrack(in: tracks)?.id,
            2
        )
    }

    func testSpiderHTTPURLPercentEncodesUnicodeModulePath() throws {
        let raw = "https://git.yylx.win/https://raw.githubusercontent.com/fantaiying7/EXT/refs/heads/main/模板.js"
        let url = try XCTUnwrap(SpiderHTTPURL.parse(raw))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertTrue(url.absoluteString.contains("%E6%A8%A1%E6%9D%BF.js"))
    }

    func testInlineImageRequestSeparatesFongMiHeaders() throws {
        let raw = try XCTUnwrap(
            URL(
                string: "https://image.example.invalid/poster.jpg"
                    + "@Referer=https://api.example.invalid/"
                    + "@User-Agent=Fixture%20Player"
            )
        )
        let request = InlineImageRequest.parse(raw)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://image.example.invalid/poster.jpg"
        )
        XCTAssertEqual(request.headers["Referer"], "https://api.example.invalid/")
        XCTAssertEqual(request.headers["User-Agent"], "Fixture Player")
    }

    func testAndroidBridgeAuthorizationStateUsesStableControlIDs() throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "请选择网盘",
              "inputCount": 0,
              "imageCount": 0,
              "buttons": ["停用中", "停用中"],
              "controls": [
                {"id": "view:103", "title": "我的夸父-未登录", "enabled": true, "role": "button"},
                {"id": "view:104", "title": "停用中", "enabled": false, "role": "status"}
              ],
              "texts": ["网盘配置"],
              "phase": "chooser",
              "provider": "quark",
              "authenticated": false,
              "generation": 7
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )

        XCTAssertTrue(state.isAuthorizationPrompt)
        XCTAssertEqual(
            state.actionableControls.map(\.id),
            ["view:103"]
        )
        XCTAssertEqual(state.actionableControls.first?.role, "button")
        XCTAssertEqual(state.generation, 7)
    }

    func testAndroidBridgeLegacyImageDoesNotImplyQRCode() throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "请使用网盘 APP 扫码登录",
              "inputCount": 0,
              "imageCount": 1,
              "buttons": []
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )

        XCTAssertFalse(state.isQRCode)
        XCTAssertTrue(state.isAuthorizationPrompt)
        XCTAssertTrue(state.actionableControls.isEmpty)
    }

    func testAndroidBridgeRecognizesOnlyStructuredCredentialPushRole() throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "Untrusted presentation text",
              "inputCount": 0,
              "imageCount": 1,
              "buttons": [],
              "texts": ["Untrusted helper text"],
              "phase": "qr",
              "provider": "opaque-provider",
              "credentialPush": true,
              "providerOwnerID": "android-owner-v1:test-owner",
              "configurationID": "configuration-a",
              "siteKey": "site-a",
              "actionContract": {
                "credentialSubmission": {
                  "parameters": {},
                  "credentialField": "credential"
                }
              },
              "authenticated": false
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )

        XCTAssertTrue(state.isCredentialPush)
        XCTAssertTrue(state.isAuthorizationPrompt)
    }

    func testAndroidBridgeRejectsCredentialPushWithoutExactActionContract()
        throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "Untrusted presentation text",
              "inputCount": 1,
              "imageCount": 1,
              "buttons": ["Continue"],
              "credentialPush": true,
              "providerOwnerID": "android-owner-v1:test-owner",
              "configurationID": "configuration-a",
              "siteKey": "site-a",
              "authenticated": false
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )

        XCTAssertFalse(state.isCredentialPush)
    }

    func testAndroidProviderOwnerIdentityIsStableAndFullyScoped() throws {
        let jarURL = try XCTUnwrap(URL(string: "https://example.test/a.jar"))
        let first = AndroidDexBridgeClient.providerOwnerID(
            configurationID: "configuration-a",
            siteKey: "site-a",
            jarURL: jarURL,
            jarMD5: "ABCDEF"
        )

        XCTAssertEqual(
            first,
            AndroidDexBridgeClient.providerOwnerID(
                configurationID: "configuration-a",
                siteKey: "site-a",
                jarURL: jarURL,
                jarMD5: "abcdef"
            )
        )
        XCTAssertNotEqual(
            first,
            AndroidDexBridgeClient.providerOwnerID(
                configurationID: "configuration-b",
                siteKey: "site-a",
                jarURL: jarURL,
                jarMD5: "abcdef"
            )
        )
        XCTAssertNotEqual(
            first,
            AndroidDexBridgeClient.providerOwnerID(
                configurationID: "configuration-a",
                siteKey: "site-b",
                jarURL: jarURL,
                jarMD5: "abcdef"
            )
        )
    }

    func testAndroidBridgeDoesNotInferCredentialPushFromTextOrInputCount()
        throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "Configuration form",
              "inputCount": 1,
              "imageCount": 0,
              "buttons": ["Continue"],
              "texts": ["Enter a value"],
              "phase": "form",
              "provider": "opaque-provider",
              "authenticated": false
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        let interaction = state.configurationInteraction(
            requestID: UUID(),
            actionKind: .authorization
        )

        XCTAssertFalse(state.isCredentialPush)
        XCTAssertEqual(interaction.actionKind, .authorization)
        let semantic = ConfigurationInteractionClassificationPolicy
            .nativeSemantic(
                interaction: interaction,
                hasVerifiedQRCode: false,
                credentialPush: false,
                state: state
            )
        XCTAssertFalse(semantic.isAuthorization)
        XCTAssertEqual(
            ConfigurationInteractionClassificationPolicy.interactionKind(
                for: semantic
            ),
            .configuration
        )
    }

    func testAndroidBridgeDoesNotPresentRemoteInputHelperAsLoginQRCode() throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "请输入百度网盘Cookie：",
              "inputCount": 1,
              "imageCount": 1,
              "buttons": ["扫描二维码", "OK"],
              "texts": ["请扫码或者输入\\nhttp://:9978/proxy?do=input"],
              "phase": "credentials",
              "provider": "baidu",
              "authenticated": false,
              "remoteInput": true
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )

        XCTAssertTrue(state.isRemoteInputQRCode)
        XCTAssertFalse(state.isQRCode)
        XCTAssertTrue(state.isAuthorizationPrompt)
    }

    func testAndroidBridgeEmptyChooserIsNotAnAuthorizationPrompt() throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "选择网盘登录方式",
              "inputCount": 0,
              "imageCount": 0,
              "buttons": [],
              "controls": [],
              "texts": [],
              "phase": "chooser",
              "provider": "",
              "authenticated": false
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )

        XCTAssertFalse(state.hasVisibleAuthorizationContent)
        XCTAssertFalse(state.isAuthorizationPrompt)
    }

    func testAndroidBridgeTextOnlyDisclaimerIsNotAnAuthorizationPrompt() throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "选择网盘登录方式",
              "inputCount": 0,
              "imageCount": 0,
              "buttons": [],
              "controls": [],
              "texts": ["本接口免费分享！切勿上当！"],
              "phase": "chooser",
              "provider": "",
              "authenticated": false
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )

        XCTAssertTrue(state.hasVisibleAuthorizationContent)
        XCTAssertFalse(state.isAuthorizationPrompt)
    }

    func testConfigurationInteractionUsesStructuralKindAndClickableControls()
        throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "扫码登录（只是误导性显示文本）",
              "inputCount": 0,
              "imageCount": 0,
              "buttons": [],
              "controls": [
                {"id": "choice:1", "title": "普通配置", "enabled": true, "clickable": true, "role": "button"},
                {"id": "status:1", "title": "不可点击状态", "enabled": true, "clickable": false, "role": "status"},
                {"id": "disabled:1", "title": "已停用", "enabled": false, "clickable": true, "role": "button"}
              ],
              "texts": [],
              "phase": "awaitingUser",
              "provider": "opaque-provider",
              "generation": 9
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        let requestID = UUID()
        let interaction = state.configurationInteraction(
            requestID: requestID,
            actionKind: .configuration
        )

        XCTAssertEqual(interaction.id, requestID)
        XCTAssertEqual(interaction.actionKind, .configuration)
        XCTAssertEqual(interaction.phase, .choice)
        XCTAssertEqual(interaction.outcome, .pending)
        XCTAssertEqual(interaction.qrRole, .none)
        XCTAssertEqual(interaction.controls.map(\.id), ["choice:1"])
        XCTAssertEqual(interaction.controls.first?.role, .action)
        XCTAssertEqual(interaction.generation, 9)
    }

    func testConfigurationInteractionHonorsBridgeOrderingKindWithoutTitleInference()
        throws {
        let requestID = UUID()
        let data = Data(
            """
            {
              "interactionID": "\(requestID.uuidString)",
              "revision": 12,
              "kind": "ordering",
              "method": "action",
              "visible": true,
              "title": "登录授权（误导性文本）",
              "inputCount": 0,
              "imageCount": 0,
              "buttons": [],
              "controls": [
                {"id":"order:1","title":"第一项","enabled":true,"clickable":true,"role":"action"},
                {"id":"order:status","title":"状态","enabled":true,"clickable":false,"role":"status"}
              ],
              "texts": [],
              "phase": "awaitingUser",
              "outcome": "stay",
              "terminal": false
            }
            """.utf8
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        let interaction = state.configurationInteraction(
            requestID: requestID,
            actionKind: .configuration
        )

        XCTAssertEqual(interaction.actionKind, .ordering)
        XCTAssertEqual(interaction.phase, .choice)
        XCTAssertEqual(interaction.outcome, .pending)
        XCTAssertEqual(interaction.generation, 12)
        XCTAssertEqual(interaction.controls.map(\.id), ["order:1"])
        XCTAssertEqual(interaction.qrRole, .none)
    }

    func testAndroidActionKindUsesOnlyExplicitProtocolTag() {
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: "command"),
            .command
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: "toggle"),
            .toggle
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: "order"),
            .ordering
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: "qr"),
            .configuration
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(
                tag: "credential"
            ),
            .configuration
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(
                tag: "authorization"
            ),
            .authorization
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: "web"),
            .webSetting
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: "other"),
            .configuration
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: nil),
            .configuration
        )
    }

    func testConfigurationInteractionReattachingHostRemainsPending() throws {
        let requestID = UUID()
        let data = Data(
            """
            {
              "interactionID": "\(requestID.uuidString)",
              "revision": 4,
              "kind": "authorization",
              "method": "action",
              "visible": false,
              "title": "",
              "inputCount": 0,
              "imageCount": 0,
              "buttons": [],
              "phase": "reattaching",
              "outcome": "stay",
              "terminal": false,
              "hostUnavailable": true
            }
            """.utf8
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        let interaction = state.configurationInteraction(
            requestID: requestID,
            actionKind: .configuration
        )

        XCTAssertEqual(state.hostUnavailable, true)
        XCTAssertEqual(interaction.actionKind, .authorization)
        XCTAssertEqual(interaction.phase, .reattaching)
        XCTAssertEqual(interaction.outcome, .pending)
    }

    func testConfigurationInteractionRequiresValidatedQRCodeForAuthorization()
        throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "Native content",
              "inputCount": 0,
              "imageCount": 1,
              "buttons": [],
              "controls": [],
              "texts": [],
              "phase": "awaitingUser"
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        let requestID = UUID()
        let imageOnly = state.configurationInteraction(
            requestID: requestID,
            actionKind: .configuration
        )
        let validated = state.configurationInteraction(
            requestID: requestID,
            actionKind: .configuration,
            validatedQRCode: Data([0x51, 0x52])
        )
        let declaredAuthorization = state.configurationInteraction(
            requestID: requestID,
            actionKind: .authorization,
            validatedQRCode: Data([0x51, 0x52])
        )
        let declaredAuthorizationWithoutQRCode = state
            .configurationInteraction(
                requestID: requestID,
                actionKind: .authorization
            )

        XCTAssertEqual(imageOnly.actionKind, .configuration)
        XCTAssertEqual(imageOnly.qrRole, .none)
        XCTAssertEqual(imageOnly.phase, .status)
        XCTAssertEqual(validated.actionKind, .configuration)
        XCTAssertEqual(validated.qrRole, .candidate)
        XCTAssertEqual(validated.phase, .qrCode)
        XCTAssertEqual(declaredAuthorization.actionKind, .authorization)
        XCTAssertEqual(declaredAuthorization.qrRole, .login)
        XCTAssertEqual(declaredAuthorization.phase, .qrCode)
        XCTAssertEqual(
            declaredAuthorizationWithoutQRCode.actionKind,
            .authorization
        )
        XCTAssertNotEqual(
            declaredAuthorizationWithoutQRCode.qrRole,
            .login
        )
        XCTAssertFalse(
            ConfigurationInteractionClassificationPolicy.nativeSemantic(
                interaction: declaredAuthorizationWithoutQRCode,
                hasVerifiedQRCode: false,
                credentialPush: false,
                state: state
            ).isAuthorization
        )
        XCTAssertEqual(
            ConfigurationInteractionClassificationPolicy.nativeSemantic(
                interaction: declaredAuthorization,
                hasVerifiedQRCode: true,
                credentialPush: false,
                state: state
            ),
            .qrAuthorization
        )
        XCTAssertFalse(
            ConfigurationInteractionClassificationPolicy
                .legacySemantic(tag: "qr")
                .isAuthorization
        )
    }

    func testOrderingInteractionCannotBePromotedToAuthorizationByQRCode()
        throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "kind": "ordering",
              "title": "网盘线路前后排序",
              "inputCount": 0,
              "imageCount": 1,
              "buttons": [],
              "controls": [],
              "texts": [],
              "phase": "qr"
            }
            """.data(using: .utf8)
        )
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: data
        )
        let interaction = state.configurationInteraction(
            requestID: UUID(),
            actionKind: .configuration,
            validatedQRCode: Data([0x51, 0x52])
        )

        XCTAssertEqual(interaction.actionKind, .ordering)
        XCTAssertEqual(interaction.qrRole, .candidate)
        XCTAssertFalse(
            ConfigurationInteractionClassificationPolicy.nativeSemantic(
                interaction: interaction,
                hasVerifiedQRCode: true,
                credentialPush: false,
                state: state
            ).isAuthorization
        )
    }

    func testInteractionHandleRetainsTerminalResponseAfterUIPresentation()
        async throws {
        let requestID = UUID()
        let expected = ConfigurationInteractionTerminalResponse(
            requestID: requestID,
            outcome: .succeeded,
            providerResult: .string("provider-final-result"),
            error: nil,
            httpStatusCode: 200,
            refreshPerformed: nil
        )
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .configuration
        ) {
            try await Task.sleep(nanoseconds: 10_000_000)
            return expected
        }
        let presented = ConfigurationInteraction(
            id: requestID,
            actionKind: .configuration,
            phase: .choice,
            outcome: .pending,
            title: "Choose",
            provider: nil,
            generation: 1,
            controls: [],
            qrRole: .none,
            qrImage: nil
        )

        await handle.record(presented)
        let firstRead = try await handle.finalResponse()
        let secondRead = try await handle.finalResponse()
        let latest = await handle.latestInteraction()

        XCTAssertEqual(firstRead, expected)
        XCTAssertEqual(secondRead, expected)
        XCTAssertEqual(latest, presented)
    }

    func testInteractionHandleUsesOneRequestIDForEveryScopedOperation()
        async throws {
        let requestID = UUID()
        let expected = ConfigurationInteractionTerminalResponse(
            requestID: requestID,
            outcome: .succeeded,
            providerResult: .string("final"),
            error: nil,
            httpStatusCode: 200,
            refreshPerformed: nil
        )
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .configuration,
            stateProvider: { receivedID in
                guard receivedID == requestID else {
                    throw AppError.spider("state request id mismatch")
                }
                return try JSONDecoder().decode(
                    AndroidBridgeUIState.self,
                    from: Data(
                        """
                        {"interactionID":"\(requestID.uuidString)","visible":false,"title":"","inputCount":0,"imageCount":0,"buttons":[],"phase":"processing","outcome":"stay","terminal":false}
                        """.utf8
                    )
                )
            },
            snapshotProvider: { receivedID in
                guard receivedID == requestID else {
                    throw AppError.spider("snapshot request id mismatch")
                }
                return Data([0x01, 0x02])
            },
            submitProvider: {
                receivedID, _, _, _, generation in
                guard receivedID == requestID else {
                    throw AppError.spider("submit request id mismatch")
                }
                return AndroidBridgeUISubmitResult(
                    clicked: true,
                    stale: false,
                    generation: generation
                )
            },
            verifyProvider: {
                receivedID, succeeded, _, refreshPerformed in
                guard receivedID == requestID, succeeded else {
                    throw AppError.spider("verify request id mismatch")
                }
                return ConfigurationInteractionTerminalResponse(
                    requestID: receivedID,
                    outcome: .succeeded,
                    providerResult: nil,
                    error: nil,
                    httpStatusCode: 200,
                    refreshPerformed: refreshPerformed
                )
            }
        ) { expected }

        let state = try await handle.currentState()
        let snapshot = try await handle.snapshot()
        let submission = try await handle.submit(
            text: nil,
            button: "",
            controlID: "control:1",
            generation: 7
        )
        let verification = try await handle.verify(
            succeeded: true,
            actualRefreshPerformed: false
        )

        XCTAssertEqual(state.interactionID, requestID.uuidString)
        XCTAssertEqual(snapshot, Data([0x01, 0x02]))
        XCTAssertEqual(submission.generation, 7)
        XCTAssertEqual(verification.requestID, requestID)
        XCTAssertEqual(verification.providerResult, .string("final"))
        XCTAssertNil(verification.refreshPerformed)
    }

    func testInteractionHandleWaitsForScopedCancellationAcknowledgement()
        async throws {
        let requestID = UUID()
        let recorder = ConfigurationCancellationTestRecorder()
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .configuration,
            cancelProvider: { receivedID in
                await recorder.recordStarted(receivedID)
                try await Task.sleep(nanoseconds: 20_000_000)
                await recorder.recordAcknowledged(receivedID)
            }
        ) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ConfigurationInteractionTerminalResponse(
                requestID: requestID,
                outcome: .succeeded,
                providerResult: .string("late"),
                error: nil,
                httpStatusCode: 200,
                refreshPerformed: nil
            )
        }

        await handle.cancelAndWait()
        let events = await recorder.events

        XCTAssertEqual(events, ["start:\(requestID)", "ack:\(requestID)"])
    }

    func testAppStateScopedVerificationPreservesDelayedProviderTerminalResult()
        async throws {
        let requestID = UUID()
        let providerTerminal = ConfigurationInteractionTerminalResponse(
            requestID: requestID,
            outcome: .succeeded,
            providerResult: .object([
                "url": .string("provider-owned-result")
            ]),
            error: nil,
            httpStatusCode: 200,
            refreshPerformed: true
        )
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .playback,
            verifyProvider: {
                receivedID, succeeded, _, refreshPerformed in
                XCTAssertEqual(receivedID, requestID)
                XCTAssertTrue(succeeded)
                return ConfigurationInteractionTerminalResponse(
                    requestID: receivedID,
                    outcome: .succeeded,
                    providerResult: nil,
                    error: nil,
                    httpStatusCode: 200,
                    refreshPerformed: refreshPerformed
                )
            }
        ) {
            // Reproduce the real race: the state verification endpoint becomes
            // terminal just before the original `/v1/invoke` returns its value.
            try await Task.sleep(nanoseconds: 50_000_000)
            return providerTerminal
        }
        let observer = Task {
            try await handle.finalResponse()
        }

        await AppState.verifyScopedConfigurationInteraction(
            handle,
            succeeded: true,
            actualRefreshPerformed: false,
            providerResultGraceNanoseconds: 1_000_000_000
        )
        let observed = try await observer.value
        let repeatedTerminal = try await handle.finalResponse()

        XCTAssertEqual(observed, providerTerminal)
        XCTAssertEqual(repeatedTerminal.providerResult, providerTerminal.providerResult)
    }

    func testAppStateScopedVerificationPublishesBoundedFallbackOnce()
        async throws {
        let requestID = UUID()
        let verifiedFallback = ConfigurationInteractionTerminalResponse(
            requestID: requestID,
            outcome: .succeeded,
            providerResult: nil,
            error: nil,
            httpStatusCode: 200,
            refreshPerformed: false
        )
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .authorization,
            verifyProvider: { _, _, _, _ in verifiedFallback }
        ) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ConfigurationInteractionTerminalResponse(
                requestID: requestID,
                outcome: .succeeded,
                providerResult: .string("too-late"),
                error: nil,
                httpStatusCode: 200,
                refreshPerformed: nil
            )
        }
        let observer = Task {
            try await handle.finalResponse()
        }

        await AppState.verifyScopedConfigurationInteraction(
            handle,
            succeeded: true,
            actualRefreshPerformed: false,
            providerResultGraceNanoseconds: 5_000_000
        )
        let first = try await observer.value
        let repeated = try await handle.finalResponse()

        XCTAssertEqual(first, verifiedFallback)
        XCTAssertEqual(repeated, verifiedFallback)
    }

    func testScopedVerificationUsesReturnedOutcomeForProviderResultGrace()
        async throws {
        let requestID = UUID()
        let providerTerminal = ConfigurationInteractionTerminalResponse(
            requestID: requestID,
            outcome: .succeeded,
            providerResult: .string("delayed-provider-result"),
            error: nil,
            httpStatusCode: 200,
            refreshPerformed: true
        )
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .configuration,
            verifyProvider: { receivedID, succeeded, _, _ in
                XCTAssertEqual(receivedID, requestID)
                XCTAssertFalse(succeeded)
                return ConfigurationInteractionTerminalResponse(
                    requestID: receivedID,
                    outcome: .succeeded,
                    providerResult: nil,
                    error: nil,
                    httpStatusCode: 200,
                    refreshPerformed: false
                )
            }
        ) {
            try await Task.sleep(nanoseconds: 50_000_000)
            return providerTerminal
        }
        let observer = Task {
            try await handle.finalResponse()
        }

        await AppState.verifyScopedConfigurationInteraction(
            handle,
            succeeded: false,
            error: "stale-host-input",
            actualRefreshPerformed: false,
            providerResultGraceNanoseconds: 1_000_000_000
        )
        let observed = try await observer.value
        let repeated = try await handle.finalResponse()

        XCTAssertEqual(observed, providerTerminal)
        XCTAssertEqual(repeated, providerTerminal)
    }

    func testScopedVerificationThrowWinsOverLateProviderSuccessOnce()
        async throws {
        let requestID = UUID()
        let verificationMessage = "scoped verification failed"
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .authorization,
            verifyProvider: { _, _, _, _ in
                throw AppError.spider(verificationMessage)
            }
        ) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return ConfigurationInteractionTerminalResponse(
                requestID: requestID,
                outcome: .succeeded,
                providerResult: .string("late-success-must-not-win"),
                error: nil,
                httpStatusCode: 200,
                refreshPerformed: nil
            )
        }
        let observer = Task {
            try await handle.finalResponse()
        }

        await AppState.verifyScopedConfigurationInteraction(
            handle,
            succeeded: true,
            providerResultGraceNanoseconds: 1_000_000_000
        )

        do {
            _ = try await observer.value
            XCTFail("Verification failure must be the only terminal result")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(verificationMessage)
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        do {
            _ = try await handle.finalResponse()
            XCTFail(
                "Late provider success must not replace verification failure"
            )
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(verificationMessage)
            )
        }
    }

    func testAndroidBridgeTerminalResponseUsesActualScopedOutcomeAndRefresh()
        throws {
        let requestID = UUID()
        let data = Data(
            """
            {
              "ok": true,
              "result": "provider-final-result",
              "interactionID": "\(requestID.uuidString)",
              "interaction": {
                "interactionID": "\(requestID.uuidString)",
                "phase": "completed",
                "outcome": "completed",
                "terminal": true,
                "refreshPerformed": true
              }
            }
            """.utf8
        )
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        let terminal = AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: requestID,
            data: data,
            response: response
        )

        XCTAssertEqual(terminal.requestID, requestID)
        XCTAssertEqual(terminal.outcome, .succeeded)
        XCTAssertEqual(terminal.providerResult, .string("provider-final-result"))
        XCTAssertEqual(terminal.refreshPerformed, true)
    }

    func testAndroidBridgeLegacyTerminalResponseDoesNotInventRefreshState()
        throws {
        let requestID = UUID()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let terminal = AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: requestID,
            data: Data(#"{"ok":true,"result":"legacy-result"}"#.utf8),
            response: response
        )

        XCTAssertEqual(terminal.outcome, .succeeded)
        XCTAssertEqual(terminal.providerResult, .string("legacy-result"))
        XCTAssertNil(terminal.refreshPerformed)
    }

    func testAndroidBridgeAcceptedWorkerResponseIsPendingUntilScopedTerminalState()
        throws {
        let requestID = UUID()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: 202,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let terminal = AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: requestID,
            data: Data(
                """
                {"ok":true,"interactionID":"\(requestID.uuidString)"}
                """.utf8
            ),
            response: response
        )

        XCTAssertEqual(terminal.outcome, .pending)
        XCTAssertNil(terminal.providerResult)
    }

    func testAndroidBridgeStrictTerminalResponseRejectsMissingInteractionID()
        throws {
        let requestID = UUID()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let terminal = AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: requestID,
            data: Data(#"{"ok":true,"result":"unscoped"}"#.utf8),
            response: response,
            requiresScopedIdentity: true
        )

        XCTAssertEqual(terminal.outcome, .failed)
        XCTAssertNil(terminal.providerResult)
    }

    func testAndroidBridgeStrictEmptyActionAcknowledgementRemainsPending()
        throws {
        let requestID = UUID()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let terminal = AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: requestID,
            data: Data(
                """
                {"ok":true,"result":null,"interactionID":"\(requestID.uuidString)"}
                """.utf8
            ),
            response: response,
            requiresScopedIdentity: true
        )

        XCTAssertEqual(terminal.outcome, .pending)
        XCTAssertNil(terminal.providerResult)
    }

    func testAndroidBridgeExplicitImmediateResultMayCompleteWithoutUI()
        throws {
        let requestID = UUID()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let terminal = AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: requestID,
            data: Data(
                """
                {"ok":true,"result":"done","interactionID":"\(requestID.uuidString)"}
                """.utf8
            ),
            response: response,
            requiresScopedIdentity: true,
            allowsImmediateAuthoritativeResult: true
        )

        XCTAssertEqual(terminal.outcome, .succeeded)
        XCTAssertEqual(terminal.providerResult, .string("done"))
    }

    func testAndroidBridgeRejectsTerminalResponseFromDifferentInteraction()
        throws {
        let requestID = UUID()
        let otherID = UUID()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:19978/v1/invoke")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let terminal = AndroidDexBridgeClient.decodeTerminalResponse(
            requestID: requestID,
            data: Data(
                """
                {"ok":true,"result":"must-not-leak","interactionID":"\(otherID.uuidString)","interaction":{"interactionID":"\(otherID.uuidString)","phase":"completed","outcome":"completed","terminal":true}}
                """.utf8
            ),
            response: response
        )

        XCTAssertEqual(terminal.outcome, .failed)
        XCTAssertNil(terminal.providerResult)
        XCTAssertTrue(terminal.error?.contains("其他配置操作") == true)
    }

    func testAndroidPlaybackContractMergesHeadersWithPlayerResultPrecedence() {
        let result = AndroidDexSpiderSiteProvider.applyingPlaybackRequestContract(
            to: SitePlaybackResult(
                url: "https://media.example.invalid/video",
                needsParsing: false,
                flag: "百度",
                headers: [
                    "Referer": "https://player.example.invalid/",
                    "Authorization": "Bearer short-lived"
                ]
            ),
            siteHeaders: [
                "Referer": "https://site.example.invalid/",
                "User-Agent": "Fixture Agent"
            ]
        )

        XCTAssertEqual(
            result.headers["Referer"],
            "https://player.example.invalid/"
        )
        XCTAssertEqual(result.headers["User-Agent"], "Fixture Agent")
        XCTAssertEqual(
            result.headers["Authorization"],
            "Bearer short-lived"
        )
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
    }

    func testAndroidBridgeSendsSiteHeadersOnlyForPlaybackRequests() {
        let headers = [
            "Cookie": "request-scoped-secret",
            "User-Agent": "Fixture Agent"
        ]

        XCTAssertEqual(
            AndroidDexBridgeClient.requestScopedPlaybackHeaders(
                method: "play",
                siteHeaders: headers
            ),
            headers
        )
        XCTAssertNil(
            AndroidDexBridgeClient.requestScopedPlaybackHeaders(
                method: "detail",
                siteHeaders: headers
            )
        )
        XCTAssertNil(
            AndroidDexBridgeClient.requestScopedPlaybackHeaders(
                method: "play",
                siteHeaders: [:]
            )
        )
    }

    func testAndroidBridgeMediaSessionUsesScopedLoopbackAndLegacyCapability() {
        let client = AndroidDexBridgeClient()
        let scoped = client.hostReachableMediaURL(
            "http://127.0.0.1:9978/proxy/media/session-123"
        )
        let legacy = client.hostReachableMediaURL(
            "https://media.example.invalid/movie.mp4?signature=fixture"
        )
        let legacyComponents = URLComponents(string: legacy)

        XCTAssertEqual(
            scoped,
            "http://127.0.0.1:19978/proxy/media/session-123"
        )
        XCTAssertEqual(
            AndroidDexBridgeClient.providerMediaSessionID(from: scoped),
            "session-123"
        )
        XCTAssertTrue(AndroidDexBridgeClient.isLoopbackMediaURL(scoped))
        XCTAssertEqual(legacyComponents?.host, "127.0.0.1")
        XCTAssertEqual(legacyComponents?.port, 19_978)
        XCTAssertEqual(legacyComponents?.path, "/v1/media")
        XCTAssertEqual(
            legacyComponents?.queryItems?.first(where: { $0.name == "url" })?
                .value,
            "https://media.example.invalid/movie.mp4?signature=fixture"
        )
    }

    func testAndroidPlaybackHandoffRequiresMatchingOpaqueSessionMetadata() {
        let fingerprint = String(repeating: "a", count: 64)
        let handoff = AndroidDexSpiderSiteProvider.playbackHandoff(
            from: .object([
                "url": .string(
                    "http://127.0.0.1:9978/proxy/media/session-123"
                ),
                "mediaSessionID": .string("session-123"),
                "upstreamFingerprint": .string(fingerprint),
                "refreshPerformed": .bool(true),
                // This signed URL-shaped field is deliberately ignored by
                // playbackHandoff and never copied into the media session.
                "upstreamURL": .string(
                    "https://secret.invalid/media?token=must-not-leak"
                )
            ])
        )

        XCTAssertEqual(handoff?.mediaSessionID, "session-123")
        XCTAssertEqual(handoff?.upstreamFingerprint, fingerprint)
        XCTAssertEqual(handoff?.refreshPerformed, true)
        XCTAssertNil(
            AndroidDexSpiderSiteProvider.validatedUpstreamFingerprint(
                String(repeating: "A", count: 64)
            )
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.playbackSessionTransport(
                mediaURL:
                    "http://127.0.0.1:19978/proxy/media/session-123",
                providerSessionID: handoff?.mediaSessionID
            ),
            .providerLoopback
        )
        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.playbackSessionTransport(
                mediaURL: "http://127.0.0.1:19978/v1/media?url=legacy",
                providerSessionID: nil
            ),
            .compatibilityLoopback
        )
    }

    func testAndroidPlaybackReferenceIsStableAndProviderOpaque() {
        let site = SiteConfiguration(
            key: "opaque-site-key",
            name: "Renamed Site",
            type: 3,
            api: "csp_Provider"
        )
        let configurationIdentity = UUID().uuidString.lowercased()
        let episodeReference = "provider://opaque/item/42?generation=7"
        let first = AndroidDexSpiderSiteProvider.playbackResourceReference(
            site: site,
            configurationIdentity: configurationIdentity,
            flag: "opaque-line-a",
            episodeURL: episodeReference
        )
        let repeated = AndroidDexSpiderSiteProvider.playbackResourceReference(
            site: site,
            configurationIdentity: configurationIdentity,
            flag: "opaque-line-a",
            episodeURL: episodeReference
        )
        let otherLine = AndroidDexSpiderSiteProvider.playbackResourceReference(
            site: site,
            configurationIdentity: configurationIdentity,
            flag: "opaque-line-b",
            episodeURL: episodeReference
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first.sourceIdentity, otherLine.sourceIdentity)
        XCTAssertEqual(first.configurationIdentity, configurationIdentity)
        XCTAssertEqual(first.siteIdentity, site.key)
        XCTAssertEqual(first.stableResourceLocator, episodeReference)
        XCTAssertEqual(first.stability, .providerReplay)
    }

    func testAndroidPlaybackReferenceIsBoundToCurrentProviderAndConfiguration()
        throws {
        let configurationID = UUID()
        let site = SiteConfiguration(
            key: "site-a",
            name: "Site A",
            type: 3,
            api: "csp_Provider"
        )
        let provider = try AndroidDexSpiderSiteProvider(
            site: site,
            configurationID: configurationID,
            jarReference: "https://configuration.invalid/provider.jar",
            baseURL: nil,
            bridge: AndroidDexBridgeClient()
        )
        let valid = AndroidDexSpiderSiteProvider.playbackResourceReference(
            site: site,
            configurationIdentity: configurationID.uuidString.lowercased(),
            flag: "line-a",
            episodeURL: "provider://opaque/item/42"
        )

        XCTAssertTrue(provider.acceptsPlaybackResourceReference(valid))

        var wrongConfiguration = valid
        wrongConfiguration.configurationIdentity = UUID()
            .uuidString.lowercased()
        XCTAssertFalse(
            provider.acceptsPlaybackResourceReference(wrongConfiguration)
        )

        var wrongSite = valid
        wrongSite.siteIdentity = "site-b"
        XCTAssertFalse(provider.acceptsPlaybackResourceReference(wrongSite))

        var wrongProvider = valid
        wrongProvider.providerKind = "node-http"
        XCTAssertFalse(
            provider.acceptsPlaybackResourceReference(wrongProvider)
        )

        var wrongVersion = valid
        wrongVersion.providerVersion += 1
        XCTAssertFalse(
            provider.acceptsPlaybackResourceReference(wrongVersion)
        )

        var expired = valid
        expired.expiresAt = Date(timeIntervalSinceNow: -1)
        XCTAssertFalse(provider.acceptsPlaybackResourceReference(expired))
    }

    func testAndroidTerminalProviderResultPreservesItsMediaSession()
        throws {
        let configurationID = UUID()
        let site = SiteConfiguration(
            key: "site-a",
            name: "Site A",
            type: 3,
            api: "csp_Provider"
        )
        let provider = try AndroidDexSpiderSiteProvider(
            site: site,
            configurationID: configurationID,
            jarReference: "https://configuration.invalid/provider.jar",
            baseURL: nil,
            bridge: AndroidDexBridgeClient()
        )
        let fingerprint = String(repeating: "a", count: 64)
        let terminalResult: JSONValue = .object([
            "parse": .integer(0),
            "url": .string(
                "http://127.0.0.1:9978/proxy/media/session-123"
            ),
            "mediaSessionID": .string("session-123"),
            "upstreamFingerprint": .string(fingerprint),
            "refreshPerformed": .bool(true)
        ])

        let result = try provider.playbackResult(
            from: terminalResult,
            flag: "line-a",
            episodeURL: "provider://opaque/item/42"
        )

        XCTAssertEqual(
            result.url,
            "http://127.0.0.1:19978/proxy/media/session-123"
        )
        XCTAssertEqual(result.mediaSession?.sessionID, "session-123")
        XCTAssertEqual(
            result.mediaSession?.upstreamResourceFingerprint,
            fingerprint
        )
        XCTAssertEqual(result.mediaSession?.refreshPerformed, true)
        XCTAssertEqual(
            result.resourceReference?.configurationIdentity,
            configurationID.uuidString.lowercased()
        )
    }

    @MainActor
    func testAuthoritativePlaybackFailureRequiresStructuredAuthorizationEvidence() {
        let initialFailure = AppState.playbackFailureMessage(
            "播放错误：loading failed",
            validationPolicy: .playerAuthoritative,
            refreshPerformed: false
        )
        XCTAssertEqual(initialFailure, "播放错误：loading failed")
        XCTAssertEqual(
            AppState.playbackFailureMessage(
                "播放错误：http status 403",
                validationPolicy: .playerAuthoritative,
                refreshPerformed: true
            ),
            "播放错误：http status 403"
        )
        let authorizationFailure = AppState.playbackFailureMessage(
            "播放错误：上游拒绝请求",
            validationPolicy: .playerAuthoritative,
            refreshPerformed: true,
            upstreamHTTPStatusCode: 403
        )
        XCTAssertTrue(authorizationFailure.contains("重新授权"))
        XCTAssertTrue(authorizationFailure.contains("已完成一次同资源刷新"))
        XCTAssertEqual(
            AppState.playbackFailureMessage(
                "普通地址不可达",
                validationPolicy: .preflight
            ),
            "普通地址不可达"
        )
    }

    @MainActor
    func testPlaybackRequestSignatureUsesStableUpstreamIdentity() {
        let reference = PlaybackResourceReference(
            configurationIdentity: "configuration-a",
            siteIdentity: "site-a",
            providerKind: "android-dex",
            providerVersion: 1,
            stableResourceLocator: "provider://opaque/item/42",
            sourceIdentity: "source-a",
            episodeIdentity: "episode-a",
            stability: .providerStable
        )
        func result(
            sessionID: String,
            fingerprint: String,
            refreshPerformed: Bool? = nil
        ) -> SitePlaybackResult {
            let url = "http://127.0.0.1:9978/provider-media/\(sessionID)"
            return SitePlaybackResult(
                url: url,
                needsParsing: false,
                flag: "line",
                headers: ["X-Provider-Media-Session": sessionID],
                validationPolicy: .playerAuthoritative,
                resourceReference: reference,
                mediaSession: PlaybackMediaSession(
                    sessionID: sessionID,
                    transport: .providerLoopback,
                    mediaURL: url,
                    headers: ["X-Provider-Media-Session": sessionID],
                    upstreamResourceFingerprint: fingerprint,
                    refreshPerformed: refreshPerformed,
                    resourceReference: reference
                )
            )
        }

        let first = result(sessionID: "random-session-a", fingerprint: "upstream-a")
        let repeated = result(sessionID: "random-session-b", fingerprint: "upstream-a")
        let refreshed = result(sessionID: "random-session-c", fingerprint: "upstream-b")
        let explicitlyRefreshed = result(
            sessionID: "random-session-d",
            fingerprint: "upstream-a",
            refreshPerformed: true
        )

        XCTAssertEqual(
            AppState.playbackRequestSignature(for: first),
            AppState.playbackRequestSignature(for: repeated)
        )
        XCTAssertNotEqual(
            AppState.playbackRequestSignature(for: first),
            AppState.playbackRequestSignature(for: refreshed)
        )
        XCTAssertNotEqual(
            AppState.playbackRequestSignature(for: first),
            AppState.playbackRequestSignature(for: explicitlyRefreshed)
        )
        XCTAssertFalse(
            AppState.playbackRequestSignature(for: first)
                .contains(reference.stableResourceLocator)
        )
        XCTAssertFalse(
            AppState.playbackRequestSignature(for: first)
                .contains("upstream-a")
        )
    }

    @MainActor
    func testLegacyPlaybackDedupeSignatureDoesNotRetainSecrets() {
        let result = SitePlaybackResult(
            url: "https://media.invalid/movie?token=must-not-remain",
            needsParsing: false,
            flag: "line",
            headers: [
                "Authorization": "Bearer must-not-remain",
                "Cookie": "session=must-not-remain"
            ]
        )

        let signature = AppState.playbackRequestSignature(for: result)

        XCTAssertTrue(signature.hasPrefix("legacy-v1:"))
        XCTAssertFalse(signature.contains("must-not-remain"))
        XCTAssertEqual(signature.count, "legacy-v1:".count + 64)
    }

    func testPlaybackFallbackPreservesProviderOrderWithoutDisplayNameRules() {
        let smart = PlaySource(
            name: "阿狸智2",
            episodes: [PlayEpisode(name: "01", url: "smart")]
        )
        let unrelated = PlaySource(
            name: "备用线",
            episodes: [PlayEpisode(name: "01", url: "other")]
        )
        let original = PlaySource(
            name: "阿狸原2",
            episodes: [PlayEpisode(name: "01", url: "original")]
        )

        XCTAssertEqual(
            AppState.orderedPlaybackSources(
                [smart, unrelated, original],
                selectedSourceID: original.id
            ).map(\.name),
            ["阿狸原2", "阿狸智2", "备用线"]
        )

        let renamedOriginal = PlaySource(
            name: "Completely Renamed",
            episodes: [PlayEpisode(name: "01", url: "renamed")]
        )
        XCTAssertEqual(
            AppState.orderedPlaybackSources(
                [unrelated, renamedOriginal, smart],
                selectedSourceID: renamedOriginal.id
            ).map(\.name),
            ["Completely Renamed", "阿狸智2", "备用线"]
        )
    }

    func testAndroidBridgeNetworkUsesUsableDefaultRouteAsReadinessBoundary() {
        XCTAssertTrue(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is connected to \"AndroidWifi\"",
                routes: "default via 10.0.2.2 dev wlan0"
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is enabled\nWifi is disconnected",
                routes: "default via 10.0.2.2 dev wlan0"
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is disabled",
                routes: "default via 192.0.2.1 dev eth0"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is connected to \"AndroidWifi\"",
                routes: "10.0.2.0/24 dev wlan0"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is enabled",
                routes: "default dev dummy0 scope link"
            )
        )
    }

    func testAndroidBridgeNetworkEvidenceHelpers() {
        let routes = """
        default via 10.0.2.2 dev wlan0 proto dhcp
        10.0.2.0/24 dev wlan0 scope link
        """
        XCTAssertEqual(
            AndroidDexBridgeRuntime.defaultGateway(from: routes),
            "10.0.2.2"
        )
        XCTAssertTrue(AndroidDexBridgeRuntime.hasUsableDefaultRoute(routes))
        XCTAssertTrue(AndroidDexBridgeRuntime.containsSecurityException(
            "java.lang.SecurityException: Uid 2000 does not have access"
        ))
    }

    func testAndroidRuntimeStagePreservesExactSixtyEightPercentBoundary() {
        XCTAssertEqual(
            AndroidRuntimeStartupStage.stage(for: 0.68),
            .checkingEmulatorNetwork
        )
        XCTAssertEqual(
            AndroidRuntimeStatus.starting(progress: 0.68).stage,
            .checkingEmulatorNetwork
        )
    }

    func testAndroidDiagnosticsSanitizeUnrelatedADBDevicesAndForwards() {
        let devices = """
        List of devices attached
        emulator-5554 device product:sdk model:owned
        R58M123 unauthorized usb:1-2 product:private model:phone
        emulator-5556 offline transport_id:9
        """
        XCTAssertEqual(
            AndroidDexBridgeRuntime.sanitizedADBDevices(
                devices,
                ownedSerial: "emulator-5554"
            ),
            [
                "emulator-5554 state=device owned=true",
                "<unrelated-device> state=unauthorized owned=false",
                "<unrelated-device> state=offline owned=false"
            ]
        )
        let forwards = """
        emulator-5554 tcp:19978 tcp:9978
        R58M123 tcp:42000 tcp:42000
        """
        XCTAssertEqual(
            AndroidDexBridgeRuntime.sanitizedADBForwards(
                forwards,
                ownedSerial: "emulator-5554"
            ),
            ["emulator-5554 tcp:19978 tcp:9978"]
        )
    }

    func testAndroidRuntimeErrorPresentationIsNotGenericSpiderFailure() throws {
        let error = AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: .checkingEmulatorNetwork,
                category: .emulatorNetworkUnavailable,
                message: "technical detail"
            )
        )
        let presentation = try XCTUnwrap(
            AndroidRuntimeUserFacingErrorMapper.presentation(for: error)
        )
        XCTAssertEqual(presentation.title, "Android 兼容环境启动失败")
        XCTAssertTrue(presentation.message.contains("Emulator"))
        XCTAssertFalse(presentation.message.contains("technical detail"))
    }

    func testAndroidBridgeTimeoutDoesNotClaimCleanedEmulatorIsRunning()
        throws {
        let error = AndroidRuntimeFailureError(
            record: AndroidRuntimeFailureRecord(
                occurredAt: Date(),
                stage: .probingBridge,
                category: .bridgeHealthTimedOut,
                message: "bridge probe exhausted"
            )
        )
        let presentation = try XCTUnwrap(
            AndroidRuntimeUserFacingErrorMapper.presentation(for: error)
        )

        XCTAssertTrue(presentation.message.contains("本次启动已失败"))
        XCTAssertFalse(presentation.message.contains("Emulator 已启动"))
    }

    func testAndroidManagedRuntimeLifecycleClassifiesExitBeforeOwnership() {
        XCTAssertEqual(
            AndroidDexBridgeRuntime.managedRuntimeFailureCategory(
                processPresent: false,
                processOwned: false,
                deviceRequired: true,
                deviceReachable: false,
                deviceOwned: false
            ),
            .runtimeExited
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.managedRuntimeFailureCategory(
                processPresent: true,
                processOwned: false,
                deviceRequired: true,
                deviceReachable: true,
                deviceOwned: true
            ),
            .emulatorOwnershipMismatch
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.managedRuntimeFailureCategory(
                processPresent: true,
                processOwned: true,
                deviceRequired: true,
                deviceReachable: false,
                deviceOwned: false
            ),
            .adbUnavailable
        )
        XCTAssertNil(
            AndroidDexBridgeRuntime.managedRuntimeFailureCategory(
                processPresent: true,
                processOwned: true,
                deviceRequired: false,
                deviceReachable: false,
                deviceOwned: false
            )
        )
    }

    func testAndroidFailedRuntimeRecordClearsOnlyAfterProcessAndDeviceExit() {
        XCTAssertTrue(
            AndroidDexBridgeRuntime.failedRuntimeRecordCanBeCleared(
                processPresent: false,
                deviceReachable: false
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.failedRuntimeRecordCanBeCleared(
                processPresent: true,
                deviceReachable: false
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.failedRuntimeRecordCanBeCleared(
                processPresent: false,
                deviceReachable: true
            )
        )
    }

    func testAndroidLastFailureRemainsVisibleAfterOperationStops() throws {
        let failure = AndroidRuntimeFailureRecord(
            occurredAt: Date(),
            stage: .checkingEmulatorNetwork,
            category: .emulatorNetworkUnavailable,
            message: "network evidence"
        )

        let status = try XCTUnwrap(
            AndroidRuntimeFailureStatePolicy.status(
                operationStatus: nil,
                lastFailure: failure
            )
        )
        XCTAssertEqual(status.phase, .failed)
        XCTAssertEqual(status.stage, .checkingEmulatorNetwork)
        XCTAssertTrue(status.detail.contains("network evidence"))
    }

    func testAndroidRecoveryIsBoundedAndSkipsKnownFailedCommand() {
        XCTAssertEqual(
            AndroidRuntimeRecoveryPolicy.networkObservationTimeout,
            30
        )
        XCTAssertEqual(
            AndroidRuntimeRecoveryPolicy.initialBridgeProbeAttempts,
            30
        )
        XCTAssertEqual(
            AndroidRuntimeRecoveryPolicy.recoveredBridgeProbeAttempts,
            20
        )
        XCTAssertGreaterThan(
            AndroidRuntimeRecoveryPolicy.bridgeProbePollNanoseconds,
            0
        )
        XCTAssertFalse(
            AndroidRuntimeRecoveryPolicy.shouldRetryKnownFailedNetworkCommand(
                lastFailureStage: .checkingEmulatorNetwork,
                networkRecoveryResult: "command_failed"
            )
        )
        XCTAssertTrue(
            AndroidRuntimeRecoveryPolicy.shouldRetryKnownFailedNetworkCommand(
                lastFailureStage: .checkingEmulatorNetwork,
                networkRecoveryResult: "timed_out"
            )
        )
    }

    func testAndroidToolchainResolverPrefersUserSelectionOverEnvironment()
        throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AndroidResolver-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected SDK")
        let environmentSDK = root.appendingPathComponent("Environment SDK")
        try makeFakeAndroidSDK(at: selected)
        try makeFakeAndroidSDK(at: environmentSDK)

        let resolver = AndroidToolchainResolver(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            homeDirectory: root.appendingPathComponent("Home"),
            environment: ["ANDROID_HOME": environmentSDK.path],
            userSelectedSDKRoot: selected.path,
            fileManager: .default
        )

        XCTAssertEqual(
            resolver.resolve()?.sdkRoot,
            selected.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testAndroidToolchainResolverPrefersManagedSDKThenAndroidHome()
        throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AndroidResolver-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        let managed = support.appendingPathComponent("AndroidRuntime/sdk")
        let selected = root.appendingPathComponent("Selected")
        let androidHome = root.appendingPathComponent("AndroidHome")
        let deprecated = root.appendingPathComponent("Deprecated")
        try makeFakeAndroidSDK(at: managed)
        try makeFakeAndroidSDK(at: selected)
        try makeFakeAndroidSDK(at: androidHome)
        try makeFakeAndroidSDK(at: deprecated)

        var resolver = AndroidToolchainResolver(
            applicationSupportDirectory: support,
            homeDirectory: root.appendingPathComponent("Home"),
            environment: [
                "ANDROID_HOME": androidHome.path,
                "ANDROID_SDK_ROOT": deprecated.path
            ],
            userSelectedSDKRoot: selected.path,
            fileManager: .default
        )
        XCTAssertEqual(
            resolver.resolve()?.sdkRoot,
            managed.standardizedFileURL.resolvingSymlinksInPath()
        )

        try FileManager.default.removeItem(at: managed)
        resolver = AndroidToolchainResolver(
            applicationSupportDirectory: support,
            homeDirectory: root.appendingPathComponent("Home"),
            environment: [
                "ANDROID_HOME": androidHome.path,
                "ANDROID_SDK_ROOT": deprecated.path
            ],
            userSelectedSDKRoot: nil,
            fileManager: .default
        )
        XCTAssertEqual(
            resolver.resolve()?.sdkRoot,
            androidHome.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testAndroidToolchainResolverFindsOnlyInstalledArm64Images() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AndroidImages-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFakeAndroidSDK(at: root)
        let valid = root.appendingPathComponent(
            "system-images/android-35/google_apis/arm64-v8a"
        )
        let invalid = root.appendingPathComponent(
            "system-images/android-36/google_apis/x86_64"
        )
        try FileManager.default.createDirectory(
            at: valid,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: invalid,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: valid.appendingPathComponent("package.xml").path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: invalid.appendingPathComponent("package.xml").path,
                contents: Data()
            )
        )
        let resolver = AndroidToolchainResolver(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            homeDirectory: root.appendingPathComponent("Home"),
            environment: [:],
            userSelectedSDKRoot: nil,
            fileManager: .default
        )
        let toolchain = try XCTUnwrap(resolver.toolchain(at: root))

        XCTAssertEqual(
            resolver.installedSystemImages(in: toolchain).map(\.packageID),
            ["system-images;android-35;google_apis;arm64-v8a"]
        )
    }

    func testAndroidRuntimeIdentityPoliciesRejectAmbiguousOwnership() {
        XCTAssertTrue(
            AndroidDexBridgeRuntime.ownershipAllowsMutation(
                processOwned: true,
                deviceOwned: true
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.ownershipAllowsMutation(
                processOwned: false,
                deviceOwned: true
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.ownershipAllowsMutation(
                processOwned: true,
                deviceOwned: false
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.candidateConsolePorts.allSatisfy {
                $0 >= 5_554 && $0 <= 5_682 && $0.isMultiple(of: 2)
            }
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.commandMatches(
                "/sdk/emulator -avd OKVideoMac_Runtime -port 5560",
                avdName: "OKVideoMac_Runtime",
                consolePort: 5_560
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.commandMatches(
                "/sdk/emulator -avd Pixel_8 -port 5560",
                avdName: "OKVideoMac_Runtime",
                consolePort: 5_560
            )
        )
    }

    func testAndroidBridgeHealthRequiresCurrentGeneration() {
        let current: [String: Any] = [
            "ok": true,
            "version": AndroidDexBridgeRuntime.bridgeVersion,
            "generation": "current-generation"
        ]
        XCTAssertTrue(
            AndroidDexBridgeRuntime.healthMatches(
                current,
                generation: "current-generation"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.healthMatches(
                current,
                generation: "stale-generation"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.healthMatches(
                [
                    "ok": true,
                    "version": AndroidDexBridgeRuntime.bridgeVersion
                ],
                generation: "current-generation"
            )
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.healthValidation(
                current,
                generation: "stale-generation"
            ),
            .generationMismatch
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.healthValidation(
                [
                    "ok": true,
                    "version": "0.0.0",
                    "generation": "current-generation"
                ],
                generation: "current-generation"
            ),
            .versionMismatch
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.bridgeFailureCategory(
                for: AndroidBridgeHealthValidation.versionMismatch.rawValue
            ),
            .bridgeVersionMismatch
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.terminalBridgeProbeMessage(
                for: AndroidBridgeHealthValidation.versionMismatch.rawValue
            ).contains("版本不匹配")
        )
    }

    func testAndroidBridgeContractMatchesBundledAPKGradleAndHealth() throws {
        let apk = try XCTUnwrap(
            Bundle.main.url(
                forResource: "AndroidDexBridge-release",
                withExtension: "apk"
            ),
            "测试宿主必须包含实际交付的 Android Bridge APK"
        )
        let badging = try androidAAPTBadging(for: apk)
        let packageLine = try XCTUnwrap(
            badging.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.hasPrefix("package:") })
        )
        let packageName = androidBadgingAttribute("name", in: packageLine)
        let versionName = androidBadgingAttribute(
            "versionName",
            in: packageLine
        )
        let versionCode = androidBadgingAttribute(
            "versionCode",
            in: packageLine
        ).flatMap(Int.init)

        XCTAssertEqual(packageName, "com.okvideomac.dexbridge")
        XCTAssertEqual(versionName, AndroidDexBridgeRuntime.bridgeVersion)
        XCTAssertEqual(versionCode, AndroidDexBridgeRuntime.bridgeVersionCode)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gradle = try String(
            contentsOf: repository.appendingPathComponent(
                "Helpers/AndroidDexBridge/app/build.gradle"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(gradle.contains(
            "versionCode = \(AndroidDexBridgeRuntime.bridgeVersionCode)"
        ))
        XCTAssertTrue(gradle.contains(
            "versionName = \"\(AndroidDexBridgeRuntime.bridgeVersion)\""
        ))

        let bridgeServer = try String(
            contentsOf: repository.appendingPathComponent(
                "Helpers/AndroidDexBridge/app/src/main/java/"
                    + "com/okvideomac/dexbridge/BridgeServer.java"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(bridgeServer.contains(
            ".getPackageInfo(context.getPackageName(), 0)"
        ))
        XCTAssertTrue(bridgeServer.contains(".versionName"))
        XCTAssertEqual(
            AndroidDexBridgeRuntime.healthValidation(
                [
                    "ok": true,
                    "version": try XCTUnwrap(versionName),
                    "generation": "packaged-generation"
                ],
                generation: "packaged-generation"
            ),
            .healthy
        )
    }

    private func androidAAPTBadging(for apk: URL) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let roots = [
            environment["ANDROID_SDK_ROOT"],
            environment["ANDROID_HOME"],
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Android/sdk").path,
            "/Volumes/XcodeDev/AndroidSDK"
        ].compactMap { $0 }
        let aapt = roots.lazy.compactMap { root -> URL? in
            let buildTools = URL(fileURLWithPath: root)
                .appendingPathComponent("build-tools")
            let versions = (try? FileManager.default.contentsOfDirectory(
                at: buildTools,
                includingPropertiesForKeys: nil
            ))?.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
            return versions
                .map { $0.appendingPathComponent("aapt") }
                .first(where: {
                    FileManager.default.isExecutableFile(atPath: $0.path)
                })
        }.first
        let executable = try XCTUnwrap(
            aapt,
            "验证实际 APK 版本需要 Android SDK build-tools/aapt"
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["dump", "badging", apk.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }

    private func androidBadgingAttribute(
        _ name: String,
        in packageLine: String
    ) -> String? {
        guard let start = packageLine.range(of: "\(name)='") else {
            return nil
        }
        let suffix = packageLine[start.upperBound...]
        guard let end = suffix.firstIndex(of: "'") else { return nil }
        return String(suffix[..<end])
    }

    func testAndroidBridgeForwardInspectionIsScopedToVerifiedSerial() {
        let listing = """
        emulator-5554 tcp:19978 tcp:9978
        emulator-5560 tcp:19978 tcp:8096
        """
        XCTAssertTrue(
            AndroidDexBridgeRuntime.portForwardExists(
                listing: listing,
                device: "emulator-5554",
                host: 19_978,
                guest: 9_978
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.portForwardExists(
                listing: listing,
                device: "emulator-5560",
                host: 19_978,
                guest: 9_978
            )
        )
    }

    private func makeFakeAndroidSDK(at root: URL) throws {
        let adb = root.appendingPathComponent("platform-tools/adb")
        let emulator = root.appendingPathComponent("emulator/emulator")
        for executable in [adb, emulator] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data("#!/bin/sh\nexit 0\n".utf8)
                )
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }
    }

    func testAndroidBridgeRewritesCloudOriginalProxyAndEncodesItsPath() {
        let client = AndroidDexBridgeClient()
        let rewritten = client.hostReachableProxyURL(
            "http://127.0.0.1:6677/proxy/play/夸父盘/九门/10.mkv"
        )

        XCTAssertEqual(
            rewritten,
            "http://127.0.0.1:16677/proxy/play/"
                + "%E5%A4%B8%E7%88%B6%E7%9B%98/"
                + "%E4%B9%9D%E9%97%A8/10.mkv"
        )
        XCTAssertNotNil(URL(string: rewritten))
    }

    func testAndroidBridgeRewritesWexKaiserProxy() {
        let client = AndroidDexBridgeClient()
        let rewritten = client.hostReachableProxyURL(
            "http://127.0.0.1:8096/kaiser?url=https%3A%2F%2Fexample.invalid%2Fmovie.mp4"
        )

        XCTAssertEqual(
            rewritten,
            "http://127.0.0.1:19978/v1/media?url="
                + "https%3A%2F%2Fexample.invalid%2Fmovie.mp4"
        )
    }

    func testAndroidBridgePreservesNestedKaiserQueryParameters() {
        let client = AndroidDexBridgeClient()
        let rewritten = client.hostReachableProxyURL(
            "http://127.0.0.1:18096/kaiser?url="
                + "https://media.example.invalid/movie.mp4?thread=1"
                + "&chunk=2&key=a%2Bb&type=3"
        )

        let components = URLComponents(string: rewritten)
        XCTAssertEqual(components?.port, 19_978)
        XCTAssertEqual(components?.path, "/v1/media")
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "url" })?.value,
            "https://media.example.invalid/movie.mp4?thread=1"
                + "&chunk=2&key=a%2Bb&type=3"
        )
    }

    func testAndroidBridgeKeepsKaiserFallbackWithoutRemoteURL() {
        let client = AndroidDexBridgeClient()
        let rewritten = client.hostReachableProxyURL(
            "http://127.0.0.1:8096/kaiser?provider=quark"
        )

        XCTAssertEqual(
            rewritten,
            "http://127.0.0.1:18096/kaiser?provider=quark"
        )
    }

    func testAndroidBridgeRecognizesExistingPortForward() {
        let listing = """
        emulator-5554 tcp:19978 tcp:9978
        emulator-5554 tcp:18096 tcp:8096
        """

        XCTAssertTrue(
            AndroidDexBridgeRuntime.portForwardExists(
                listing: listing,
                device: "emulator-5554",
                host: 18_096,
                guest: 8_096
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.portForwardExists(
                listing: listing,
                device: "emulator-5554",
                host: 16_677,
                guest: 6_677
            )
        )
    }

    func testAndroidBridgeReadsInstalledVersionCode() {
        XCTAssertEqual(
            AndroidDexBridgeRuntime.installedVersionCode(
                from: "versionCode=23 minSdk=24 targetSdk=27"
            ),
            23
        )
        XCTAssertNil(
            AndroidDexBridgeRuntime.installedVersionCode(
                from: "package not installed"
            )
        )
    }

    func testAndroidBridgeDoesNotRewriteUnrecognizedLoopbackService() {
        let client = AndroidDexBridgeClient()
        let raw = "http://127.0.0.1:10001/internal/status"

        XCTAssertEqual(client.hostReachableProxyURL(raw), raw)
    }

    func testAndroidDexEmptyHomeRequiresSpiderReset() {
        XCTAssertTrue(
            AndroidDexSpiderSiteProvider.shouldResetSpider(
                homeValue: .string(" \n"),
                homeVideoValue: .null
            )
        )
        XCTAssertFalse(
            AndroidDexSpiderSiteProvider.shouldResetSpider(
                homeValue: .object([:]),
                homeVideoValue: nil
            )
        )
        XCTAssertFalse(
            AndroidDexSpiderSiteProvider.shouldResetSpider(
                homeValue: .string(""),
                homeVideoValue: .object(["list": .array([])])
            )
        )
    }

    func testAndroidDexEmptyFirstSearchRequiresSpiderReset() {
        XCTAssertTrue(
            AndroidDexSpiderSiteProvider.shouldRetrySearch(
                page: 1,
                value: .string(" \n")
            )
        )
        XCTAssertFalse(
            AndroidDexSpiderSiteProvider.shouldRetrySearch(
                page: 2,
                value: .string("")
            )
        )
        XCTAssertTrue(
            AndroidDexSpiderSiteProvider.shouldRetrySearch(
                page: 1,
                value: .object(["list": .array([])])
            )
        )
    }

    func testAndroidDexEmptyFirstCategoryRequiresSingleSpiderRecovery() {
        XCTAssertTrue(
            AndroidDexSpiderSiteProvider.shouldRetryCategory(
                page: 1,
                value: .object(["list": .array([])])
            )
        )
        XCTAssertTrue(
            AndroidDexSpiderSiteProvider.shouldRetryCategory(
                page: 1,
                value: .string(" \n")
            )
        )
        XCTAssertFalse(
            AndroidDexSpiderSiteProvider.shouldRetryCategory(
                page: 2,
                value: .object(["list": .array([])])
            )
        )
        XCTAssertFalse(
            AndroidDexSpiderSiteProvider.shouldRetryCategory(
                page: 1,
                value: .object([
                    "list": .array([.object(["vod_id": .string("1")])])
                ])
            )
        )
    }

    func testAndroidDexAuthorizationMonitoringUsesStructuralActionContext() {
        XCTAssertFalse(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "detail"
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "detail",
                explicitAuthorizationAction: true
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "action"
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "play"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "search"
            )
        )
    }

    func testAndroidDexFailedInvocationAllowsLateAuthorizationUIToWin()
        async throws {
        let hidden = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: Data(
                """
                {
                  "visible": false,
                  "title": "",
                  "inputCount": 0,
                  "imageCount": 0,
                  "buttons": []
                }
                """.utf8
            )
        )
        let authorization = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: Data(
                """
                {
                  "visible": true,
                  "title": "请选择网盘",
                  "inputCount": 0,
                  "imageCount": 0,
                  "buttons": ["百度网盘"]
                }
                """.utf8
            )
        )
        var states = [hidden, authorization]

        let resolved = await AndroidDexBridgeClient
            .waitForAuthorizationStateAfterFailure(
                attempts: 2,
                pollIntervalNanoseconds: 0
            ) {
                states.removeFirst()
            }

        XCTAssertEqual(resolved, authorization)
        XCTAssertTrue(states.isEmpty)
    }

    func testAndroidDexRequestKeepsObservingWhenNativeUIArrivesAfterOneSecond()
        async throws {
        let hidden = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: Data(
                """
                {"visible":false,"title":"","inputCount":0,"imageCount":0,"buttons":[],"phase":"processing","outcome":"stay","terminal":false}
                """.utf8
            )
        )
        let authorization = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: Data(
                """
                {"visible":true,"title":"Native UI","inputCount":1,"imageCount":0,"buttons":["Continue"],"phase":"awaitingUser","outcome":"stay","terminal":false}
                """.utf8
            )
        )
        var pollCount = 0
        let startedAt = Date()

        let resolved = await AndroidDexBridgeClient
            .waitForAuthorizationStateAfterFailure(
                attempts: 13,
                pollIntervalNanoseconds: 100_000_000
            ) {
                pollCount += 1
                return pollCount >= 12 ? authorization : hidden
            }

        XCTAssertEqual(resolved, authorization)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 1)
    }

    @MainActor
    func testHistoryConfigurationResolutionSwitchesOnlyToAvailableOwner() {
        let first = UUID()
        let second = UUID()
        let current = HistoryRecord(
            configurationID: first,
            siteKey: "same-key",
            videoID: "1",
            title: "Current"
        )
        let inactive = HistoryRecord(
            configurationID: second,
            siteKey: "same-key",
            videoID: "1",
            title: "Inactive"
        )
        let missing = HistoryRecord(
            configurationID: UUID(),
            siteKey: "same-key",
            videoID: "missing",
            title: "Missing"
        )
        let legacy = HistoryRecord(
            siteKey: "same-key",
            videoID: "legacy",
            title: "Legacy"
        )

        XCTAssertEqual(
            AppState.historyConfigurationResolution(
                record: current,
                activeConfigurationID: first,
                availableConfigurationIDs: [first, second]
            ),
            .current
        )
        XCTAssertEqual(
            AppState.historyConfigurationResolution(
                record: inactive,
                activeConfigurationID: first,
                availableConfigurationIDs: [first, second]
            ),
            .switchTo(second)
        )
        XCTAssertEqual(
            AppState.historyConfigurationResolution(
                record: missing,
                activeConfigurationID: first,
                availableConfigurationIDs: [first, second]
            ),
            .unavailable
        )
        XCTAssertEqual(
            AppState.historyConfigurationResolution(
                record: legacy,
                activeConfigurationID: first,
                availableConfigurationIDs: [first, second]
            ),
            .legacy
        )
    }

    @MainActor
    func testVisibleHistoryIsScopedToActiveConfigurationAndSelectedSite() {
        let first = UUID()
        let second = UUID()
        let firstRecord = HistoryRecord(
            configurationID: first,
            siteKey: "shared-site-key",
            videoID: "first",
            title: "First"
        )
        let secondRecord = HistoryRecord(
            configurationID: second,
            siteKey: "shared-site-key",
            videoID: "second",
            title: "Second"
        )
        let anotherSiteRecord = HistoryRecord(
            configurationID: first,
            siteKey: "another-site-key",
            videoID: "another-site",
            title: "Another Site"
        )
        let legacyRecord = HistoryRecord(
            siteKey: "shared-site-key",
            videoID: "legacy",
            title: "Legacy"
        )

        XCTAssertEqual(
            AppState.historyRecords(
                [
                    secondRecord,
                    legacyRecord,
                    anotherSiteRecord,
                    firstRecord
                ],
                for: first,
                siteKey: "shared-site-key"
            ),
            [firstRecord]
        )
        XCTAssertTrue(
            AppState.historyRecords(
                [firstRecord, secondRecord],
                for: nil,
                siteKey: "shared-site-key"
            ).isEmpty
        )
        XCTAssertTrue(
            AppState.historyRecords(
                [firstRecord, anotherSiteRecord],
                for: first,
                siteKey: nil
            ).isEmpty
        )
    }

    @MainActor
    func testBlankSiteActionResultDoesNotClaimOperationCompleted() {
        let placeholder = JSONValue.object([
            "list": .array([.object([:])]),
            "parse": .integer(0),
            "jx": .integer(0)
        ])

        XCTAssertNil(AppState.siteActionMessage(placeholder))
        XCTAssertNotEqual(
            AppState.unconfirmedSiteActionMessage,
            "操作已完成。"
        )
        XCTAssertNotEqual(
            AppState.unsupportedSiteActionMessage,
            "操作已完成。"
        )
        XCTAssertTrue(
            AppState.unsupportedSiteActionMessage.contains("尚未完成")
        )
    }

    @MainActor
    func testOnlyJavaDexActionsWaitForCloudAuthorization() {
        XCTAssertTrue(
            AppState.shouldWaitForCloudAuthorization(
                capability: .javaDexSpider
            )
        )
        XCTAssertFalse(
            AppState.shouldWaitForCloudAuthorization(
                capability: .javaScriptSpider
            )
        )
        XCTAssertFalse(
            AppState.shouldWaitForCloudAuthorization(
                capability: .standardJSON
            )
        )
    }

    @MainActor
    func testSiteActionPreservesExplicitUpstreamMessage() {
        XCTAssertEqual(
            AppState.siteActionMessage(
                .object(["message": .string("请使用百度网盘扫码登录")])
            ),
            "请使用百度网盘扫码登录"
        )
        XCTAssertEqual(
            AppState.siteActionMessage(.string("Cookie 已清除")),
            "Cookie 已清除"
        )
    }

    @MainActor
    func testAutomaticConfigurationRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(
            AppState.shouldAutomaticallyRefreshConfiguration(
                sourceKind: .remote,
                lastAttemptAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            AppState.shouldAutomaticallyRefreshConfiguration(
                sourceKind: .localFile,
                lastAttemptAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            AppState.shouldAutomaticallyRefreshConfiguration(
                sourceKind: .remote,
                lastAttemptAt: now.addingTimeInterval(-60),
                now: now,
                interval: 300
            )
        )
        XCTAssertTrue(
            AppState.shouldAutomaticallyRefreshConfiguration(
                sourceKind: .remote,
                lastAttemptAt: now.addingTimeInterval(-301),
                now: now,
                interval: 300
            )
        )
    }

    func testPlayerSurfaceOnlyTogglesFullScreenOnLeftDoubleClick() {
        XCTAssertEqual(
            PlayerSurfaceGesture.action(clickCount: 1, buttonNumber: 0),
            .ignore
        )
        XCTAssertTrue(
            PlayerSurfaceGesture.togglesFullScreen(
                clickCount: 2,
                buttonNumber: 0
            )
        )
        XCTAssertFalse(
            PlayerSurfaceGesture.togglesFullScreen(
                clickCount: 1,
                buttonNumber: 0
            )
        )
        XCTAssertFalse(
            PlayerSurfaceGesture.togglesFullScreen(
                clickCount: 2,
                buttonNumber: 1
            )
        )
    }

    func testLiveControlsAutoHideWhenPointerIsParkedOverOverlay() {
        XCTAssertTrue(
            PlayerControlVisibilityPolicy.shouldAutoHide(
                isLivePlayback: true,
                controlsHovering: true,
                isFailed: false,
                isPlaying: true
            )
        )
        XCTAssertFalse(
            PlayerControlVisibilityPolicy.shouldAutoHide(
                isLivePlayback: true,
                controlsHovering: false,
                isFailed: false,
                keepsControlsVisible: true,
                isPlaying: false
            )
        )
        XCTAssertFalse(
            PlayerControlVisibilityPolicy.shouldAutoHide(
                isLivePlayback: false,
                controlsHovering: true,
                isFailed: false,
                isPlaying: true
            )
        )
    }

    func testPlayerSurfaceDoesNotRevealControlsOnSyntheticMouseEntry() {
        XCTAssertTrue(
            PlayerSurfaceTrackingPolicy.options.contains(.mouseMoved)
        )
        XCTAssertFalse(
            PlayerSurfaceTrackingPolicy.options.contains(.mouseEnteredAndExited)
        )
    }

    func testPlayerWindowMutationsAreDeferredDuringLiveResize() {
        XCTAssertFalse(
            PlayerWindowMutationPolicy.canApply(isInLiveResize: true)
        )
        XCTAssertTrue(
            PlayerWindowMutationPolicy.canApply(isInLiveResize: false)
        )
    }

    func testLiveWindowAlwaysUsesSixteenByNineRegardlessOfChannelVideo() {
        let ratio = PlayerWindowAspectPolicy.aspectRatio(
            isLivePlayback: true,
            override: "4:3",
            videoWidth: 720,
            videoHeight: 576
        )

        XCTAssertEqual(ratio ?? 0, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertTrue(
            PlayerViewportPolicy.usesFixedLiveWindow(siteKey: "live")
        )
        XCTAssertFalse(
            PlayerViewportPolicy.usesFixedLiveWindow(siteKey: "vod")
        )
        XCTAssertEqual(
            PlayerViewportPolicy.panscan(siteKey: "live"),
            0,
            accuracy: 0.0001
        )
    }

    func testPlayerDefaultWindowIsLargerAndRemainsSixteenByNine() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = PlayerWindowSizingPolicy.initialContentSize(
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(size.width, 1_180.8, accuracy: 0.001)
        XCTAssertEqual(size.height, 664.2, accuracy: 0.001)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(size.width, visibleFrame.width * 0.82)
        XCTAssertLessThanOrEqual(size.height, visibleFrame.height * 0.86)
    }

    func testLiveImmersiveControlsScaleWithPlayerViewport() {
        let compact = LivePlayerOverlayMetrics(
            viewportSize: CGSize(width: 800, height: 450)
        )
        let standard = LivePlayerOverlayMetrics(
            viewportSize: CGSize(width: 1_280, height: 720)
        )
        let large = LivePlayerOverlayMetrics(
            viewportSize: CGSize(width: 1_920, height: 1_080)
        )

        XCTAssertEqual(compact.scale, 0.80, accuracy: 0.0001)
        XCTAssertEqual(standard.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(large.scale, 1.10, accuracy: 0.0001)
        XCTAssertEqual(compact.controlDiameter, 34, accuracy: 0.001)
        XCTAssertEqual(standard.controlDiameter, 40, accuracy: 0.001)
        XCTAssertEqual(large.controlDiameter, 44, accuracy: 0.001)
        XCTAssertEqual(compact.volumeSliderWidth, 76, accuracy: 0.001)
        XCTAssertEqual(standard.volumeSliderWidth, 92, accuracy: 0.001)
        XCTAssertEqual(large.volumeSliderWidth, 101.2, accuracy: 0.001)
        XCTAssertLessThan(
            compact.outerHorizontalPadding,
            standard.outerHorizontalPadding
        )
        XCTAssertLessThan(
            standard.outerHorizontalPadding,
            large.outerHorizontalPadding
        )
    }

    func testOnDemandWindowUsesOverrideOrDetectedVideoRatio() {
        XCTAssertEqual(
            PlayerWindowAspectPolicy.aspectRatio(
                isLivePlayback: false,
                override: "2.35:1",
                videoWidth: 1_920,
                videoHeight: 1_080
            ) ?? 0,
            2.35,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlayerWindowAspectPolicy.aspectRatio(
                isLivePlayback: false,
                override: nil,
                videoWidth: 1_920,
                videoHeight: 1_080
            ) ?? 0,
            16.0 / 9.0,
            accuracy: 0.0001
        )
        XCTAssertNil(
            PlayerWindowAspectPolicy.aspectRatio(
                isLivePlayback: false,
                override: nil,
                videoWidth: 1_920,
                videoHeight: 0
            )
        )
    }

    func testPlayerWindowAspectSizeKeepsWidthAndHeightInSync() throws {
        let size = try XCTUnwrap(
            PlayerWindowAspectPolicy.contentSize(
                current: NSSize(width: 1_200, height: 800),
                aspectRatio: 16.0 / 9.0,
                minimum: NSSize(width: 900, height: 600),
                maximum: NSSize(width: 1_920, height: 1_080)
            )
        )

        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(size.width, 900)
        XCTAssertGreaterThanOrEqual(size.height, 600)
    }

    @MainActor
    func testPlayerWindowChromeLocksAspectWithoutResizingOnLiveChannelChange() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let toolbar = NSToolbar(identifier: "fixture-toolbar")
        window.toolbar = toolbar
        toolbar.isVisible = true
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        let originalWindowFrame = window.frame
        let originalContentAspectRatio = window.contentAspectRatio

        let coordinator = PlayerWindowConfigurator.Coordinator(onRestore: {})
        coordinator.attach(to: window)
        await drainMainQueue()

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(toolbar.isVisible)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.frame, originalWindowFrame)
        XCTAssertEqual(window.contentAspectRatio, originalContentAspectRatio)

        coordinator.configure(
            isLivePlayback: false,
            controlsVisible: false,
            title: "琅琊榜 · 第 23 集",
            videoAspectRatio: 2.0
        )
        await drainMainQueue()
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden ?? false)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(toolbar.isVisible)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(
            window.contentAspectRatio.width / window.contentAspectRatio.height,
            2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            window.contentRect(forFrameRect: window.frame).width
                / window.contentRect(forFrameRect: window.frame).height,
            2.0,
            accuracy: 0.005
        )

        coordinator.configure(
            isLivePlayback: true,
            controlsVisible: true,
            title: "013 CCTV-3(高清)",
            videoAspectRatio: 16.0 / 9.0
        )
        await drainMainQueue()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(toolbar.isVisible)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.title, "013 CCTV-3(高清)")
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true)
        XCTAssertEqual(
            window.contentAspectRatio.width / window.contentAspectRatio.height,
            16.0 / 9.0,
            accuracy: 0.0001
        )
        let liveFrame = window.frame

        coordinator.configure(
            isLivePlayback: true,
            controlsVisible: false,
            title: "CCTV-1",
            videoAspectRatio: 16.0 / 9.0
        )
        await drainMainQueue()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(toolbar.isVisible)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden ?? false)
        XCTAssertEqual(window.title, "CCTV-1")
        XCTAssertEqual(window.frame, liveFrame)

        window.setFrame(
            NSRect(x: 40, y: 60, width: 1_120, height: 630),
            display: false
        )

        // AppKit can update unrelated style-mask bits while entering or
        // leaving full screen. Restoring player chrome must preserve them and
        // must not resize the frame to compensate for toolbar visibility.
        window.styleMask.insert(.miniaturizable)
        coordinator.restore()
        await drainMainQueue()

        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(toolbar.isVisible)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(
            window.frame,
            NSRect(x: 40, y: 60, width: 1_120, height: 630)
        )
        XCTAssertEqual(window.contentAspectRatio, originalContentAspectRatio)
    }

    @MainActor
    func testPlayerWindowRestoreSkipsMutationsAfterWindowWillClose() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        var didRestore = false
        let coordinator = PlayerWindowConfigurator.Coordinator(onRestore: {
            didRestore = true
        })
        coordinator.attach(to: window)
        await drainMainQueue()

        let closingFrame = NSRect(x: 80, y: 90, width: 1_120, height: 630)
        window.setFrame(closingFrame, display: false)
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )

        coordinator.restore()
        await drainMainQueue()

        XCTAssertTrue(didRestore)
        XCTAssertEqual(window.frame, closingFrame)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @MainActor
    func testClickedHistoryRecordIsAuthoritativeForResumePosition() {
        let record = HistoryRecord(
            siteKey: "old-site",
            videoID: "old-video-id",
            title: "Fixture",
            sourceName: "old-source-name",
            episodeName: "old-episode-name",
            position: 1_234,
            duration: 3_600
        )

        XCTAssertEqual(AppState.historyResumePosition(from: record), 1_234)
        XCTAssertNil(AppState.historyResumePosition(from: nil))

        var completed = record
        completed.position = 3_590
        XCTAssertNil(AppState.historyResumePosition(from: completed))

        var unknownDuration = record
        unknownDuration.duration = 0
        XCTAssertEqual(
            AppState.historyResumePosition(from: unknownDuration),
            1_234
        )
    }

    @MainActor
    func testHistoryPlaybackSelectionRestoresRecordedEpisodeDirectly() {
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: "fixture",
                siteName: "Fixture",
                videoID: "video-1",
                title: "Fixture Video"
            ),
            playSources: [
                PlaySource(
                    name: "线路一",
                    episodes: [
                        PlayEpisode(name: "第1集", url: "episode-1"),
                        PlayEpisode(name: "第2集", url: "episode-2")
                    ]
                ),
                PlaySource(
                    name: "线路二",
                    episodes: [
                        PlayEpisode(name: "第1集", url: "backup-1"),
                        PlayEpisode(name: "第2集", url: "backup-2")
                    ]
                )
            ]
        )
        let record = HistoryRecord(
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture Video",
            sourceName: "线路二",
            episodeName: "第2集",
            position: 180
        )

        let selection = AppState.historyPlaybackSelection(
            in: detail,
            record: record
        )

        XCTAssertEqual(selection?.source.name, "线路二")
        XCTAssertEqual(selection?.episode.url, "backup-2")
    }

    @MainActor
    func testHistoryPlaybackSelectionPrefersDurableReferenceAfterRename() {
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: "fixture",
                siteName: "Fixture",
                videoID: "video-1",
                title: "Fixture Video"
            ),
            playSources: [
                PlaySource(
                    name: "刷新后的线路名",
                    episodes: [
                        PlayEpisode(name: "第 1 集", url: "durable-token"),
                        PlayEpisode(name: "第 2 集", url: "episode-2")
                    ]
                )
            ]
        )
        let record = HistoryRecord(
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture Video",
            sourceName: "旧线路名",
            episodeName: "[2.4GB]Fixture.Show.S01E01.2026.mkv",
            episodeReference: "durable-token",
            position: 180
        )

        let selection = AppState.historyPlaybackSelection(
            in: detail,
            record: record
        )

        XCTAssertEqual(selection?.source.name, "刷新后的线路名")
        XCTAssertEqual(selection?.episode.name, "第 1 集")
    }

    @MainActor
    func testHistoryPlaybackSelectionSurvivesDisplayAndDomainChanges() throws {
        let oldSource = PlaySource(
            name: "Old Display Name",
            episodes: [
                PlayEpisode(
                    name: "Old Episode Label",
                    url: "https://old.invalid/resource/file-17?token=old-secret"
                )
            ]
        )
        let oldEpisode = try XCTUnwrap(oldSource.episodes.first)
        let record = HistoryRecord(
            siteKey: "renamed-site-key",
            videoID: "renamed-video-id",
            title: "Renamed Title",
            sourceName: oldSource.name,
            episodeName: oldEpisode.name,
            playbackReference: AppState.historyPlaybackReference(
                source: oldSource,
                episode: oldEpisode,
                headers: [:]
            )
        )
        let refreshedSource = PlaySource(
            name: "Completely Different Display Name",
            episodes: [
                PlayEpisode(
                    name: "Completely Different Episode Label",
                    url: "https://new.invalid/resource/file-17?token=new-secret"
                )
            ]
        )
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: "renamed-site-key",
                siteName: "Renamed Site",
                videoID: "renamed-video-id",
                title: "Renamed Title"
            ),
            playSources: [refreshedSource]
        )

        let selection = AppState.historyPlaybackSelection(in: detail, record: record)

        XCTAssertEqual(selection?.source.name, refreshedSource.name)
        XCTAssertEqual(
            selection?.episode.url,
            "https://new.invalid/resource/file-17?token=new-secret"
        )
    }

    @MainActor
    func testLegacyHistoryDoesNotGuessWhenDisplayIdentityIsAmbiguous() {
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: "fixture",
                siteName: "Fixture",
                videoID: "video-1",
                title: "Fixture"
            ),
            playSources: [
                PlaySource(
                    name: "Same Name",
                    episodes: [PlayEpisode(name: "Episode", url: "first")]
                ),
                PlaySource(
                    name: "Same Name",
                    episodes: [PlayEpisode(name: "Episode", url: "second")]
                )
            ]
        )
        let record = HistoryRecord(
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture",
            sourceName: "Same Name",
            episodeName: "Episode"
        )

        XCTAssertNil(AppState.historyPlaybackSelection(in: detail, record: record))
    }

    @MainActor
    func testHistoryReferencePersistsOnlySafeReplayHeaders() {
        let source = PlaySource(
            name: "Display",
            episodes: [PlayEpisode(name: "Episode", url: "/resource/17")]
        )
        let reference = AppState.historyPlaybackReference(
            source: source,
            episode: source.episodes[0],
            headers: [
                "User-Agent": "FixtureAgent/1.0",
                "Referer": "https://example.invalid/watch?token=secret&item=17",
                "Origin": "https://example.invalid",
                "Cookie": "session=secret",
                "Authorization": "Bearer secret"
            ]
        )

        XCTAssertEqual(reference.replayHeaders["User-Agent"], "FixtureAgent/1.0")
        XCTAssertNil(reference.replayHeaders["Origin"])
        XCTAssertNil(reference.replayHeaders["Referer"])
        XCTAssertNil(reference.replayHeaders["Cookie"])
        XCTAssertNil(reference.replayHeaders["Authorization"])
    }

    @MainActor
    func testHistoryReferencePersistsProviderIdentityAndUsesItForRefresh()
        throws {
        let source = PlaySource(
            name: "Display",
            episodes: [PlayEpisode(name: "Episode", url: "expired-resource")]
        )
        let configurationID = UUID()
        let providerReference = PlaybackResourceReference(
            configurationIdentity: configurationID.uuidString.lowercased(),
            siteIdentity: "site-a",
            providerKind: "android-dex-spider",
            providerVersion: 1,
            stableResourceLocator: "provider-opaque-item-42",
            sourceIdentity: source.stableIdentity,
            episodeIdentity: source.episodes[0].stableIdentity,
            stability: .providerStable
        )
        let playbackReference = AppState.historyPlaybackReference(
            source: source,
            episode: source.episodes[0],
            providerResourceReference: providerReference,
            headers: [
                "Cookie": "must-not-persist",
                "Authorization": "Bearer must-not-persist"
            ]
        )
        let record = HistoryRecord(
            siteKey: "site-a",
            videoID: "video-a",
            title: "Title",
            episodeReference: "expired-resource",
            playbackReference: playbackReference
        )

        XCTAssertEqual(
            playbackReference.providerResourceReference,
            providerReference
        )
        XCTAssertTrue(playbackReference.replayHeaders.isEmpty)
        let site = SiteConfiguration(
            key: "site-a",
            name: "Site A",
            type: 3,
            api: "csp_Provider"
        )
        let androidProvider = try AndroidDexSpiderSiteProvider(
            site: site,
            configurationID: configurationID,
            jarReference: "https://configuration.invalid/provider.jar",
            baseURL: nil,
            bridge: AndroidDexBridgeClient()
        )
        XCTAssertEqual(
            AppState.acceptedHistoryProviderReference(
                from: record,
                provider: androidProvider
            ),
            providerReference
        )
        XCTAssertNil(
            AppState.acceptedHistoryProviderReference(
                from: record,
                provider: UnsupportedSiteProvider(site: site)
            )
        )

        var legacyRecord = record
        legacyRecord.playbackReference?.providerResourceReference = nil
        XCTAssertNil(
            AppState.acceptedHistoryProviderReference(
                from: legacyRecord,
                provider: androidProvider
            ),
            "Legacy records must rebuild through their current local provider"
        )
    }

    @MainActor
    func testHistoryNeverPersistsOrReplaysRuntimeLoopbackCapabilities()
        throws {
        let nodeProxy = try XCTUnwrap(
            URL(string: "http://127.0.0.1:18888/proxy/media/session-secret")
        )
        let remote = try XCTUnwrap(
            URL(string: "https://media.invalid/movie.mp4")
        )
        let signedRemote = try XCTUnwrap(
            URL(
                string: "https://media.invalid/movie.mp4"
                    + "?token=must-not-persist&expires=2000000000"
            )
        )
        let providerReference = PlaybackResourceReference(
            configurationIdentity: UUID().uuidString.lowercased(),
            siteIdentity: "site-a",
            providerKind: "android-dex-spider",
            providerVersion: 1,
            stableResourceLocator: "provider-opaque-item-42",
            sourceIdentity: "source-a",
            episodeIdentity: "episode-a",
            stability: .providerReplay
        )
        let providerResult = SitePlaybackResult(
            url: remote.absoluteString,
            needsParsing: false,
            flag: "line",
            mediaSession: PlaybackMediaSession(
                sessionID: "session-secret",
                transport: .compatibilityDirect,
                mediaURL: remote.absoluteString,
                resourceReference: providerReference
            )
        )

        XCTAssertNil(
            AppState.persistentHistoryMediaReference(
                nodeProxy,
                playbackResult: nil
            )
        )
        XCTAssertNil(
            AppState.persistentHistoryMediaReference(
                remote,
                playbackResult: providerResult
            )
        )
        XCTAssertNil(
            AppState.persistentHistoryMediaReference(
                remote,
                playbackResult: nil
            )
        )
        XCTAssertNil(
            AppState.persistentHistoryMediaReference(
                signedRemote,
                playbackResult: nil
            )
        )
        XCTAssertNil(
            AppState.persistentHistoryEpisodeReference(
                signedRemote.absoluteString
            )
        )
        XCTAssertEqual(
            AppState.persistentHistoryEpisodeReference(
                "provider-opaque-item-42-generation-7"
            ),
            "provider-opaque-item-42-generation-7"
        )

        var unsafeProviderReference = providerReference
        unsafeProviderReference.stableResourceLocator =
            signedRemote.absoluteString
        XCTAssertNil(
            AppState.persistentProviderResourceReference(
                unsafeProviderReference
            )
        )
        XCTAssertNil(
            AppState.persistentProviderResourceReference(providerReference),
            "providerReplay locators are runtime-only capabilities"
        )
        var durableProviderReference = providerReference
        durableProviderReference.stability = .providerStable
        XCTAssertEqual(
            AppState.persistentProviderResourceReference(
                durableProviderReference
            ),
            durableProviderReference
        )

        let unsafeEncodedLocator = try JSONSerialization.data(
            withJSONObject: [
                "resourceID": "item-42",
                "authorizationToken": "must-not-persist"
            ],
            options: [.sortedKeys]
        ).base64EncodedString()
        XCTAssertNil(
            AppState.persistentHistoryEpisodeReference(
                unsafeEncodedLocator
            )
        )

        let loopbackRecord = HistoryRecord(
            siteKey: "node-site",
            videoID: "video-a",
            title: "Title",
            mediaReference: nodeProxy.absoluteString
        )
        XCTAssertNil(
            AppState.replayableHistoryPlayback(
                record: loopbackRecord,
                siteName: "Node"
            )
        )
        let signedRecord = HistoryRecord(
            siteKey: "android-site",
            videoID: "video-b",
            title: "Title",
            mediaReference: signedRemote.absoluteString
        )
        XCTAssertNil(
            AppState.replayableHistoryPlayback(
                record: signedRecord,
                siteName: "Android"
            )
        )
    }

    @MainActor
    func testHistoryPlaybackSelectionUsesExplicitEpisodeIdentityOnly() {
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: "fixture",
                siteName: "Fixture",
                videoID: "video-1",
                title: "Fixture Video"
            ),
            playSources: [
                PlaySource(
                    name: "线路一",
                    episodes: [
                        PlayEpisode(name: "第 23 集", url: "new-token")
                    ]
                )
            ]
        )
        let record = HistoryRecord(
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture Video",
            sourceName: "线路一",
            episodeName: "Show.S01E23.old-name.mkv",
            episodeReference: "expired-token"
        )

        let selection = AppState.historyPlaybackSelection(
            in: detail,
            record: record
        )

        XCTAssertEqual(selection?.episode.url, "new-token")
    }

    @MainActor
    func testHistoryCachedPlaybackRejectsRedactedSignedURL() {
        let redacted = HistoryRecord(
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture",
            mediaReference: "https://media.example/video.m3u8?token=%3Credacted%3E"
        )
        XCTAssertNil(
            AppState.replayableHistoryPlayback(
                record: redacted,
                siteName: "Fixture"
            )
        )
    }

    @MainActor
    func testHistoryCachedPlaybackBuildsDurableContext() throws {
        let record = HistoryRecord(
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture",
            sourceName: "线路一",
            episodeName: "第2集",
            episodeReference: "provider-opaque-item-42",
            mediaReference: "file:///tmp/okvideomac-history-fixture.m3u8",
            position: 42
        )
        let replay = try XCTUnwrap(
            AppState.replayableHistoryPlayback(
                record: record,
                siteName: "Fixture Site"
            )
        )

        XCTAssertEqual(replay.detail.summary.videoID, "video-1")
        XCTAssertEqual(replay.source.name, "线路一")
        XCTAssertEqual(replay.episode.url, "provider-opaque-item-42")
        XCTAssertEqual(
            replay.media.url.absoluteString,
            "file:///tmp/okvideomac-history-fixture.m3u8"
        )
    }

    @MainActor
    func testHistorySearchMatchRequiresValidUnambiguousTitle() {
        let record = HistoryRecord(
            siteKey: "renamed-site",
            videoID: "expired-session-id",
            title: "Target Film"
        )
        let unique = VideoSummary(
            siteKey: "renamed-site",
            siteName: "Renamed Site",
            videoID: "current-id",
            title: "Target Film"
        )

        XCTAssertEqual(
            AppState.historySearchMatch(in: [unique], record: record)?.videoID,
            "current-id"
        )
        XCTAssertNil(AppState.historySearchMatch(
            in: [
                unique,
                VideoSummary(
                    siteKey: "renamed-site",
                    siteName: "Renamed Site",
                    videoID: "ambiguous-id",
                    title: "Target Film"
                )
            ],
            record: record
        ))
        XCTAssertNil(AppState.historySearchQuery(for: "   "))
        XCTAssertNil(AppState.historySearchQuery(for: "untitled"))
        XCTAssertEqual(
            AppState.historySearchQuery(for: "  Target Film  "),
            "Target Film"
        )
    }

    func testVideoPageMergerStopsAfterEmptyNextPage() {
        let first = videoSummary(id: "first")
        let current = VideoPage(
            items: [first],
            pagination: Pagination(page: 1, pageCount: 99)
        )
        let loaded = VideoPage(
            items: [],
            pagination: Pagination(page: 2, pageCount: 99)
        )

        let merged = VideoPageMerger.merge(
            current: current,
            loaded: loaded,
            requestedPage: 2
        )

        XCTAssertEqual(merged.items, [first])
        XCTAssertEqual(merged.pagination.page, 2)
        XCTAssertEqual(merged.pagination.pageCount, 2)
        XCTAssertFalse(merged.pagination.hasMore)
    }

    func testVideoPageMergerStopsAfterAllDuplicateNextPage() {
        let first = videoSummary(id: "first")
        let current = VideoPage(
            items: [first],
            pagination: Pagination(page: 1, pageCount: 99)
        )
        let loaded = VideoPage(
            items: [first],
            pagination: Pagination(page: 2, pageCount: 99)
        )

        let merged = VideoPageMerger.merge(
            current: current,
            loaded: loaded,
            requestedPage: 2
        )

        XCTAssertEqual(merged.items, [first])
        XCTAssertFalse(merged.pagination.hasMore)
    }

    func testVideoPageMergerAppendsOnePageAndKeepsPagination() {
        let first = videoSummary(id: "first")
        let second = videoSummary(id: "second")
        let current = VideoPage(
            items: [first],
            pagination: Pagination(page: 1, pageCount: 3)
        )
        let loaded = VideoPage(
            items: [first, second],
            pagination: Pagination(page: 2, pageCount: 3)
        )

        let merged = VideoPageMerger.merge(
            current: current,
            loaded: loaded,
            requestedPage: 2
        )

        XCTAssertEqual(merged.items, [first, second])
        XCTAssertEqual(merged.pagination.page, 2)
        XCTAssertEqual(merged.pagination.pageCount, 3)
        XCTAssertTrue(merged.pagination.hasMore)
    }

    func testVideoCardMetadataMovesOnlyValidScoresOntoPoster() {
        XCTAssertEqual(
            VideoCardMetadata.ratingText(from: " 7.8 "),
            "7.8"
        )
        XCTAssertNil(VideoCardMetadata.ratingText(from: "0"))
        XCTAssertNil(VideoCardMetadata.ratingText(from: "更新至 12 集"))
        XCTAssertEqual(
            VideoCardMetadata.ratingText(from: "评分：7.5"),
            "7.5"
        )
        XCTAssertEqual(
            VideoCardMetadata.ratingText(from: "豆瓣评分 8.2 分"),
            "8.2"
        )
        XCTAssertNil(VideoCardMetadata.secondaryText(from: "评分：7.5"))
        XCTAssertNil(VideoCardMetadata.secondaryText(from: "7.8"))
        XCTAssertNil(VideoCardMetadata.secondaryText(from: "0"))
        XCTAssertEqual(
            VideoCardMetadata.secondaryText(from: "更新至 12 集"),
            "更新至 12 集"
        )
    }

    func testHomeSiteNamesHideExecutionBackendDetails() {
        XCTAssertEqual(
            HomeSitePresentation.displayName(
                siteName: "豆瓣首页",
                capability: .javaScriptSpider
            ),
            "豆瓣首页"
        )
        XCTAssertEqual(
            HomeSitePresentation.displayName(
                siteName: "影视站点",
                capability: .javaDexSpider
            ),
            "影视站点"
        )
        XCTAssertEqual(
            HomeSitePresentation.displayName(
                siteName: "等待迁移",
                capability: .unsupportedSpider
            ),
            "等待迁移（暂不可用）"
        )
    }

    func testSearchResultPresentationCanMergeAndSeparateDuplicateTitles() {
        let values = [
            VideoSummary(
                siteKey: "a",
                siteName: "A",
                videoID: "1",
                title: "揭秘日",
                year: "2026"
            ),
            VideoSummary(
                siteKey: "b",
                siteName: "B",
                videoID: "2",
                title: "揭秘日",
                year: "2026"
            )
        ]

        let merged = SearchResultPresentation.clusters(
            from: values,
            keyword: "揭秘日",
            mergesDuplicates: true,
            sortOrder: .relevance
        )
        let separated = SearchResultPresentation.clusters(
            from: values,
            keyword: "揭秘日",
            mergesDuplicates: false,
            sortOrder: .relevance
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sources.count, 2)
        XCTAssertEqual(separated.count, 2)
        XCTAssertTrue(separated.allSatisfy { $0.sources.count == 1 })
    }

    func testMergedSearchClusterRequiresExplicitSourceSelection() {
        let sourceA = VideoSummary(
            siteKey: "a",
            siteName: "来源 A",
            videoID: "1",
            title: "群体"
        )
        let sourceB = VideoSummary(
            siteKey: "b",
            siteName: "来源 B",
            videoID: "2",
            title: "群体"
        )
        let single = SearchResultCluster(
            id: "single",
            title: "群体",
            year: nil,
            sources: [sourceA]
        )
        let multiple = SearchResultCluster(
            id: "multiple",
            title: "群体",
            year: nil,
            sources: [sourceA, sourceB]
        )

        XCTAssertFalse(SearchClusterOpenPolicy.requiresSourceSelection(single))
        XCTAssertTrue(SearchClusterOpenPolicy.requiresSourceSelection(multiple))
    }

    func testSearchMergePreferenceUsesStablePersistentKey() {
        XCTAssertEqual(
            SearchDisplayPreferences.mergesDuplicateTitlesKey,
            "search.mergesDuplicateTitles"
        )
    }

    func testHistoryRetentionMenuKeepsStandardAndExistingValues() {
        XCTAssertEqual(
            HistoryRetentionPresets.standardDays,
            [30, 60, 90, 180, 365, 3_650]
        )
        XCTAssertEqual(
            HistoryRetentionPresets.options(including: 45),
            [30, 45, 60, 90, 180, 365, 3_650]
        )
        XCTAssertEqual(HistoryRetentionPresets.title(for: 365), "1 年")
        XCTAssertEqual(HistoryRetentionPresets.title(for: 3_650), "10 年")
    }

    func testSearchResultPresentationPreservesCoreRelevanceOrder() {
        let values = [
            VideoSummary(
                siteKey: "b",
                siteName: "B",
                videoID: "2",
                title: "揭秘日"
            ),
            VideoSummary(
                siteKey: "c",
                siteName: "C",
                videoID: "3",
                title: "揭秘日（臻彩）"
            ),
            VideoSummary(
                siteKey: "a",
                siteName: "A",
                videoID: "1",
                title: "中华揭秘之寻味新疆"
            )
        ]

        let clusters = SearchResultPresentation.clusters(
            from: values,
            keyword: "揭秘日",
            mergesDuplicates: true,
            sortOrder: .relevance
        )

        XCTAssertEqual(clusters.map(\.title), ["揭秘日", "揭秘日（臻彩）", "中华揭秘之寻味新疆"])
    }

    func testSearchSessionGateRejectsCancelledAndSupersededSessions() {
        var gate = SearchSessionGate()
        let first = gate.begin()
        XCTAssertTrue(gate.accepts(first))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(first))

        let second = gate.begin()
        let third = gate.begin()
        XCTAssertFalse(gate.accepts(second))
        XCTAssertTrue(gate.accepts(third))
    }

    func testActivityIndicatorStopsAnimationAfterLoadingDisappears() {
        var lifecycle = AppActivityIndicatorLifecycle()
        lifecycle.appear(reduceMotion: false)
        XCTAssertTrue(lifecycle.isAnimating)
        let first = lifecycle.rotationDegrees(
            at: Date(timeIntervalSinceReferenceDate: 0.1)
        )
        let second = lifecycle.rotationDegrees(
            at: Date(timeIntervalSinceReferenceDate: 0.2)
        )
        XCTAssertNotEqual(first, second)

        lifecycle.disappear()
        XCTAssertFalse(lifecycle.isAnimating)
        XCTAssertEqual(
            lifecycle.rotationDegrees(at: Date()),
            0
        )

        lifecycle.appear(reduceMotion: true)
        XCTAssertFalse(lifecycle.isAnimating)
        lifecycle.updateReduceMotion(false)
        XCTAssertTrue(lifecycle.isAnimating)
        lifecycle.disappear()
        XCTAssertFalse(lifecycle.isAnimating)
    }

    func testSearchResultPresentationSortsBySourceCountAndYear() {
        let values = [
            VideoSummary(
                siteKey: "a",
                siteName: "A",
                videoID: "1",
                title: "甲",
                year: "2024"
            ),
            VideoSummary(
                siteKey: "b",
                siteName: "B",
                videoID: "2",
                title: "甲",
                year: "2024"
            ),
            VideoSummary(
                siteKey: "c",
                siteName: "C",
                videoID: "3",
                title: "乙",
                year: "2026"
            )
        ]

        let bySources = SearchResultPresentation.clusters(
            from: values,
            keyword: "",
            mergesDuplicates: true,
            sortOrder: .sourceCount
        )
        let byYear = SearchResultPresentation.clusters(
            from: values,
            keyword: "",
            mergesDuplicates: true,
            sortOrder: .newest
        )

        XCTAssertEqual(bySources.first?.title, "甲")
        XCTAssertEqual(byYear.first?.title, "乙")
    }

    private func videoSummary(id: String) -> VideoSummary {
        VideoSummary(
            siteKey: "fixture",
            siteName: "Fixture",
            videoID: id,
            title: id
        )
    }
}

final class NodeBundleCompatibilityTests: XCTestCase {
    func testDescriptorUpgradesAuthenticatedHTTPAndDerivesScriptURL() throws {
        let source = try XCTUnwrap(
            URL(string: "http://fixture:secret@example.invalid/index.js.md5")
        )

        let descriptor = try NodeBundleSourceDescriptor(url: source)

        XCTAssertEqual(
            descriptor.checksumURL.absoluteString,
            "https://example.invalid/index.js.md5"
        )
        XCTAssertEqual(
            descriptor.scriptURL.absoluteString,
            "https://example.invalid/index.js"
        )
        XCTAssertEqual(
            descriptor.authorizationHeader,
            "Basic " + Data("fixture:secret".utf8).base64EncodedString()
        )
        XCTAssertFalse(descriptor.cacheKey.isEmpty)
    }

    func testNodeConfigurationNormalizationPromotesVideoSites() throws {
        let source = Data(
            #"{"video":{"danmuSearchUrl":"/danmu","sites":[{"key":"nodejs_fixture","name":"Fixture","type":3,"api":"/spider/fixture/3","enable":true}]}}"#
                .utf8
        )

        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(source)
        let configuration = try ConfigurationParser().parse(normalized)
        let site = try XCTUnwrap(configuration.sites.first)

        XCTAssertEqual(site.key, "nodejs_fixture")
        XCTAssertEqual(site.api, "/spider/fixture/3")
        XCTAssertEqual(site.extra["okNodeRuntime"], .bool(true))
        XCTAssertEqual(configuration.danmaku, "/danmu")
    }

    func testNodeConfigurationNormalizationPreservesDeclaredCapabilities() throws {
        let source = Data(
            #"{"video":{"sites":[{"key":"utility-fixture","name":"Renamed Utility","type":3,"api":"/spider/utility/3","enable":true,"searchable":0,"quickSearch":0,"filterable":0,"indexs":0},{"key":"home-fixture","name":"Renamed Home","type":3,"api":"/spider/home/3","enable":true,"searchable":1,"quickSearch":1,"filterable":1,"indexs":1},{"key":"disabled-fixture","name":"Disabled","type":3,"api":"/spider/disabled/3","enable":false}]}}"#
                .utf8
        )

        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(source)
        let configuration = try ConfigurationParser().parse(normalized)
        let utility = try XCTUnwrap(
            configuration.sites.first(where: { $0.key == "utility-fixture" })
        )
        let home = try XCTUnwrap(
            configuration.sites.first(where: { $0.key == "home-fixture" })
        )
        let disabled = try XCTUnwrap(
            configuration.sites.first(where: { $0.key == "disabled-fixture" })
        )

        XCTAssertEqual(utility.searchable, 0)
        XCTAssertEqual(utility.quickSearch, 0)
        XCTAssertEqual(utility.indexs, 0)
        XCTAssertEqual(utility.extra["filterable"], .integer(0))
        XCTAssertEqual(home.searchable, 1)
        XCTAssertEqual(home.quickSearch, 1)
        XCTAssertEqual(home.indexs, 1)
        XCTAssertEqual(home.extra["filterable"], .integer(1))
        XCTAssertEqual(disabled.hide, 1)
    }

    func testNodeBundleMD5Compatibility() {
        XCTAssertEqual(
            NodeBundleRuntimeService.md5Hex(Data("hello".utf8)),
            "5d41402abc4b2a76b9719d911017c592"
        )
    }

    func testDescriptorBindsPinToURLSourceAndVersionWithoutSendingFragment() throws {
        let hash = String(repeating: "a", count: 64)
        let first = try NodeBundleSourceDescriptor(
            url: try XCTUnwrap(URL(
                string: "http://example.invalid/index.js.md5#sha256=\(hash)&source=alpha&version=1"
            ))
        )
        let nextVersion = try NodeBundleSourceDescriptor(
            url: try XCTUnwrap(URL(
                string: "http://example.invalid/index.js.md5#sha256=\(hash)&source=alpha&version=2"
            ))
        )

        XCTAssertEqual(first.expectedSHA256, hash)
        XCTAssertEqual(first.sourceID, "alpha")
        XCTAssertEqual(first.declaredVersion, "1")
        XCTAssertNil(first.checksumURL.fragment)
        XCTAssertNil(first.scriptURL.fragment)
        XCTAssertNotEqual(first.pinIdentity, nextVersion.pinIdentity)
        XCTAssertNotEqual(first.cacheKey, nextVersion.cacheKey)
    }

    func testFinalRedirectURLsDetermineWhetherTrustedPinIsRequired() throws {
        let http = try XCTUnwrap(URL(string: "http://cdn.invalid/index.js"))
        let https = try XCTUnwrap(URL(string: "https://cdn.invalid/index.js"))

        XCTAssertFalse(try NodeBundleRuntimeService.requiresTrustedSHA256(
            finalChecksumURL: https.appendingPathExtension("md5"),
            finalScriptURL: https
        ))
        XCTAssertTrue(try NodeBundleRuntimeService.requiresTrustedSHA256(
            finalChecksumURL: http.appendingPathExtension("md5"),
            finalScriptURL: https
        ))
        XCTAssertTrue(try NodeBundleRuntimeService.requiresTrustedSHA256(
            finalChecksumURL: https.appendingPathExtension("md5"),
            finalScriptURL: http
        ))
    }

    func testHTTPBundleWithoutPinIsSecurityRejection() throws {
        let finalURL = try XCTUnwrap(URL(string: "http://cdn.invalid/index.js"))

        XCTAssertThrowsError(try NodeBundleRuntimeService.validateTrustedSHA256(
            expected: nil,
            actual: String(repeating: "b", count: 64),
            requiresTrustedSHA256: true,
            finalScriptURL: finalURL
        )) { error in
            guard case NodeBundleRuntimeError.missingTrustedSHA256 = error else {
                return XCTFail("意外错误：\(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("安全拒绝"))
        }
    }

    func testTrustedPinMismatchIsSecurityRejection() throws {
        let finalURL = try XCTUnwrap(URL(string: "http://cdn.invalid/index.js"))

        XCTAssertThrowsError(try NodeBundleRuntimeService.validateTrustedSHA256(
            expected: String(repeating: "a", count: 64),
            actual: String(repeating: "b", count: 64),
            requiresTrustedSHA256: true,
            finalScriptURL: finalURL
        )) { error in
            guard case NodeBundleRuntimeError.sha256Mismatch = error else {
                return XCTFail("意外错误：\(error)")
            }
        }
    }

    func testExecutionPathRehashRejectsTamperedCache() throws {
        let original = Data("module.exports = {};".utf8)
        let tampered = Data("module.exports = { pwned: true };".utf8)
        let httpsScript = try XCTUnwrap(URL(string: "https://cdn.invalid/index.js"))

        XCTAssertThrowsError(try NodeBundleRuntimeService.validateBundleDataForExecution(
            tampered,
            expectedMD5: NodeBundleRuntimeService.md5Hex(original),
            expectedInternalSHA256: NodeBundleRuntimeService.sha256Hex(original),
            trustedSHA256: nil,
            finalChecksumURL: httpsScript.appendingPathExtension("md5"),
            finalScriptURL: httpsScript
        )) { error in
            guard case NodeBundleRuntimeError.integrityRejected = error else {
                return XCTFail("意外错误：\(error)")
            }
        }
    }

    func testNodeEnvironmentIsMinimalAndDropsInjectionVariables() throws {
        let runtime = URL(fileURLWithPath: "/tmp/okvideo-node-runtime")
        let environment = try NodeBundleRuntimeService.sanitizedNodeEnvironment(
            bundlePath: runtime.appendingPathComponent("index.js"),
            runtimeDirectory: runtime,
            temporaryDirectory: runtime.appendingPathComponent("tmp"),
            parentPID: 42
        )

        XCTAssertEqual(environment["OKVIDEO_PARENT_PID"], "42")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(environment["NODE_OPTIONS"])
        XCTAssertNil(environment["NODE_PATH"])
        XCTAssertFalse(environment.keys.contains { $0.hasPrefix("DYLD_") })
        XCTAssertFalse(environment.keys.contains { $0.hasPrefix("LD_") })
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
    }

    func testContractDetectorKeepsContractAAndFindsHostIntegratedContractB() throws {
        let contractA = Data(
            "module.exports={start(){},stop(){}};".utf8
        )
        let contractB = Data(
            "catServerFactory;catDartServerPort();process.env.DEV_HTTP_PORT;".utf8
        )

        XCTAssertEqual(
            try NodeRuntimeContractDetector.detect(validatedBundleData: contractA),
            .service
        )
        XCTAssertEqual(
            try NodeRuntimeContractDetector.detect(validatedBundleData: contractB),
            .hostIntegrated
        )
    }

    func testPartialContractBMarkersFailClosedWithoutExecutingBundle() {
        let ambiguous = Data("void catServerFactory;".utf8)

        XCTAssertThrowsError(
            try NodeRuntimeContractDetector.detect(validatedBundleData: ambiguous)
        ) { error in
            XCTAssertEqual(error as? NodeBundleRuntimeError, .unsupportedHostContract)
        }
    }

    func testContractBMinimumConfigurationIsDataOnlyAndSchemaValidated() throws {
        let data = try ContractBConfigBuilder.buildMinimumConfiguration()
        try ContractBConfigBuilder.validate(data)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            ((object["sites"] as? [String: Any])?["list"] as? [Any])?.count,
            0
        )
        XCTAssertEqual(
            ((object["pans"] as? [String: Any])?["list"] as? [Any])?.count,
            0
        )
    }

    func testContractBConfigurationRejectsMissingRequiredCommonShape() {
        XCTAssertThrowsError(
            try ContractBConfigBuilder.validate(Data(#"{"sites":{"list":[]}}"#.utf8))
        ) { error in
            XCTAssertEqual(
                error as? NodeBundleRuntimeError,
                .configurationContractInvalid
            )
        }
    }

    func testContractBEnvironmentIsBoundedAndDoesNotPolluteContractA() throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("okvideo-contract-env")
        let contractA = try NodeBundleRuntimeService.sanitizedNodeEnvironment(
            bundlePath: runtime.appendingPathComponent("index.js"),
            runtimeDirectory: runtime,
            temporaryDirectory: runtime.appendingPathComponent("tmp")
        )
        let contractB = try NodeBundleRuntimeService.sanitizedNodeEnvironment(
            bundlePath: runtime.appendingPathComponent("index.js"),
            runtimeDirectory: runtime,
            temporaryDirectory: runtime.appendingPathComponent("tmp"),
            contractAdditions: [
                "DEV_HTTP_PORT": "12345",
                "OKVIDEO_CONTRACT_B_CONFIG_PATH": runtime
                    .appendingPathComponent("config.json").path,
                "OKVIDEO_CONTRACT_B_STATE_PATH": runtime
                    .appendingPathComponent("state.json").path
            ]
        )

        XCTAssertNil(contractA["DEV_HTTP_PORT"])
        XCTAssertEqual(contractB["DEV_HTTP_PORT"], "12345")
        XCTAssertNil(contractB["NODE_PATH"])
        XCTAssertThrowsError(try NodeBundleRuntimeService.sanitizedNodeEnvironment(
            bundlePath: runtime.appendingPathComponent("index.js"),
            runtimeDirectory: runtime,
            temporaryDirectory: runtime.appendingPathComponent("tmp"),
            contractAdditions: ["NODE_PATH": "/tmp/injected"]
        ))
    }

    func testContractBPortAllocationIsDynamicAndNonFixed() throws {
        let first = try NodeRuntimeLoopbackPortAllocator.allocate()
        let second = try NodeRuntimeLoopbackPortAllocator.allocate()

        XCTAssertNotEqual(first, 9_988)
        XCTAssertNotEqual(second, 9_988)
        XCTAssertTrue((1...65_535).contains(first))
        XCTAssertTrue((1...65_535).contains(second))
    }

    func testContractBListenerStateRejectsNonLoopbackHost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("okvideo-contract-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        try Data(
            #"{"contract":"contract-b-host-integrated","phase":"listener-observed","host":"0.0.0.0","family":"IPv4","port":19000}"#.utf8
        ).write(to: stateURL)

        XCTAssertNil(ContractBListenerState.readValidated(from: stateURL))
    }

    func testOrdinaryHTTPConfigurationIsOutsideNodeBundlePolicy() throws {
        let ordinary = try XCTUnwrap(URL(string: "http://example.invalid/config.json"))
        let node = try XCTUnwrap(URL(string: "http://example.invalid/index.js.md5"))

        XCTAssertFalse(NodeBundleRuntimeService.supports(ordinary))
        XCTAssertTrue(NodeBundleRuntimeService.supports(node))
    }

    func testNativeAndQuickJSSitesRemainOutsideNodeReadinessBarrier() throws {
        let loopback = try XCTUnwrap(URL(string: "http://127.0.0.1:18000/"))
        let native = SiteConfiguration(
            key: "native_fixture",
            name: "Native",
            type: 0,
            api: "https://example.invalid/api"
        )
        let quickJS = SiteConfiguration(
            key: "quickjs_fixture",
            name: "QuickJS",
            type: 3,
            api: "https://example.invalid/spider.js"
        )

        XCTAssertFalse(NodeHTTPSpiderSiteProvider.canHandle(
            site: native,
            baseURL: loopback
        ))
        XCTAssertFalse(NodeHTTPSpiderSiteProvider.canHandle(
            site: quickJS,
            baseURL: loopback
        ))
    }

    func testNodeAndLocalJavaScriptOwnershipNeverFallsThroughToAndroid()
        throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://configuration.invalid/config.json")
        )
        let node = SiteConfiguration(
            key: "node-csp",
            name: "Node",
            type: 3,
            api: "csp_Node",
            jar: "https://configuration.invalid/provider.jar",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let localJavaScript = SiteConfiguration(
            key: "local-js-csp",
            name: "Local JS",
            type: 3,
            api: "csp_Local",
            jar: "https://configuration.invalid/provider.jar",
            extra: [
                "script": .string(
                    "https://configuration.invalid/provider.js"
                )
            ]
        )

        XCTAssertTrue(
            SiteProviderRoutingPolicy.hasExclusiveNodeRuntimeOwnership(node)
        )
        XCTAssertNil(
            SiteProviderRoutingPolicy.javaDexJarReference(
                site: node,
                configurationSpider: nil,
                baseURL: baseURL
            )
        )
        XCTAssertNotNil(
            SiteProviderRoutingPolicy.localJavaScriptURL(
                site: localJavaScript,
                configurationSpider: nil,
                baseURL: baseURL
            )
        )
        XCTAssertNil(
            SiteProviderRoutingPolicy.javaDexJarReference(
                site: localJavaScript,
                configurationSpider: nil,
                baseURL: baseURL
            )
        )
    }

    func testContentAddressedLocalJavaScriptNeverRoutesToAndroid() throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://configuration.invalid/config.json")
        )
        let digest = "1fb66ff185ea35252d2ae2a07d058ec1"

        for extensionName in ["js", "mjs", "cjs"] {
            let script = "https://configuration.invalid/provider."
                + extensionName + ";md5;" + digest
            let site = SiteConfiguration(
                key: "local-script-\(extensionName)",
                name: "Local Script",
                type: 3,
                api: "csp_LocalScript"
            )

            XCTAssertEqual(
                SiteProviderRoutingPolicy.localJavaScriptURL(
                    site: site,
                    configurationSpider: script,
                    baseURL: baseURL
                )?.absoluteString,
                "https://configuration.invalid/provider.\(extensionName)"
            )
            XCTAssertNil(
                SiteProviderRoutingPolicy.javaDexJarReference(
                    site: site,
                    configurationSpider: script,
                    baseURL: baseURL
                )
            )
        }
    }

    func testCSPWithoutJarOrDexProvenanceCannotUseAndroid() throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://configuration.invalid/config.json")
        )
        let site = SiteConfiguration(
            key: "ambiguous-csp",
            name: "Ambiguous",
            type: 3,
            api: "csp_Ambiguous"
        )

        XCTAssertNil(
            SiteProviderRoutingPolicy.javaDexJarReference(
                site: site,
                configurationSpider:
                    "https://configuration.invalid/provider.bin",
                baseURL: baseURL
            )
        )
        XCTAssertEqual(
            SiteProviderRoutingPolicy.javaDexJarReference(
                site: site,
                configurationSpider:
                    "https://configuration.invalid/provider.jar;md5;fixture",
                baseURL: baseURL
            ),
            "https://configuration.invalid/provider.jar;md5;fixture"
        )
        XCTAssertEqual(
            SiteProviderRoutingPolicy.javaDexJarReference(
                site: site,
                configurationSpider:
                    "https://configuration.invalid/provider.jpg;md5;"
                    + "1fb66ff185ea35252d2ae2a07d058ec1",
                baseURL: baseURL
            ),
            "https://configuration.invalid/provider.jpg;md5;"
                + "1fb66ff185ea35252d2ae2a07d058ec1"
        )
        XCTAssertNil(
            SiteProviderRoutingPolicy.javaDexJarReference(
                site: site,
                configurationSpider:
                    "https://configuration.invalid/provider.jpg;md5;invalid",
                baseURL: baseURL
            )
        )
    }

    func testContentAddressedMDriveRoutesToAndroidWithoutAuthorizationInference()
        throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://configuration.invalid/config.json")
        )
        let spider = "https://configuration.invalid/provider.jpg;md5;"
            + "1fb66ff185ea35252d2ae2a07d058ec1"
        let site = SiteConfiguration(
            key: "drive-fixture",
            name: "Drive Fixture",
            type: 3,
            api: "csp_MyDriveGuard"
        )

        XCTAssertEqual(
            SiteProviderRoutingPolicy.javaDexJarReference(
                site: site,
                configurationSpider: spider,
                baseURL: baseURL
            ),
            spider
        )

        XCTAssertEqual(
            AndroidDexSpiderSiteProvider.interactionActionKind(tag: nil),
            .configuration
        )
        XCTAssertFalse(
            ConfigurationInteractionClassificationPolicy
                .legacySemantic(tag: nil)
                .isAuthorization
        )
    }

    func testOfflineLegacyCacheMigratesWithExplicitTOFUTrust() async throws {
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(fixture: fixture)

        let snapshot = try await service.prepareBundleForTesting(
            from: fixture.sourceURL
        )

        XCTAssertEqual(snapshot.sha256, NodeBundleRuntimeService.sha256Hex(fixture.script))
        XCTAssertEqual(snapshot.trustState, .legacyTOFU)
        let metadataURL = fixture.cacheDirectory
            .appendingPathComponent("NodeBundles")
            .appendingPathComponent(snapshot.cacheKey)
            .appendingPathComponent("metadata.json")
        let metadata = try JSONDecoder().decode(
            NodeBundleRuntimeService.CacheMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        XCTAssertEqual(metadata.trustState, .legacyTOFU)
        XCTAssertNotEqual(metadata.trustState, .publisherSHA256)
    }

    func testUnpinnedHTTPRedirectDiscardsDownloadAndMigratesLegacyCache() async throws {
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let untrustedDownload = Data("module.exports = { network: true };".utf8)
        let untrustedMD5 = NodeBundleRuntimeService.md5Hex(untrustedDownload)
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix(".md5") {
                let finalURL = try XCTUnwrap(URL(
                    string: "http://cdn.invalid/current.js.md5"
                ))
                return HTTPResponse(
                    url: finalURL,
                    statusCode: 200,
                    headers: ["Content-Type": "text/plain"],
                    body: Data(untrustedMD5.utf8),
                    diagnostics: HTTPResponseDiagnostics(
                        originalURL: request.url,
                        redirects: [HTTPRedirectHop(
                            statusCode: 302,
                            sourceURL: request.url,
                            destinationURL: finalURL
                        )],
                        finalURL: finalURL,
                        statusCode: 200,
                        contentType: "text/plain",
                        contentLength: untrustedMD5.count,
                        duration: 0.25
                    )
                )
            }
            let finalURL = try XCTUnwrap(URL(
                string: "http://cdn.invalid/current.jpg"
            ))
            return HTTPResponse(
                url: finalURL,
                statusCode: 200,
                headers: ["Content-Type": "image/jpeg"],
                body: untrustedDownload,
                diagnostics: HTTPResponseDiagnostics(
                    originalURL: request.url,
                    redirects: [HTTPRedirectHop(
                        statusCode: 302,
                        sourceURL: request.url,
                        destinationURL: finalURL
                    )],
                    finalURL: finalURL,
                    statusCode: 200,
                    contentType: "image/jpeg",
                    contentLength: untrustedDownload.count,
                    duration: 0.5
                )
            )
        }
        let service = NodeBundleRuntimeService(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            cacheDirectory: fixture.cacheDirectory,
            remoteHTTPClient: client
        )

        let snapshot = try await service.prepareBundleForTesting(
            from: fixture.sourceURL
        )

        XCTAssertEqual(snapshot.trustState, .legacyTOFU)
        XCTAssertEqual(
            snapshot.sha256,
            NodeBundleRuntimeService.sha256Hex(fixture.script)
        )
        XCTAssertNotEqual(
            snapshot.sha256,
            NodeBundleRuntimeService.sha256Hex(untrustedDownload)
        )
        let second = try await service.prepareBundleForTesting(
            from: fixture.sourceURL
        )
        XCTAssertEqual(second.sha256, snapshot.sha256)
        let logURL = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeRuntime")
            .appendingPathComponent(snapshot.cacheKey)
            .appendingPathComponent("node.log")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("NODE_BUNDLE_RESPONSE"))
        XCTAssertTrue(log.contains("current.jpg"))
        XCTAssertTrue(log.contains("image/jpeg"))
        XCTAssertTrue(log.contains("NODE_TRUST_HASH_CHANGED"))
        XCTAssertTrue(log.contains("legacyTOFU"))
    }

    func testLegacyMigrationRejectsMD5Mismatch() async throws {
        let fixture = try makeLegacyCacheFixture(checksum: String(repeating: "0", count: 32))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(fixture: fixture)

        do {
            _ = try await service.prepareBundleForTesting(from: fixture.sourceURL)
            XCTFail("MD5 不匹配的旧缓存不应迁移")
        } catch {
            guard case NodeBundleRuntimeError.legacyMD5Mismatch = error else {
                return XCTFail("意外错误：\(error)")
            }
        }
    }

    func testMigratedCacheRehashRejectsTampering() async throws {
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(fixture: fixture)
        let snapshot = try await service.prepareBundleForTesting(from: fixture.sourceURL)
        let migratedScript = fixture.cacheDirectory
            .appendingPathComponent("NodeBundles")
            .appendingPathComponent(snapshot.cacheKey)
            .appendingPathComponent("index.js")
        try Data("module.exports = { tampered: true };".utf8)
            .write(to: migratedScript, options: .atomic)

        do {
            _ = try await service.prepareBundleForTesting(from: fixture.sourceURL)
            XCTFail("篡改后的新缓存不应进入执行路径")
        } catch {
            guard case NodeBundleRuntimeError.integrityRejected = error else {
                return XCTFail("意外错误：\(error)")
            }
        }
    }

    func testValidNewCacheIsPreferredOverChangedLegacyCache() async throws {
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(fixture: fixture)
        let first = try await service.prepareBundleForTesting(from: fixture.sourceURL)
        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let legacyScript = fixture.cacheDirectory
            .appendingPathComponent("NodeBundles")
            .appendingPathComponent(descriptor.legacyCacheKey)
            .appendingPathComponent("index.js")
        try Data("module.exports = { changed: true };".utf8)
            .write(to: legacyScript, options: .atomic)

        let second = try await service.prepareBundleForTesting(from: fixture.sourceURL)
        XCTAssertEqual(second.sha256, first.sha256)
        XCTAssertEqual(second.trustState, .legacyTOFU)
    }

    func testEmptyNewCacheDirectoryDoesNotBlockLegacyMigration() async throws {
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let emptyNewCache = fixture.cacheDirectory
            .appendingPathComponent("NodeBundles")
            .appendingPathComponent(descriptor.cacheKey)
        try FileManager.default.createDirectory(
            at: emptyNewCache,
            withIntermediateDirectories: true
        )
        let service = makeOfflineRuntime(fixture: fixture)

        let snapshot = try await service.prepareBundleForTesting(from: fixture.sourceURL)

        XCTAssertEqual(snapshot.trustState, .legacyTOFU)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: emptyNewCache.appendingPathComponent("metadata.json").path
        ))
    }

    func testInterruptedLegacyMigrationLeavesNoExecutableNewCache() async throws {
        enum FixtureError: Error { case interrupted }
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            migrationCommitHook: { throw FixtureError.interrupted }
        )
        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)

        do {
            _ = try await service.prepareBundleForTesting(from: fixture.sourceURL)
            XCTFail("提交前中断应导致迁移失败")
        } catch {
            guard case NodeBundleRuntimeError.legacyMigrationFailed = error else {
                return XCTFail("意外错误：\(error)")
            }
        }
        let root = fixture.cacheDirectory.appendingPathComponent("NodeBundles")
        let destination = root.appendingPathComponent(descriptor.cacheKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".\(descriptor.cacheKey).tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testUnavailableNodeProviderReportsRuntimeFailureWithoutUsingStaleEndpoint() async throws {
        let provider = NodeRuntimeUnavailableSiteProvider(
            site: SiteConfiguration(
                key: "nodejs_offline",
                name: "离线站点",
                type: 3,
                api: "/spider/offline/3",
                extra: ["okNodeRuntime": .bool(true)]
            ),
            reason: "内置 Node 启动失败"
        )

        do {
            _ = try await provider.search(keyword: "测试", page: 1, quick: false)
            XCTFail("端点失效时不应发出业务请求")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("端点不可用"))
            XCTAssertTrue(error.localizedDescription.contains("启动失败"))
        }
    }

    func testNodeRestartPolicyIsBoundedExponentialBackoff() {
        XCTAssertEqual(NodeBundleRuntimeService.restartDelays, [1, 2, 5])
    }

    func testNodeDiagnosticClassifierSeparatesFailureLayers() {
        XCTAssertEqual(
            NodeDiagnosticClassifier.classify(
                HTTPClientError.timeout,
                context: .bundleTransport
            ),
            .init(category: .transport, code: .transportTimeout)
        )
        XCTAssertEqual(
            NodeDiagnosticClassifier.classify(
                HTTPClientError.transport("ECONNRESET"),
                context: .bundleTransport
            ),
            .init(category: .transport, code: .transportReset)
        )
        XCTAssertEqual(
            NodeDiagnosticClassifier.classify(
                NodeBundleRuntimeError.legacyMigrationFailed("fixture"),
                context: .bundleTransport
            ),
            .init(category: .cache, code: .cacheMigrationFailed)
        )
        XCTAssertEqual(
            NodeDiagnosticClassifier.classify(
                NodeBundleRuntimeError.nodeExitedUnexpectedly("fixture"),
                context: .runtime
            ),
            .init(category: .runtime, code: .runtimeExited)
        )
        XCTAssertEqual(
            NodeDiagnosticClassifier.classify(
                HTTPClientError.transport("connection reset"),
                context: .spiderSite
            ),
            .init(category: .spiderSite, code: .spiderRequestFailed)
        )
    }

    func testNodeDiagnosticLogSanitizesRotatesAndUsesPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("okvideo-node-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appendingPathComponent("node.log")
        try Data("Authorization: Bearer legacy-secret\n".utf8).write(to: logURL)

        let writer = NodeDiagnosticLogWriter(
            logURL: logURL,
            maximumBytes: 1_024,
            retainedFileCount: 2
        )
        for index in 0..<80 {
            writer.writeNodeOutput(Data(
                "token=secret-\(index) /Users/alice/private \(String(repeating: "x", count: 80))\n".utf8
            ))
        }
        writer.writeNodeOutput(Data(
            #"{"req":{"method":"GET","url":"/proxy/quark?pst=signed-url-cookie-token"},"msg":"GET http://127.0.0.1:18988/proxy/quark?pst=another-secret"}"#.utf8
        ))
        writer.writeNodeOutput(Data("\n".utf8))
        writer.close()

        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("node.log") }
        XCTAssertLessThanOrEqual(files.count, 3)
        let combined = try files.map { try String(contentsOf: $0) }.joined()
        XCTAssertFalse(combined.contains("legacy-secret"))
        XCTAssertFalse(combined.contains("secret-"))
        XCTAssertFalse(combined.contains("signed-url-cookie-token"))
        XCTAssertFalse(combined.contains("another-secret"))
        XCTAssertFalse(combined.contains("pst="))
        XCTAssertTrue(combined.contains("/proxy/quark?<redacted>"))
        XCTAssertFalse(combined.contains("alice"))
        XCTAssertTrue(combined.contains("<HOME>"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: logURL.path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testRuntimeInitializationPurgesLogsFromAllLegacyCacheKeysOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("okvideo-node-root-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support")
        let cache = root.appendingPathComponent("Caches")
        let runtimeRoot = support.appendingPathComponent("NodeRuntime")
        for key in ["old-a", "old-b"] {
            let directory = runtimeRoot.appendingPathComponent(key)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data("token=legacy-secret".utf8).write(
                to: directory.appendingPathComponent("node.log")
            )
            try Data("rotated-secret".utf8).write(
                to: directory.appendingPathComponent("node.log.1")
            )
        }

        _ = NodeBundleRuntimeService(
            applicationSupportDirectory: support,
            cacheDirectory: cache,
            remoteHTTPClient: NodeProviderStubHTTPClient { _ in
                throw HTTPClientError.transport("offline")
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: runtimeRoot.appendingPathComponent("diagnostics-v2.marker").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtimeRoot.appendingPathComponent("old-a/node.log").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtimeRoot.appendingPathComponent("old-b/node.log.1").path
        ))
    }

    func testNodeReleaseErrorPresentationNeverLeaksTechnicalDetails() throws {
        let rawURL = try XCTUnwrap(URL(
            string: "http://user:secret@example.invalid/index.js?token=value"
        ))
        let presentation = try XCTUnwrap(
            NodeUserFacingErrorMapper.presentation(
                for: NodeBundleRuntimeError.missingTrustedSHA256(finalURL: rawURL)
            )
        )

        XCTAssertEqual(presentation.title, "Node 安全校验失败")
        XCTAssertFalse(presentation.message.contains("http"))
        XCTAssertFalse(presentation.message.contains("secret"))
        XCTAssertFalse(presentation.message.contains("SHA-256"))
    }

    func testIntentionalStopPublishesStoppedAndDoesNotRestart() async throws {
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(fixture: fixture)

        await service.stop()

        let status = await service.currentStatus()
        XCTAssertEqual(status, .stopped)
    }

    func testSharedRuntimeStartupCompletesImmediateOperationsWithoutRace() async throws {
        let startup = SharedNodeRuntimeStartup<Int>()

        for expected in 0..<100 {
            let value = try await startup.run(sessionID: UUID()) { expected }
            XCTAssertEqual(value, expected)
        }
    }

    func testConcurrentRuntimeCallersJoinExactlyOneStartup() async throws {
        let startup = SharedNodeRuntimeStartup<Int>()
        let sessionID = UUID()
        let gate = NodeReadinessTestGate()
        let counter = NodeReadinessTestCounter()

        let callers = (0..<3).map { _ in
            Task {
                try await startup.run(sessionID: sessionID) {
                    await counter.increment()
                    await gate.wait()
                    return 42
                }
            }
        }
        let didStart = await waitUntil { await counter.value == 1 }
        XCTAssertTrue(didStart)
        var startupCount = await counter.value
        XCTAssertEqual(startupCount, 1)

        await gate.open()
        for caller in callers {
            let value = try await caller.value
            XCTAssertEqual(value, 42)
        }
        startupCount = await counter.value
        XCTAssertEqual(startupCount, 1)
    }

    func testCallerCancellationDoesNotCancelSharedRuntimeStartup() async throws {
        let startup = SharedNodeRuntimeStartup<Int>()
        let sessionID = UUID()
        let gate = NodeReadinessTestGate()
        let counter = NodeReadinessTestCounter()
        let sharedOperation: @Sendable () async throws -> Int = {
            await counter.increment()
            await gate.wait()
            try Task.checkCancellation()
            return 7
        }
        let cancelledCaller = Task {
            try await startup.run(
                sessionID: sessionID,
                sharedOperation
            )
        }
        let survivingCaller = Task {
            try await startup.run(
                sessionID: sessionID,
                sharedOperation
            )
        }
        let didStart = await waitUntil { await counter.value == 1 }
        XCTAssertTrue(didStart)

        cancelledCaller.cancel()
        do {
            _ = try await cancelledCaller.value
            XCTFail("被取消的 caller 不应继续")
        } catch is CancellationError {
            // Expected: only this waiter is cancelled.
        }
        var startupCount = await counter.value
        XCTAssertEqual(startupCount, 1)

        await gate.open()
        let survivingValue = try await survivingCaller.value
        XCTAssertEqual(survivingValue, 7)
        startupCount = await counter.value
        XCTAssertEqual(startupCount, 1)
    }

    func testFailedSharedRuntimeStartupAllowsControlledRetry() async throws {
        enum FixtureFailure: Error { case firstAttempt }
        let startup = SharedNodeRuntimeStartup<Int>()
        let counter = NodeReadinessTestCounter()

        do {
            _ = try await startup.run(sessionID: UUID()) {
                await counter.increment()
                throw FixtureFailure.firstAttempt
            }
            XCTFail("首次 startup 应失败")
        } catch FixtureFailure.firstAttempt {
            // Expected.
        }

        let value = try await startup.run(sessionID: UUID()) {
            await counter.increment()
            return 9
        }
        XCTAssertEqual(value, 9)
        let startupCount = await counter.value
        XCTAssertEqual(startupCount, 2)
    }

    func testNodeBusinessRequestWaitsForReadinessAndUsesReadyEndpoint() async throws {
        let gate = NodeReadinessTestGate()
        let readinessCalls = NodeReadinessTestCounter()
        let client = NodeReadinessRecordingHTTPClient()
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18001/"))
        let readyURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18002/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: SiteConfiguration(
                key: "nodejs_readiness_fixture",
                name: "Readiness Fixture",
                type: 3,
                api: "/spider/readiness/3",
                extra: ["okNodeRuntime": .bool(true)]
            ),
            baseURL: initialURL,
            httpClient: client,
            ensureRuntimeReady: {
                await readinessCalls.increment()
                await gate.wait()
                return readyURL
            }
        )

        let request = Task { try await provider.home() }
        let reachedBarrier = await waitUntil { await readinessCalls.value == 1 }
        XCTAssertTrue(reachedBarrier)
        var requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)

        await gate.open()
        _ = try await request.value
        requestCount = await client.requestCount
        let lastPort = await client.lastURL?.port
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(lastPort, 18_002)
    }

    func testRuntimeWaitsForHealthSharesOneProcessAndUsesReadyFastPath() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(nodeReadinessFixtureScript(startDelayMilliseconds: 250).utf8)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let node = try testNodeExecutableURL()
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: node,
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        let endpoints: [URL]
        do {
            endpoints = try await withThrowingTaskGroup(of: URL.self) { group in
                for _ in 0..<3 {
                    group.addTask {
                        try await service.ensureReady(from: fixture.sourceURL)
                    }
                }
                var values: [URL] = []
                for try await endpoint in group {
                    values.append(endpoint)
                }
                return values
            }
        } catch {
            let log = (try? runtimeLog(fixture: fixture)) ?? "<missing log>"
            XCTFail("runtime startup failed: \(error)\n\(log)")
            await service.stop()
            return
        }
        XCTAssertEqual(Set(endpoints).count, 1)
        let status = await service.currentStatus()
        XCTAssertEqual(status, .running(try XCTUnwrap(endpoints.first)))

        let warmStart = Date()
        let warmEndpoint = try await service.ensureReady(from: fixture.sourceURL)
        let warmElapsed = Date().timeIntervalSince(warmStart)
        XCTAssertEqual(warmEndpoint, endpoints.first)
        XCTAssertLessThan(warmElapsed, 0.1)

        let log = try runtimeLog(fixture: fixture)
        XCTAssertEqual(log.components(separatedBy: "Bundled Node process launched").count - 1, 1)
        XCTAssertTrue(log.contains("NODE_RUNTIME_STARTUP_JOINED"))
        XCTAssertTrue(log.contains("NODE_RUNTIME_READY"))
        await service.stop()
    }

    func testReadinessTimeoutExitsStartingAndSubsequentRequestRetries() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(nodeReadinessFixtureScript(startDelayMilliseconds: 2_000).utf8)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 0.15,
            readinessPollInterval: 0.01
        )

        for _ in 0..<2 {
            do {
                _ = try await service.ensureReady(from: fixture.sourceURL)
                XCTFail("永不在 deadline 前 ready 的 runtime 应超时")
            } catch {
                guard case .failed = await service.currentStatus() else {
                    return XCTFail("失败后 runtime 不应停留在 starting")
                }
            }
        }

        let log = try runtimeLog(fixture: fixture)
        XCTAssertEqual(log.components(separatedBy: "Bundled Node process launched").count - 1, 2)
        await service.stop()
    }

    func testRuntimeDeathInvalidatesEndpointAndNextRequestRecovers() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(nodeReadinessFixtureScript(startDelayMilliseconds: 0).utf8)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )
        let first: URL
        do {
            first = try await service.ensureReady(from: fixture.sourceURL)
        } catch {
            let log = (try? runtimeLog(fixture: fixture)) ?? "<missing log>"
            XCTFail("runtime startup failed: \(error)\n\(log)")
            await service.stop()
            return
        }
        _ = try? await URLSession.shared.data(
            from: first.appendingPathComponent("exit")
        )
        let invalidated = await waitUntil {
            let status = await service.currentStatus()
            if case .restarting = status { return true }
            return false
        }
        XCTAssertTrue(invalidated)

        let recovered = try await service.ensureReady(from: fixture.sourceURL)
        XCTAssertNotEqual(recovered, first)
        let log = try runtimeLog(fixture: fixture)
        XCTAssertTrue(log.contains("NODE_RUNTIME_ENDPOINT_INVALIDATED"))
        XCTAssertEqual(log.components(separatedBy: "Bundled Node process launched").count - 1, 2)
        await service.stop()
    }

    func testNodeSpawnFailurePublishesFailedAndCanBeRetried() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(nodeReadinessFixtureScript(startDelayMilliseconds: 0).utf8)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missingExecutable = fixture.root.appendingPathComponent("missing-node")
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: missingExecutable,
            readinessTimeout: 0.2,
            readinessPollInterval: 0.01
        )

        for _ in 0..<2 {
            do {
                _ = try await service.ensureReady(from: fixture.sourceURL)
                XCTFail("无效 executable 不应启动成功")
            } catch {
                guard case .failed = await service.currentStatus() else {
                    return XCTFail("spawn failure 后 runtime 不应停在 starting")
                }
            }
        }
        await service.stop()
    }

    func testNodeExitBeforeHealthPublishesFailedWithoutStickingInStarting() async throws {
        let script = Data(
            "module.exports={start(){process.exit(9)},stop(){}};".utf8
        )
        let fixture = try makeLegacyCacheFixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 1,
            readinessPollInterval: 0.01
        )

        do {
            _ = try await service.ensureReady(from: fixture.sourceURL)
            XCTFail("health ready 前退出的 Node 不应被发布为 ready")
        } catch {
            let status = await service.currentStatus()
            guard case .failed = status else {
                return XCTFail("early exit 后 runtime 不应停留在 starting")
            }
        }
        await service.stop()
    }

    func testContractBStartPromiseDoesNotPublishReadyBeforeLoopbackListener() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(
                    startDelayMilliseconds: 250,
                    startsAuxiliaryListener: true
                ).utf8
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        let startedAt = Date()
        let endpoint: URL
        do {
            endpoint = try await service.ensureReady(from: fixture.sourceURL)
        } catch {
            let log = (try? runtimeLog(fixture: fixture)) ?? "<missing log>"
            XCTFail("Contract B fixture failed: \(error)\n\(log)")
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThanOrEqual(elapsed, 0.20)
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertNotEqual(endpoint.port, 9_988)
        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let stateURL = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeRuntime")
            .appendingPathComponent(descriptor.cacheKey)
            .appendingPathComponent("contract-b-state.json")
        let state = try XCTUnwrap(ContractBListenerState.readValidated(from: stateURL))
        XCTAssertEqual(state.host, "127.0.0.1")
        XCTAssertEqual(state.port, endpoint.port)

        let (configurationData, _) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("config")
        )
        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(
            configurationData
        )
        let configuration = try ConfigurationParser().parse(normalized)
        XCTAssertEqual(configuration.sites.first?.key, "nodejs_contract_b")

        let (auxiliaryData, _) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("auxiliary")
        )
        let auxiliaryAddress = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: auxiliaryData)
                as? [String: Any]
        )
        XCTAssertEqual(auxiliaryAddress["address"] as? String, "127.0.0.1")
        XCTAssertGreaterThan(auxiliaryAddress["port"] as? Int ?? 0, 0)

        let log = try runtimeLog(fixture: fixture)
        XCTAssertTrue(log.contains("NODE_RUNTIME_CONTRACT_DETECTED"))
        XCTAssertTrue(log.contains("NODE_RUNTIME_HOST_ADAPTER_READY"))
        XCTAssertTrue(log.contains("NODE_RUNTIME_LISTENER_OBSERVED"))
        XCTAssertTrue(log.contains("NODE_RUNTIME_CAPABILITY_VALIDATED"))
        await service.stop()
    }

    func testContractBBridgesOwnedInternalWebviewActionOnTheBusinessResponse() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        let endpoint: URL
        do {
            endpoint = try await service.ensureReady(from: fixture.sourceURL)
        } catch {
            let log = (try? runtimeLog(fixture: fixture)) ?? "<missing log>"
            XCTFail("Contract B host action fixture failed: \(error)\n\(log)")
            return
        }
        var request = URLRequest(
            url: endpoint.appendingPathComponent("host-action")
        )
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let encoded = try XCTUnwrap(
            http.value(forHTTPHeaderField: "X-OKVideo-Host-Message")
        )
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let options = try XCTUnwrap(object["opt"] as? [String: Any])
        let url = try XCTUnwrap(URL(string: options["url"] as? String ?? ""))

        XCTAssertEqual(object["action"] as? String, "openInternalWebview")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, endpoint.port)
        XCTAssertEqual(url.path, "/website")
        await service.stop()
    }

    func testContractBQueuesLateHostActionByInvocationID() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )
        let endpoint = try await service.ensureReady(from: fixture.sourceURL)
        let invocationID = UUID().uuidString.lowercased()
        var request = URLRequest(
            url: endpoint.appendingPathComponent("late-host-action")
        )
        request.httpMethod = "POST"
        request.setValue(invocationID, forHTTPHeaderField: "X-OKVideo-Invocation-ID")
        let (_, response) = try await URLSession.shared.data(for: request)
        let businessResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertNil(
            businessResponse.value(forHTTPHeaderField: "X-OKVideo-Host-Message")
        )

        var pollComponents = URLComponents(
            url: endpoint.appendingPathComponent(
                "__okvideo/host-message/\(invocationID)"
            ),
            resolvingAgainstBaseURL: false
        )
        pollComponents?.queryItems = [URLQueryItem(name: "wait", value: "1000")]
        let pollURL = try XCTUnwrap(pollComponents?.url)
        let (messageData, pollResponse) = try await URLSession.shared.data(from: pollURL)
        XCTAssertEqual((pollResponse as? HTTPURLResponse)?.statusCode, 200)
        let message = try XCTUnwrap(
            JSONSerialization.jsonObject(with: messageData) as? [String: Any]
        )
        XCTAssertEqual(message["action"] as? String, "openInternalWebview")
        await service.stop()
    }

    func testContractBDoesNotCrossWireConcurrentHostActions() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )
        let endpoint = try await service.ensureReady(from: fixture.sourceURL)
        let invocations = [
            "first": UUID().uuidString.lowercased(),
            "second": UUID().uuidString.lowercased()
        ]

        func invoke(marker: String) async throws {
            var components = URLComponents(
                url: endpoint.appendingPathComponent(
                    "late-host-action-concurrent"
                ),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "marker", value: marker)]
            var request = URLRequest(url: try XCTUnwrap(components?.url))
            request.httpMethod = "POST"
            request.setValue(
                try XCTUnwrap(invocations[marker]),
                forHTTPHeaderField: "X-OKVideo-Invocation-ID"
            )
            _ = try await URLSession.shared.data(for: request)
        }

        async let firstInvocation: Void = invoke(marker: "first")
        async let secondInvocation: Void = invoke(marker: "second")
        _ = try await (firstInvocation, secondInvocation)

        for marker in ["first", "second"] {
            var components = URLComponents(
                url: endpoint.appendingPathComponent(
                    "__okvideo/host-message/\(try XCTUnwrap(invocations[marker]))"
                ),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "wait", value: "1000")]
            let (data, response) = try await URLSession.shared.data(
                from: try XCTUnwrap(components?.url)
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let message = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let options = try XCTUnwrap(message["opt"] as? [String: Any])
            let url = try XCTUnwrap(URL(string: options["url"] as? String ?? ""))
            XCTAssertEqual(url.path, "/website/\(marker)")
        }
        await service.stop()
    }

    func testContractBProfileBridgePersistsAcrossRestartAndIsSourceBound() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8
            ),
            sourceFragment: "source=renamed-fixture&version=7"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        let firstEndpoint = try await service.ensureReady(from: fixture.sourceURL)
        let (writeData, writeResponse) = try await URLSession.shared.data(
            from: firstEndpoint.appendingPathComponent("profile-write")
        )
        XCTAssertEqual(
            (writeResponse as? HTTPURLResponse)?.statusCode,
            200
        )
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: writeData)
                as? [String: Bool])?["ok"],
            true
        )
        await service.stop()

        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let runtimeDirectory = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeRuntime")
            .appendingPathComponent(descriptor.cacheKey)
        let profileURL = runtimeDirectory.appendingPathComponent(
            "contract-b-profile.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL.path))

        let unrelatedURL = try XCTUnwrap(URL(
            string: "https://fixture.invalid/index.js.md5#source=another-source&version=7"
        ))
        let unrelatedDescriptor = try NodeBundleSourceDescriptor(
            url: unrelatedURL
        )
        XCTAssertNotEqual(descriptor.cacheKey, unrelatedDescriptor.cacheKey)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.applicationSupportDirectory
                .appendingPathComponent("NodeRuntime")
                .appendingPathComponent(unrelatedDescriptor.cacheKey)
                .appendingPathComponent("contract-b-profile.json")
                .path
        ))

        let secondEndpoint = try await service.ensureReady(from: fixture.sourceURL)
        let (readData, readResponse) = try await URLSession.shared.data(
            from: secondEndpoint.appendingPathComponent("profile-read")
        )
        XCTAssertEqual((readResponse as? HTTPURLResponse)?.statusCode, 200)
        let profile = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: readData)
                as? [String: String]
        )
        XCTAssertEqual(profile["marker"], "persisted")
        XCTAssertEqual(profile["privateValue"], "fixture-private")
        await service.stop()
    }

    func testContractAColdStartupMarkerScanMicrobenchmark() async throws {
        var startupMilliseconds: [Int] = []
        for _ in 0..<3 {
            let fixture = try makeLegacyCacheFixture(
                script: Data(
                    nodeReadinessFixtureScript(
                        startDelayMilliseconds: 0
                    ).utf8
                )
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let service = makeOfflineRuntime(
                fixture: fixture,
                nodeExecutableURL: try testNodeExecutableURL(),
                readinessTimeout: 5,
                readinessPollInterval: 0.02
            )

            let startedAt = Date()
            let endpoint = try await service.ensureReady(from: fixture.sourceURL)
            startupMilliseconds.append(
                Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
            XCTAssertEqual(endpoint.host, "127.0.0.1")
            await service.stop()
        }

        let sorted = startupMilliseconds.sorted()
        let minimum = try XCTUnwrap(sorted.first)
        let maximum = try XCTUnwrap(sorted.last)
        let median = sorted[sorted.count / 2]
        let runs = startupMilliseconds.map { String($0) }.joined(separator: ",")
        let report = "CONTRACT_A_COLD_STARTUP_MS runs=\(runs) min=\(minimum) median=\(median) max=\(maximum)"
        print(report)
    }

    func testContractBUsesVerifiedNativeResponseSemanticsWithoutResponseGuard() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(nodeContractBFixtureScript(
                startDelayMilliseconds: 0,
                emitsLateSecondWrite: true
            ).utf8)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        let endpoint = try await service.ensureReady(from: fixture.sourceURL)
        let (configurationData, _) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("config")
        )
        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(
            configurationData
        )
        XCTAssertNoThrow(try ConfigurationParser().parse(normalized))
        guard case .running = await service.currentStatus() else {
            return XCTFail("宿主已证明的 route rejection 后进程应保持运行")
        }

        let rejectionWasObserved = await waitUntil {
            ((try? self.runtimeLog(fixture: fixture)) ?? "")
                .contains("CONTRACT_B_UNHANDLED_REJECTION")
        }
        XCTAssertTrue(rejectionWasObserved)
        await service.stop()
    }

    func testContractBReadinessTimeoutDoesNotTreatResolvedStartAsReady() async throws {
        let script = #"""
        'use strict';
        void catServerFactory;
        void catDartServerPort;
        void process.env.DEV_HTTP_PORT;
        module.exports = { start(config) { return Promise.resolve(config); }, stop() {} };
        """#
        let fixture = try makeLegacyCacheFixture(script: Data(script.utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 0.2,
            readinessPollInterval: 0.01
        )

        do {
            _ = try await service.ensureReady(from: fixture.sourceURL)
            XCTFail("listener 和 capability 未就绪时不得发布 Ready")
        } catch {
            XCTAssertEqual(
                error as? NodeBundleRuntimeError,
                .contractBReadinessFailed
            )
        }
        await service.stop()
    }

    func testContractBProcessExitBeforeReadyIsFailure() async throws {
        let script = #"""
        'use strict';
        void catServerFactory;
        void catDartServerPort;
        void process.env.DEV_HTTP_PORT;
        module.exports = { start(config) { process.exit(12); }, stop() {} };
        """#
        let fixture = try makeLegacyCacheFixture(script: Data(script.utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 1,
            readinessPollInterval: 0.01
        )

        do {
            _ = try await service.ensureReady(from: fixture.sourceURL)
            XCTFail("提前退出的 Contract B 不得发布 Ready")
        } catch {
            guard case .failed = await service.currentStatus() else {
                return XCTFail("early exit 后状态必须是 failed")
            }
        }
        await service.stop()
    }

    func testContractBStopRestartClosesOldListenerAndAllocatesFreshEndpoint() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        let first = try await service.ensureReady(from: fixture.sourceURL)
        await service.stop()
        let stopped = await waitUntil {
            do {
                _ = try await URLSession.shared.data(
                    from: first.appendingPathComponent("config")
                )
                return false
            } catch {
                return true
            }
        }
        XCTAssertTrue(stopped)
        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let runtimeDirectory = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeRuntime")
            .appendingPathComponent(descriptor.cacheKey)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtimeDirectory.appendingPathComponent(
                "contract-b-config.json"
            ).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtimeDirectory.appendingPathComponent(
                "contract-b-state.json"
            ).path
        ))

        let second = try await service.ensureReady(from: fixture.sourceURL)
        XCTAssertEqual(second.host, "127.0.0.1")
        XCTAssertNotEqual(second.port, 9_988)
        await service.stop()
    }

    func testContractBConcurrentRuntimesUseDistinctLoopbackPorts() async throws {
        let script = Data(nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8)
        let firstFixture = try makeLegacyCacheFixture(script: script)
        let secondFixture = try makeLegacyCacheFixture(script: script)
        defer {
            try? FileManager.default.removeItem(at: firstFixture.root)
            try? FileManager.default.removeItem(at: secondFixture.root)
        }
        let executable = try testNodeExecutableURL()
        let firstService = makeOfflineRuntime(
            fixture: firstFixture,
            nodeExecutableURL: executable,
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )
        let secondService = makeOfflineRuntime(
            fixture: secondFixture,
            nodeExecutableURL: executable,
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        async let first = firstService.ensureReady(from: firstFixture.sourceURL)
        async let second = secondService.ensureReady(from: secondFixture.sourceURL)
        let endpoints = try await [first, second]

        XCTAssertEqual(endpoints[0].host, "127.0.0.1")
        XCTAssertEqual(endpoints[1].host, "127.0.0.1")
        XCTAssertNotEqual(endpoints[0].port, endpoints[1].port)
        await firstService.stop()
        await secondService.stop()
    }

    func testContractBErrorPresentationIsSpecificAndRedacted() {
        let unsupported = NodeUserFacingErrorMapper.presentation(
            for: NodeBundleRuntimeError.unsupportedHostContract
        )
        let invalidConfig = NodeUserFacingErrorMapper.presentation(
            for: NodeBundleRuntimeError.configurationContractInvalid
        )

        XCTAssertEqual(unsupported?.title, "Node 兼容模式不受支持")
        XCTAssertEqual(invalidConfig?.title, "Node 源配置无效")
        XCTAssertFalse(unsupported?.message.contains("catServerFactory") ?? true)
        XCTAssertFalse(invalidConfig?.message.contains("sites") ?? true)
    }

    func testRealContractBSamplesFromEnvironment() async throws {
        guard let specification = ProcessInfo.processInfo.environment[
            "OKVIDEO_CONTRACT_B_REAL_SAMPLES"
        ], !specification.isEmpty else {
            throw XCTSkip("Real Contract B samples were not supplied")
        }
        let samples = specification.split(separator: ";").map {
            $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        }
        XCTAssertGreaterThanOrEqual(samples.count, 2)

        for fields in samples {
            XCTAssertTrue((4...5).contains(fields.count))
            guard (4...5).contains(fields.count) else { continue }
            let name = fields[0]
            let script = try Data(contentsOf: URL(fileURLWithPath: fields[1]))
            XCTAssertEqual(NodeBundleRuntimeService.md5Hex(script), fields[2], name)
            XCTAssertEqual(NodeBundleRuntimeService.sha256Hex(script), fields[3], name)
            let fixture = try makeLegacyCacheFixture(script: script)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let service = makeOfflineRuntime(
                fixture: fixture,
                nodeExecutableURL: try testNodeExecutableURL(),
                readinessTimeout: 10,
                readinessPollInterval: 0.05
            )
            var validationStage = "runtime"
            var observedEndpointPort: Int?
            do {
                let runtimeStartedAt = Date()
                let endpoint = try await service.ensureReady(from: fixture.sourceURL)
                let runtimeReadyMilliseconds = Int(
                    Date().timeIntervalSince(runtimeStartedAt) * 1_000
                )
                XCTAssertEqual(endpoint.host, "127.0.0.1", name)
                XCTAssertNotEqual(endpoint.port, 9_988, name)
                validationStage = "config"
                let configurationStartedAt = Date()
                let (configurationData, _) = try await URLSession.shared.data(
                    from: endpoint.appendingPathComponent("config")
                )
                let normalized = try NodeBundleRuntimeService.normalizeConfiguration(
                    configurationData
                )
                let parsed = try ConfigurationParser().parse(normalized)
                let configurationMilliseconds = Int(
                    Date().timeIntervalSince(configurationStartedAt) * 1_000
                )
                XCTAssertFalse(parsed.sites.isEmpty, name)
                let endpointPort = try XCTUnwrap(endpoint.port)
                observedEndpointPort = endpointPort
                let listeners = try systemListeners(on: endpointPort)
                XCTAssertTrue(listeners.contains("127.0.0.1:"), "\(name): \(listeners)")
                XCTAssertFalse(listeners.contains("*:\(endpointPort)"), "\(name): \(listeners)")
                print(
                    "REAL_SAMPLE_DISCOVERY name=\(name) "
                        + "runtime_ready_ms=\(runtimeReadyMilliseconds) "
                        + "config_ms=\(configurationMilliseconds) "
                        + "sites=\(parsed.sites.map(\.key).joined(separator: ","))"
                )

                if fields.count == 5, !fields[4].isEmpty {
                    validationStage = "site-selection"
                    let site = try XCTUnwrap(
                        parsed.sites.first(where: { $0.key == fields[4] })
                    )
                    var boundedSite = site
                    boundedSite.timeout = min(site.timeout ?? 15, 15)
                    let clientConfiguration = URLSessionConfiguration.ephemeral
                    clientConfiguration.connectionProxyDictionary = [:]
                    let provider = try NodeHTTPSpiderSiteProvider(
                        site: boundedSite,
                        baseURL: endpoint,
                        httpClient: URLSessionHTTPClient(
                            configuration: clientConfiguration
                        ),
                        ensureRuntimeReady: { endpoint }
                    )
                    validationStage = "home"
                    let homeStartedAt = Date()
                    let home = try await provider.home()
                    let homeMilliseconds = Int(
                        Date().timeIntervalSince(homeStartedAt) * 1_000
                    )
                    guard !home.categories.isEmpty else {
                        throw AppError.spider("\(name) home returned no categories")
                    }
                    validationStage = "category"
                    let categoryStartedAt = Date()
                    var selectedCategoryPage: VideoPage?
                    for category in home.categories.prefix(5) {
                        let page = try await provider.category(
                            id: category.id,
                            page: 1,
                            filters: [:]
                        )
                        if !page.items.isEmpty {
                            selectedCategoryPage = page
                            break
                        }
                    }
                    let categoryMilliseconds = Int(
                        Date().timeIntervalSince(categoryStartedAt) * 1_000
                    )
                    guard let categoryPage = selectedCategoryPage else {
                        throw AppError.spider(
                            "\(name) first five categories returned no items"
                        )
                    }
                    let seed = try XCTUnwrap(
                        home.recommendations.first ?? categoryPage.items.first
                    )
                    var summary = seed
                    var searchMilliseconds = 0
                    if boundedSite.searchable == 1 {
                        validationStage = "search"
                        let searchStartedAt = Date()
                        let search = try await provider.search(
                            keyword: seed.title,
                            page: 1,
                            quick: false
                        )
                        searchMilliseconds = Int(
                            Date().timeIntervalSince(searchStartedAt) * 1_000
                        )
                        guard let searchSummary = search.items.first else {
                            throw AppError.spider("\(name) search returned no items")
                        }
                        summary = searchSummary
                    }
                    validationStage = "detail"
                    let detailStartedAt = Date()
                    let detail = try await provider.detail(id: summary.videoID)
                    let detailMilliseconds = Int(
                        Date().timeIntervalSince(detailStartedAt) * 1_000
                    )
                    let source = try XCTUnwrap(detail.playSources.first)
                    let episode = try XCTUnwrap(source.episodes.first)
                    validationStage = "play"
                    let playStartedAt = Date()
                    let playback = try await provider.player(
                        flag: source.name,
                        episodeURL: episode.url
                    )
                    let playMilliseconds = Int(
                        Date().timeIntervalSince(playStartedAt) * 1_000
                    )
                    XCTAssertFalse(playback.url.isEmpty, "\(name) play")
                    let playbackURL = try XCTUnwrap(URL(string: playback.url))
                    XCTAssertTrue(
                        ["http", "https"].contains(
                            playbackURL.scheme?.lowercased() ?? ""
                        ),
                        "\(name) play must remain actionable by the player"
                    )
                    print(
                        "REAL_SAMPLE_BUSINESS_TIMING name=\(name) "
                            + "home_ms=\(homeMilliseconds) "
                            + "category_ms=\(categoryMilliseconds) "
                            + "search_ms=\(searchMilliseconds) "
                            + "detail_ms=\(detailMilliseconds) "
                            + "play_ms=\(playMilliseconds)"
                    )
                }
                print(
                    "REAL_SAMPLE_RESULT name=\(name) loopback=PASS "
                        + "config=PASS business=\(fields.count == 5 ? "PASS" : "NOT_REQUESTED")"
                )
            } catch {
                XCTFail("\(name) stage=\(validationStage) failed: \(error)")
            }
            await service.stop()
            if let observedEndpointPort {
                let listenersAfterStop = try systemListeners(
                    on: observedEndpointPort
                )
                XCTAssertTrue(
                    listenersAfterStop.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    "\(name) old listener must close"
                )
            }
            let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
            let runtimeDirectory = fixture.applicationSupportDirectory
                .appendingPathComponent("NodeRuntime")
                .appendingPathComponent(descriptor.cacheKey)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: runtimeDirectory.appendingPathComponent(
                    "contract-b-config.json"
                ).path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: runtimeDirectory.appendingPathComponent(
                    "contract-b-state.json"
                ).path
            ))
            let stoppedStatus = await service.currentStatus()
            XCTAssertEqual(stoppedStatus, .stopped)
            print(
                "REAL_SAMPLE_CLEANUP name=\(name) process=STOPPED "
                    + "listener=CLOSED temporary_files=REMOVED"
            )
        }
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<20_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return false
    }

    private func systemListeners(on port: Int) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    }

    private func testNodeExecutableURL() throws -> URL {
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("NodeRuntime")
                .appendingPathComponent("node"),
            URL(fileURLWithPath: "/opt/homebrew/opt/node@22-direct/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node")
        ].compactMap { $0 }
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("Node runtime executable is unavailable")
        }
        return executable
    }

    private func runtimeLog(fixture: LegacyCacheFixture) throws -> String {
        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let logURL = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeRuntime")
            .appendingPathComponent(descriptor.cacheKey)
            .appendingPathComponent("node.log")
        return try String(contentsOf: logURL, encoding: .utf8)
    }

    private func nodeReadinessFixtureScript(
        startDelayMilliseconds: Int
    ) -> String {
        #"""
        'use strict';
        const http = require('http');
        let server = null;
        module.exports = {
          start() {
            return new Promise((resolve) => {
              setTimeout(() => {
                server = http.createServer((request, response) => {
                  response.setHeader('Content-Type', 'application/json');
                  if (request.url === '/health') {
                    response.end(JSON.stringify({ok: true, name: 'CatVodSpiderios'}));
                  } else if (request.url === '/config') {
                    response.end(JSON.stringify({sites: []}));
                  } else if (request.url === '/exit') {
                    response.end(JSON.stringify({ok: true}));
                    setImmediate(() => process.exit(7));
                  } else {
                    response.statusCode = 404;
                    response.end(JSON.stringify({error: 'fixture-not-found'}));
                  }
                });
                server.listen(0, '127.0.0.1', () => {
                  console.log(`fixture listening http://127.0.0.1:${server.address().port}`);
                  resolve();
                });
              }, \#(startDelayMilliseconds));
            });
          },
          stop() {
            return new Promise((resolve) => server ? server.close(resolve) : resolve());
          }
        };
        """#
    }

    private func nodeContractBFixtureScript(
        startDelayMilliseconds: Int,
        emitsLateSecondWrite: Bool = false,
        startsAuxiliaryListener: Bool = false
    ) -> String {
        #"""
        'use strict';
        let server = null;
        let auxiliary = null;
        module.exports = {
          start(config) {
            if (!config || !config.sites || !Array.isArray(config.sites.list) ||
                !config.pans || !Array.isArray(config.pans.list)) {
              throw new Error('invalid fixture config');
            }
            if (catDartServerPort() !== Number(process.env.DEV_HTTP_PORT)) {
              throw new Error('unexpected Dart bridge port');
            }
            if (\#(startsAuxiliaryListener ? "true" : "false")) {
              auxiliary = require('http').createServer((request, response) => {
                response.end('auxiliary');
              });
              auxiliary.listen({port: 0, host: '0.0.0.0'});
            }
            setTimeout(() => {
              server = catServerFactory((request, response) => {
                response.setHeader('Content-Type', 'application/json');
                if (request.url === '/config') {
                  response.end(JSON.stringify({video:{sites:[{key:'nodejs_contract_b',name:'Contract B',type:3,api:'/spider/contract_b/3'}]}}));
                  if (\#(emitsLateSecondWrite ? "true" : "false")) {
                    Promise.resolve().then(() => {
                      response.writeHead(200, {'Content-Type':'application/json'});
                      response.end('{}');
                    });
                  }
                } else if (request.url === '/spider/contract_b/3/home') {
                  response.end(JSON.stringify({class:[],list:[]}));
                } else if (request.url === '/auxiliary') {
                  response.end(JSON.stringify(auxiliary && auxiliary.address()));
                } else if (request.url === '/host-action') {
                  const hostPort = catDartServerPort();
                  fetch(`http://127.0.0.1:${hostPort}/msg`, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({
                      action: 'openInternalWebview',
                      opt: {url: `http://192.168.1.88:${hostPort}/website`}
                    })
                  }).then(() => response.end(JSON.stringify({ok:true})))
                    .catch(() => {
                      response.statusCode = 500;
                      response.end(JSON.stringify({ok:false}));
                    });
                } else if (request.url.startsWith('/late-host-action-concurrent?')) {
                  const hostPort = catDartServerPort();
                  const marker = new URL(
                    request.url,
                    'http://127.0.0.1'
                  ).searchParams.get('marker');
                  response.end(JSON.stringify({ok:true}));
                  setTimeout(() => {
                    const payload = JSON.stringify({
                      action: 'openInternalWebview',
                      opt: {url: `http://127.0.0.1:${hostPort}/website/${marker}`}
                    });
                    const messageRequest = require('http').request({
                      hostname: '127.0.0.1',
                      port: hostPort,
                      path: '/msg',
                      method: 'POST',
                      headers: {
                        'Content-Type':'application/json',
                        'Content-Length':Buffer.byteLength(payload)
                      }
                    });
                    messageRequest.on('error', () => {});
                    messageRequest.end(payload);
                  }, marker === 'first' ? 80 : 20);
                } else if (request.url === '/late-host-action') {
                  const hostPort = catDartServerPort();
                  response.end(JSON.stringify({ok:true}));
                  setTimeout(() => {
                    const payload = JSON.stringify({
                      action: 'openInternalWebview',
                      opt: {url: `http://127.0.0.1:${hostPort}/website`}
                    });
                    const messageRequest = require('http').request({
                      hostname: '127.0.0.1',
                      port: hostPort,
                      path: '/msg',
                      method: 'POST',
                      headers: {
                        'Content-Type':'application/json',
                        'Content-Length':Buffer.byteLength(payload)
                      }
                    });
                    messageRequest.on('error', () => {});
                    messageRequest.end(payload);
                  }, 50);
                } else if (request.url === '/profile-write') {
                  fetch(`http://127.0.0.1:${catDartServerPort()}/msg`, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({
                      action: 'saveProfile',
                      opt: {marker: 'persisted', privateValue: 'fixture-private'}
                    })
                  }).then(async (profileResponse) => {
                    response.statusCode = profileResponse.status;
                    response.end(await profileResponse.text());
                  }).catch(() => {
                    response.statusCode = 500;
                    response.end(JSON.stringify({ok:false}));
                  });
                } else if (request.url === '/profile-read') {
                  fetch(`http://127.0.0.1:${catDartServerPort()}/msg`, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({action: 'queryProfile'})
                  }).then(async (profileResponse) => {
                    response.statusCode = profileResponse.status;
                    response.end(await profileResponse.text());
                  }).catch(() => {
                    response.statusCode = 500;
                    response.end(JSON.stringify({ok:false}));
                  });
                } else {
                  response.statusCode = 404;
                  response.end(JSON.stringify({error:'fixture-not-found'}));
                }
              });
              server.listen({port: process.env.DEV_HTTP_PORT || 9988, host: '0.0.0.0'});
            }, \#(startDelayMilliseconds));
            return Promise.resolve();
          },
          stop() {
            const closing = [server, auxiliary]
              .filter((listener) => listener && listener.listening)
              .map((listener) => new Promise((resolve) => listener.close(resolve)));
            return Promise.all(closing);
          }
        };
        """#
    }

    private struct LegacyCacheFixture {
        let root: URL
        let applicationSupportDirectory: URL
        let cacheDirectory: URL
        let sourceURL: URL
        let script: Data
    }

    private func makeLegacyCacheFixture(
        checksum suppliedChecksum: String? = nil,
        script suppliedScript: Data? = nil,
        sourceFragment: String = "source=fixture&version=1"
    ) throws -> LegacyCacheFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("okvideo-node-migration-\(UUID().uuidString)")
        let support = root.appendingPathComponent("Application Support")
        let cache = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        let source = try XCTUnwrap(
            URL(string: "https://fixture.invalid/index.js.md5#\(sourceFragment)")
        )
        let descriptor = try NodeBundleSourceDescriptor(url: source)
        let legacy = cache
            .appendingPathComponent("NodeBundles")
            .appendingPathComponent(descriptor.legacyCacheKey)
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        let script = suppliedScript ?? Data("module.exports = {};".utf8)
        let checksum = suppliedChecksum ?? NodeBundleRuntimeService.md5Hex(script)
        try script.write(to: legacy.appendingPathComponent("index.js"))
        try Data(checksum.utf8).write(
            to: legacy.appendingPathComponent("index.js.md5")
        )
        return LegacyCacheFixture(
            root: root,
            applicationSupportDirectory: support,
            cacheDirectory: cache,
            sourceURL: source,
            script: script
        )
    }

    private func makeOfflineRuntime(
        fixture: LegacyCacheFixture,
        migrationCommitHook: (() throws -> Void)? = nil,
        nodeExecutableURL: URL? = nil,
        readinessTimeout: TimeInterval = 90,
        readinessPollInterval: TimeInterval = 0.1
    ) -> NodeBundleRuntimeService {
        NodeBundleRuntimeService(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            cacheDirectory: fixture.cacheDirectory,
            remoteHTTPClient: NodeProviderStubHTTPClient { _ in
                throw URLError(.notConnectedToInternet)
            },
            nodeExecutableURL: nodeExecutableURL,
            migrationCommitHook: migrationCommitHook,
            readinessTimeout: readinessTimeout,
            readinessPollInterval: readinessPollInterval
        )
    }

    func testNodeProviderUsesPOSTHomeWithoutAndroidCapability() async throws {
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 3,
            api: "/spider/fixture/3",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            XCTAssertEqual(request.method, .post)
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            if request.url.path.hasSuffix("/home") {
                let body = try XCTUnwrap(request.body)
                let object = try JSONDecoder().decode(JSONValue.self, from: body)
                XCTAssertEqual(object.objectValue?["filter"], .bool(true))
                return HTTPResponse(
                    url: request.url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        #"{"class":[{"type_id":"movie","type_name":"电影"}],"list":[{"vod_id":"1","vod_name":"测试影片"}]}"#
                            .utf8
                    )
                )
            }
            throw HTTPClientError.statusCode(404)
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client
        )

        let home = try await provider.home()

        XCTAssertEqual(provider.capability, .javaScriptSpider)
        XCTAssertEqual(home.categories.map(\.name), ["电影"])
        XCTAssertEqual(home.recommendations.map(\.title), ["测试影片"])
    }

    func testNodeProviderInitializesOnceBeforeConcurrentBusinessRequests() async throws {
        let client = NodeLifecycleRecordingHTTPClient(initStatusCode: 200)
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: baseURL,
            httpClient: client
        )

        async let first = provider.home()
        async let second = provider.home()
        _ = try await [first, second]

        let paths = await client.requestPaths()
        XCTAssertEqual(paths.filter { $0.hasSuffix("/init") }.count, 1)
        XCTAssertEqual(paths.first, "/spider/lifecycle/3/init")
        XCTAssertEqual(paths.filter { $0.hasSuffix("/home") }.count, 2)
    }

    func testNodeProviderReinitializesWhenRuntimeEndpointChanges() async throws {
        let firstURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let secondURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18989/"))
        let endpoint = NodeRuntimeEndpointBox(firstURL)
        let client = NodeLifecycleRecordingHTTPClient(initStatusCode: 200)
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: firstURL,
            httpClient: client,
            ensureRuntimeReady: { await endpoint.current() }
        )

        _ = try await provider.home()
        await endpoint.set(secondURL)
        _ = try await provider.home()

        let initializedPorts = await client.initializedPorts()
        XCTAssertEqual(initializedPorts, [18_988, 18_989])
    }

    func testNodeProviderKeepsContractACompatibleWhenInitIsAbsent() async throws {
        let client = NodeLifecycleRecordingHTTPClient(initStatusCode: 404)
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: baseURL,
            httpClient: client
        )

        let home = try await provider.home()

        XCTAssertEqual(home.categories.map(\.name), ["电影"])
        let initializedPorts = await client.initializedPorts()
        XCTAssertEqual(initializedPorts, [18_988])
    }

    func testNodeProviderDoesNotSwallowInitFailure() async throws {
        let client = NodeLifecycleRecordingHTTPClient(initStatusCode: 500)
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: baseURL,
            httpClient: client
        )

        do {
            _ = try await provider.home()
            XCTFail("init 失败后不得继续请求 home")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("init 失败"))
        }
        let paths = await client.requestPaths()
        XCTAssertEqual(paths.filter { $0.hasSuffix("/init") }.count, 2)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/home") })
    }

    func testNodeProviderSurfacesCloudLoginAsNativeWebAuthorization() async throws {
        let site = SiteConfiguration(
            key: "nodejs_mypan",
            name: "我的|网盘",
            type: 4,
            api: "/spider/mypan/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            XCTAssertTrue(request.allowsNonSuccessfulStatus)
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            return HTTPResponse(
                url: request.url,
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"error":"还没有配置百度网盘 Cookie，请先到配置中心登录"}"#.utf8
                )
            )
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client
        )

        do {
            _ = try await provider.category(
                id: "mine:baidu",
                page: 1,
                filters: [:]
            )
            XCTFail("应该进入 Node 授权中心")
        } catch let authorization as NodeWebAuthorizationRequired {
            XCTAssertEqual(
                authorization.websiteURL.absoluteString,
                "http://127.0.0.1:18988/website"
            )
            XCTAssertTrue(authorization.message.contains("百度网盘"))
        }
    }

    func testNodeProviderPresentsValidatedContractBInternalWebviewAction() async throws {
        let site = SiteConfiguration(
            key: "nodejs_generic_action",
            name: "Generic|Action",
            type: 4,
            api: "/spider/generic/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let hostMessage = Data(
            #"{"action":"openInternalWebview","opt":{"url":"http://127.0.0.1:18988/website"}}"#.utf8
        ).base64EncodedString()
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            XCTAssertTrue(request.url.path.hasSuffix("/detail"))
            let body = try XCTUnwrap(request.body)
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            XCTAssertEqual(
                value.objectValue?["id"],
                .string("arbitrary-action")
            )
            XCTAssertEqual(
                value.objectValue?["ids"],
                .array([.string("arbitrary-action")])
            )
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "X-OKVideo-Host-Message": hostMessage
                ],
                body: Data(#"{"list":[{"vod_name":"","vod_content":""}]}"#.utf8)
            )
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client
        )
        let action = SiteActionItem(
            siteKey: site.key,
            siteName: site.name,
            itemID: "arbitrary-action",
            title: "任意功能"
        )

        do {
            _ = try await provider.select(action: action)
            XCTFail("宿主内部页面操作应交给现有内置 Web 配置流程")
        } catch let authorization as NodeWebAuthorizationRequired {
            XCTAssertEqual(
                authorization.websiteURL.absoluteString,
                "http://127.0.0.1:18988/website"
            )
            XCTAssertEqual(authorization.title, "Generic Action")
        }
    }

    func testNodeProviderPresentsValidatedInternalWebviewReturnedByArbitraryCategory() async throws {
        let site = SiteConfiguration(
            key: "renamed_bundle_9f2a",
            name: "Unrelated Display Label",
            type: 4,
            api: "/spider/renamed/73",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let hostMessage = Data(
            #"{"action":"openInternalWebview","opt":{"url":"http://127.0.0.1:18988/website"}}"#.utf8
        ).base64EncodedString()
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            XCTAssertTrue(request.url.path.hasSuffix("/category"))
            let body = try XCTUnwrap(request.body)
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            XCTAssertEqual(value.objectValue?["id"], .string("category-4d1c"))
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "X-OKVideo-Host-Message": hostMessage
                ],
                body: Data(#"{"list":[],"page":1,"pagecount":1}"#.utf8)
            )
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client
        )

        do {
            _ = try await provider.category(
                id: "category-4d1c",
                page: 1,
                filters: [:]
            )
            XCTFail("分类响应中的宿主操作不能被映射成空内容页")
        } catch let authorization as NodeWebAuthorizationRequired {
            XCTAssertEqual(
                authorization.websiteURL.absoluteString,
                "http://127.0.0.1:18988/website"
            )
            XCTAssertEqual(authorization.title, "Unrelated Display Label")
        }
    }

    func testNodeActionCategoryPreservesArbitraryConfigurationCard() async throws {
        let site = SiteConfiguration(
            key: "renamed_bundle_action_page",
            name: "Unrelated Action Page",
            type: 4,
            api: "/spider/renamed/73",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            if request.url.path.contains("/__okvideo/host-message/") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 204,
                    headers: [:],
                    body: Data()
                )
            }
            XCTAssertTrue(request.url.path.hasSuffix("/category"))
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"list":[{"vod_id":"opaque-card","vod_name":"任意配置卡片","action":"configure"}],"page":1,"pagecount":1}"#.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let page = try await provider.actionCategory(
            id: "opaque-category",
            page: 1,
            filters: [:]
        )

        XCTAssertEqual(page.items.map(\.videoID), ["opaque-card"])
        XCTAssertEqual(page.items.first?.resolvedContentKind, .action)
    }

    func testNodePlayerMergesSiteAndResponseHeadersAndUsesPlayerValidation() async throws {
        let site = SiteConfiguration(
            key: "renamed_authenticated_source",
            name: "Authenticated Source",
            type: 4,
            api: "/spider/authenticated/4",
            header: [
                "User-Agent": "Site Agent",
                "Referer": "https://site.example/"
            ],
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"parse":0,"url":"https://media.example/movie.mp4","header":{"Referer":"https://response.example/","Cookie":"session=fixture"}}"#.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let result = try await provider.player(flag: "直链", episodeURL: "episode")

        XCTAssertEqual(result.headers["User-Agent"], "Site Agent")
        XCTAssertEqual(result.headers["Referer"], "https://response.example/")
        XCTAssertEqual(result.headers["Cookie"], "session=fixture")
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
    }

    func testNodeHomeDoesNotInferActionFromCategoryIdentifier() async throws {
        let site = SiteConfiguration(
            key: "nodejs_generic_fixture",
            name: "Generic Fixture",
            type: 4,
            api: "/spider/generic/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            XCTAssertTrue(
                request.url.path.hasSuffix("/home")
                    || request.url.path.hasSuffix("/homeVod")
            )
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"class":[{"type_id":"setting","type_name":"任意功能"}],"list":[{"vod_id":"arbitrary-action","vod_name":"任意卡片"}]}"#.utf8
                )
            )
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client
        )

        let home = try await provider.home()

        XCTAssertEqual(home.categories.map(\.id), ["setting"])
        XCTAssertEqual(home.categories.first?.resolvedContentKind, .media)
        XCTAssertEqual(home.recommendations.map(\.videoID), ["arbitrary-action"])
        XCTAssertTrue(home.actionItems.isEmpty)
    }

    func testNodePlayerRewritesRuntimeProxyToLoopback() async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let replayStore = NodePlaybackReplayMemoryStore()
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 4,
            api: "/spider/fixture/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"parse":0,"url":"http://192.168.1.9:18988/spider/fixture/4/proxy/media?id=1"}"#.utf8
                )
            )
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client,
            playbackReplayStore: replayStore,
            configurationIdentity: configurationIdentity
        )

        let result = try await provider.player(flag: "直链", episodeURL: "episode")

        XCTAssertEqual(
            result.url,
            "http://127.0.0.1:18988/spider/fixture/4/proxy/media?id=1"
        )
        let reference = try XCTUnwrap(result.resourceReference)
        XCTAssertEqual(reference.configurationIdentity, configurationIdentity)
        XCTAssertTrue(reference.stableResourceLocator.hasPrefix("nhr1."))
        XCTAssertEqual(
            replayStore.replay(for: reference.stableResourceLocator),
            NodePlaybackReplay(flag: "直链", episodeURL: "episode")
        )
    }

    func testNodePlayerRespectsProviderOrderForRuntimeOwnedTransports()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let replayStore = NodePlaybackReplayMemoryStore()
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 4,
            api: "/spider/fixture/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"parse":0,"url":["Provider relay","http://192.168.1.9:18988/spider/fixture/4/proxy/stream?id=1","Original","https://media.example.invalid/original?id=1"]}"#.utf8
                )
            )
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client,
            playbackReplayStore: replayStore,
            configurationIdentity: configurationIdentity
        )

        let result = try await provider.player(flag: "direct", episodeURL: "episode")

        XCTAssertEqual(
            result.url,
            "http://127.0.0.1:18988/spider/fixture/4/proxy/stream?id=1"
        )
        XCTAssertEqual(
            result.qualities.map(\.url),
            [
                "http://127.0.0.1:18988/spider/fixture/4/proxy/stream?id=1",
                "https://media.example.invalid/original?id=1"
            ]
        )
        let reference = try XCTUnwrap(result.resourceReference)
        XCTAssertEqual(reference.configurationIdentity, configurationIdentity)
        XCTAssertEqual(
            replayStore.replay(for: reference.stableResourceLocator),
            NodePlaybackReplay(flag: "direct", episodeURL: "episode")
        )
    }

    func testNodePlayerKeepsSharedQualitySelectionForRemoteTransports()
        async throws {
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 4,
            api: "/spider/fixture/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"parse":0,"url":["Provider relay","https://media.example.invalid/relay","Original","https://media.example.invalid/original"]}"#.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let result = try await provider.player(flag: "direct", episodeURL: "episode")

        XCTAssertEqual(
            result.url,
            "https://media.example.invalid/original"
        )
    }

    func testQuarkEpisodeReferenceKeepsStableHistoryIdentityWithoutStoken() throws {
        let passcodeStore = QuarkPasscodeMemoryStore()
        let original = try makeQuarkEpisodeReference(
            stoken: "expired-stoken",
            passcode: "2468"
        )
        let identity = try XCTUnwrap(
            QuarkEpisodeReference.identity(from: original)
        )

        let durable = QuarkEpisodeReference.durableHistoryReference(
            original,
            passcodeStore: passcodeStore
        )
        let durableBytes = Data(durable.utf8)
        let storedText = try XCTUnwrap(
            String(data: durableBytes, encoding: .utf8)
        ).lowercased()

        XCTAssertEqual(identity.providerID, "quark")
        XCTAssertEqual(identity.shareID, "share-123")
        XCTAssertEqual(identity.fileID, "file-456")
        XCTAssertTrue(durable.hasPrefix("qhr1."))
        XCTAssertEqual(
            PlaybackPersistencePolicy.sanitizedOpaqueLocator(durable),
            durable
        )
        XCTAssertEqual(QuarkEpisodeReference.identity(from: durable), identity)
        XCTAssertTrue(QuarkEpisodeReference.requiresShareTokenRefresh(durable))
        XCTAssertEqual(QuarkEpisodeReference.passcode(from: durable), "")
        for forbidden in [
            "stoken", "passcode", "password", "pwd", "playtoken",
            "2468", "expired-stoken"
        ] {
            XCTAssertFalse(
                storedText.contains(forbidden),
                "durable reference leaked \(forbidden)"
            )
        }
        XCTAssertEqual(
            passcodeStore.passcode(
                for: QuarkEpisodeReference.credentialAccount(for: identity)
            ),
            "2468"
        )
    }

    func testNodeProviderRefreshesDurableQuarkHistoryBeforePlayback() async throws {
        let passcodeStore = QuarkPasscodeMemoryStore()
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .none)
        let provider = try makeNodeProvider(
            httpClient: client,
            quarkPasscodeStore: passcodeStore
        )
        let original = try makeQuarkEpisodeReference(
            stoken: "expired-stoken",
            passcode: "2468"
        )
        let durable = QuarkEpisodeReference.durableHistoryReference(
            original,
            passcodeStore: passcodeStore
        )

        let result = try await provider.player(
            flag: "夸克",
            episodeURL: durable
        )
        let requests = await client.capturedRequests()
        let playRequests = requests.filter { $0.url.path.hasSuffix("/play") }
        let tokenRequests = requests.filter {
            $0.url == QuarkEpisodeReference.shareTokenURL
        }

        XCTAssertEqual(result.url, "https://media.example.invalid/video.m3u8")
        XCTAssertEqual(tokenRequests.count, 1)
        XCTAssertEqual(playRequests.count, 1)
        XCTAssertEqual(
            try quarkTokenRequestPasscode(from: tokenRequests[0]),
            "2468"
        )
        let refreshedEpisode = try nodeEpisodeID(from: playRequests[0])
        XCTAssertEqual(
            QuarkEpisodeReference.identity(from: refreshedEpisode),
            QuarkEpisodeReference.identity(from: original)
        )
        XCTAssertEqual(
            try quarkStoken(from: refreshedEpisode),
            "fresh-stoken"
        )
        let refreshedData = try XCTUnwrap(
            Data(
                base64Encoded: refreshedEpisode,
                options: .ignoreUnknownCharacters
            )
        )
        let refreshedText = try XCTUnwrap(
            String(data: refreshedData, encoding: .utf8)
        ).lowercased()
        XCTAssertFalse(refreshedText.contains("passcode"))
        XCTAssertFalse(refreshedText.contains("password"))
        XCTAssertFalse(refreshedText.contains("2468"))
    }

    func testNodePlayerReturnsStableOpaqueQuarkResourceReference() async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let passcodeStore = QuarkPasscodeMemoryStore()
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .none)
        let provider = try makeNodeProvider(
            httpClient: client,
            quarkPasscodeStore: passcodeStore,
            configurationIdentity: configurationIdentity
        )
        let episode = try makeQuarkEpisodeReference(
            stoken: "current-stoken",
            passcode: "2468"
        )

        let result = try await provider.player(
            flag: "原画",
            episodeURL: episode
        )
        let reference = try XCTUnwrap(result.resourceReference)
        let locator = reference.stableResourceLocator.lowercased()

        XCTAssertEqual(reference.schemaVersion, 1)
        XCTAssertEqual(reference.configurationIdentity, configurationIdentity)
        XCTAssertEqual(reference.siteIdentity, "nodejs_quark")
        XCTAssertEqual(reference.providerKind, "node-http-spider")
        XCTAssertEqual(reference.providerVersion, 1)
        XCTAssertEqual(reference.stability, .providerStable)
        XCTAssertTrue(reference.stableResourceLocator.hasPrefix("qhr1."))
        XCTAssertEqual(
            QuarkEpisodeReference.identity(from: reference.stableResourceLocator),
            QuarkEpisodeReference.identity(from: episode)
        )
        XCTAssertTrue(provider.acceptsPlaybackResourceReference(reference))
        for forbidden in [
            "stoken", "passcode", "password", "pwd", "playtoken",
            "2468", "current-stoken"
        ] {
            XCTAssertFalse(locator.contains(forbidden))
        }
    }

    func testPlaybackHistoryOwnerRemainsCapturedConfigurationAfterSwitch() {
        let configurationA = UUID()
        let configurationB = UUID()

        XCTAssertEqual(
            PlaybackConfigurationOwnershipPolicy.historyOwner(
                captured: configurationA,
                current: configurationB
            ),
            configurationA
        )
    }

    func testInFlightPlaybackCannotBeReownedByNewConfiguration() throws {
        let configurationA = UUID()
        let configurationB = UUID()
        let captured = PlaybackConfigurationOwnershipPolicy
            .capturedConfigurationID(
                requested: configurationA,
                history: nil,
                current: configurationA
            )

        XCTAssertEqual(captured, configurationA)
        XCTAssertFalse(
            PlaybackConfigurationOwnershipPolicy.canBeginPlayback(
                captured: try XCTUnwrap(captured),
                current: configurationB
            )
        )
        XCTAssertEqual(
            PlaybackConfigurationOwnershipPolicy.historyOwner(
                captured: try XCTUnwrap(captured),
                current: configurationB
            ),
            configurationA
        )
    }

    func testNodePlayerWrapsExplicitGenericProviderStableReference()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let stableLocator = "node-item-42-file-7"
        let replayStore = NodePlaybackReplayMemoryStore()
        let client = NodeStableReferenceHTTPClient(
            stableLocator: stableLocator
        )
        let provider = try makeGenericNodeProvider(
            httpClient: client,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )

        let result = try await provider.player(
            flag: "provider-line",
            episodeURL: "http://127.0.0.1:18988/temporary/item?nonce=ephemeral"
        )
        let reference = try XCTUnwrap(result.resourceReference)

        XCTAssertEqual(reference.configurationIdentity, configurationIdentity)
        XCTAssertEqual(reference.siteIdentity, "nodejs_stable_fixture")
        XCTAssertEqual(reference.providerKind, "node-http-spider")
        XCTAssertEqual(reference.providerVersion, 1)
        XCTAssertTrue(reference.stableResourceLocator.hasPrefix("npr1."))
        XCTAssertEqual(reference.stability, .providerStable)
        XCTAssertNil(reference.expiresAt)
        XCTAssertTrue(provider.acceptsPlaybackResourceReference(reference))
        XCTAssertEqual(
            PlaybackPersistencePolicy.sanitizedProviderResourceReference(
                reference
            ),
            reference
        )
        XCTAssertEqual(
            replayStore.replay(for: reference.stableResourceLocator),
            NodePlaybackReplay(flag: "provider-line", episodeURL: stableLocator)
        )
        let differentlyBoundProvider = try makeGenericNodeProvider(
            httpClient: client,
            configurationIdentity: UUID().uuidString.lowercased(),
            playbackReplayStore: replayStore
        )
        XCTAssertFalse(
            differentlyBoundProvider.acceptsPlaybackResourceReference(reference),
            "a device-local locator handle must not replay across configurations"
        )
        let encoded = try JSONEncoder().encode(reference)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(stableLocator))
    }

    func testNodeGenericStableReferencePersistsAndRefreshesAfterRestart()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let stableLocator = "node-library-17-resource-99"
        let replayStore = NodePlaybackReplayMemoryStore()
        let initialClient = NodeStableReferenceHTTPClient(
            stableLocator: stableLocator
        )
        let initialProvider = try makeGenericNodeProvider(
            httpClient: initialClient,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )
        let initial = try await initialProvider.player(
            flag: "provider-line",
            episodeURL: "http://127.0.0.1:18988/temporary/item?nonce=discarded"
        )
        let initialReference = try XCTUnwrap(initial.resourceReference)
        let durable = try XCTUnwrap(
            HistoryPlaybackReference(
                sourceIdentity: initialReference.sourceIdentity,
                resourceIdentity: initialReference.episodeIdentity,
                providerResourceReference: initialReference,
                replayHeaders: [
                    "Cookie": "must-not-persist",
                    "Authorization": "Bearer must-not-persist"
                ]
            ).sanitizedForPersistence()
        )
        let encoded = try JSONEncoder().encode(durable)
        let decoded = try JSONDecoder().decode(
            HistoryPlaybackReference.self,
            from: encoded
        )
        let persistedReference = try XCTUnwrap(
            decoded.providerResourceReference
        )

        XCTAssertEqual(persistedReference, initialReference)
        XCTAssertTrue(decoded.replayHeaders.isEmpty)
        let persistedText = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)
        )
        XCTAssertFalse(persistedText.contains("temporary/item"))
        XCTAssertFalse(persistedText.contains("must-not-persist"))

        // A new provider instance models an app restart. The replay response
        // intentionally omits the descriptor; after a successful direct
        // replay the accepted durable reference must remain attached.
        let replayClient = NodeStableReferenceHTTPClient(stableLocator: nil)
        let restartedProvider = try makeGenericNodeProvider(
            httpClient: replayClient,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )
        let refreshed = try await restartedProvider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: "history-video",
                title: "多个完全同名结果",
                sourceIdentity: persistedReference.sourceIdentity,
                resourceIdentity: persistedReference.episodeIdentity,
                sourceName: "provider-line",
                episodeName: "历史分集",
                episodeReference: "obsolete-ephemeral-reference",
                providerResourceReference: persistedReference
            )
        )
        let requests = await replayClient.capturedRequests()

        XCTAssertEqual(
            requests.filter { $0.url.path.hasSuffix("/play") }.count,
            1
        )
        XCTAssertFalse(requests.contains {
            $0.url.path.hasSuffix("/search")
                || $0.url.path.hasSuffix("/detail")
        })
        let replayRequest = try XCTUnwrap(
            requests.first { $0.url.path.hasSuffix("/play") }
        )
        XCTAssertEqual(try nodeEpisodeID(from: replayRequest), stableLocator)
        XCTAssertEqual(
            refreshed.episode.url,
            persistedReference.stableResourceLocator
        )
        XCTAssertEqual(
            refreshed.playbackResult.resourceReference,
            persistedReference
        )

        XCTAssertTrue(
            replayStore.removeReplay(
                for: persistedReference.stableResourceLocator
            )
        )
        do {
            _ = try await restartedProvider.refreshPlayback(
                PlaybackRefreshRequest(
                    videoID: "history-video",
                    title: "多个完全同名结果",
                    sourceIdentity: persistedReference.sourceIdentity,
                    resourceIdentity: persistedReference.episodeIdentity,
                    sourceName: "provider-line",
                    episodeName: "历史分集",
                    providerResourceReference: persistedReference
                )
            )
            XCTFail("missing device-local locator must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("本机安全资源引用"))
        }
    }

    func testNodePlayerKeepsCompatibilityReplayCapabilityOutOfHistory()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let unsafeLocators: [String?] = [
            nil,
            "https://media.example.invalid/signed/item-42",
            "node-item-42-token-secret"
        ]

        for locator in unsafeLocators {
            let replayStore = NodePlaybackReplayMemoryStore()
            let client = NodeStableReferenceHTTPClient(
                stableLocator: locator
            )
            let provider = try makeGenericNodeProvider(
                httpClient: client,
                configurationIdentity: configurationIdentity,
                playbackReplayStore: replayStore
            )
            let result = try await provider.player(
                flag: "provider-line",
                episodeURL: "opaque-provider-input?token=runtime-only"
            )
            let reference = try XCTUnwrap(result.resourceReference)
            let encoded = try JSONEncoder().encode(reference)
            let persistedText = try XCTUnwrap(
                String(data: encoded, encoding: .utf8)
            )

            XCTAssertTrue(reference.stableResourceLocator.hasPrefix("nhr1."))
            XCTAssertEqual(reference.stability, .providerStable)
            XCTAssertTrue(provider.acceptsPlaybackResourceReference(reference))
            XCTAssertFalse(persistedText.contains("runtime-only"))
            XCTAssertFalse(persistedText.contains("signed/item-42"))
            XCTAssertFalse(persistedText.contains("token-secret"))
            XCTAssertEqual(
                replayStore.replay(for: reference.stableResourceLocator),
                NodePlaybackReplay(
                    flag: "provider-line",
                    episodeURL: "opaque-provider-input?token=runtime-only"
                )
            )
        }
    }

    func testNodeSecureReplayReferenceRefreshesExactResourceAfterRestart()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let replayStore = NodePlaybackReplayMemoryStore()
        let originalEpisode = "opaque-file-42?authorization=runtime-only"
        let initialClient = NodeStableReferenceHTTPClient(stableLocator: nil)
        let initialProvider = try makeGenericNodeProvider(
            httpClient: initialClient,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )

        let initial = try await initialProvider.player(
            flag: "cloud-original",
            episodeURL: originalEpisode
        )
        let reference = try XCTUnwrap(initial.resourceReference)
        let persisted = try JSONEncoder().encode(reference)
        let persistedText = try XCTUnwrap(
            String(data: persisted, encoding: .utf8)
        )

        XCTAssertTrue(reference.stableResourceLocator.hasPrefix("nhr1."))
        XCTAssertFalse(persistedText.contains(originalEpisode))
        XCTAssertFalse(persistedText.contains("runtime-only-cookie"))
        XCTAssertFalse(persistedText.contains("http://"))
        XCTAssertFalse(persistedText.contains("127.0.0.1"))
        XCTAssertEqual(initial.mediaSession?.transport, .providerLoopback)
        XCTAssertEqual(initial.mediaSession?.headers["Cookie"], "runtime-only-cookie")
        let initialRequests = await initialClient.capturedRequests()
        XCTAssertTrue(initialRequests.allSatisfy {
            $0.url.host == "127.0.0.1" && $0.url.port == 18_988
        })
        XCTAssertTrue(initialRequests.allSatisfy {
            $0.url.path.hasSuffix("/init") || $0.url.path.hasSuffix("/play")
        })

        let refreshClient = NodeStableReferenceHTTPClient(stableLocator: nil)
        let restartedProvider = try makeGenericNodeProvider(
            httpClient: refreshClient,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )
        let refreshed = try await restartedProvider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: "history-video",
                title: "重复标题",
                sourceIdentity: reference.sourceIdentity,
                resourceIdentity: reference.episodeIdentity,
                sourceName: nil,
                episodeName: "历史分集",
                episodeReference: "expired-display-reference",
                providerResourceReference: reference
            )
        )
        let requests = await refreshClient.capturedRequests()
        let playRequest = try XCTUnwrap(
            requests.first { $0.url.path.hasSuffix("/play") }
        )

        XCTAssertTrue(requests.allSatisfy {
            $0.url.host == "127.0.0.1" && $0.url.port == 18_988
        })
        XCTAssertEqual(try nodeEpisodeID(from: playRequest), originalEpisode)
        XCTAssertEqual(
            requests.filter { $0.url.path.hasSuffix("/play") }.count,
            1
        )
        XCTAssertFalse(requests.contains {
            $0.url.path.hasSuffix("/search")
                || $0.url.path.hasSuffix("/detail")
        })
        XCTAssertEqual(
            refreshed.playbackResult.resourceReference,
            reference
        )
        XCTAssertEqual(
            refreshed.playbackResult.mediaSession?.refreshPerformed,
            true
        )
        XCTAssertEqual(
            refreshed.playbackResult.mediaSession?.transport,
            .providerLoopback
        )
    }

    func testNodeSecureReplayReferenceDoesNotFallBackWhenKeychainItemMissing()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let initialStore = NodePlaybackReplayMemoryStore()
        let initialProvider = try makeGenericNodeProvider(
            httpClient: NodeStableReferenceHTTPClient(stableLocator: nil),
            configurationIdentity: configurationIdentity,
            playbackReplayStore: initialStore
        )
        let initial = try await initialProvider.player(
            flag: "cloud-original",
            episodeURL: "opaque-file-42"
        )
        let reference = try XCTUnwrap(initial.resourceReference)
        let refreshClient = NodeStableReferenceHTTPClient(stableLocator: nil)
        let restartedProvider = try makeGenericNodeProvider(
            httpClient: refreshClient,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: NodePlaybackReplayMemoryStore()
        )

        do {
            _ = try await restartedProvider.refreshPlayback(
                PlaybackRefreshRequest(
                    videoID: "history-video",
                    title: "重复标题",
                    sourceIdentity: reference.sourceIdentity,
                    resourceIdentity: reference.episodeIdentity,
                    sourceName: "cloud-original",
                    episodeName: "历史分集",
                    episodeReference: "expired-display-reference",
                    providerResourceReference: reference
                )
            )
            XCTFail("missing secure replay entry must not use title search")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("安全资源引用已失效"))
        }

        let requests = await refreshClient.capturedRequests()
        XCTAssertFalse(requests.contains {
            $0.url.path.hasSuffix("/play")
                || $0.url.path.hasSuffix("/search")
                || $0.url.path.hasSuffix("/detail")
        })
    }

    func testNodeLoopbackPlayFailsClosedWhenSecureReplayCannotBeStored()
        async throws {
        let client = NodeStableReferenceHTTPClient(stableLocator: nil)
        let provider = try makeGenericNodeProvider(
            httpClient: client,
            configurationIdentity: UUID().uuidString.lowercased(),
            playbackReplayStore: NodePlaybackReplayRejectingStore()
        )

        do {
            _ = try await provider.player(
                flag: "cloud-original",
                episodeURL: "opaque-file-42"
            )
            XCTFail("provider loopback playback must require a durable replay")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("本机安全引用"))
        }

        let requests = await client.capturedRequests()
        XCTAssertEqual(
            requests.filter { $0.url.path.hasSuffix("/play") }.count,
            1
        )
        XCTAssertFalse(requests.contains {
            $0.url.path.hasSuffix("/search")
                || $0.url.path.hasSuffix("/detail")
        })
    }

    func testNodePlaybackReferenceIsBoundToCurrentProviderAndConfiguration()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let provider = try makeNodeProvider(
            httpClient: QuarkRefreshHTTPClient(firstPlayFailure: .none),
            configurationIdentity: configurationIdentity
        )
        let result = try await provider.player(
            flag: "原画",
            episodeURL: try makeQuarkEpisodeReference(
                stoken: "current-stoken"
            )
        )
        let valid = try XCTUnwrap(result.resourceReference)

        XCTAssertTrue(provider.acceptsPlaybackResourceReference(valid))

        var wrongConfiguration = valid
        wrongConfiguration.configurationIdentity = UUID()
            .uuidString.lowercased()
        XCTAssertFalse(
            provider.acceptsPlaybackResourceReference(wrongConfiguration)
        )

        var wrongSite = valid
        wrongSite.siteIdentity = "another-node-site"
        XCTAssertFalse(provider.acceptsPlaybackResourceReference(wrongSite))

        var wrongProvider = valid
        wrongProvider.providerKind = "android-dex-spider"
        XCTAssertFalse(
            provider.acceptsPlaybackResourceReference(wrongProvider)
        )

        var wrongVersion = valid
        wrongVersion.providerVersion += 1
        XCTAssertFalse(
            provider.acceptsPlaybackResourceReference(wrongVersion)
        )

        var expired = valid
        expired.expiresAt = Date(timeIntervalSinceNow: -1)
        XCTAssertFalse(provider.acceptsPlaybackResourceReference(expired))
    }

    func testNodeRefreshReplaysStableQuarkLocatorWithoutSearchOrDetail()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let passcodeStore = QuarkPasscodeMemoryStore()
        let initialProvider = try makeNodeProvider(
            httpClient: QuarkRefreshHTTPClient(firstPlayFailure: .none),
            quarkPasscodeStore: passcodeStore,
            configurationIdentity: configurationIdentity
        )
        let initialResult = try await initialProvider.player(
            flag: "原画",
            episodeURL: try makeQuarkEpisodeReference(
                stoken: "current-stoken",
                passcode: "2468"
            )
        )
        let reference = try XCTUnwrap(initialResult.resourceReference)

        let refreshClient = QuarkRefreshHTTPClient(firstPlayFailure: .none)
        let refreshProvider = try makeNodeProvider(
            httpClient: refreshClient,
            quarkPasscodeStore: passcodeStore,
            configurationIdentity: configurationIdentity
        )
        let refreshed = try await refreshProvider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: "history-video-id",
                title: "多个同名的影片",
                sourceIdentity: reference.sourceIdentity,
                resourceIdentity: reference.episodeIdentity,
                sourceName: "原画",
                episodeName: "第 1 集",
                episodeReference: "obsolete-ephemeral-reference",
                providerResourceReference: reference
            )
        )
        let requests = await refreshClient.capturedRequests()

        XCTAssertEqual(
            requests.filter { $0.url == QuarkEpisodeReference.shareTokenURL }.count,
            1
        )
        XCTAssertEqual(
            requests.filter { $0.url.path.hasSuffix("/play") }.count,
            1
        )
        XCTAssertFalse(
            requests.contains {
                $0.url.path.hasSuffix("/search")
                    || $0.url.path.hasSuffix("/detail")
            }
        )
        XCTAssertEqual(refreshed.detail.summary.videoID, "history-video-id")
        XCTAssertEqual(refreshed.source.name, "原画")
        XCTAssertEqual(refreshed.episode.name, "第 1 集")
        XCTAssertEqual(
            refreshed.episode.url,
            reference.stableResourceLocator
        )
        let refreshedReference = try XCTUnwrap(
            refreshed.playbackResult.resourceReference
        )
        XCTAssertTrue(
            refreshProvider.acceptsPlaybackResourceReference(refreshedReference)
        )
        XCTAssertEqual(
            QuarkEpisodeReference.identity(
                from: refreshedReference.stableResourceLocator
            ),
            QuarkEpisodeReference.identity(
                from: reference.stableResourceLocator
            )
        )

        // Model AppState's first player-load failure followed by the provider
        // refresh above. The expired authoritative request gets exactly one
        // direct attempt; it must not spend the remaining budget on unrelated
        // configured parsers. The second actual media-loader invocation must
        // then receive every value from the refreshed provider snapshot.
        let configuredParser = ParseConfiguration(
            name: "Unrelated parser",
            type: 1,
            url: "https://parser.example.invalid/?url="
        )
        let obsoleteResult = SitePlaybackResult(
            url: "https://expired.example.invalid/old-media.m3u8",
            needsParsing: false,
            flag: refreshed.source.name,
            headers: ["X-Playback-Revision": "expired"],
            validationPolicy: .playerAuthoritative,
            resourceReference: reference
        )
        let obsoleteContext = PlaybackResolutionAttemptContext(
            detail: refreshed.detail,
            source: refreshed.source,
            episode: PlayEpisode(
                name: "旧分集",
                url: "obsolete-ephemeral-reference"
            ),
            result: obsoleteResult
        )
        let refreshedContext = PlaybackResolutionAttemptContext(
            detail: refreshed.detail,
            source: refreshed.source,
            episode: refreshed.episode,
            result: refreshed.playbackResult
        )
        let parseExecutor = PlaybackParseInvocationRecorder()
        let resolver = PlaybackResolver(
            parseExecutor: parseExecutor,
            mediaProbe: RejectingPlaybackMediaProbe()
        )
        var obsoleteAttempts = 0
        for await event in resolver.resolve(
            obsoleteContext.resolutionRequest(
                configuredParsers: [configuredParser],
                maximumAttempts: 8
            ),
            mediaLoader: { _, _ in
                throw AppError.playback("fixture loading failed")
            }
        ) {
            if case .attempting = event {
                obsoleteAttempts += 1
            }
        }
        XCTAssertEqual(obsoleteAttempts, 1)

        let loadRecorder = PlaybackMediaLoadRecorder()
        var refreshedAttempts = 0
        for await event in resolver.resolve(
            refreshedContext.resolutionRequest(
                configuredParsers: [configuredParser],
                maximumAttempts: 7
            ),
            mediaLoader: { media, _ in
                await loadRecorder.record(media)
            }
        ) {
            if case .attempting = event {
                refreshedAttempts += 1
            }
        }
        let loadedMedia = await loadRecorder.loadedMedia()
        let parserInvocationCount = await parseExecutor.invocationCount()

        XCTAssertEqual(refreshedAttempts, 1)
        XCTAssertEqual(parserInvocationCount, 0)
        XCTAssertEqual(
            loadedMedia?.url.absoluteString,
            refreshed.playbackResult.url
        )
        XCTAssertNotEqual(
            loadedMedia?.url.absoluteString,
            obsoleteResult.url
        )
        XCTAssertEqual(
            loadedMedia?.headers["X-Playback-Revision"],
            "refreshed"
        )
        XCTAssertEqual(loadedMedia?.episodeName, refreshed.episode.name)
    }

    func testNodeProviderKeepsCurrentQuarkEpisodeUnchangedWhenTokenIsValid() async throws {
        let passcodeStore = QuarkPasscodeMemoryStore()
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .none)
        let provider = try makeNodeProvider(
            httpClient: client,
            quarkPasscodeStore: passcodeStore
        )
        let episode = try makeQuarkEpisodeReference(
            stoken: "current-stoken",
            passcode: "2468"
        )

        _ = try await provider.player(flag: "夸克", episodeURL: episode)
        let requests = await client.capturedRequests()
        let playRequests = requests.filter { $0.url.path.hasSuffix("/play") }

        XCTAssertEqual(
            requests.filter {
                $0.url == QuarkEpisodeReference.shareTokenURL
            }.count,
            0
        )
        XCTAssertEqual(playRequests.count, 1)
        XCTAssertEqual(try nodeEpisodeID(from: playRequests[0]), episode)
    }

    func testNodeProviderPrefersCurrentQuarkPasscodeOverStoredValue() async throws {
        let passcodeStore = QuarkPasscodeMemoryStore()
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .expiredStoken)
        let episode = try makeQuarkEpisodeReference(
            stoken: "expired-stoken",
            passcode: "2468"
        )
        let identity = try XCTUnwrap(
            QuarkEpisodeReference.identity(from: episode)
        )
        passcodeStore.store(
            "obsolete-passcode",
            for: QuarkEpisodeReference.credentialAccount(for: identity)
        )
        let provider = try makeNodeProvider(
            httpClient: client,
            quarkPasscodeStore: passcodeStore
        )

        _ = try await provider.player(flag: "夸克", episodeURL: episode)
        let requests = await client.capturedRequests()
        let tokenRequest = try XCTUnwrap(
            requests.first {
                $0.url == QuarkEpisodeReference.shareTokenURL
            }
        )

        XCTAssertEqual(
            try quarkTokenRequestPasscode(from: tokenRequest),
            "2468"
        )
    }

    func testNodeProviderRefreshesExplicit41016OnceAndRetriesPlayOnce() async throws {
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .expiredStoken)
        let provider = try makeNodeProvider(httpClient: client)
        let episode = try makeQuarkEpisodeReference(stoken: "expired-stoken")

        let result = try await provider.player(flag: "夸克", episodeURL: episode)
        let requests = await client.capturedRequests()
        let playRequests = requests.filter { $0.url.path.hasSuffix("/play") }
        let tokenRequests = requests.filter {
            $0.url == QuarkEpisodeReference.shareTokenURL
        }

        XCTAssertEqual(result.url, "https://media.example.invalid/video.m3u8")
        XCTAssertEqual(tokenRequests.count, 1)
        XCTAssertEqual(playRequests.count, 2)
        XCTAssertEqual(
            try quarkStoken(from: nodeEpisodeID(from: playRequests[0])),
            "expired-stoken"
        )
        XCTAssertEqual(
            try quarkStoken(from: nodeEpisodeID(from: playRequests[1])),
            "fresh-stoken"
        )
    }

    func testNodeProviderRecoversFromLegacyMissingTaskErrorWithoutBlindRetry() async throws {
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .missingTask)
        let provider = try makeNodeProvider(httpClient: client)
        let episode = try makeQuarkEpisodeReference(stoken: "expired-stoken")

        _ = try await provider.player(flag: "夸克", episodeURL: episode)
        let requests = await client.capturedRequests()

        XCTAssertEqual(
            requests.filter { $0.url.path.hasSuffix("/play") }.count,
            2
        )
        XCTAssertEqual(
            requests.filter { $0.url == QuarkEpisodeReference.shareTokenURL }.count,
            1
        )
    }

    func testQuarkRefreshFailurePreservesOriginalErrorCode() async throws {
        let client = NodeProviderStubHTTPClient { request in
            XCTAssertEqual(request.url, QuarkEpisodeReference.shareTokenURL)
            return HTTPResponse(
                url: request.url,
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"code":41016,"message":"分享的 stoken 过期"}"#.utf8
                )
            )
        }
        let provider = try makeNodeProvider(httpClient: client)
        let durable = QuarkEpisodeReference.durableHistoryReference(
            try makeQuarkEpisodeReference(stoken: "expired-stoken")
        )

        do {
            _ = try await provider.player(flag: "夸克", episodeURL: durable)
            XCTFail("令牌刷新失败时应保留原始错误")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("41016"))
            XCTAssertTrue(error.localizedDescription.contains("stoken 过期"))
        }
    }

    private func makeNodeProvider(
        httpClient: HTTPClient,
        quarkPasscodeStore: QuarkPasscodeStoring = QuarkPasscodeMemoryStore(),
        configurationIdentity: String? = nil
    ) throws -> NodeHTTPSpiderSiteProvider {
        try NodeHTTPSpiderSiteProvider(
            site: SiteConfiguration(
                key: "nodejs_quark",
                name: "夸克网盘",
                type: 4,
                api: "/spider/quark/4",
                extra: ["okNodeRuntime": .bool(true)]
            ),
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: httpClient,
            quarkPasscodeStore: quarkPasscodeStore,
            configurationIdentity: configurationIdentity
        )
    }

    private func makeGenericNodeProvider(
        httpClient: HTTPClient,
        configurationIdentity: String,
        playbackReplayStore: NodePlaybackReplayStoring =
            NodePlaybackKeychainReplayStore()
    ) throws -> NodeHTTPSpiderSiteProvider {
        try NodeHTTPSpiderSiteProvider(
            site: SiteConfiguration(
                key: "nodejs_stable_fixture",
                name: "Stable Node Fixture",
                type: 4,
                api: "/spider/stable-fixture/4",
                extra: ["okNodeRuntime": .bool(true)]
            ),
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: httpClient,
            playbackReplayStore: playbackReplayStore,
            configurationIdentity: configurationIdentity
        )
    }

    func testApplicationAppearanceNamesCoverAllThemeChoices() {
        XCTAssertNil(AppAppearanceController.appearanceName(for: .system))
        XCTAssertEqual(
            AppAppearanceController.appearanceName(for: .light),
            .aqua
        )
        XCTAssertEqual(
            AppAppearanceController.appearanceName(for: .dark),
            .darkAqua
        )
    }

    func testAndroidRuntimeStatusExposesManualControlStates() {
        XCTAssertEqual(AndroidRuntimeStatus.stopped.phase, .stopped)
        XCTAssertFalse(AndroidRuntimeStatus.stopped.isRunning)
        XCTAssertEqual(AndroidRuntimeStatus.running.phase, .running)
        XCTAssertTrue(AndroidRuntimeStatus.running.isRunning)

        let starting = AndroidRuntimeStatus.starting(
            "等待 Android 系统完成开机",
            progress: 0.56
        )
        XCTAssertEqual(starting.phase, .starting)
        XCTAssertEqual(starting.progress, 0.56)
        XCTAssertTrue(starting.detail.contains("Android"))
    }

    func testPlayerProgressHoverFractionClampsToTrackBounds() {
        XCTAssertEqual(
            PlayerProgressHoverPolicy.fraction(x: -20, width: 200),
            0
        )
        XCTAssertEqual(
            PlayerProgressHoverPolicy.fraction(x: 50, width: 200),
            0.25
        )
        XCTAssertEqual(
            PlayerProgressHoverPolicy.fraction(x: 260, width: 200),
            1
        )
        XCTAssertNil(
            PlayerProgressHoverPolicy.fraction(x: 10, width: 0)
        )
    }

    func testPlayerProgressHoverTimeUsesMediaDuration() {
        XCTAssertEqual(
            PlayerProgressHoverPolicy.time(fraction: 0.5, duration: 4_048),
            2_024
        )
        XCTAssertEqual(
            PlayerProgressHoverPolicy.time(fraction: 2, duration: 100),
            100
        )
        XCTAssertNil(
            PlayerProgressHoverPolicy.time(fraction: 0.5, duration: 0)
        )
    }

    func testPlayerProgressHoverTooltipStaysInsideTrack() {
        XCTAssertEqual(
            PlayerProgressHoverPolicy.tooltipCenterX(
                fraction: 0,
                width: 200,
                tooltipWidth: 58
            ),
            29
        )
        XCTAssertEqual(
            PlayerProgressHoverPolicy.tooltipCenterX(
                fraction: 1,
                width: 200,
                tooltipWidth: 58
            ),
            171
        )
    }
}

private actor ConfigurationCancellationTestRecorder {
    private(set) var events: [String] = []

    func recordStarted(_ requestID: UUID) {
        events.append("start:\(requestID)")
    }

    func recordAcknowledged(_ requestID: UUID) {
        events.append("ack:\(requestID)")
    }
}

private actor NodeReadinessTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor NodeReadinessTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor NodeReadinessRecordingHTTPClient: HTTPClient {
    private(set) var requestCount = 0
    private(set) var lastURL: URL?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        lastURL = request.url
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"class":[],"list":[]}"#.utf8)
        )
    }
}

private let nodeLifecycleFixtureSite = SiteConfiguration(
    key: "nodejs_lifecycle_fixture",
    name: "Lifecycle Fixture",
    type: 3,
    api: "/spider/lifecycle/3",
    extra: ["okNodeRuntime": .bool(true)]
)

private actor NodeRuntimeEndpointBox {
    private var endpoint: URL

    init(_ endpoint: URL) {
        self.endpoint = endpoint
    }

    func current() -> URL {
        endpoint
    }

    func set(_ endpoint: URL) {
        self.endpoint = endpoint
    }
}

private actor NodeLifecycleRecordingHTTPClient: HTTPClient {
    private let initStatusCode: Int
    private var requests: [URL] = []

    init(initStatusCode: Int) {
        self.initStatusCode = initStatusCode
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request.url)
        if request.url.path.hasSuffix("/init") {
            try await Task.sleep(nanoseconds: 25_000_000)
            return HTTPResponse(
                url: request.url,
                statusCode: initStatusCode,
                headers: ["Content-Type": "application/json"],
                body: initStatusCode == 500
                    ? Data(#"{"error":"fixture init rejected"}"#.utf8)
                    : Data(#"{}"#.utf8)
            )
        }
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"class":[{"type_id":"movie","type_name":"电影"}],"list":[]}"#.utf8
            )
        )
    }

    func requestPaths() -> [String] {
        requests.map(\.path)
    }

    func initializedPorts() -> [Int] {
        requests
            .filter { $0.path.hasSuffix("/init") }
            .compactMap(\.port)
    }
}

private struct NodeProviderStubHTTPClient: HTTPClient {
    let handler: (HTTPRequest) throws -> HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try handler(request)
    }
}

private actor NodeStableReferenceHTTPClient: HTTPClient {
    private let stableLocator: String?
    private var requests: [HTTPRequest] = []

    init(stableLocator: String?) {
        self.stableLocator = stableLocator
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url.path.hasSuffix("/init") {
            return HTTPResponse(
                url: request.url,
                statusCode: 404,
                headers: [:],
                body: Data()
            )
        }
        guard request.url.path.hasSuffix("/play") else {
            throw HTTPClientError.statusCode(404)
        }

        var response: [String: Any] = [
            "parse": 0,
            "url": "http://127.0.0.1:18988/src/down/runtime-capability",
            "header": ["Cookie": "runtime-only-cookie"]
        ]
        if let stableLocator {
            response["providerResourceReference"] = [
                "schemaVersion": 1,
                "providerVersion": 1,
                "stableResourceLocator": stableLocator,
                "stability": "providerStable"
            ]
        }
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(
                withJSONObject: response,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
    }
}

private final class QuarkPasscodeMemoryStore: QuarkPasscodeStoring {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func passcode(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    @discardableResult
    func store(_ passcode: String, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[account] = passcode
        return true
    }
}

private final class NodePlaybackReplayMemoryStore: NodePlaybackReplayStoring {
    private let lock = NSLock()
    private var values: [String: NodePlaybackReplay] = [:]

    func replay(for locator: String) -> NodePlaybackReplay? {
        lock.lock()
        defer { lock.unlock() }
        return values[locator]
    }

    @discardableResult
    func store(_ replay: NodePlaybackReplay, for locator: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[locator] = replay
        return true
    }

    @discardableResult
    func removeReplay(for locator: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: locator)
        return true
    }
}

private struct NodePlaybackReplayRejectingStore: NodePlaybackReplayStoring {
    func replay(for locator: String) -> NodePlaybackReplay? { nil }

    func store(_ replay: NodePlaybackReplay, for locator: String) -> Bool {
        false
    }

    func removeReplay(for locator: String) -> Bool { false }
}

private actor QuarkRefreshHTTPClient: HTTPClient {
    enum FirstPlayFailure {
        case none
        case expiredStoken
        case missingTask
    }

    private let firstPlayFailure: FirstPlayFailure
    private var playRequestCount = 0
    private var requests: [HTTPRequest] = []

    init(firstPlayFailure: FirstPlayFailure) {
        self.firstPlayFailure = firstPlayFailure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url == QuarkEpisodeReference.shareTokenURL {
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"data":{"stoken":"fresh-stoken"}}"#.utf8)
            )
        }
        if request.url.path.hasSuffix("/init") {
            return HTTPResponse(
                url: request.url,
                statusCode: 404,
                headers: [:],
                body: Data()
            )
        }
        guard request.url.path.hasSuffix("/play") else {
            throw HTTPClientError.statusCode(404)
        }
        playRequestCount += 1
        if playRequestCount == 1 {
            switch firstPlayFailure {
            case .none:
                break
            case .expiredStoken:
                return HTTPResponse(
                    url: request.url,
                    statusCode: 500,
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        #"{"code":41016,"error":"分享的 stoken 过期"}"#.utf8
                    )
                )
            case .missingTask:
                return HTTPResponse(
                    url: request.url,
                    statusCode: 500,
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        #"{"error":"夸克转存没有返回 task_id"}"#.utf8
                    )
                )
            }
        }
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"parse":0,"url":"https://media.example.invalid/video.m3u8","header":{"X-Playback-Revision":"refreshed"}}"#.utf8
            )
        )
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
    }
}

private actor PlaybackParseInvocationRecorder: ParseExecutor {
    private var count = 0

    func resolve(
        parser: ParseConfiguration,
        inputURL: String,
        headers: HTTPHeaders
    ) async throws -> ParsedMedia {
        count += 1
        throw AppError.parsing("unexpected generic parser invocation")
    }

    func invocationCount() -> Int {
        count
    }
}

private struct RejectingPlaybackMediaProbe: MediaProbe {
    func validate(url: URL, headers: HTTPHeaders) async throws -> Bool {
        false
    }
}

private actor PlaybackMediaLoadRecorder {
    private var media: ResolvedMedia?

    func record(_ media: ResolvedMedia) {
        self.media = media
    }

    func loadedMedia() -> ResolvedMedia? {
        media
    }
}

private func makeQuarkEpisodeReference(
    stoken: String,
    passcode: String = ""
) throws -> String {
    let tokenData = try JSONSerialization.data(
        withJSONObject: [
            "shareId": "share-123",
            "fid": "file-456",
            "stoken": stoken,
            "passcode": passcode
        ],
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let token = try XCTUnwrap(String(data: tokenData, encoding: .utf8))
    let outerData = try JSONSerialization.data(
        withJSONObject: [
            "providerId": "quark",
            "shareId": "share-123",
            "fileId": "file-456",
            "playToken": token
        ],
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return outerData.base64EncodedString()
}

private func nodeEpisodeID(from request: HTTPRequest) throws -> String {
    let body = try XCTUnwrap(request.body)
    let value = try JSONDecoder().decode(JSONValue.self, from: body)
    return try XCTUnwrap(value.objectValue?["id"]?.stringValue)
}

private func quarkTokenRequestPasscode(
    from request: HTTPRequest
) throws -> String {
    let body = try XCTUnwrap(request.body)
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    return try XCTUnwrap(object["passcode"] as? String)
}

private func quarkStoken(from episodeReference: String) throws -> String {
    let outerData = try XCTUnwrap(
        Data(base64Encoded: episodeReference, options: .ignoreUnknownCharacters)
    )
    let outer = try XCTUnwrap(
        JSONSerialization.jsonObject(with: outerData) as? [String: Any]
    )
    let playToken = try XCTUnwrap(outer["playToken"] as? String)
    let token = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(playToken.utf8)) as? [String: Any]
    )
    return try XCTUnwrap(token["stoken"] as? String)
}

private actor ImageRepositoryHTTPClientProbe: HTTPClient {
    private let body: Data?
    private let error: HTTPClientError?
    private let delayNanoseconds: UInt64
    private var failuresRemaining: Int
    private var count = 0

    init(body: Data, delayNanoseconds: UInt64 = 0) {
        self.body = body
        self.error = nil
        self.delayNanoseconds = delayNanoseconds
        failuresRemaining = 0
    }

    init(
        body: Data,
        failuresBeforeSuccess: Int,
        delayNanoseconds: UInt64 = 0
    ) {
        self.body = body
        self.error = nil
        self.delayNanoseconds = delayNanoseconds
        failuresRemaining = max(0, failuresBeforeSuccess)
    }

    init(error: HTTPClientError, delayNanoseconds: UInt64 = 0) {
        self.body = nil
        self.error = error
        self.delayNanoseconds = delayNanoseconds
        failuresRemaining = 0
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw HTTPClientError.statusCode(503)
        }
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "image/tiff"],
            body: body ?? Data()
        )
    }

    func requestCount() -> Int {
        count
    }
}

private actor ImageRefererFallbackHTTPClient: HTTPClient {
    private let imageData: Data
    private let initialStatus: Int
    private let fallbackStatus: Int?
    private var requests: [HTTPRequest] = []

    init(
        imageData: Data,
        initialStatus: Int,
        fallbackStatus: Int? = nil
    ) {
        self.imageData = imageData
        self.initialStatus = initialStatus
        self.fallbackStatus = fallbackStatus
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let hasReferer = request.headers["Referer"]?.isEmpty == false
        if !hasReferer {
            throw HTTPClientError.statusCode(initialStatus)
        }
        if let fallbackStatus {
            throw HTTPClientError.statusCode(fallbackStatus)
        }
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "image/tiff"],
            body: imageData
        )
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
    }
}

private actor NodeProxyEndpointTransitionHTTPClient: HTTPClient {
    private let stalePort: Int
    private let imageData: Data
    private var ports: [Int] = []

    init(stalePort: Int, imageData: Data) {
        self.stalePort = stalePort
        self.imageData = imageData
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let port = request.url.port ?? -1
        ports.append(port)
        if port == stalePort {
            try await Task.sleep(nanoseconds: 150_000_000)
            throw HTTPClientError.statusCode(503)
        }
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: ["Content-Type": "image/tiff"],
            body: imageData
        )
    }

    func requestCount() -> Int {
        ports.count
    }

    func requestedPorts() -> [Int] {
        ports
    }
}
