import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

final class OKVideoMacTests: XCTestCase {
    func testXCTestHostUsesIsolatedRuntimeDirectories() throws {
        let directories = try AppEnvironment.runtimeDirectories(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            processIdentifier: 4242
        )
        let productionSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OKVideoMac")

        XCTAssertNotEqual(
            directories.applicationSupport.standardizedFileURL,
            productionSupport.standardizedFileURL
        )
        XCTAssertTrue(
            directories.applicationSupport.path.contains("OKVideoMac-XCTest-4242-")
        )
    }

    func testProductionRuntimeDoesNotUseTestDirectoryPolicy() {
        XCTAssertFalse(AppEnvironment.isXCTestHost(environment: [:]))
        XCTAssertTrue(
            AppEnvironment.isXCTestHost(
                environment: ["XCTestBundlePath": "/tmp/OKVideoMacTests.xctest"]
            )
        )
    }

    func testPortableBackupRoundTripPreservesConfigurationAndHistory() throws {
        let configurationID = UUID()
        let configuration = StoredConfiguration(
            id: configurationID,
            name: "Fixture",
            sourceKind: .remote,
            sourceValue: "https://example.invalid/config.json",
            baseURL: URL(string: "https://example.invalid/"),
            rawData: Data(#"{"sites":[]}"#.utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            isActive: true
        )
        let history = HistoryRecord(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture Video",
            sourceKey: "line-1",
            sourceName: "Line One",
            episodeName: "Episode 2",
            episodeReference: "episode-2",
            position: 42,
            duration: 100,
            watchedAt: Date(timeIntervalSince1970: 200)
        )

        let data = try PortableBackupCodec.encode(
            configuration: configuration,
            history: [history],
            appVersion: "1.2.3",
            appBuild: "456",
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let decoded = try PortableBackupCodec.decode(data)

        XCTAssertEqual(decoded.manifest.schemaVersion, 1)
        XCTAssertEqual(decoded.manifest.historyCount, 1)
        XCTAssertEqual(decoded.payload.configuration.id, configurationID)
        XCTAssertEqual(decoded.payload.configuration.name, "Fixture")
        XCTAssertEqual(decoded.payload.configuration.rawData, configuration.rawData)
        XCTAssertEqual(decoded.payload.history, [history])
    }

    func testPortableBackupRejectsPayloadChecksumMismatch() throws {
        let configuration = StoredConfiguration(
            name: "Fixture",
            sourceKind: .pasted,
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        let data = try PortableBackupCodec.encode(
            configuration: configuration,
            history: [],
            appVersion: "1",
            appBuild: "1"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var envelope = try decoder.decode(
            PortableBackupEnvelope.self,
            from: data
        )
        envelope.payload.append(0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let corrupted = try encoder.encode(envelope)

        XCTAssertThrowsError(try PortableBackupCodec.decode(corrupted)) {
            XCTAssertEqual($0 as? PortableBackupError, .checksumMismatch)
        }
    }

    func testPortableBackupRejectsUnsafeHistoryReference() throws {
        let configuration = StoredConfiguration(
            name: "Fixture",
            sourceKind: .pasted,
            rawData: Data(#"{"sites":[]}"#.utf8),
            isActive: true
        )
        let unsafeHistory = HistoryRecord(
            configurationID: configuration.id,
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture",
            mediaReference: "https://example.invalid/signed.m3u8?token=secret"
        )

        XCTAssertThrowsError(
            try PortableBackupCodec.encode(
                configuration: configuration,
                history: [unsafeHistory],
                appVersion: "1",
                appBuild: "1"
            )
        ) {
            XCTAssertEqual($0 as? PortableBackupError, .invalidHistory)
        }
    }

    func testShortcutRoutePolicyGivesPlayerWindowPriority() {
        XCTAssertEqual(
            ShortcutRoutePolicy.context(
                browserWindowIsKey: true,
                playerWindowIsKey: true
            ),
            .player
        )
        XCTAssertFalse(
            ShortcutRoutePolicy.allowsBrowserCommands(
                browserWindowIsKey: true,
                playerWindowIsKey: true
            )
        )
        XCTAssertTrue(
            ShortcutRoutePolicy.allowsPlayerCommands(
                browserWindowIsKey: true,
                playerWindowIsKey: true
            )
        )
    }

    func testShortcutRoutePolicyRoutesBrowserOnlyWhenBrowserIsKey() {
        XCTAssertEqual(
            ShortcutRoutePolicy.context(
                browserWindowIsKey: true,
                playerWindowIsKey: false
            ),
            .browser
        )
        XCTAssertTrue(
            ShortcutRoutePolicy.allowsBrowserCommands(
                browserWindowIsKey: true,
                playerWindowIsKey: false
            )
        )
        XCTAssertFalse(
            ShortcutRoutePolicy.allowsPlayerCommands(
                browserWindowIsKey: true,
                playerWindowIsKey: false
            )
        )
    }

    func testShortcutRoutePolicyRejectsUnrelatedWindows() {
        XCTAssertEqual(
            ShortcutRoutePolicy.context(
                browserWindowIsKey: false,
                playerWindowIsKey: false
            ),
            .other
        )
        XCTAssertFalse(
            ShortcutRoutePolicy.allowsBrowserCommands(
                browserWindowIsKey: false,
                playerWindowIsKey: false
            )
        )
        XCTAssertFalse(
            ShortcutRoutePolicy.allowsPlayerCommands(
                browserWindowIsKey: false,
                playerWindowIsKey: false
            )
        )
    }

    func testBrowserEscapeStopsSearchBeforeReturningHome() {
        XCTAssertEqual(
            BrowserEscapeRoutePolicy.action(
                isHomeSearchPresented: true,
                isSearching: true,
                hasSearchFolder: false,
                hasDetailPresentation: false,
                hasBlockingPresentation: false
            ),
            .stopSearch
        )
        XCTAssertEqual(
            BrowserEscapeRoutePolicy.action(
                isHomeSearchPresented: true,
                isSearching: false,
                hasSearchFolder: false,
                hasDetailPresentation: false,
                hasBlockingPresentation: false
            ),
            .returnHome
        )
    }

    func testBrowserEscapeDefersToForegroundPresentation() {
        XCTAssertEqual(
            BrowserEscapeRoutePolicy.action(
                isHomeSearchPresented: true,
                isSearching: true,
                hasSearchFolder: false,
                hasDetailPresentation: false,
                hasBlockingPresentation: true
            ),
            .none
        )
        XCTAssertEqual(
            BrowserEscapeRoutePolicy.action(
                isHomeSearchPresented: false,
                isSearching: false,
                hasSearchFolder: false,
                hasDetailPresentation: false,
                hasBlockingPresentation: false
            ),
            .none
        )
    }

    func testBrowserEscapeDismissesDetailBeforeSearch() {
        XCTAssertEqual(
            BrowserEscapeRoutePolicy.action(
                isHomeSearchPresented: true,
                isSearching: false,
                hasSearchFolder: false,
                hasDetailPresentation: true,
                hasBlockingPresentation: false
            ),
            .dismissDetail
        )
    }

    func testBrowserEscapeNavigatesFolderBeforeStoppingSearch() {
        XCTAssertEqual(
            BrowserEscapeRoutePolicy.action(
                isHomeSearchPresented: true,
                isSearching: true,
                hasSearchFolder: true,
                hasDetailPresentation: false,
                hasBlockingPresentation: false
            ),
            .navigateBackFolder
        )
    }

    func testSearchFolderBackDestinationPreservesEntryOrigin() {
        XCTAssertEqual(
            SearchFolderNavigationPolicy.backDestination(
                pathCount: 2,
                origin: .home
            ),
            .parentFolder
        )
        XCTAssertEqual(
            SearchFolderNavigationPolicy.backDestination(
                pathCount: 1,
                origin: .home
            ),
            .home
        )
        XCTAssertEqual(
            SearchFolderNavigationPolicy.backDestination(
                pathCount: 1,
                origin: .searchResults
            ),
            .searchResults
        )
    }

    func testSearchFolderBackDestinationUsesSafeLegacyFallback() {
        XCTAssertEqual(
            SearchFolderNavigationPolicy.backDestination(
                pathCount: 1,
                origin: nil
            ),
            .searchResults
        )
        XCTAssertNil(
            SearchFolderNavigationPolicy.backDestination(
                pathCount: 0,
                origin: .home
            )
        )
    }

    func testDetailReturnSnapshotOnlyCapturesHomeSearch() {
        XCTAssertNil(
            DetailHomeSearchReturnPolicy.capture(
                isHomeSearchPresented: false,
                selectedSiteKey: "site-a",
                folderPath: [],
                folderOrigin: .home
            )
        )

        XCTAssertEqual(
            DetailHomeSearchReturnPolicy.capture(
                isHomeSearchPresented: true,
                selectedSiteKey: "site-a",
                folderPath: [],
                folderOrigin: .searchResults
            ),
            DetailHomeSearchReturnSnapshot(
                selectedSiteKey: "site-a",
                folderPath: [],
                folderOrigin: .searchResults
            )
        )
    }

    func testPlayerWindowCommandsRemainDistinctForTheSamePlaybackRequest() {
        let requestID = UUID()
        let first = PlayerWindowCommand(
            requestID: requestID,
            kind: .showAndActivate
        )
        let second = PlayerWindowCommand(
            requestID: requestID,
            kind: .focus
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.requestID, second.requestID)
    }

    func testPlayerFocusCompensationStopsAfterFocusOrApplicationSwitch() {
        XCTAssertTrue(
            PlayerWindowFocusCompensationPolicy.shouldRetry(
                isApplicationActive: true,
                isWindowKey: false,
                ownsRequest: true,
                isCommandPending: true
            )
        )
        XCTAssertFalse(
            PlayerWindowFocusCompensationPolicy.shouldRetry(
                isApplicationActive: false,
                isWindowKey: false,
                ownsRequest: true,
                isCommandPending: true
            )
        )
        XCTAssertFalse(
            PlayerWindowFocusCompensationPolicy.shouldRetry(
                isApplicationActive: true,
                isWindowKey: true,
                ownsRequest: true,
                isCommandPending: true
            )
        )
        XCTAssertFalse(
            PlayerWindowFocusCompensationPolicy.shouldRetry(
                isApplicationActive: true,
                isWindowKey: false,
                ownsRequest: false,
                isCommandPending: true
            )
        )
    }

    @MainActor
    func testHistoryPlaybackRequestShowsPlayerSynchronouslyAndDeduplicates()
        async throws {
        let state = AppState.bootstrap()
        let configurationID = UUID()
        let first = HistoryRecord(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "video-1",
            title: "Fixture One",
            sourceKey: "line-1",
            episodeName: "Episode 1"
        )
        let second = HistoryRecord(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "video-2",
            title: "Fixture Two",
            sourceKey: "line-1",
            episodeName: "Episode 1"
        )

        state.requestHistoryPlayback(first)
        let initial = try XCTUnwrap(state.playerWindowCommand)
        XCTAssertTrue(state.isPlayerPresented)
        XCTAssertEqual(state.historyPlaybackLoadingID, first.id)
        XCTAssertEqual(state.playbackResolutionState, .restoringHistory)
        XCTAssertEqual(initial.kind, .showAndActivate)

        state.requestHistoryPlayback(first)
        let duplicate = try XCTUnwrap(state.playerWindowCommand)
        XCTAssertEqual(duplicate.kind, .focus)
        XCTAssertEqual(duplicate.requestID, initial.requestID)
        XCTAssertNotEqual(duplicate.id, initial.id)

        state.requestHistoryPlayback(second)
        let replacement = try XCTUnwrap(state.playerWindowCommand)
        XCTAssertEqual(replacement.kind, .focus)
        XCTAssertNotEqual(replacement.requestID, initial.requestID)
        XCTAssertEqual(state.historyPlaybackLoadingID, second.id)

        await Task.yield()
        XCTAssertTrue(state.canRetryHistoryPlayback)
        XCTAssertNil(state.playerPresentedError)

        await state.closePlayer()
    }

    func testPlaybackErrorsRouteToPlayerOnlyWhileItExists() {
        XCTAssertTrue(
            PlayerErrorPresentationPolicy.targetsPlayer(
                title: "清晰度切换失败",
                isPlayerPresented: true
            )
        )
        XCTAssertFalse(
            PlayerErrorPresentationPolicy.targetsPlayer(
                title: "清晰度切换失败",
                isPlayerPresented: false
            )
        )
        XCTAssertFalse(
            PlayerErrorPresentationPolicy.targetsPlayer(
                title: "配置刷新失败",
                isPlayerPresented: true
            )
        )
    }

    func testConfigurationPresentationFallsBackWhenDetailHostWasDismissed() {
        XCTAssertEqual(
            ConfigurationPresentationTargetPolicy.resolvedTarget(
                requested: .detail,
                hasDetailPresentation: false
            ),
            .mainWindow
        )
        XCTAssertEqual(
            ConfigurationPresentationTargetPolicy.resolvedTarget(
                requested: .detail,
                hasDetailPresentation: true
            ),
            .detail
        )
        XCTAssertEqual(
            ConfigurationPresentationTargetPolicy.resolvedTarget(
                requested: .mainWindow,
                hasDetailPresentation: false
            ),
            .mainWindow
        )
    }

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
                targetUsesNodeRuntime: false,
                ownsCurrentRequest: true
            )
        )
        XCTAssertFalse(
            ConfigurationActivationRuntimePolicy.shouldStopNodeRuntime(
                targetUsesNodeRuntime: false,
                ownsCurrentRequest: false
            )
        )
        XCTAssertFalse(
            ConfigurationActivationRuntimePolicy.shouldStopNodeRuntime(
                targetUsesNodeRuntime: true,
                ownsCurrentRequest: true
            )
        )
    }

    func testConfigurationPostActivationPolicyRejectsStaleABASession() {
        let configurationA = UUID()
        let firstASession = UUID()
        let finalASession = UUID()

        XCTAssertFalse(
            ConfigurationPostActivationPolicy.isCurrent(
                expectedSessionID: firstASession,
                currentSessionID: finalASession,
                expectedConfigurationID: configurationA,
                activeConfigurationID: configurationA
            )
        )
        XCTAssertTrue(
            ConfigurationPostActivationPolicy.isCurrent(
                expectedSessionID: finalASession,
                currentSessionID: finalASession,
                expectedConfigurationID: configurationA,
                activeConfigurationID: configurationA
            )
        )
    }

    func testCacheOnlyStartupPreemptsRemoteFirstStartup() {
        XCTAssertTrue(
            NodeRuntimeStartupPreemptionPolicy.shouldPreempt(
                current: .remoteFirst,
                incoming: .cacheOnly
            )
        )
        XCTAssertFalse(
            NodeRuntimeStartupPreemptionPolicy.shouldPreempt(
                current: .cacheOnly,
                incoming: .remoteFirst
            )
        )
        XCTAssertFalse(
            NodeRuntimeStartupPreemptionPolicy.shouldPreempt(
                current: .cacheOnly,
                incoming: .cacheOnly
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
                isMountEnabled: true,
                hasRenderPlayer: true
            )
        )
        XCTAssertFalse(
            PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: true,
                isMountEnabled: true,
                hasRenderPlayer: false
            )
        )
        XCTAssertFalse(
            PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: true,
                isMountEnabled: false,
                hasRenderPlayer: true
            )
        )
        XCTAssertTrue(
            PlayerSurfaceMountPolicy.shouldMount(
                isPlayerPresented: true,
                isMountEnabled: true,
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

    func testMPVRenderVisibilitySuppressesHiddenAndMiniaturizedSurfaces() {
        XCTAssertTrue(
            MPVRenderVisibilityPolicy.shouldRequestDisplay(
                isAttachedToWindow: true,
                isWindowVisible: true,
                isMiniaturized: false,
                isOcclusionVisible: true
            )
        )
        XCTAssertFalse(
            MPVRenderVisibilityPolicy.shouldRequestDisplay(
                isAttachedToWindow: true,
                isWindowVisible: true,
                isMiniaturized: true,
                isOcclusionVisible: true
            )
        )
        XCTAssertFalse(
            MPVRenderVisibilityPolicy.shouldRequestDisplay(
                isAttachedToWindow: true,
                isWindowVisible: true,
                isMiniaturized: false,
                isOcclusionVisible: false
            )
        )
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

    func testMPVPerformanceProfileDefaultsToBoundedBalancedCache() {
        let suiteName = "OKVideoMacTests.MPVPerformanceProfile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            MPVPlaybackPerformanceProfile.configured(
                environment: [:],
                defaults: defaults
            ),
            .balanced
        )
        let options = Dictionary(
            uniqueKeysWithValues:
                MPVPlaybackPerformanceProfile.balanced.mpvOptions.map {
                    ($0.name, $0.value)
                }
        )
        XCTAssertEqual(options["cache"], "auto")
        XCTAssertEqual(options["cache-secs"], "60")
        XCTAssertEqual(options["demuxer-max-bytes"], "128MiB")
        XCTAssertEqual(options["demuxer-max-back-bytes"], "32MiB")

        defaults.set(
            MPVPlaybackPerformanceProfile.legacy.rawValue,
            forKey: MPVPlaybackPerformanceProfile.defaultsKey
        )
        XCTAssertEqual(
            MPVPlaybackPerformanceProfile.configured(
                environment: [:],
                defaults: defaults
            ),
            .legacy
        )
        XCTAssertEqual(
            MPVPlaybackPerformanceProfile.configured(
                environment: [
                    MPVPlaybackPerformanceProfile.environmentKey:
                        MPVPlaybackPerformanceProfile.balanced.rawValue
                ],
                defaults: defaults
            ),
            .balanced
        )
    }

    func testTVBoxPlaybackUsesScopedCacheAndFormatWithoutChangingStandardLoad() throws {
        let bridgeURL = try XCTUnwrap(URL(
            string: "http://127.0.0.1:19978/proxy/media/session-id"
        ))
        let standard = ResolvedMedia(
            url: bridgeURL,
            headers: [:],
            format: "application/vnd.apple.mpegurl",
            siteKey: "site",
            sourceName: "线路",
            episodeName: "第 1 集"
        )
        XCTAssertEqual(
            MPVTVBoxPlaybackPolicy.loadCommand(for: standard),
            ["loadfile", bridgeURL.absoluteString, "replace"]
        )

        var tvBox = standard
        tvBox.transportProfile = .tvBox
        let command = MPVTVBoxPlaybackPolicy.loadCommand(for: tvBox)
        XCTAssertEqual(Array(command.prefix(4)), [
            "loadfile", bridgeURL.absoluteString, "replace", "-1"
        ])
        let options = try XCTUnwrap(command.last)
        XCTAssertTrue(options.contains("cache-secs=24"))
        XCTAssertTrue(options.contains("demuxer-max-bytes=48MiB"))
        XCTAssertTrue(options.contains("demuxer-max-back-bytes=12MiB"))
        XCTAssertTrue(options.contains("demuxer-lavf-format=hls"))

        let fallback = MPVTVBoxPlaybackPolicy.loadCommand(
            for: tvBox,
            omitFormatHint: true
        )
        XCTAssertFalse(try XCTUnwrap(fallback.last).contains(
            "demuxer-lavf-format"
        ))
    }

    func testMPVRenderControlDefaultsToAdvancedWithLegacyRollback() {
        let suiteName = "OKVideoMacTests.MPVRenderControl.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            MPVRenderControlMode.configured(
                environment: [:],
                defaults: defaults
            ),
            .advanced
        )
        XCTAssertTrue(MPVRenderControlMode.advanced.usesAdvancedControl)
        XCTAssertFalse(MPVRenderControlMode.legacy.usesAdvancedControl)

        XCTAssertEqual(
            MPVRenderControlMode.configured(
                environment: [
                    MPVRenderControlMode.environmentKey:
                        MPVRenderControlMode.legacy.rawValue
                ],
                defaults: defaults
            ),
            .legacy
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

    @MainActor
    func testTVBoxWarmRetentionIsCancelledByImmediateReplay() async throws {
        let controller = PlayerLifecycleController(mode: .fullDestroy)
        guard let original = controller.renderPlayer else {
            throw XCTSkip("libmpv is unavailable in this test environment")
        }
        let originalID = original.renderOwnerID
        await controller.closeAfterPlayback(
            requestID: UUID(),
            warmRetentionSeconds: 1
        )
        XCTAssertEqual(controller.renderPlayer?.renderOwnerID, originalID)

        let replay = try await controller.prepareForPlayback(requestID: UUID())
        XCTAssertEqual(replay.renderOwnerID, originalID)
        await controller.shutdown()
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
                key: "source-disabled",
                name: "Source Disabled",
                availability: .userDisabled
            ),
            SearchScopeSiteOption(
                key: "disabled",
                name: "Disabled",
                unavailableReason: "站点声明不支持搜索"
            )
        ]

        XCTAssertEqual(
            SearchSiteScopePolicy.effectiveSiteKeys(scope: .all, options: options),
            ["a", "b", "source-disabled"]
        )
    }

    func testCustomSearchScopeCanStillExcludeSourceDisabledSite() {
        let options = [
            SearchScopeSiteOption(key: "a", name: "A", unavailableReason: nil),
            SearchScopeSiteOption(
                key: "source-disabled",
                name: "Source Disabled",
                availability: .userDisabled
            )
        ]
        let scope = SearchSiteScope(mode: .custom, selectedSiteKeys: ["a"])

        XCTAssertEqual(
            SearchSiteScopePolicy.effectiveSiteKeys(scope: scope, options: options),
            ["a"]
        )
    }

    func testDynamicSiteCatalogRecognizesProfileGeneratedProviders() {
        let staticSite = SiteConfiguration(
            key: "nodejs_bili_all",
            name: "Bili",
            type: 3,
            api: "/spider/bili_all/3"
        )
        let dynamicSite = SiteConfiguration(
            key: "nodejs_alist_profile-generated",
            name: "AList",
            type: 3,
            api: "/spider/alist_profile-generated/3"
        )

        XCTAssertFalse(
            NodeDynamicSiteCatalogPolicy.containsConfiguredProvider(
                in: [staticSite]
            )
        )
        XCTAssertTrue(
            NodeDynamicSiteCatalogPolicy.containsConfiguredProvider(
                in: [staticSite, dynamicSite]
            )
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

    func testSearchScopeDoesNotPreExcludeSearchableZeroNodeSite() {
        let site = SiteConfiguration(
            key: "node-utility",
            name: "Renamed Utility",
            type: 3,
            api: "/spider/utility/3",
            searchable: 0,
            extra: [
                "okNodeRuntime": .bool(true),
                "okNodeSearchCapabilityState": .string("unsupported"),
                "okNodeCapabilities": .array([])
            ]
        )

        XCTAssertEqual(
            SearchScopeSiteAvailabilityPolicy.availability(
                for: site,
                providerCapability: .javaScriptSpider
            ),
            .enabled
        )
    }

    func testSearchScopeKeepsFullCatalogueDisabledSiteOptIn() {
        let site = SiteConfiguration(
            key: "catalogue-disabled",
            name: "Disabled in Source",
            type: 3,
            api: "/spider/disabled/3",
            searchable: 2,
            extra: ["okNodeCatalogDisabled": .bool(true)]
        )

        XCTAssertEqual(
            SearchScopeSiteAvailabilityPolicy.availability(
                for: site,
                providerCapability: .javaScriptSpider
            ),
            .userDisabled
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

    func testHomeIndexCardRoutesDirectlyToSearchWithoutNameHeuristics() {
        let summary = VideoSummary(
            siteKey: "opaque-index",
            siteName: "Renamed Provider",
            videoID: "provider-owned-id",
            title: "索引影片"
        )
        let indexSite = SiteConfiguration(
            key: "opaque-index",
            name: "Completely Renamed",
            type: 4,
            api: "/spider/index/4",
            indexs: 1
        )
        let detailSite = SiteConfiguration(
            key: "opaque-index",
            name: "Completely Renamed",
            type: 4,
            api: "/spider/index/4",
            indexs: 0
        )

        XCTAssertEqual(
            HomeItemRoutePolicy.route(summary: summary, site: indexSite),
            .search
        )
        XCTAssertEqual(
            HomeItemRoutePolicy.route(summary: summary, site: detailSite),
            .detail
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

    @MainActor
    func testPlayerTimelineDoesNotInvalidateWholeAppState() {
        let state = AppState.bootstrap()
        var appStateUpdateCount = 0
        var snapshotUpdateCount = 0
        let appStateObservation = state.objectWillChange.sink {
            appStateUpdateCount += 1
        }
        let snapshotObservation = state.playerSnapshotState.objectWillChange.sink {
            snapshotUpdateCount += 1
        }
        var snapshot = state.playerSnapshot
        snapshot.position = 12

        state.playerSnapshotState.update(snapshot)

        XCTAssertEqual(state.playerSnapshot.position, 12)
        XCTAssertEqual(appStateUpdateCount, 0)
        XCTAssertEqual(snapshotUpdateCount, 1)
        withExtendedLifetime((appStateObservation, snapshotObservation)) {}
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

    func testHomeResumeKeepsCompleteCategoryState() {
        let home = SiteHome(
            categories: [VideoCategory(id: "movie", name: "电影")],
            recommendations: []
        )

        XCTAssertEqual(
            HomeResumePolicy.action(
                home: home,
                selection: .category("movie"),
                selectedCategoryID: "movie",
                hasCategoryPage: true,
                lastCategoryID: nil
            ),
            .keep
        )
    }

    func testHomeResumeReloadsSelectedCategoryWhenItsPageIsMissing() {
        let home = SiteHome(
            categories: [VideoCategory(id: "movie", name: "电影")],
            recommendations: []
        )

        XCTAssertEqual(
            HomeResumePolicy.action(
                home: home,
                selection: .category("movie"),
                selectedCategoryID: "movie",
                hasCategoryPage: false,
                lastCategoryID: nil
            ),
            .loadCategory("movie")
        )
    }

    func testHomeResumeRepairsMissingPresentationWithRecommendationFirst() {
        let home = SiteHome(
            categories: [VideoCategory(id: "movie", name: "电影")],
            recommendations: [
                VideoSummary(
                    siteKey: "site",
                    siteName: "站点",
                    videoID: "featured",
                    title: "推荐"
                )
            ]
        )

        XCTAssertEqual(
            HomeResumePolicy.action(
                home: home,
                selection: .empty,
                selectedCategoryID: nil,
                hasCategoryPage: false,
                lastCategoryID: "movie"
            ),
            .showRecommendation
        )
    }

    func testHomeResumeUsesLastCategoryBeforeFirstCategoryWithoutRecommendations() {
        let home = SiteHome(
            categories: [
                VideoCategory(id: "movie", name: "电影"),
                VideoCategory(id: "series", name: "剧集")
            ],
            recommendations: []
        )

        XCTAssertEqual(
            HomeResumePolicy.action(
                home: home,
                selection: .empty,
                selectedCategoryID: nil,
                hasCategoryPage: false,
                lastCategoryID: "series"
            ),
            .loadCategory("series")
        )
    }

    func testHomePresentationDetectsTheBlankPartialState() {
        let home = SiteHome(
            categories: [VideoCategory(id: "movie", name: "电影")],
            recommendations: []
        )

        XCTAssertFalse(
            HomeResumePolicy.isStructurallyValid(
                home: home,
                selection: .empty,
                selectedCategoryID: nil
            )
        )
    }

    func testSelectingTheCurrentLoadedSiteIsIdempotent() {
        XCTAssertFalse(
            HomeSiteSelectionPolicy.requiresTransition(
                requestedKey: "site-a",
                currentKey: "site-a",
                hasCurrentHome: true,
                isCurrentContent: true,
                isHomeLoading: false
            )
        )
        XCTAssertTrue(
            HomeSiteSelectionPolicy.requiresTransition(
                requestedKey: "site-b",
                currentKey: "site-a",
                hasCurrentHome: true,
                isCurrentContent: true,
                isHomeLoading: false
            )
        )
    }

    func testLeavingSearchClearsToolbarKeyword() async {
        await MainActor.run {
            let state = AppState(environment: nil)
            state.searchDraftKeyword = "寒战 1994"
            state.presentHomeSearch()

            state.selectSection(.history)

            XCTAssertFalse(state.isHomeSearchPresented)
            XCTAssertEqual(state.searchDraftKeyword, "")
            XCTAssertEqual(state.activeSearchKeyword, "")
            XCTAssertEqual(state.selectedSection, .history)
        }
    }

    func testSidebarSearchUsesSectionSpecificLanguage() {
        let video = SidebarSearchPresentationPolicy.presentation(for: .home)
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.placeholder, "搜索点播内容…")
        XCTAssertEqual(video.accessibilityLabel, "搜索点播内容")

        let live = SidebarSearchPresentationPolicy.presentation(for: .live)
        XCTAssertEqual(live.kind, .liveChannels)
        XCTAssertEqual(live.placeholder, "搜索频道…")
        XCTAssertEqual(live.accessibilityLabel, "搜索直播频道")

        for section in [AppSection.favorites, .history, .settings] {
            XCTAssertEqual(
                SidebarSearchPresentationPolicy.presentation(for: section).kind,
                .video
            )
        }
    }

    func testSidebarRowHoverOnlyAddsACompactEnabledOverlay() {
        XCTAssertEqual(
            SidebarRowHoverPolicy.hoverOverlayOpacity(
                isSelected: false,
                isHovering: false,
                isEnabled: true
            ),
            0
        )
        XCTAssertEqual(
            SidebarRowHoverPolicy.hoverOverlayOpacity(
                isSelected: false,
                isHovering: true,
                isEnabled: true
            ),
            0.06
        )
        XCTAssertEqual(
            SidebarRowHoverPolicy.hoverOverlayOpacity(
                isSelected: true,
                isHovering: true,
                isEnabled: true
            ),
            0.04
        )
        XCTAssertEqual(
            SidebarRowHoverPolicy.hoverOverlayOpacity(
                isSelected: false,
                isHovering: true,
                isEnabled: false
            ),
            0
        )
        XCTAssertEqual(SidebarRowHoverPolicy.cornerRadius, 6)
        XCTAssertEqual(SidebarRowHoverPolicy.animationDuration, 0.11)
        XCTAssertEqual(
            SidebarRowHoverPolicy.selectionBackgroundOpacity,
            0.10
        )
    }

    func testSidebarVideoSearchReturnsToItsOriginSection() async {
        await MainActor.run {
            let state = AppState(environment: nil)
            state.selectSection(.history)

            state.searchFromSidebar("寒战 1994")

            XCTAssertTrue(state.isHomeSearchPresented)
            XCTAssertEqual(state.selectedSection, .home)
            XCTAssertEqual(state.homeSearchReturnSection, .history)
            XCTAssertEqual(state.homeSearchBackTitle, "返回历史")

            state.returnFromSearchToOrigin()

            XCTAssertFalse(state.isHomeSearchPresented)
            XCTAssertEqual(state.selectedSection, .history)
            XCTAssertEqual(state.searchDraftKeyword, "")
            XCTAssertEqual(state.activeSearchKeyword, "")
            XCTAssertNil(state.homeSearchReturnSection)
        }
    }

    func testClearingSidebarSearchRestoresTheOriginSection() async {
        await MainActor.run {
            let state = AppState(environment: nil)
            state.selectSection(.favorites)
            state.searchFromSidebar("电影")

            state.clearGlobalVideoSearch()

            XCTAssertFalse(state.isHomeSearchPresented)
            XCTAssertEqual(state.selectedSection, .favorites)
            XCTAssertEqual(state.searchDraftKeyword, "")
            XCTAssertEqual(state.activeSearchKeyword, "")
        }
    }

    func testEditingSearchDraftDoesNotRenameTheActiveResultSet() async {
        await MainActor.run {
            let state = AppState(environment: nil)
            state.selectSection(.history)
            state.searchFromSidebar("你好旧时光")

            XCTAssertEqual(state.searchDraftKeyword, "你好旧时光")
            XCTAssertEqual(state.activeSearchKeyword, "你好旧时光")

            state.searchDraftKeyword = "尚未提交的新关键词"

            XCTAssertEqual(state.searchDraftKeyword, "尚未提交的新关键词")
            XCTAssertEqual(state.activeSearchKeyword, "你好旧时光")
            XCTAssertTrue(state.isHomeSearchPresented)
            XCTAssertEqual(state.homeSearchReturnSection, .history)
        }
    }

    func testGlobalSearchFocusDoesNotChangeTheCurrentSection() async {
        await MainActor.run {
            let state = AppState(environment: nil)
            state.selectSection(.live)
            let previousRequest = state.globalSearchFocusRequest

            state.focusGlobalSearch()

            XCTAssertEqual(state.selectedSection, .live)
            XCTAssertEqual(
                state.globalSearchFocusRequest,
                previousRequest &+ 1
            )
        }
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

        let items = HomePresentationPolicy.actionItems(
            from: page,
            inheritedFrom: category
        )
        XCTAssertEqual(items.map(\.itemID), ["action-item", "movie-item"])
        XCTAssertEqual(
            items.map(\.resolvedRoute),
            [
                .providerSelection(itemID: "action-item"),
                .providerSelection(itemID: "movie-item")
            ]
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
            restored.actionItems.first?.resolvedRoute,
            .actionCategory(categoryID: "settings-entry")
        )
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

    func testCategoryFilterReloadPreservesTheVisibleFirstPage() {
        XCTAssertTrue(
            CategoryReloadPresentationPolicy.shouldPreserveCurrentPage(
                requestedPage: 1,
                requestedCategoryID: "movie",
                currentCategoryID: "movie",
                hasCurrentPage: true
            )
        )
        XCTAssertFalse(
            CategoryReloadPresentationPolicy.shouldPreserveCurrentPage(
                requestedPage: 1,
                requestedCategoryID: "series",
                currentCategoryID: "movie",
                hasCurrentPage: true
            )
        )
        XCTAssertFalse(
            CategoryReloadPresentationPolicy.shouldPreserveCurrentPage(
                requestedPage: 2,
                requestedCategoryID: "movie",
                currentCategoryID: "movie",
                hasCurrentPage: true
            )
        )
    }

    func testFilterOverflowShowsEveryOptionWhenTheyFit() {
        let options = [
            VideoFilterOption(name: "全部", value: "all"),
            VideoFilterOption(name: "电影", value: "movie"),
            VideoFilterOption(name: "电视剧", value: "series")
        ]

        let visibility = FilterOverflowLayoutPolicy.visibility(
            options: options,
            selectedValue: "movie",
            availableWidth: 10_000
        )

        XCTAssertEqual(visibility.visibleValues, ["all", "movie", "series"])
        XCTAssertTrue(visibility.hiddenValues.isEmpty)
    }

    func testFilterChipsUseOneWidthForTextAndYears() {
        XCTAssertEqual(
            FilterOverflowLayoutPolicy.chipWidth(title: "喜剧"),
            FilterOverflowLayoutPolicy.chipWidth(title: "2026")
        )
        XCTAssertEqual(
            FilterOverflowLayoutPolicy.chipWidth(title: "中国香港"),
            FilterOverflowLayoutPolicy.uniformChipWidth
        )
    }

    func testFilterOverflowKeepsAnOverflowSelectionVisible() {
        let options = [
            VideoFilterOption(name: "全部", value: "all"),
            VideoFilterOption(name: "中国大陆", value: "china"),
            VideoFilterOption(name: "中国香港", value: "hong-kong"),
            VideoFilterOption(name: "美国", value: "usa"),
            VideoFilterOption(name: "日本", value: "japan"),
            VideoFilterOption(name: "法国", value: "france")
        ]

        let visibility = FilterOverflowLayoutPolicy.visibility(
            options: options,
            selectedValue: "france",
            availableWidth: 180
        )

        XCTAssertTrue(visibility.visibleValues.contains("france"))
        XCTAssertFalse(visibility.hiddenValues.contains("france"))
        XCTAssertFalse(visibility.hiddenValues.isEmpty)
        XCTAssertEqual(
            Set(visibility.visibleValues + visibility.hiddenValues),
            Set(options.map(\.value))
        )
    }

    func testFilterOverflowUsesLastAvailableColumnForAdjacentMoreButton() {
        let options = (0..<8).map {
            VideoFilterOption(name: "选项\($0)", value: "value-\($0)")
        }
        let fourColumnWidth =
            HomeBrowseGridMetrics.chipWidth * 4
            + HomeBrowseGridMetrics.columnSpacing * 3

        let visibility = FilterOverflowLayoutPolicy.visibility(
            options: options,
            selectedValue: "value-1",
            availableWidth: fourColumnWidth
        )

        XCTAssertEqual(
            FilterOverflowLayoutPolicy.columnCapacity(
                availableWidth: fourColumnWidth
            ),
            4
        )
        XCTAssertEqual(visibility.visibleValues.count, 3)
        XCTAssertEqual(visibility.hiddenValues.count, 5)
        XCTAssertTrue(visibility.visibleValues.contains("value-0"))
        XCTAssertTrue(visibility.visibleValues.contains("value-1"))
    }

    func testHomeBrowseGridUsesOneColumnRhythm() {
        XCTAssertEqual(
            HomeBrowseGridMetrics.optionLeadingInset,
            HomeBrowseGridMetrics.labelWidth
                + HomeBrowseGridMetrics.labelContentSpacing
        )
        XCTAssertEqual(
            FilterOverflowLayoutPolicy.uniformChipWidth,
            HomeBrowseGridMetrics.chipWidth
        )
        XCTAssertEqual(
            FilterOverflowLayoutPolicy.chipSpacing,
            HomeBrowseGridMetrics.columnSpacing
        )
        XCTAssertEqual(
            HomeBrowseGridMetrics.categoryLeadingInset,
            8
        )
    }

    func testHomeFilterDefaultsDoNotProduceActiveTokens() {
        let filters = homeFilterFixtures()
        let defaults = HomeFilterPresentationPolicy.defaultSelection(
            filters: filters
        )

        XCTAssertEqual(defaults, ["type": "all", "year": "all-years"])
        XCTAssertTrue(
            HomeFilterPresentationPolicy.activeTokens(
                filters: filters,
                selection: defaults
            ).isEmpty
        )
    }

    func testHomeFilterTokensUseDynamicFilterAndOptionNames() {
        let filters = homeFilterFixtures()
        let tokens = HomeFilterPresentationPolicy.activeTokens(
            filters: filters,
            selection: ["type": "comedy", "year": "2026"]
        )

        XCTAssertEqual(tokens.map(\.filterName), ["类型", "年代"])
        XCTAssertEqual(tokens.map(\.optionName), ["喜剧", "2026"])
    }

    func testResettingOneHomeFilterPreservesOtherSelections() {
        let filters = homeFilterFixtures()
        let reset = HomeFilterPresentationPolicy.resetting(
            filterID: "type",
            filters: filters,
            selection: ["type": "comedy", "year": "2026"]
        )

        XCTAssertEqual(reset, ["type": "all", "year": "2026"])
    }

    private func homeFilterFixtures() -> [VideoFilter] {
        [
            VideoFilter(
                id: "type",
                name: "类型",
                options: [
                    VideoFilterOption(name: "全部类型", value: "all"),
                    VideoFilterOption(name: "喜剧", value: "comedy")
                ]
            ),
            VideoFilter(
                id: "year",
                name: "年代",
                options: [
                    VideoFilterOption(name: "全部年代", value: "all-years"),
                    VideoFilterOption(name: "2026", value: "2026")
                ]
            )
        ]
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

    func testNodeAuthorizationCompletionRequiresCurrentChallengeAndRequest() {
        let challengeID = UUID()
        let matching = NodeAuthorizationCompletionSignal(
            challengeID: challengeID,
            requestID: "request-current",
            provider: "fixture",
            profileRevision: "revision-2"
        )
        let staleRequest = NodeAuthorizationCompletionSignal(
            challengeID: challengeID,
            requestID: "request-stale",
            provider: "fixture",
            profileRevision: "revision-2"
        )
        let anotherChallenge = NodeAuthorizationCompletionSignal(
            challengeID: UUID(),
            requestID: "request-current",
            provider: "fixture",
            profileRevision: "revision-2"
        )

        XCTAssertTrue(
            NodeAuthorizationCompletionMatchingPolicy.matches(
                expectedChallengeID: challengeID,
                expectedRequestID: "request-current",
                signal: matching
            )
        )
        XCTAssertFalse(
            NodeAuthorizationCompletionMatchingPolicy.matches(
                expectedChallengeID: challengeID,
                expectedRequestID: "request-current",
                signal: staleRequest
            )
        )
        XCTAssertFalse(
            NodeAuthorizationCompletionMatchingPolicy.matches(
                expectedChallengeID: challengeID,
                expectedRequestID: "request-current",
                signal: anotherChallenge
            )
        )
        XCTAssertFalse(
            NodeAuthorizationCompletionMatchingPolicy.matches(
                expectedChallengeID: challengeID,
                expectedRequestID: nil,
                signal: matching
            )
        )
    }

    func testLegacyProfileRevisionTriggersOnlyOnePlaybackVerification() {
        XCTAssertTrue(
            NodeProfileRevisionVerificationPolicy.shouldVerifyAutomatically(
                isPlayback: true,
                requestID: nil,
                allowsAutomaticRetry: true,
                hasAttemptedVerification: false
            )
        )
        XCTAssertFalse(
            NodeProfileRevisionVerificationPolicy.shouldVerifyAutomatically(
                isPlayback: true,
                requestID: nil,
                allowsAutomaticRetry: true,
                hasAttemptedVerification: true
            )
        )
        XCTAssertFalse(
            NodeProfileRevisionVerificationPolicy.shouldVerifyAutomatically(
                isPlayback: true,
                requestID: "explicit-request",
                allowsAutomaticRetry: true,
                hasAttemptedVerification: false
            )
        )
        XCTAssertFalse(
            NodeProfileRevisionVerificationPolicy.shouldVerifyAutomatically(
                isPlayback: false,
                requestID: nil,
                allowsAutomaticRetry: true,
                hasAttemptedVerification: false
            )
        )
    }

    func testNodeRuntimeWebsiteLocationRebindsAfterRuntimeRestart() throws {
        let original = try XCTUnwrap(
            URL(string: "http://127.0.0.1:55485/website/account?tab=cloud#qr")
        )
        let location = try XCTUnwrap(NodeRuntimeWebsiteLocation(url: original))
        let restartedEndpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:60241/")
        )

        XCTAssertEqual(
            location.resolved(against: restartedEndpoint)?.absoluteString,
            "http://127.0.0.1:60241/website/account?tab=cloud#qr"
        )
        XCTAssertNil(
            NodeRuntimeWebsiteLocation(
                url: try XCTUnwrap(
                    URL(string: "http://127.0.0.1:55485/ordinary-page")
                )
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

    func testConfigurationCoordinatorGenerationRejectsLateCallbackWhenIDIsReused() {
        let identity = HomeContentIdentity(
            configurationID: UUID(),
            siteKey: "site"
        )
        let reusedInteractionID = UUID()
        var coordinator = ConfigurationInteractionCoordinator()
        let first = coordinator.begin(
            sourceIdentity: identity,
            semantic: .qrAuthorization,
            transport: .native,
            title: "First playback",
            interactionID: reusedInteractionID
        )
        let replacement = coordinator.begin(
            sourceIdentity: identity,
            semantic: .qrAuthorization,
            transport: .native,
            title: "Replacement playback",
            interactionID: reusedInteractionID
        )

        XCTAssertEqual(first.interactionID, replacement.interactionID)
        XCTAssertGreaterThan(replacement.generation, first.generation)
        XCTAssertFalse(
            coordinator.owns(
                reusedInteractionID,
                generation: first.generation
            )
        )
        XCTAssertTrue(
            coordinator.owns(
                reusedInteractionID,
                generation: replacement.generation
            )
        )
    }

    func testConfigurationStateRequiresOwnedScopedIdentity() {
        let interactionID = UUID()
        func state(_ rawID: String?) -> AndroidBridgeUIState {
            AndroidBridgeUIState(
                interactionID: rawID,
                revision: 1,
                kind: "configuration",
                phase: "awaitingUser",
                generation: 1,
                outcome: "pending",
                terminal: false,
                error: nil
            )
        }

        XCTAssertTrue(
            ConfigurationInteractionStatePolicy.accepts(
                state(interactionID.uuidString),
                interactionID: interactionID,
                requiresScopedIdentity: true
            )
        )
        XCTAssertFalse(
            ConfigurationInteractionStatePolicy.accepts(
                state(UUID().uuidString),
                interactionID: interactionID,
                requiresScopedIdentity: true
            )
        )
        XCTAssertFalse(
            ConfigurationInteractionStatePolicy.accepts(
                state(nil),
                interactionID: interactionID,
                requiresScopedIdentity: true
            )
        )
        XCTAssertTrue(
            ConfigurationInteractionStatePolicy.accepts(
                state(nil),
                interactionID: interactionID,
                requiresScopedIdentity: false
            )
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

    func testCloudAccountStatusIsScopedToExactProviderOwner() {
        let providerID = CloudAccountProviderIdentity.identifier(
            capability: .javaDexSpider,
            api: "csp_MyDriveGuard"
        )!
        var store = CloudAccountStatusStore()

        XCTAssertTrue(
            store.observe(
                title: "我的夸父 - 已登录",
                scopeID: providerID
            )
        )
        XCTAssertEqual(
            store.reconciledTitle(
                "我的夸父 - 未登录",
                scopeID: providerID
            ),
            "我的夸父 - 已登录"
        )
    }

    func testFishConfigurationCenterUsesCloudAccountAuthorizationContract() {
        XCTAssertTrue(
            MyDriveGuardActionContract.supportsAccountAuthorization(
                api: "csp_FishConfig"
            )
        )
        XCTAssertTrue(
            MyDriveGuardActionContract.supportsAccountAuthorization(
                api: " csp_MyDriveGuard "
            )
        )
        XCTAssertFalse(
            MyDriveGuardActionContract.supportsAccountAuthorization(
                api: "csp_Unrelated"
            )
        )

        let site = SiteConfiguration(
            key: "settings-center",
            name: "设置中心",
            type: 3,
            api: "csp_FishConfig"
        )
        let home = SiteHome(
            categories: [VideoCategory(id: "peizhi", name: "网盘设置")],
            recommendations: [],
            actionItems: [
                SiteActionItem(
                    siteKey: site.key,
                    siteName: site.name,
                    itemID: "login",
                    title: "扫码登录",
                    action: "LoginShow"
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
        XCTAssertEqual(normalized.actionItems.first?.tag, "authorization")
    }

    func testCloudAccountStatusReconcilesStatusOnlyConfigurationCard() {
        let providerID = CloudAccountProviderIdentity.identifier(
            capability: .javaDexSpider,
            api: "csp_FishConfig"
        )!
        var store = CloudAccountStatusStore()
        _ = store.observe(
            title: "我的哪哪 - 已登录",
            scopeID: providerID
        )
        let items = [
            SiteActionItem(
                siteKey: "settings",
                siteName: "设置中心",
                itemID: "status",
                title: "当前状态",
                remarks: "未登录"
            ),
            SiteActionItem(
                siteKey: "settings",
                siteName: "设置中心",
                itemID: "login",
                title: "扫码登录",
                remarks: "扫码或输入 Cookie",
                action: "LoginShow"
            )
        ]

        let reconciled = CloudAccountStatusPresentationPolicy.applying(
            to: items,
            accountLabel: "百度网盘",
            scopeID: providerID,
            store: store
        )
        XCTAssertEqual(reconciled[0].remarks, "已登录")
        XCTAssertEqual(reconciled[1].remarks, "扫码或输入 Cookie")

        let unrelated = CloudAccountStatusPresentationPolicy.applying(
            to: items,
            accountLabel: "夸克网盘",
            scopeID: providerID,
            store: store
        )
        XCTAssertEqual(unrelated[0].remarks, "未登录")
    }

    func testCloudAccountStatusDoesNotCrossProviderBoundary() {
        let first = CloudAccountProviderIdentity.identifier(
            capability: .javaDexSpider,
            api: "csp_MyDriveGuard"
        )!
        let second = CloudAccountProviderIdentity.identifier(
            capability: .javaDexSpider,
            api: "csp_OtherDrive"
        )!
        var store = CloudAccountStatusStore()
        _ = store.observe(title: "我的优汐 - 已登录", scopeID: first)

        XCTAssertEqual(
            store.reconciledTitle(
                "我的优汐 - 未登录",
                scopeID: second
            ),
            "我的优汐 - 未登录"
        )
    }

    func testCloudAccountStatusRejectsTransientUnauthenticatedSnapshot() {
        let providerID = CloudAccountProviderIdentity.identifier(
            capability: .javaDexSpider,
            api: "csp_MyDriveGuard"
        )!
        var store = CloudAccountStatusStore()
        _ = store.observe(title: "我的阿狸 - 已登录", scopeID: providerID)

        XCTAssertFalse(
            store.observe(
                title: "我的阿狸 - 未登录",
                scopeID: providerID
            )
        )
        XCTAssertEqual(
            store.reconciledTitle(
                "我的阿狸 - 未登录",
                scopeID: providerID
            ),
            "我的阿狸 - 已登录"
        )
        XCTAssertFalse(
            store.observe(
                title: "我的阿狸 - 正在确认",
                scopeID: providerID
            )
        )
        XCTAssertEqual(
            store.reconciledTitle(
                "我的阿狸 - 正在确认",
                scopeID: providerID
            ),
            "我的阿狸 - 已登录"
        )
        XCTAssertTrue(
            store.observe(
                title: "我的阿狸 - 未登录",
                scopeID: providerID,
                explicitlyUnauthenticated: true
            )
        )
        XCTAssertEqual(
            store.reconciledTitle(
                "我的阿狸 - 已登录",
                scopeID: providerID
            ),
            "我的阿狸 - 未登录"
        )
    }

    func testCloudAccountClearCommandOnlyInvalidatesMatchingAccount() {
        let providerID = CloudAccountProviderIdentity.identifier(
            capability: .javaDexSpider,
            api: "csp_MyDriveGuard"
        )!
        var store = CloudAccountStatusStore()
        _ = store.observe(title: "我的夸父 - 已登录", scopeID: providerID)
        _ = store.observe(title: "我的优汐 - 已登录", scopeID: providerID)

        XCTAssertTrue(
            store.invalidate(scopeID: providerID, command: "ucClean")
        )
        XCTAssertEqual(
            store.reconciledTitle(
                "我的夸父 - 未登录",
                scopeID: providerID
            ),
            "我的夸父 - 已登录"
        )
        XCTAssertEqual(
            store.reconciledTitle(
                "我的优汐 - 已登录",
                scopeID: providerID
            ),
            "我的优汐 - 未登录"
        )
    }

    func testCloudAccountStatusPersistsWithoutCredentials() throws {
        let providerID = CloudAccountProviderIdentity.identifier(
            capability: .javaDexSpider,
            api: "csp_MyDriveGuard"
        )!
        var store = CloudAccountStatusStore()
        _ = store.observe(title: "我的哪哪 - 已登录", scopeID: providerID)

        let restored = try XCTUnwrap(
            store.setting.flatMap(CloudAccountStatusStore.init(setting:))
        )
        XCTAssertEqual(
            restored.status(scopeID: providerID, accountKey: "我的哪哪"),
            .pending
        )
        XCTAssertEqual(
            restored.reconciledTitle(
                "我的哪哪 - 未登录",
                scopeID: providerID
            ),
            "我的哪哪 - 上次已授权"
        )
        XCTAssertFalse(String(describing: restored).contains("Cookie"))
        XCTAssertFalse(String(describing: restored).contains("Token"))
    }

    func testAndroidBridgeUIStateDecodesOnlyScopedSurfaceContract() throws {
        let interactionID = UUID()
        let state = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: Data(#"""
            {
              "interactionID": "\#(interactionID.uuidString)",
              "revision": 8,
              "kind": "authorization",
              "phase": "awaitingUser",
              "generation": 9,
              "outcome": "stay",
              "terminal": false,
              "workerReturned": true,
              "providerOwnerID": "owner",
              "configurationID": "configuration",
              "siteKey": "site",
              "surfaceActive": true,
              "surfaceRequestScoped": true,
              "surfaceInteractionID": "\#(interactionID.uuidString)",
              "surfaceMode": "actionActivity",
              "visible": true,
              "title": "ignored provider title",
              "inputCount": 1,
              "imageCount": 1,
              "buttons": ["ignored"],
              "controls": [{"id":"ignored"}],
              "texts": ["ignored"],
              "uiSchemaVersion": 3,
              "qrStatus": "generating",
              "authorizationStorageFingerprint": "ignored"
            }
            """#.utf8)
        )

        XCTAssertEqual(state.interactionID, interactionID.uuidString)
        XCTAssertEqual(state.interactionGeneration, 9)
        XCTAssertEqual(state.workerReturned, true)
        XCTAssertEqual(state.providerOwnerID, "owner")
        XCTAssertEqual(state.configurationID, "configuration")
        XCTAssertEqual(state.siteKey, "site")
        XCTAssertTrue(state.hasRequestScopedActionSurface)
        XCTAssertTrue(state.isAuthorizationPrompt)
    }

    func testCloudAuthorizationPlaybackOwnershipRejectsStaleRequests() {
        let current = UUID()

        XCTAssertTrue(
            CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
                requestID: current,
                activeRequestID: current,
                playbackSessionID: current,
                isPlayerPresented: true
            )
        )
        XCTAssertFalse(
            CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
                requestID: UUID(),
                activeRequestID: current,
                playbackSessionID: current,
                isPlayerPresented: true
            )
        )
        XCTAssertFalse(
            CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
                requestID: current,
                activeRequestID: current,
                playbackSessionID: current,
                isPlayerPresented: false
            )
        )
        XCTAssertFalse(
            CloudAuthorizationPlaybackOwnershipPolicy.isCurrent(
                requestID: current,
                activeRequestID: current,
                playbackSessionID: UUID(),
                isPlayerPresented: true
            )
        )
    }

    func testPlaybackAuthorizationFastTerminalResumesSameRequestExactlyOnce() {
        let requestID = UUID()
        var resolvingRequestIDs: Set<UUID> = [requestID]
        var gate = PlaybackAuthorizationResumeGate()
        var resumedRequestIDs: [UUID] = []

        func consumeAuthoritativeResult() {
            guard gate.claim(
                requestID: requestID,
                activeRequestID: requestID,
                playbackSessionID: requestID,
                isPlayerPresented: true,
                hasAuthoritativeResult: true,
                requiresAuthoritativeResult: true,
                originalRequestIsResolving: resolvingRequestIDs.contains(
                    requestID
                )
            ) else {
                return
            }
            resumedRequestIDs.append(requestID)
        }

        // A second ordinary click may reuse the existing in-flight player,
        // but an authorization continuation or an authoritative result must
        // always pass through to resolution.
        XCTAssertTrue(
            PlaybackAuthorizationResumeGate.allowsInFlightDuplicateFastPath(
                authorizationRetry: false,
                hasAuthoritativeResult: false
            )
        )
        XCTAssertFalse(
            PlaybackAuthorizationResumeGate.allowsInFlightDuplicateFastPath(
                authorizationRetry: true,
                hasAuthoritativeResult: false
            )
        )
        XCTAssertFalse(
            PlaybackAuthorizationResumeGate.allowsInFlightDuplicateFastPath(
                authorizationRetry: false,
                hasAuthoritativeResult: true
            )
        )

        // Even a terminal value available immediately at presentation cannot
        // resume until the original resolver hands off its lease.
        consumeAuthoritativeResult()
        XCTAssertTrue(resumedRequestIDs.isEmpty)

        // This is the zero-delay handoff performed before awaiting Android UI
        // presentation. The same request consumes its provider result once.
        resolvingRequestIDs.remove(requestID)
        consumeAuthoritativeResult()
        XCTAssertEqual(gate.claimedRequestID, requestID)
        XCTAssertEqual(resumedRequestIDs, [requestID])

        // A duplicate terminal callback cannot consume the authoritative
        // result or trigger the same playback continuation a second time.
        consumeAuthoritativeResult()
        XCTAssertEqual(resumedRequestIDs, [requestID])
    }

    func testAndroidActionSurfacePNGHeaderDimensions() {
        let valid = Data([
            137, 80, 78, 71, 13, 10, 26, 10,
            0, 0, 0, 13, 73, 72, 68, 82,
            0, 0, 4, 56, 0, 0, 9, 96
        ])

        let size = AndroidActionSurfaceFrame.pngPixelSize(valid)
        XCTAssertEqual(size?.width, 1_080)
        XCTAssertEqual(size?.height, 2_400)

        var invalidSignature = valid
        invalidSignature[0] = 0
        XCTAssertNil(AndroidActionSurfaceFrame.pngPixelSize(invalidSignature))
        XCTAssertNil(AndroidActionSurfaceFrame.pngPixelSize(valid.prefix(23)))

        var zeroWidth = valid
        zeroWidth.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        XCTAssertNil(AndroidActionSurfaceFrame.pngPixelSize(zeroWidth))
    }

    func testAndroidActionSurfaceGeometryAspectFitAndPixelMapping() throws {
        let portrait = AndroidActionSurfaceGeometryPolicy.fittedRect(
            container: CGSize(width: 600, height: 600),
            pixels: CGSize(width: 1_080, height: 2_400)
        )
        XCTAssertEqual(portrait.minX, 165, accuracy: 0.000_1)
        XCTAssertEqual(portrait.minY, 0, accuracy: 0.000_1)
        XCTAssertEqual(portrait.width, 270, accuracy: 0.000_1)
        XCTAssertEqual(portrait.height, 600, accuracy: 0.000_1)

        let center = try XCTUnwrap(
            AndroidActionSurfaceGeometryPolicy.pixelPoint(
                location: CGPoint(x: 300, y: 300),
                fittedRect: portrait,
                pixelWidth: 1_080,
                pixelHeight: 2_400
            )
        )
        XCTAssertEqual(center.x, 540)
        XCTAssertEqual(center.y, 1_200)

        let lowerRight = try XCTUnwrap(
            AndroidActionSurfaceGeometryPolicy.pixelPoint(
                location: CGPoint(x: 434.999, y: 599.999),
                fittedRect: portrait,
                pixelWidth: 1_080,
                pixelHeight: 2_400
            )
        )
        XCTAssertEqual(lowerRight.x, 1_079)
        XCTAssertEqual(lowerRight.y, 2_399)
        XCTAssertNil(
            AndroidActionSurfaceGeometryPolicy.pixelPoint(
                location: CGPoint(x: 164.999, y: 300),
                fittedRect: portrait,
                pixelWidth: 1_080,
                pixelHeight: 2_400
            )
        )

        let landscape = AndroidActionSurfaceGeometryPolicy.fittedRect(
            container: CGSize(width: 600, height: 500),
            pixels: CGSize(width: 2_400, height: 1_080)
        )
        XCTAssertEqual(landscape.minX, 0, accuracy: 0.000_1)
        XCTAssertEqual(landscape.minY, 115, accuracy: 0.000_1)
        XCTAssertEqual(landscape.width, 600, accuracy: 0.000_1)
        XCTAssertEqual(landscape.height, 270, accuracy: 0.000_1)
    }

    func testAndroidActionSurfacePresentationUsesNativeAspectWithoutBars() {
        let portrait = AndroidActionSurfacePresentationPolicy.preferredSize(
            pixelWidth: 720,
            pixelHeight: 1_600
        )
        XCTAssertEqual(portrait.width, 234, accuracy: 0.000_1)
        XCTAssertEqual(portrait.height, 520, accuracy: 0.000_1)
        XCTAssertEqual(
            portrait.width / portrait.height,
            720.0 / 1_600.0,
            accuracy: 0.000_1
        )

        let landscape = AndroidActionSurfacePresentationPolicy.preferredSize(
            pixelWidth: 2_400,
            pixelHeight: 1_080
        )
        XCTAssertEqual(landscape.width, 700, accuracy: 0.000_1)
        XCTAssertEqual(landscape.height, 315, accuracy: 0.000_1)
        XCTAssertEqual(
            landscape.width / landscape.height,
            2_400.0 / 1_080.0,
            accuracy: 0.000_1
        )

        let constrainedPortrait =
            AndroidActionSurfacePresentationPolicy.preferredSize(
                pixelWidth: 720,
                pixelHeight: 1_600,
                maximumHeight: 447
            )
        XCTAssertEqual(constrainedPortrait.width, 201.15, accuracy: 0.000_1)
        XCTAssertEqual(constrainedPortrait.height, 447, accuracy: 0.000_1)
    }

    func testCloudAuthorizationPresentationReservesShadowMargin() {
        XCTAssertEqual(
            CloudAuthorizationPresentationPolicy.maximumSurfaceHeight(
                containerHeight: 717
            ),
            417
        )
        XCTAssertEqual(
            CloudAuthorizationPresentationPolicy.maximumSurfaceHeight(
                containerHeight: 900
            ),
            520
        )
        XCTAssertEqual(
            CloudAuthorizationPresentationPolicy.maximumSurfaceHeight(
                containerHeight: 480
            ),
            260
        )
    }

    func testAndroidActionSurfaceLeaseRejectsStaleFrameBeforePublish() {
        let current = UUID()
        let frame = AndroidActionSurfaceFrame(
            interactionID: current,
            providerOwnerID: "owner-a",
            runtimeGeneration: "runtime-a",
            surfaceMode: "externalactivity",
            generation: 8,
            frameSequence: 2,
            pngData: Data(),
            pixelWidth: 1_080,
            pixelHeight: 2_400
        )

        XCTAssertTrue(
            AndroidActionSurfaceLeasePolicy.accepts(
                frame: frame,
                replacing: nil,
                expectedInteractionID: current,
                expectedProviderOwnerID: "owner-a",
                expectedGeneration: 8
            )
        )
        XCTAssertFalse(
            AndroidActionSurfaceLeasePolicy.accepts(
                frame: frame,
                replacing: nil,
                expectedInteractionID: UUID(),
                expectedProviderOwnerID: "owner-a",
                expectedGeneration: 8
            )
        )
        XCTAssertFalse(
            AndroidActionSurfaceLeasePolicy.accepts(
                frame: frame,
                replacing: nil,
                expectedInteractionID: current,
                expectedProviderOwnerID: "owner-b",
                expectedGeneration: 8
            )
        )
        XCTAssertFalse(
            AndroidActionSurfaceLeasePolicy.accepts(
                frame: frame,
                replacing: nil,
                expectedInteractionID: current,
                expectedProviderOwnerID: "owner-a",
                expectedGeneration: 7
            )
        )
        let newerFrame = AndroidActionSurfaceFrame(
            interactionID: current,
            providerOwnerID: "owner-a",
            runtimeGeneration: "runtime-a",
            surfaceMode: "externalactivity",
            generation: 8,
            frameSequence: 3,
            pngData: Data(),
            pixelWidth: 1_080,
            pixelHeight: 2_400
        )
        XCTAssertTrue(
            AndroidActionSurfaceLeasePolicy.accepts(
                frame: newerFrame,
                replacing: frame,
                expectedInteractionID: current,
                expectedProviderOwnerID: "owner-a",
                expectedGeneration: 8
            )
        )
        XCTAssertFalse(
            AndroidActionSurfaceLeasePolicy.accepts(
                frame: frame,
                replacing: newerFrame,
                expectedInteractionID: current,
                expectedProviderOwnerID: "owner-a",
                expectedGeneration: 8
            )
        )
        let restartedRuntimeFrame = AndroidActionSurfaceFrame(
            interactionID: current,
            providerOwnerID: "owner-a",
            runtimeGeneration: "runtime-b",
            surfaceMode: "externalactivity",
            generation: 8,
            frameSequence: 4,
            pngData: Data(),
            pixelWidth: 1_080,
            pixelHeight: 2_400
        )
        XCTAssertFalse(
            AndroidActionSurfaceLeasePolicy.accepts(
                frame: restartedRuntimeFrame,
                replacing: newerFrame,
                expectedInteractionID: current,
                expectedProviderOwnerID: "owner-a",
                expectedGeneration: 8
            )
        )
        XCTAssertTrue(AndroidActionSurfaceLeasePolicy.isExactLease(frame, frame))
        XCTAssertFalse(
            AndroidActionSurfaceLeasePolicy.isExactLease(frame, newerFrame)
        )
    }

    func testAndroidExternalSurfaceRequiresExactNonterminalRequestLease()
        throws {
        let requestID = UUID()
        func decode(
            surfaceID: UUID,
            active: Bool = true,
            terminal: Bool = false,
            mode: String = "externalActivity"
        ) throws -> AndroidBridgeUIState {
            let object: [String: Any] = [
                "interactionID": requestID.uuidString,
                "visible": false,
                "title": "",
                "inputCount": 0,
                "imageCount": 0,
                "buttons": [],
                "terminal": terminal,
                "surfaceActive": active,
                "surfaceRequestScoped": true,
                "surfaceInteractionID": surfaceID.uuidString,
                "surfaceMode": mode
            ]
            return try JSONDecoder().decode(
                AndroidBridgeUIState.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        XCTAssertTrue(
            try decode(surfaceID: requestID).hasRequestScopedActionSurface
        )
        XCTAssertFalse(
            try decode(surfaceID: UUID()).hasRequestScopedActionSurface
        )
        XCTAssertFalse(
            try decode(surfaceID: requestID, active: false)
                .hasRequestScopedActionSurface
        )
        XCTAssertFalse(
            try decode(surfaceID: requestID, terminal: true)
                .hasRequestScopedActionSurface
        )
        XCTAssertTrue(
            try decode(surfaceID: requestID, mode: "actionActivity")
                .hasRequestScopedActionSurface
        )
    }

    func testAndroidActionSessionIgnoresQRCodeLikeWindowMetadata() throws {
        let requestID = UUID()
        let legacy = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: Data(
                """
                {
                  "interactionID":"\(requestID.uuidString)",
                  "visible":true,
                  "title":"扫码登录",
                  "inputCount":1,
                  "imageCount":1,
                  "qrImageCount":1,
                  "buttons":["登录"],
                  "texts":["二维码"],
                  "terminal":false,
                  "surfaceActive":false,
                  "surfaceRequestScoped":true,
                  "surfaceInteractionID":"\(requestID.uuidString)",
                  "surfaceMode":"actionActivity"
                }
                """.utf8
            )
        )
        XCTAssertFalse(legacy.isProviderUIPrompt)

        let actionSession = try JSONDecoder().decode(
            AndroidBridgeUIState.self,
            from: Data(
                """
                {
                  "interactionID":"\(requestID.uuidString)",
                  "visible":false,
                  "title":"",
                  "inputCount":0,
                  "imageCount":0,
                  "buttons":[],
                  "terminal":false,
                  "surfaceActive":true,
                  "surfaceRequestScoped":true,
                  "surfaceInteractionID":"\(requestID.uuidString)",
                  "surfaceMode":"actionActivity"
                }
                """.utf8
            )
        )
        XCTAssertTrue(actionSession.isProviderUIPrompt)
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

    func testMPVSeekUsesRemoteFriendlyAbsoluteKeyframeCommand() {
        XCTAssertEqual(
            MPVPlayerClient.seekCommand(to: 1_008),
            ["seek", "1008.000", "absolute+keyframes"]
        )
    }

    func testSeekConfirmationTrustsNativeCompletionForImpreciseKeyframe() {
        XCTAssertFalse(
            PlayerSeekConfirmationPolicy.hasCompleted(
                snapshot: PlayerSnapshot(
                    position: 900,
                    duration: 5_400,
                    isSeeking: true,
                    seekTarget: 1_008
                )
            )
        )
        XCTAssertTrue(
            PlayerSeekConfirmationPolicy.hasCompleted(
                snapshot: PlayerSnapshot(
                    position: 960,
                    duration: 5_400,
                    isSeeking: false
                )
            ),
            "absolute+keyframes may complete well before the requested time"
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
        XCTAssertFalse(signal.hasStartedPlayback())
        XCTAssertNil(signal.claimPlaybackStarted())
        signal.cancel()

        signal.reset(requestID: fallbackRequestID)
        signal.markFileLoaded()
        XCTAssertEqual(signal.claimPlaybackStarted(), fallbackRequestID)
        XCTAssertTrue(signal.hasStartedPlayback())
        XCTAssertNil(signal.claimPlaybackStarted())
    }

    @MainActor
    func testPlaybackStartupTimeoutBeginsOnlyAfterFileLoadedArmsGate() async throws {
        let controller = PlaybackStartupGateController()
        let requestID = UUID()
        let token = controller.begin(
            requestID: requestID,
            timeoutNanoseconds: 30_000_000
        )

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(
            controller.arm(
                requestID: requestID,
                expectedIdentity: token.identity
            )
        )
        XCTAssertTrue(controller.complete(requestID: requestID))

        var iterator = token.stream.makeAsyncIterator()
        let completion = try await iterator.next()
        XCTAssertNotNil(completion)
    }

    @MainActor
    func testPlaybackStartupGateTimesOutAfterItIsArmed() async {
        let controller = PlaybackStartupGateController()
        let requestID = UUID()
        let token = controller.begin(
            requestID: requestID,
            timeoutNanoseconds: 20_000_000
        )
        XCTAssertTrue(controller.arm(requestID: requestID))

        var iterator = token.stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Armed startup gate unexpectedly completed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("没有产生音视频"))
        }
    }

    func testAndroidBridgeInteractionPollingBacksOffWithinFixedDeadline() {
        XCTAssertEqual(
            AndroidBridgeInteractionPollingPolicy.delayNanoseconds(
                afterAttempt: 0
            ),
            250_000_000
        )
        XCTAssertEqual(
            AndroidBridgeInteractionPollingPolicy.delayNanoseconds(
                afterAttempt: 8
            ),
            500_000_000
        )
        XCTAssertEqual(
            AndroidBridgeInteractionPollingPolicy.delayNanoseconds(
                afterAttempt: 24
            ),
            1_000_000_000
        )

        let startedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(
            AndroidBridgeInteractionPollingPolicy.shouldContinue(
                startedAt: startedAt,
                now: startedAt.addingTimeInterval(599.9)
            )
        )
        XCTAssertFalse(
            AndroidBridgeInteractionPollingPolicy.shouldContinue(
                startedAt: startedAt,
                now: startedAt.addingTimeInterval(600)
            )
        )
    }

    func testMPVTimelinePropertiesAreTheOnlyRateLimitedSnapshots() {
        XCTAssertTrue(MPVPlayerClient.isTimelineProperty("time-pos"))
        XCTAssertTrue(
            MPVPlayerClient.isTimelineProperty("cache-buffering-state")
        )
        XCTAssertTrue(MPVPlayerClient.isTimelineProperty("cache-speed"))
        XCTAssertFalse(MPVPlayerClient.isTimelineProperty("seeking"))
        XCTAssertFalse(MPVPlayerClient.isTimelineProperty("pause"))
        XCTAssertFalse(MPVPlayerClient.isTimelineProperty("volume"))
    }

    func testPlayerActivityOverlayRecognizesSeekAndCacheWaits() {
        XCTAssertFalse(
            PlayerActivityOverlayPolicy.isActive(
                snapshot: PlayerSnapshot(status: .playing)
            )
        )
        XCTAssertTrue(
            PlayerActivityOverlayPolicy.isActive(
                snapshot: PlayerSnapshot(
                    status: .playing,
                    isSeeking: true,
                    seekTarget: 2_188
                )
            )
        )
        XCTAssertTrue(
            PlayerActivityOverlayPolicy.isActive(
                snapshot: PlayerSnapshot(
                    status: .paused,
                    isPausedForCache: true
                )
            )
        )
        XCTAssertTrue(
            PlayerActivityOverlayPolicy.isActive(
                snapshot: PlayerSnapshot(status: .buffering)
            )
        )
        XCTAssertGreaterThan(
            PlayerActivityOverlayPolicy.presentationDelayNanoseconds,
            0
        )
        XCTAssertGreaterThan(
            PlayerActivityOverlayPolicy.minimumVisibleDuration,
            0
        )
    }

    func testPlayerSnapshotKeepsOnlyValidSeekTargets() {
        XCTAssertEqual(
            PlayerSnapshot(
                isSeeking: true,
                seekTarget: 2_188
            ).seekTarget,
            2_188
        )
        XCTAssertNil(PlayerSnapshot(seekTarget: -.infinity).seekTarget)
        XCTAssertNil(PlayerSnapshot(seekTarget: -1).seekTarget)
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
            ["点播", "直播", "收藏", "历史", "设置"]
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

    func testLiveChannelLogoURLCacheAvoidsRepeatedNormalization() throws {
        let streamURL = try XCTUnwrap(URL(string: "https://example.com/live.m3u8"))
        let channel = LiveChannel(
            groupName: "央视频道",
            name: "030 CCTV4K超高清",
            streams: [LiveStream(name: "线路 1", url: streamURL)]
        )
        let cache = LiveChannelLogoURLCache()

        let first = cache.urls(for: channel)
        let second = cache.urls(for: channel)

        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.computationCount, 1)
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
                isReplacingMedia: false,
                hasStartedPlayback: true,
                isSeeking: false,
                isPausedForCache: false,
                position: 99,
                duration: 100
            )
        )
        XCTAssertTrue(
            MPVPlaybackEndPolicy.isNaturalEnd(
                eofReached: true,
                isReplacingMedia: false,
                hasStartedPlayback: true,
                isSeeking: false,
                isPausedForCache: false,
                position: 0,
                duration: 0
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                endFileReason: 2,
                isReplacingMedia: false,
                hasStartedPlayback: true,
                isSeeking: false,
                isPausedForCache: false,
                position: 100,
                duration: 100
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                eofReached: true,
                isReplacingMedia: true,
                hasStartedPlayback: true,
                isSeeking: false,
                isPausedForCache: false,
                position: 100,
                duration: 100
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                eofReached: true,
                isReplacingMedia: false,
                hasStartedPlayback: true,
                isSeeking: true,
                isPausedForCache: false,
                position: 40,
                duration: 100
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                endFileReason: 0,
                isReplacingMedia: false,
                hasStartedPlayback: true,
                isSeeking: false,
                isPausedForCache: true,
                position: 40,
                duration: 100
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                endFileReason: 0,
                isReplacingMedia: false,
                hasStartedPlayback: false,
                isSeeking: false,
                isPausedForCache: false,
                position: 100,
                duration: 100
            )
        )
        XCTAssertFalse(
            MPVPlaybackEndPolicy.isNaturalEnd(
                endFileReason: 0,
                isReplacingMedia: false,
                hasStartedPlayback: true,
                isSeeking: false,
                isPausedForCache: false,
                position: 40,
                duration: 100
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
              "phase": "reattaching",
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

        XCTAssertEqual(interaction.actionKind, .authorization)
        XCTAssertEqual(interaction.phase, .reattaching)
        XCTAssertEqual(interaction.outcome, .pending)
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

    func testInteractionHandleRetiresSurfaceBeforePublishingTerminalResponse()
        async throws {
        let requestID = UUID()
        let recorder = ConfigurationCancellationTestRecorder()
        let handle = InteractionHandle(
            id: requestID,
            actionKind: .authorization,
            terminalCleanup: { receivedID in
                await recorder.recordStarted(receivedID)
            }
        ) {
            ConfigurationInteractionTerminalResponse(
                requestID: requestID,
                outcome: .succeeded,
                providerResult: .string("authorized"),
                error: nil,
                httpStatusCode: 200,
                refreshPerformed: nil
            )
        }

        let terminal = try await handle.finalResponse()
        await recorder.recordAcknowledged(terminal.requestID)

        let events = await recorder.events
        XCTAssertEqual(events, ["start:\(requestID)", "ack:\(requestID)"])
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

    func testAndroidPlaybackContractKeepsParserRequiredResultResolvable() {
        let result = AndroidDexSpiderSiteProvider.applyingPlaybackRequestContract(
            to: SitePlaybackResult(
                url: "https://player.example.invalid/watch/42",
                needsParsing: true,
                flag: "QY"
            ),
            siteHeaders: [:]
        )

        XCTAssertEqual(result.validationPolicy, .preflight)
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

    func testAndroidBridgeMediaSessionUsesScopedLoopbackAndRemoteDirectURL()
        throws {
        let client = AndroidDexBridgeClient()
        let scoped = try client.hostReachableMediaURL(
            "http://127.0.0.1:9978/proxy/media/session-123"
        )
        let remote = try client.hostReachableMediaURL(
            "https://media.example.invalid/movie.mp4?signature=fixture"
        )

        XCTAssertEqual(
            scoped,
            "http://127.0.0.1:19978/proxy/media/session-123"
        )
        XCTAssertEqual(
            AndroidDexBridgeClient.providerMediaSessionID(from: scoped),
            "session-123"
        )
        XCTAssertTrue(AndroidDexBridgeClient.isLoopbackMediaURL(scoped))
        XCTAssertEqual(
            remote,
            "https://media.example.invalid/movie.mp4?signature=fixture"
        )
    }

    func testAndroidBridgeRejectsUnscopedAndroidLoopbackMediaPorts() {
        let client = AndroidDexBridgeClient()
        for raw in [
            "http://127.0.0.1:5266/fishplay/go/quark_vip/movie.mkv",
            "http://localhost:43127/provider-dynamic/movie.m3u8"
        ] {
            XCTAssertThrowsError(try client.hostReachableMediaURL(raw)) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "Android 内部媒体代理未正确转发"
                    )
                )
            }
        }
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
        XCTAssertNil(
            PlaybackPersistencePolicy.sanitizedProviderResourceReference(
                first
            ),
            "Android provider-instance replay locators must remain memory-only"
        )
    }

    func testAndroidProviderContextInvalidRecognitionIsProviderNeutral() {
        XCTAssertTrue(
            AndroidProviderContextRecoveryPolicy.recognizes(
                "Spider 错误：providerUUIDUnavailable"
            )
        )
        XCTAssertTrue(
            AndroidProviderContextRecoveryPolicy.recognizes(
                "provider_uuid_unavailable"
            )
        )
        XCTAssertFalse(
            AndroidProviderContextRecoveryPolicy.recognizes(
                "network unavailable"
            )
        )
    }

    func testAndroidProviderContextRecoveryResetsExactlyOnce() async throws {
        actor Counts {
            var operations = 0
            var resets = 0

            func beginOperation() -> Int {
                operations += 1
                return operations
            }

            func recordReset() {
                resets += 1
            }

            func values() -> (Int, Int) {
                (operations, resets)
            }
        }

        let counts = Counts()
        let value: String = try await AndroidProviderContextRecoveryPolicy
            .recover {
                let attempt = await counts.beginOperation()
                if attempt == 1 {
                    throw AndroidProviderContextInvalid(
                        providerMessage: "providerUUIDUnavailable"
                    )
                }
                return "recovered"
            } reset: {
                await counts.recordReset()
            }

        XCTAssertEqual(value, "recovered")
        let values = await counts.values()
        XCTAssertEqual(values.0, 2)
        XCTAssertEqual(values.1, 1)
    }

    func testAndroidProviderContextRecoveryDoesNotLoopAfterSecondFailure()
        async {
        actor Counts {
            var operations = 0
            var resets = 0

            func beginOperation() {
                operations += 1
            }

            func recordReset() {
                resets += 1
            }

            func values() -> (Int, Int) {
                (operations, resets)
            }
        }

        let counts = Counts()
        do {
            let _: String = try await AndroidProviderContextRecoveryPolicy
                .recover {
                    await counts.beginOperation()
                    throw AndroidProviderContextInvalid(
                        providerMessage: "providerUUIDUnavailable"
                    )
                } reset: {
                    await counts.recordReset()
                }
            XCTFail("a second invalid provider context must be surfaced")
        } catch {
            XCTAssertTrue(error is AndroidProviderContextInvalid)
        }

        let values = await counts.values()
        XCTAssertEqual(values.0, 2)
        XCTAssertEqual(values.1, 1)
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
    func testPlaybackFailureSummaryDeduplicatesRetriesAndClassifiesProxyFailure() {
        XCTAssertEqual(
            AppState.consolidatedPlaybackFailureMessage([
                "夸克原画：播放错误：loading failed",
                "夸克原画：播放错误：loading failed"
            ]),
            "夸克原画：播放错误：loading failed"
        )
        XCTAssertEqual(
            AppState.consolidatedPlaybackFailureMessage([
                "Libvio：Android 内部媒体代理未正确转发",
                "Libvio：Android 内部媒体代理未正确转发"
            ]),
            "Android 内部媒体代理未正确转发"
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

    func testAndroidRuntimeClearsPreviousBootRecordWhenSerialIsUnreachable() {
        XCTAssertEqual(
            AndroidDexBridgeRuntime.runtimeRecordDecision(
                recordedBootIdentifier: "previous-boot",
                currentBootIdentifier: "current-boot",
                processPresent: true,
                processOwned: false,
                deviceReachable: false,
                deviceOwned: false
            ),
            .clearStaleRecord(.previousSystemBoot)
        )
    }

    func testAndroidRuntimeMigratesSmallLegacyBootTimeDrift() {
        let current = "session:529E73D0-0DF3-43B0-8E76-E85456E4B7AF"
            + "|legacy:1787069808:898337"

        XCTAssertTrue(
            AndroidDexBridgeRuntime.bootIdentifiersReferToSameBoot(
                "1787069804:796892",
                current
            )
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.runtimeRecordDecision(
                recordedBootIdentifier: "1787069804:796892",
                currentBootIdentifier: current,
                processPresent: true,
                processOwned: true,
                deviceReachable: true,
                deviceOwned: true
            ),
            .reuseOwnedRuntime
        )
    }

    func testAndroidRuntimeNeverIgnoresBootSessionUUIDMismatch() {
        XCTAssertFalse(
            AndroidDexBridgeRuntime.bootIdentifiersReferToSameBoot(
                "session:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA|legacy:1000:0",
                "session:BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB|legacy:1001:0"
            )
        )
    }

    func testAndroidRuntimeClearsReusedPIDWithoutTouchingThatProcess() {
        XCTAssertEqual(
            AndroidDexBridgeRuntime.processIdentityState(
                processPresent: true,
                processOwned: false
            ),
            .reusedByOtherProcess
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.runtimeRecordDecision(
                recordedBootIdentifier: "current-boot",
                currentBootIdentifier: "current-boot",
                processPresent: true,
                processOwned: false,
                deviceReachable: false,
                deviceOwned: false
            ),
            .clearStaleRecord(.pidReused)
        )
    }

    func testAndroidRuntimeRejectsReachableSerialFromPreviousBoot() {
        XCTAssertEqual(
            AndroidDexBridgeRuntime.runtimeRecordDecision(
                recordedBootIdentifier: "previous-boot",
                currentBootIdentifier: "current-boot",
                processPresent: true,
                processOwned: false,
                deviceReachable: true,
                deviceOwned: false
            ),
            .rejectConflictingRuntime
        )
    }

    func testAndroidRuntimeAdoptsLegacyManifestOnlyForOwnedProcess() {
        XCTAssertEqual(
            AndroidDexBridgeRuntime.runtimeRecordDecision(
                recordedBootIdentifier: nil,
                currentBootIdentifier: "current-boot",
                processPresent: true,
                processOwned: true,
                deviceReachable: false,
                deviceOwned: false
            ),
            .reuseOwnedRuntime
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.runtimeRecordDecision(
                recordedBootIdentifier: nil,
                currentBootIdentifier: "current-boot",
                processPresent: true,
                processOwned: false,
                deviceReachable: false,
                deviceOwned: false
            ),
            .clearStaleRecord(.pidReused)
        )
    }

    func testAndroidRuntimeBootIdentifierIsStableWithinBoot() {
        let first = AndroidDexBridgeRuntime.systemBootIdentifier()
        let second = AndroidDexBridgeRuntime.systemBootIdentifier()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
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
        let automatedTestDevice = root.appendingPathComponent(
            "system-images/android-35/aosp_atd/arm64-v8a"
        )
        let invalid = root.appendingPathComponent(
            "system-images/android-36/google_apis/x86_64"
        )
        try FileManager.default.createDirectory(
            at: valid,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: automatedTestDevice,
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
                atPath: automatedTestDevice
                    .appendingPathComponent("package.xml").path,
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
            Set(
                resolver.installedSystemImages(in: toolchain).map(\.packageID)
            ),
            Set([
                "system-images;android-35;google_apis;arm64-v8a",
                "system-images;android-35;aosp_atd;arm64-v8a"
            ])
        )
        XCTAssertEqual(
            resolver.interactiveSystemImages(in: toolchain).map(\.packageID),
            ["system-images;android-35;google_apis;arm64-v8a"]
        )
    }

    func testAndroidManagedAVDConfigurationUpgradesATDForRendering() {
        let current = """
        hw.gpu.enabled=no
        hw.gpu.mode=auto
        image.sysdir.1=system-images/android-35/aosp_atd/arm64-v8a/
        tag.display=AOSP ATD
        tag.displaynames=AOSP ATD
        tag.id=aosp_atd
        tag.ids=aosp_atd
        target=android-35

        """
        let image = AndroidSystemImage(
            packageID: "system-images;android-35;default;arm64-v8a",
            apiLevel: 35,
            variant: "default",
            architecture: "arm64-v8a"
        )

        XCTAssertTrue(
            AndroidManagedAVDConfiguration
                .requiresInteractiveImageMigration(current)
        )
        let updated = AndroidManagedAVDConfiguration.updating(
            current,
            for: image
        )
        XCTAssertFalse(
            AndroidManagedAVDConfiguration
                .requiresInteractiveImageMigration(updated)
        )
        XCTAssertEqual(
            AndroidManagedAVDConfiguration.value(
                for: "image.sysdir.1",
                in: updated
            ),
            "system-images/android-35/default/arm64-v8a/"
        )
        XCTAssertEqual(
            AndroidManagedAVDConfiguration.value(
                for: "hw.gpu.enabled",
                in: updated
            ),
            "yes"
        )
        XCTAssertEqual(
            AndroidManagedAVDConfiguration.value(
                for: "hw.gpu.mode",
                in: updated
            ),
            "host"
        )
        XCTAssertEqual(
            AndroidManagedAVDConfiguration.value(
                for: "hw.lcd.width",
                in: updated
            ),
            "720"
        )
        XCTAssertEqual(
            AndroidManagedAVDConfiguration.value(
                for: "hw.lcd.height",
                in: updated
            ),
            "1600"
        )
        XCTAssertEqual(
            AndroidManagedAVDConfiguration.value(
                for: "hw.lcd.density",
                in: updated
            ),
            "280"
        )
        XCTAssertEqual(
            AndroidManagedDisplayProfile.logicalWidth,
            411.428_571,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            AndroidManagedDisplayProfile.logicalHeight,
            914.285_714,
            accuracy: 0.000_001
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.managedDisplayProfileMatches(
                sizeOutput: "Physical size: 720x1600\n",
                densityOutput: "Physical density: 280\n",
                fontScaleOutput: "1.0\n"
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.managedDisplayProfileMatches(
                sizeOutput:
                    "Physical size: 320x640\nOverride size: 720x1600\n",
                densityOutput:
                    "Physical density: 160\nOverride density: 280\n",
                fontScaleOutput: "1.0\n"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.managedDisplayProfileMatches(
                sizeOutput: "Physical size: 320x640\n",
                densityOutput: "Physical density: 160\n",
                fontScaleOutput: "1.0\n"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.managedDisplayProfileMatches(
                sizeOutput:
                    "Physical size: 720x1600\nOverride size: 320x640\n",
                densityOutput:
                    "Physical density: 280\nOverride density: 160\n",
                fontScaleOutput: "1.0\n"
            )
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
        XCTAssertTrue(
            AndroidDexBridgeRuntime.healthMatches(
                [
                    "ok": true,
                    "version": "99.0.0",
                    "generation": "current-generation"
                ],
                generation: "current-generation",
                acceptVersionMismatch: true
            )
        )
    }

    func testAndroidBridgeDeploymentNeverDowngradesNewerInstalledBuild() {
        XCTAssertEqual(
            AndroidDexBridgeRuntime.bridgeDeploymentAction(
                installedVersionCode: AndroidDexBridgeRuntime.bridgeVersionCode
                    + 1
            ),
            .activateInstalledNewer(
                versionCode: AndroidDexBridgeRuntime.bridgeVersionCode + 1
            )
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.bridgeDeploymentAction(
                installedVersionCode: AndroidDexBridgeRuntime.bridgeVersionCode
            ),
            .installBundled
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.bridgeDeploymentAction(
                installedVersionCode: nil
            ),
            .installBundled
        )
    }

    func testAndroidBridgeTreatsGhostPackageAsMissingInstallation() {
        let ghostPackageDump = """
        Packages:
          Package [com.okvideomac.dexbridge] (f592963):
            pkg=null
            codePath=/data/app/~~stale/com.okvideomac.dexbridge-stale
            versionCode=999 targetSdk=27
            User 0: installed=true
        """
        XCTAssertNil(
            AndroidDexBridgeRuntime.installedVersionCode(
                from: ghostPackageDump
            )
        )

        let healthyPackageDump = """
        Packages:
          Package [com.okvideomac.dexbridge] (44ce1f4):
            pkg=Package{44ce1f4 com.okvideomac.dexbridge}
            codePath=/data/app/~~valid/com.okvideomac.dexbridge-valid
            versionCode=51 minSdk=24 targetSdk=27
        """
        XCTAssertEqual(
            AndroidDexBridgeRuntime.installedVersionCode(
                from: healthyPackageDump
            ),
            51
        )
    }

    func testAndroidBridgeEqualVersionRequiresExactBundledAPKIdentity() {
        let bundled = String(repeating: "a", count: 64)
        let installed = String(repeating: "b", count: 64)
        XCTAssertFalse(
            AndroidDexBridgeRuntime.bridgeInstallRequired(
                installedVersionCode: AndroidDexBridgeRuntime.bridgeVersionCode,
                installedSHA256: bundled.uppercased(),
                bundledSHA256: bundled
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.bridgeInstallRequired(
                installedVersionCode: AndroidDexBridgeRuntime.bridgeVersionCode,
                installedSHA256: installed,
                bundledSHA256: bundled
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.bridgeInstallRequired(
                installedVersionCode: AndroidDexBridgeRuntime.bridgeVersionCode,
                installedSHA256: nil,
                bundledSHA256: bundled
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.bridgeInstallRequired(
                installedVersionCode: AndroidDexBridgeRuntime.bridgeVersionCode
                    - 1,
                installedSHA256: bundled,
                bundledSHA256: bundled
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.bridgeInstallRequired(
                installedVersionCode: AndroidDexBridgeRuntime.bridgeVersionCode
                    + 1,
                installedSHA256: installed,
                bundledSHA256: bundled
            )
        )
    }

    func testAndroidBridgeParsesOwnedBaseAPKAndSHA256Output() {
        let path = "/data/app/~~abc_123==/com.okvideomac.dexbridge-xyz==/base.apk"
        XCTAssertEqual(
            AndroidDexBridgeRuntime.installedAPKPath(
                from: "package:\(path)\r\n"
            ),
            path
        )
        XCTAssertNil(
            AndroidDexBridgeRuntime.installedAPKPath(
                from: "package:/system/priv-app/Other/base.apk\n"
            )
        )
        let digest = String(repeating: "c", count: 64)
        XCTAssertEqual(
            AndroidDexBridgeRuntime.sha256FromCommandOutput(
                "\(digest)  \(path)\n"
            ),
            digest
        )
        XCTAssertNil(
            AndroidDexBridgeRuntime.sha256FromCommandOutput("not-a-digest")
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

        XCTAssertEqual(
            AndroidDexBridgeRuntime.bridgeApplicationID,
            packageName
        )
        XCTAssertEqual(
            AndroidDexBridgeRuntime.bridgeCertificateSHA256.count,
            64
        )
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

    func testAndroidAVDPersistentFingerprintDetectsDataChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let first = root.appendingPathComponent("first.avd", isDirectory: true)
        let second = root.appendingPathComponent("second.avd", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )
        let config = Data("target=android-35\n".utf8)
        let userdata = Data(repeating: 0x5a, count: 140_000)
        for directory in [first, second] {
            try config.write(to: directory.appendingPathComponent("config.ini"))
            try userdata.write(
                to: directory.appendingPathComponent("userdata-qemu.img.qcow2")
            )
        }
        let firstFingerprint = try AndroidDexBridgeRuntime
            .avdPersistentFingerprint(at: first)
        XCTAssertEqual(
            firstFingerprint,
            try AndroidDexBridgeRuntime.avdPersistentFingerprint(at: second)
        )

        var changed = userdata
        changed[changed.count - 1] = 0x6b
        try changed.write(
            to: second.appendingPathComponent("userdata-qemu.img.qcow2")
        )
        XCTAssertNotEqual(
            firstFingerprint,
            try AndroidDexBridgeRuntime.avdPersistentFingerprint(at: second)
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
        // aapt badging can exceed the pipe buffer. Drain while the child is
        // running; waiting first can deadlock the complete Xcode test suite.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
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

    func testAndroidBridgeInstallMustPreservePackageIdentity() throws {
        let before = try XCTUnwrap(
            AndroidDexBridgeRuntime.installedPackageContinuity(
                from: """
                  userId=10123
                  dataDir=/data/user/0/com.okvideomac.dexbridge
                  firstInstallTime=2026-08-20 10:11:12
                """
            )
        )
        let after = try XCTUnwrap(
            AndroidDexBridgeRuntime.installedPackageContinuity(
                from: """
                  userId=10123
                  dataDir=/data/user/0/com.okvideomac.dexbridge
                  firstInstallTime=2026-08-20 10:11:12
                """
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeRuntime.installPreservesPackageContinuity(
                before: before,
                after: after
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.installPreservesPackageContinuity(
                before: before,
                after: AndroidInstalledPackageContinuity(
                    firstInstallTime: after.firstInstallTime,
                    userID: after.userID + 1,
                    dataDirectory: after.dataDirectory
                )
            )
        )
    }

    func testAndroidBridgeDismissesOnlyItsExactCompatibilityWarning() {
        let windows = """
        Window #0 Window{1 u0 DeprecatedTargetSdkVersionDialog}:
        Window #1 Window{2 u0 com.okvideomac.dexbridge/com.okvideomac.dexbridge.BridgeActivity}:
        """
        XCTAssertTrue(
            AndroidDeprecatedTargetSDKWarningPolicy.shouldInspect(
                windowDump: windows
            )
        )
        XCTAssertFalse(
            AndroidDeprecatedTargetSDKWarningPolicy.shouldInspect(
                windowDump: windows.replacingOccurrences(
                    of: "com.okvideomac.dexbridge",
                    with: "com.example.other"
                )
            )
        )

        let hierarchy = """
        <hierarchy><node text="OKVideo Dex Bridge" bounds="[0,0][10,10]" />
        <node text="OK" resource-id="android:id/button1" class="android.widget.Button" bounds="[228,381][292,429]" /></hierarchy>
        """
        XCTAssertEqual(
            AndroidDeprecatedTargetSDKWarningPolicy.dismissalPoint(
                uiHierarchy: hierarchy
            ),
            .init(x: 260, y: 405)
        )
        XCTAssertNil(
            AndroidDeprecatedTargetSDKWarningPolicy.dismissalPoint(
                uiHierarchy: hierarchy.replacingOccurrences(
                    of: "OKVideo Dex Bridge",
                    with: "Another App"
                )
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
        XCTAssertFalse(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "action"
            )
        )
        XCTAssertFalse(
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

    func testAndroidDexFailedInvocationIgnoresUnscopedLegacyUI()
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

        XCTAssertNil(resolved)
        XCTAssertTrue(states.isEmpty)
    }

    func testAndroidDexRequestDoesNotInferPromptFromLegacyWindowContent()
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

        XCTAssertNil(resolved)
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
    func testVisibleHistoryIsScopedToActiveConfigurationAcrossSites() {
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
                for: first
            ),
            [anotherSiteRecord, firstRecord]
        )
        XCTAssertTrue(
            AppState.historyRecords(
                [firstRecord, secondRecord],
                for: nil
            ).isEmpty
        )
    }

    @MainActor
    func testFongMiBlankSiteActionResultIsSilentCompletion() {
        let placeholder = JSONValue.object([
            "list": .array([.object([:])]),
            "parse": .integer(0),
            "jx": .integer(0)
        ])

        XCTAssertNil(AppState.siteActionMessage(.null))
        XCTAssertNil(AppState.siteActionMessage(.string("")))
        XCTAssertNil(AppState.siteActionMessage(.object([:])))
        XCTAssertNil(AppState.siteActionMessage(placeholder))
        XCTAssertEqual(
            AppState.siteActionMessage(
                .object(["msg": .string("清除成功")])
            ),
            "清除成功"
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

        XCTAssertEqual(size.width, 1_152, accuracy: 0.001)
        XCTAssertEqual(size.height, 648, accuracy: 0.001)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(size.width, visibleFrame.width - 80)
        XCTAssertLessThanOrEqual(size.height, visibleFrame.height - 80)
    }

    @MainActor
    func testWindowLayoutResetIssuesFreshTargetedCommands() throws {
        let state = AppState(environment: nil)

        state.restoreDefaultWindowLayout(.mainWindow)
        let mainCommand = try XCTUnwrap(state.appWindowLayoutCommand)
        XCTAssertEqual(mainCommand.target, .mainWindow)

        state.restoreDefaultWindowLayout(.playerWindow)
        let playerCommand = try XCTUnwrap(state.appWindowLayoutCommand)
        XCTAssertEqual(playerCommand.target, .playerWindow)
        XCTAssertNotEqual(playerCommand.id, mainCommand.id)
    }

    func testMainWindowUsesComfortableDefaultAndFitsSmallScreens() {
        let desktopSize = AppWindowLayoutPolicy.defaultContentSize(
            for: .mainWindow,
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        XCTAssertEqual(desktopSize, NSSize(width: 1_240, height: 780))

        let compactVisibleFrame = NSRect(
            x: 0,
            y: 0,
            width: 1_000,
            height: 700
        )
        let compactSize = AppWindowLayoutPolicy.defaultContentSize(
            for: .mainWindow,
            visibleFrame: compactVisibleFrame
        )
        XCTAssertLessThanOrEqual(
            compactSize.width,
            compactVisibleFrame.width - 80
        )
        XCTAssertLessThanOrEqual(
            compactSize.height,
            compactVisibleFrame.height - 80
        )
    }

    func testPlayerDefaultWindowShrinksWithoutLosingAspectRatio() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 650)
        let size = AppWindowLayoutPolicy.defaultContentSize(
            for: .playerWindow,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(size.width, visibleFrame.width - 80)
        XCTAssertLessThanOrEqual(size.height, visibleFrame.height - 80)
    }

    func testPlayerWindowFrameReturnsFromDisconnectedDisplay() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let disconnectedFrame = NSRect(
            x: 2_800,
            y: 300,
            width: 1_000,
            height: 600
        )
        let adjusted = PlayerWindowFrameVisibilityPolicy.adjustedFrame(
            disconnectedFrame,
            visibleFrames: [visibleFrame],
            fallbackVisibleFrame: visibleFrame
        )

        XCTAssertTrue(visibleFrame.contains(adjusted))
        XCTAssertEqual(adjusted.size, disconnectedFrame.size)

        let alreadyVisible = NSRect(x: 120, y: 90, width: 1_000, height: 600)
        XCTAssertEqual(
            PlayerWindowFrameVisibilityPolicy.adjustedFrame(
                alreadyVisible,
                visibleFrames: [visibleFrame],
                fallbackVisibleFrame: visibleFrame
            ),
            alreadyVisible
        )
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
    func testPlayerWindowChromeUpdatesAspectConstraintWithoutResizing() async {
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
        XCTAssertEqual(window.frame, originalWindowFrame)

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
        XCTAssertEqual(liveFrame, originalWindowFrame)

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
    func testHistoryNavigationRecipeRebuildsFreshEpisodeAfterRestart() throws {
        let configurationID = UUID()
        let originalSource = PlaySource(
            name: "夸父原1",
            episodes: [
                PlayEpisode(
                    name: "[851.30MB] 凛丨冬下的罪恶 04.mp4",
                    url: "expired-runtime-token"
                )
            ]
        )
        let originalDetail = VideoDetail(
            summary: VideoSummary(
                siteKey: "wanou",
                siteName: "玩偶",
                videoID: "129449",
                title: "凛冬下的罪恶"
            ),
            playSources: [originalSource]
        )
        let recipe = AppState.historyNavigationRecipe(
            detail: originalDetail,
            source: originalSource,
            episode: originalSource.episodes[0],
            configurationID: configurationID,
            position: 735.55
        )
        XCTAssertEqual(recipe.episode.normalizedFilename, "凛冬下的罪恶04")

        let encoded = try JSONEncoder().encode(
            HistoryPlaybackReference(
                sourceIdentity: "legacy-source-digest",
                resourceIdentity: "legacy-episode-digest",
                navigationRecipe: recipe
            )
        )
        let restartedReference = try JSONDecoder().decode(
            HistoryPlaybackReference.self,
            from: encoded
        )
        let record = HistoryRecord(
            configurationID: configurationID,
            siteKey: "wanou",
            videoID: "129449",
            title: "凛冬下的罪恶",
            sourceName: "夸父原1",
            episodeName: originalSource.episodes[0].name,
            playbackReference: restartedReference,
            position: 735.55,
            duration: 1_199.872
        )
        let refreshedDetail = VideoDetail(
            summary: originalDetail.summary,
            playSources: [
                PlaySource(
                    name: "升级后的夸父线路",
                    episodes: [
                        PlayEpisode(
                            name: "凛冬下的罪恶.04.mkv",
                            url: "fresh-runtime-token"
                        )
                    ]
                )
            ]
        )

        let selection = AppState.historyPlaybackSelection(
            in: refreshedDetail,
            record: record
        )
        XCTAssertEqual(selection?.episode.url, "fresh-runtime-token")
        XCTAssertEqual(AppState.historyResumePosition(from: record), 735.55)
    }

    @MainActor
    func testHistoryNavigationRecipeOffersChoicesInsteadOfGuessing() {
        let configurationID = UUID()
        let recipe = HistoryNavigationRecipe(
            configurationID: configurationID,
            siteKey: "fixture",
            detailID: "video-1",
            source: HistoryNavigationSource(
                flag: "旧线路",
                name: "旧线路"
            ),
            episode: HistoryNavigationEpisode(
                name: "影片 04.mp4",
                normalizedFilename: "影片04",
                episodeNumber: 4
            )
        )
        let record = HistoryRecord(
            configurationID: configurationID,
            siteKey: "fixture",
            videoID: "video-1",
            title: "影片",
            playbackReference: HistoryPlaybackReference(
                sourceIdentity: "old-source",
                resourceIdentity: "old-episode",
                navigationRecipe: recipe
            )
        )
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: "fixture",
                siteName: "Fixture",
                videoID: "video-1",
                title: "影片"
            ),
            playSources: [
                PlaySource(
                    name: "新线路 A",
                    episodes: [PlayEpisode(name: "影片 04.mp4", url: "a")]
                ),
                PlaySource(
                    name: "新线路 B",
                    episodes: [PlayEpisode(name: "影片 04.mp4", url: "b")]
                )
            ]
        )

        XCTAssertNil(AppState.historyPlaybackSelection(in: detail, record: record))
        XCTAssertEqual(
            AppState.historyPlaybackChoices(in: detail, record: record).count,
            2
        )
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
    func testHistoryReferenceRejectsAndroidProviderInstanceIdentity()
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

        XCTAssertNil(playbackReference.providerResourceReference)
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
        XCTAssertTrue(androidProvider.acceptsPlaybackResourceReference(providerReference))

        let legacyReference = HistoryPlaybackReference(
            sourceIdentity: source.stableIdentity,
            resourceIdentity: source.episodes[0].stableIdentity,
            providerResourceReference: providerReference
        )
        let legacyRecordWithProviderLocator = HistoryRecord(
            siteKey: "site-a",
            videoID: "video-a",
            title: "Title",
            episodeReference: "expired-resource",
            playbackReference: legacyReference
        )
        XCTAssertNil(
            AppState.acceptedHistoryProviderReference(
                from: legacyRecordWithProviderLocator,
                provider: androidProvider
            ),
            "History must rebuild Android playback through current detail"
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
        XCTAssertNil(
            AppState.persistentHistoryEpisodeReference(
                "provider-uuid/item-42",
                providerCapability: .javaDexSpider
            )
        )
    }

    @MainActor
    func testHistoryPlaybackSessionCacheReusesOnlyLiveMemorySession() throws {
        let configurationID = UUID()
        let episode = PlayEpisode(name: "第 2 集", url: "provider-runtime-ref")
        let source = PlaySource(name: "网盘线路", episodes: [episode])
        let detail = VideoDetail(
            summary: VideoSummary(
                siteKey: "site-a",
                siteName: "Site A",
                videoID: "video-a",
                title: "Title"
            ),
            playSources: [source]
        )
        let mediaURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:19978/proxy/media/session-a")
        )
        let playback = ActivePlaybackContext(
            configurationID: configurationID,
            detail: detail,
            source: source,
            episode: episode,
            media: ResolvedMedia(
                url: mediaURL,
                headers: [:],
                siteKey: "site-a",
                sourceName: source.name,
                episodeName: episode.name
            ),
            playbackResult: nil,
            providerResourceReference: nil
        )
        let record = HistoryRecord(
            configurationID: configurationID,
            siteKey: "site-a",
            videoID: "video-a",
            title: "Title",
            sourceKey: source.id,
            sourceName: source.name,
            episodeName: episode.name
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        var cache = HistoryPlaybackSessionCache(lifetime: 10, capacity: 2)
        cache.store(playback, for: [record.id], now: startedAt)

        XCTAssertEqual(
            cache.playback(
                for: record.id,
                now: Date(timeIntervalSince1970: 109)
            )?.media.url,
            mediaURL
        )
        XCTAssertNil(
            cache.playback(
                for: record.id,
                now: Date(timeIntervalSince1970: 120)
            )
        )
        XCTAssertEqual(cache.count, 0)
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
        XCTAssertNil(
            AppState.persistentProviderResourceReference(
                durableProviderReference
            ),
            "Android Dex locators are tied to one live Spider instance"
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
        XCTAssertEqual(
            AppState.historySearchQuery(for: "楚门的世界（臻彩） 4K HDR"),
            "楚门的世界"
        )
        let decoratedRecord = HistoryRecord(
            siteKey: "renamed-site",
            videoID: "expired-cloud-id",
            title: "楚门的世界（臻彩）"
        )
        XCTAssertEqual(
            AppState.historySearchMatch(
                in: [
                    VideoSummary(
                        siteKey: "renamed-site",
                        siteName: "Renamed Site",
                        videoID: "current-cloud-id",
                        title: "楚门的世界 4K"
                    )
                ],
                record: decoratedRecord
            )?.videoID,
            "current-cloud-id"
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

    func testHomeToolbarLayoutUsesContentWidthBreakpoints() {
        XCTAssertEqual(
            HomeToolbarLayoutPolicy.layout(contentWidth: 1_200),
            .expanded
        )
        XCTAssertEqual(
            HomeToolbarLayoutPolicy.layout(contentWidth: 900),
            .expanded
        )
        XCTAssertEqual(
            HomeToolbarLayoutPolicy.layout(contentWidth: 899),
            .compact
        )
        XCTAssertEqual(
            HomeToolbarLayoutPolicy.layout(contentWidth: 650),
            .compact
        )
        XCTAssertEqual(
            HomeToolbarLayoutPolicy.layout(contentWidth: 649),
            .minimal
        )
    }

    func testHomeToolbarCompactControlsRemainBounded() {
        XCTAssertEqual(HomeToolbarLayout.expanded.sitePickerWidth, 210)
        XCTAssertEqual(HomeToolbarLayout.compact.sitePickerWidth, 150)
        XCTAssertEqual(HomeToolbarLayout.minimal.sitePickerWidth, 0)
    }

    func testBrowserToolbarChromeKeepsNativeUnifiedFillAcrossScroll() {
        XCTAssertEqual(
            BrowserToolbarChromePolicy.appearance(
                isScrolled: false,
                isWindowActive: true,
                reduceTransparency: false
            ),
            BrowserToolbarChromeAppearance(
                fill: .referenceTone,
                separatorOpacity: 0.30
            )
        )
        XCTAssertEqual(
            BrowserToolbarChromePolicy.appearance(
                isScrolled: true,
                isWindowActive: true,
                reduceTransparency: false
            ),
            BrowserToolbarChromeAppearance(
                fill: .referenceTone,
                separatorOpacity: 0.34
            )
        )
    }

    func testBrowserChromeAndSidebarMatchModernMacMetrics() {
        XCTAssertEqual(AppSidebarMetrics.minimumWidth, 224)
        XCTAssertEqual(AppSidebarMetrics.idealWidth, 224)
        XCTAssertEqual(AppSidebarMetrics.maximumWidth, 280)
        XCTAssertEqual(AppSidebarMetrics.horizontalInset, 16)
        XCTAssertEqual(AppSidebarMetrics.searchHeight, 32)
        XCTAssertEqual(AppSidebarMetrics.rowHeight, 26)
        XCTAssertEqual(AppSidebarMetrics.labelFontSize, 14)
        XCTAssertEqual(AppSidebarMetrics.iconWidth, 18)
        XCTAssertEqual(AppSidebarMetrics.iconTextSpacing, 8)
        XCTAssertEqual(AppSidebarMetrics.rowContentMinimumWidth, 168)
    }

    @MainActor
    func testBrowserWindowChromeUsesNativeFullSizeTitlebar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        BrowserWindowChromeController.configure(window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
    }

    func testBrowserToolbarChromeAdaptsAccessibilityAndInactiveWindows() {
        XCTAssertEqual(
            BrowserToolbarChromePolicy.appearance(
                isScrolled: true,
                isWindowActive: false,
                reduceTransparency: false
            ).separatorOpacity,
            0.22
        )
        XCTAssertEqual(
            BrowserToolbarChromePolicy.appearance(
                isScrolled: false,
                isWindowActive: true,
                reduceTransparency: true
            ).fill,
            .referenceTone
        )
        XCTAssertEqual(
            BrowserToolbarChromePolicy.appearance(
                isScrolled: true,
                isWindowActive: true,
                reduceTransparency: true
            ).fill,
            .referenceTone
        )
    }

    func testSearchToolbarLayoutKeepsControlsUsableAtEveryWidth() {
        XCTAssertEqual(
            SearchToolbarLayoutPolicy.layout(contentWidth: 1_200),
            .expanded
        )
        XCTAssertEqual(
            SearchToolbarLayoutPolicy.layout(contentWidth: 900),
            .compact
        )
        XCTAssertEqual(
            SearchToolbarLayoutPolicy.layout(contentWidth: 640),
            .minimal
        )
        XCTAssertGreaterThan(SearchToolbarLayout.expanded.statusWidth, 200)
        XCTAssertEqual(SearchToolbarLayout.minimal.scopeWidth, 42)
        XCTAssertEqual(SearchToolbarLayout.minimal.sortWidth, 42)
    }

    func testSearchSourceNavigationShowsAllSourcesWhenTheyFit() {
        let candidates = ["all", "a", "b"].map {
            SearchSourceNavigationCandidate(id: $0, width: 40)
        }

        let partition = SearchSourceNavigationLayoutPolicy.partition(
            candidates: candidates,
            selectedID: "all",
            availableWidth: 200
        )

        XCTAssertEqual(partition.visibleIDs, ["all", "a", "b"])
        XCTAssertTrue(partition.hiddenIDs.isEmpty)
    }

    func testSearchSourceNavigationPromotesSelectedOverflowSource() {
        let candidates = ["all", "a", "b", "c"].map {
            SearchSourceNavigationCandidate(id: $0, width: 40)
        }

        let partition = SearchSourceNavigationLayoutPolicy.partition(
            candidates: candidates,
            selectedID: "c",
            availableWidth: 180
        )

        XCTAssertEqual(partition.visibleIDs, ["c"])
        XCTAssertEqual(partition.hiddenIDs, ["all", "a", "b"])
    }

    func testSearchToolbarStatusUsesStableCompletionCopy() {
        let running = SearchToolbarStatusPolicy.presentation(
            layout: .expanded,
            isSearching: true,
            firstPageCompleted: 35,
            completed: 27,
            total: 49,
            termination: nil
        )
        let completed = SearchToolbarStatusPolicy.presentation(
            layout: .expanded,
            isSearching: false,
            firstPageCompleted: 49,
            completed: 49,
            total: 49,
            termination: .completedWithProviderFailures
        )

        XCTAssertEqual(running.phase, .searching)
        XCTAssertEqual(running.text, "首批 35/49 · 已结束 27/49")
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.text, "✓ 已完成 49/49")
        XCTAssertFalse(completed.text.contains("失败"))
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

    func testSearchResultPresentationCacheReusesUnchangedInput() {
        let values = [
            VideoSummary(
                siteKey: "a",
                siteName: "A",
                videoID: "1",
                title: "缓存测试",
                year: "2026"
            )
        ]
        let cache = SearchResultPresentationCache()

        let first = cache.clusters(
            from: values,
            keyword: "缓存测试",
            mergesDuplicates: true,
            sortOrder: .relevance
        )
        let second = cache.clusters(
            from: values,
            keyword: "缓存测试",
            mergesDuplicates: true,
            sortOrder: .relevance
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.computationCount, 1)
        _ = cache.clusters(
            from: values,
            keyword: "缓存",
            mergesDuplicates: true,
            sortOrder: .relevance
        )
        XCTAssertEqual(cache.computationCount, 2)
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
            descriptor.companionConfigurationChecksumURL?.absoluteString,
            "https://example.invalid/index.config.js.md5"
        )
        XCTAssertEqual(
            descriptor.companionConfigurationScriptURL?.absoluteString,
            "https://example.invalid/index.config.js"
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
        XCTAssertEqual(site.searchable, 1)
        XCTAssertEqual(
            site.extra["okNodeSearchCapabilityState"],
            .string("unknown")
        )
        XCTAssertNil(site.extra["okNodeCapabilities"])
        XCTAssertEqual(
            NodeSearchCapabilityPolicy.declaredState(for: site),
            .unknown
        )
        XCTAssertEqual(configuration.danmaku, "/danmu")
    }

    func testNodeConfigurationNormalizationAcceptsSitesListShape() throws {
        let source = Data(
            #"{"sites":{"list":[{"key":"wrapped","name":"Wrapped","type":3,"api":"/spider/wrapped/3"}]}}"#.utf8
        )

        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(source)
        let configuration = try ConfigurationParser().parse(normalized)

        XCTAssertEqual(configuration.sites.map(\.key), ["wrapped"])
        XCTAssertEqual(
            configuration.sites.first?.extra["okNodeModuleKind"],
            .string("video")
        )
    }

    func testNonVideoModulesStayOutOfHostCatalog() throws {
        let source = Data(
            #"{"read":{"sites":[{"key":"book","name":"Book","type":13,"api":"/spider/book/13"}]},"comic":{"sites":[{"key":"comic","name":"Comic","type":20,"api":"/spider/comic/20"}]},"music":{"sites":[{"key":"music","name":"Music","type":30,"api":"/spider/music/30"}]},"pan":{"sites":[{"key":"alist","name":"AList","type":40,"api":"/spider/alist/40"}]}}"#.utf8
        )

        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(
            source,
            bundleIdentity: "official-bundle",
            profileRevision: "profile-1"
        )
        let configuration = try ConfigurationParser().parse(normalized)

        XCTAssertTrue(configuration.sites.isEmpty)
    }

    func testCatPawCapabilityRegistryIsScopedByModuleIdentity() async throws {
        let source = Data(
            #"{"video":{"sites":[{"key":"fixture","name":"Fixture","type":3,"api":"/spider/fixture/3"}]}}"#.utf8
        )
        let firstData = try NodeBundleRuntimeService.normalizeConfiguration(
            source,
            bundleIdentity: "bundle",
            profileRevision: "revision-1"
        )
        let secondData = try NodeBundleRuntimeService.normalizeConfiguration(
            source,
            bundleIdentity: "bundle",
            profileRevision: "revision-2"
        )
        let first = try XCTUnwrap(ConfigurationParser().parse(firstData).sites.first)
        let second = try XCTUnwrap(ConfigurationParser().parse(secondData).sites.first)
        let registry = CatPawCapabilityRegistry()
        let firstIdentity = CatPawModuleIdentity(site: first)
        let secondIdentity = CatPawModuleIdentity(site: second)

        await registry.recordUnsupported(.search, for: firstIdentity)

        let firstSearch = await registry.state(of: .search, for: firstIdentity)
        let secondSearch = await registry.state(of: .search, for: secondIdentity)
        let firstPlay = await registry.state(of: .play, for: firstIdentity)
        XCTAssertEqual(firstSearch, .unsupported)
        XCTAssertEqual(secondSearch, .unknown)
        XCTAssertEqual(firstPlay, .unknown)
    }

    func testMixedCatPawCatalogPublishesOnlyVideoModules() throws {
        let source = Data(
            #"{"video":{"sites":[{"key":"nodejs_kunyu77","name":"Kunyu77","type":3,"api":"/spider/kunyu77/3"},{"key":"nodejs_kkys","name":"KKYS","type":3,"api":"/spider/kkys/3"},{"key":"nodejs_ffm3u8","name":"FFM3U8","type":3,"api":"/spider/ffm3u8/3"},{"key":"nodejs_push","name":"Push","type":3,"api":"/spider/push/3"}]},"read":{"sites":[{"key":"nodejs_13bqg","name":"笔趣阁","type":10,"api":"/spider/13bqg/10"}]},"comic":{"sites":[{"key":"nodejs_copymanga","name":"拷贝漫画","type":20,"api":"/spider/copymanga/20"}]},"music":{"sites":[]},"pan":{"sites":[{"key":"nodejs_alist","name":"AList","type":40,"api":"/spider/alist/40"}]}}"#.utf8
        )
        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(
            source,
            bundleIdentity: "catpaw-open-b956aed",
            profileRevision: "fixture-profile"
        )
        let configuration = try ConfigurationParser().parse(normalized)

        XCTAssertEqual(
            configuration.sites.map(\.key),
            [
                "nodejs_kunyu77",
                "nodejs_kkys",
                "nodejs_ffm3u8",
                "nodejs_push"
            ]
        )
        XCTAssertTrue(configuration.sites.allSatisfy {
            $0.extra["okNodeModuleKind"] == .string("video")
                && $0.extra["okNodeSiteIdentity"]?.stringValue?.isEmpty == false
        })
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
        XCTAssertEqual(disabled.searchable, 1)
        XCTAssertEqual(
            utility.extra["okNodeSearchCapabilityState"],
            .string("unsupported")
        )
        XCTAssertEqual(
            home.extra["okNodeSearchCapabilityState"],
            .string("supported")
        )
        XCTAssertEqual(
            disabled.extra["okNodeSearchCapabilityState"],
            .string("unknown")
        )
        XCTAssertEqual(
            home.extra["okNodeCapabilities"],
            .array([.string("search")])
        )
        XCTAssertNil(disabled.extra["okNodeCapabilities"])
        XCTAssertEqual(
            NodeSearchCapabilityPolicy.declaredState(for: utility),
            .unsupported
        )
        XCTAssertEqual(
            NodeSearchCapabilityPolicy.declaredState(for: home),
            .supported
        )
    }

    func testNodePublishedCapabilityListTakesPrecedenceOverMissingSearchable() throws {
        let source = Data(
            #"{"sites":[{"key":"with-search","name":"With Search","type":3,"api":"/spider/with/3","okNodeCapabilities":["search","detail"]},{"key":"without-search","name":"Without Search","type":3,"api":"/spider/without/3","okNodeCapabilities":["home","detail"]}]}"#.utf8
        )

        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(source)
        let configuration = try ConfigurationParser().parse(normalized)
        let withSearch = try XCTUnwrap(
            configuration.sites.first(where: { $0.key == "with-search" })
        )
        let withoutSearch = try XCTUnwrap(
            configuration.sites.first(where: { $0.key == "without-search" })
        )

        XCTAssertEqual(withSearch.searchable, 1)
        XCTAssertEqual(
            withSearch.extra["okNodeCapabilities"],
            .array([.string("search"), .string("detail")])
        )
        XCTAssertEqual(
            NodeSearchCapabilityPolicy.declaredState(for: withSearch),
            .supported
        )
        XCTAssertEqual(withoutSearch.searchable, 0)
        XCTAssertEqual(
            withoutSearch.extra["okNodeCapabilities"],
            .array([.string("home"), .string("detail")])
        )
        XCTAssertEqual(
            NodeSearchCapabilityPolicy.declaredState(for: withoutSearch),
            .unsupported
        )
    }

    func testNodeFullConfigurationAddsDisabledSearchableCatalogueSites() throws {
        let enabled = Data(
            #"{"sites":[{"key":"enabled","name":"Enabled","type":3,"api":"/spider/enabled/3","searchable":1}]}"#.utf8
        )
        let catalogue = Data(
            #"{"sites":[{"key":"enabled","name":"Enabled","type":3,"api":"/spider/enabled/3","searchable":1},{"key":"short","name":"久久短剧","type":3,"api":"/spider/short/3","searchable":2},{"key":"settings","name":"设置中心","type":3,"api":"/spider/settings/3","configurable":true}]}"#.utf8
        )

        let normalized = try NodeBundleRuntimeService.normalizeConfiguration(
            enabled,
            catalogData: catalogue,
            bundleIdentity: "bundle-v1",
            profileIdentity: "profile-stable",
            profileRevision: "profile-v2"
        )
        let configuration = try ConfigurationParser().parse(normalized)
        let short = try XCTUnwrap(
            configuration.sites.first(where: { $0.key == "short" })
        )
        let settings = try XCTUnwrap(
            configuration.sites.first(where: { $0.key == "settings" })
        )

        XCTAssertEqual(short.searchable, 2)
        XCTAssertEqual(short.extra["okNodeCatalogDisabled"], .bool(true))
        XCTAssertEqual(short.extra["okNodeCapabilities"], .array([.string("search")]))
        XCTAssertEqual(
            short.extra["okNodeSearchCapabilityState"],
            .string("supported")
        )
        XCTAssertEqual(short.extra["okNodeBundleIdentity"], .string("bundle-v1"))
        XCTAssertEqual(
            short.extra["okNodeProfileIdentity"],
            .string("profile-stable")
        )
        XCTAssertEqual(short.extra["okNodeProfileRevision"], .string("profile-v2"))
        XCTAssertEqual(settings.searchable, 2)
        XCTAssertEqual(
            settings.extra["okNodeSearchCapabilityState"],
            .string("unknown")
        )
        XCTAssertNil(settings.extra["okNodeCapabilities"])
        XCTAssertNil(settings.extra["okNodeConfigurationRequired"])
        XCTAssertEqual(
            NodeSearchCapabilityPolicy.declaredState(for: settings),
            .unknown
        )
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

    func testContractBCompanionConfigurationParsesStaticCatPawExport() throws {
        let source = Data(
            #"""
            var __helper = () => { throw new Error("must not run"); };
            var index_config_default = {
              sites: { list: [], },
              pans: { list: [], },
              danmu: { urls: ['https://fixture.invalid/danmu'], autoPush: false },
              color: [],
              tgsou: { url: "https://fixture.invalid/tg", page: 1 },
              alist: { list: [{ name: '测试', server: 'https://alist.invalid' }] }
            };
            """#.utf8
        )

        let normalized = try ContractBCompanionConfigParser
            .normalizedConfiguration(from: source)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalized) as? [String: Any]
        )

        XCTAssertEqual(
            (object["tgsou"] as? [String: Any])?["url"] as? String,
            "https://fixture.invalid/tg"
        )
        XCTAssertEqual(
            ((object["alist"] as? [String: Any])?["list"] as? [Any])?.count,
            1
        )
    }

    func testContractBCompanionConfigurationAcceptsOfficialPublisherOnlyShape()
        throws {
        let source = Data(
            #"export default { kunyu77: { testcfg: { bbbb: 'aaaaa' } }, ffm3u8: { url: 'https://fixture.invalid/api' }, alist: [{ name: 'AList', server: 'https://alist.invalid' }], color: [] };"#.utf8
        )

        let normalized = try ContractBCompanionConfigParser
            .normalizedConfiguration(from: source)
        try ContractBConfigBuilder.validate(normalized)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalized) as? [String: Any]
        )

        XCTAssertNotNil(object["kunyu77"] as? [String: Any])
        XCTAssertNotNil(object["ffm3u8"] as? [String: Any])
        XCTAssertEqual((object["alist"] as? [Any])?.count, 1)
        XCTAssertNil(object["sites"])
        XCTAssertNil(object["pans"])
    }

    func testContractBCompanionConfigurationRejectsExecutableValues() {
        let source = Data(
            #"""
            export default {
              sites: { list: [] }, pans: { list: [] },
              danmu: { urls: [], autoPush: false }, color: [],
              tgsou: { url: getSecret() }
            };
            """#.utf8
        )

        XCTAssertThrowsError(
            try ContractBCompanionConfigParser.normalizedConfiguration(
                from: source
            )
        ) { error in
            XCTAssertEqual(
                error as? NodeBundleRuntimeError,
                .companionConfigurationSyntaxUnsupported
            )
        }
    }

    func testRealContractBCompanionConfigurationFromEnvironment() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "OKVIDEO_CONTRACT_B_CONFIG_SAMPLE"
        ], !path.isEmpty else {
            throw XCTSkip("Real Contract B companion config was not supplied")
        }
        let normalized = try ContractBCompanionConfigParser
            .normalizedConfiguration(from: Data(contentsOf: URL(fileURLWithPath: path)))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalized) as? [String: Any]
        )

        XCTAssertNotNil(object["tgsou"] as? [String: Any])
        XCTAssertNotNil(object["alist"] as? [String: Any])
        XCTAssertNotNil(object["emby"] as? [String: Any])
        XCTAssertNotNil(object["webdav"] as? [String: Any])
    }

    func testContractBDefaultsAddMissingPublisherValuesWithoutOverwritingUserData()
        throws {
        let defaults = Data(
            #"{"sites":{"list":[]},"pans":{"list":[]},"danmu":{"urls":[],"autoPush":false},"color":[],"tgsou":{"url":"https://default.invalid"},"alist":{"list":[{"name":"default"}]}}"#.utf8
        )
        let userValues = Data(
            #"{"sites":{"list":[]},"pans":{"list":[]},"danmu":{"urls":[],"autoPush":true},"color":[],"tgsou":{"url":"https://user.invalid"}}"#.utf8
        )

        let merged = try ContractBConfigBuilder.mergeDefaults(
            defaults,
            userValues: userValues
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )

        XCTAssertEqual(
            (object["tgsou"] as? [String: Any])?["url"] as? String,
            "https://user.invalid"
        )
        XCTAssertEqual(
            (object["danmu"] as? [String: Any])?["autoPush"] as? Bool,
            true
        )
        XCTAssertEqual(
            ((object["alist"] as? [String: Any])?["list"] as? [Any])?.count,
            1
        )
    }

    func testContractBConfigurationAcceptsPublisherSpecificShape() throws {
        let source = Data(
            #"{"kunyu77":{"device":"publisher-value"},"ffm3u8":{"timeout":10}}"#.utf8
        )

        try ContractBConfigBuilder.validate(source)
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
                "DEV_HTTP_HOST": "0.0.0.0",
                "DEV_HTTP_PORT": "12345",
                "OKVIDEO_CONTRACT_B_CONFIG_PATH": runtime
                    .appendingPathComponent("config.json").path,
                "OKVIDEO_CONTRACT_B_STATE_PATH": runtime
                    .appendingPathComponent("state.json").path
            ]
        )

        XCTAssertNil(contractA["DEV_HTTP_PORT"])
        XCTAssertEqual(contractB["DEV_HTTP_HOST"], "0.0.0.0")
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
        let first = try NodeRuntimePortAllocator.allocate()
        let second = try NodeRuntimePortAllocator.allocate()

        XCTAssertNotEqual(first, 9_988)
        XCTAssertNotEqual(second, 9_988)
        XCTAssertTrue((1...65_535).contains(first))
        XCTAssertTrue((1...65_535).contains(second))
    }

    func testContractBListenerStateAcceptsManagedLANHostOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("okvideo-contract-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        try Data(
            #"{"contract":"contract-b-host-integrated","phase":"listener-observed","host":"0.0.0.0","family":"IPv4","port":19000}"#.utf8
        ).write(to: stateURL)

        XCTAssertEqual(
            ContractBListenerState.readValidated(from: stateURL)?.host,
            "0.0.0.0"
        )

        try Data(
            #"{"contract":"contract-b-host-integrated","phase":"listener-observed","host":"192.168.1.114","family":"IPv4","port":19000}"#.utf8
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

    func testConfigurationImportCapabilitySummarySeparatesRuntimesAndLives()
        throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://configuration.invalid/config.json")
        )
        let digest = "1fb66ff185ea35252d2ae2a07d058ec1"
        let configuration = FongMiConfiguration(
            spider: "https://configuration.invalid/provider.jpg;md5;\(digest)",
            sites: [
                SiteConfiguration(
                    key: "java",
                    name: "Java",
                    type: 3,
                    api: "csp_Java"
                ),
                SiteConfiguration(
                    key: "javascript",
                    name: "JavaScript",
                    type: 3,
                    api: "https://configuration.invalid/provider.js"
                ),
                SiteConfiguration(
                    key: "api",
                    name: "API",
                    type: 1,
                    api: "https://configuration.invalid/api"
                )
            ],
            lives: [
                LiveConfiguration(
                    name: "Remote",
                    url: "./live.m3u"
                ),
                LiveConfiguration(
                    name: "Dynamic",
                    api: "csp_DynamicLive"
                )
            ]
        )

        let summary = ConfigurationImportCapabilityAnalyzer.summary(
            configurationID: UUID(),
            configurationName: "Fixture",
            configuration: configuration,
            baseURL: baseURL,
            androidBridgeUnavailable: true
        )

        XCTAssertEqual(summary.siteCount, 3)
        XCTAssertEqual(summary.javaDexSiteCount, 1)
        XCTAssertEqual(summary.javaScriptSiteCount, 1)
        XCTAssertEqual(summary.otherSiteCount, 1)
        XCTAssertEqual(summary.liveCount, 2)
        XCTAssertEqual(summary.synchronizableLiveCount, 1)
        XCTAssertEqual(summary.unsupportedLiveCount, 1)
        XCTAssertTrue(summary.androidBridgeUnavailable)
    }

    func testEmbeddedLiveSourceIncludesTopLevelHeaders() throws {
        let live = LiveConfiguration(
            name: "Inline",
            userAgent: "Fixture Agent",
            referer: "https://referer.invalid/",
            header: ["X-Default": "one"],
            groups: [
                LiveGroupConfiguration(
                    name: "News",
                    channels: [
                        LiveChannelConfiguration(
                            name: "Channel",
                            urls: ["https://stream.invalid/live.m3u8"],
                            header: ["X-Default": "overridden"]
                        )
                    ]
                )
            ]
        )

        let playlist = try LiveSourceParser().parse(
            EmbeddedLiveSourcePolicy.inlineData(for: live)
        )
        let headers = try XCTUnwrap(
            playlist.groups.first?.channels.first?.streams.first?.headers
        )

        XCTAssertEqual(headers["User-Agent"], "Fixture Agent")
        XCTAssertEqual(headers["Referer"], "https://referer.invalid/")
        XCTAssertEqual(headers["X-Default"], "overridden")
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

    func testCacheOnlyNodeStartupNeverWaitsForPublisherIO() async throws {
        let fixture = try makeLegacyCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let migrated = try await makeOfflineRuntime(fixture: fixture)
            .prepareBundleForTesting(from: fixture.sourceURL)
        let cacheOnlyService = NodeBundleRuntimeService(
            applicationSupportDirectory: fixture.applicationSupportDirectory,
            cacheDirectory: fixture.cacheDirectory,
            remoteHTTPClient: NodeProviderStubHTTPClient { _ in
                XCTFail("cache-only restoration must not contact the publisher")
                throw HTTPClientError.transport("unexpected publisher request")
            }
        )

        let restored = try await cacheOnlyService.prepareBundleForTesting(
            from: fixture.sourceURL,
            startupStrategy: .cacheOnly
        )

        XCTAssertEqual(restored, migrated)
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

    func testCatPawPlaybackLeaseDefersOrdinaryRuntimeStopUntilRelease()
        async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeReadinessFixtureScript(startDelayMilliseconds: 0).utf8
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
        let mediaURL = endpoint
            .appendingPathComponent("proxy")
            .appendingPathComponent("hls")
            .appendingPathComponent("fixture.m3u8")
        let reference = PlaybackResourceReference(
            configurationIdentity: "configuration",
            siteIdentity: "site",
            providerKind: "node-http-spider-runtime",
            providerVersion: 1,
            stableResourceLocator: "runtime-locator",
            sourceIdentity: "source",
            episodeIdentity: "episode",
            stability: .providerReplay
        )
        let acquiredLease = await service.acquirePlaybackLease(
            for: PlaybackMediaSession(
                sessionID: UUID().uuidString,
                transport: .providerLoopback,
                mediaURL: mediaURL.absoluteString,
                resourceReference: reference
            )
        )
        let lease = try XCTUnwrap(acquiredLease)

        await service.stop()
        let retainedStatus = await service.currentStatus()
        let retainedLeaseCount = await service
            .activePlaybackLeaseCountForTesting()
        XCTAssertEqual(retainedStatus, .running(endpoint))
        XCTAssertEqual(retainedLeaseCount, 1)

        await service.releasePlaybackLease(lease)
        let stoppedStatus = await service.currentStatus()
        let stoppedLeaseCount = await service
            .activePlaybackLeaseCountForTesting()
        XCTAssertEqual(stoppedStatus, .stopped)
        XCTAssertEqual(stoppedLeaseCount, 0)
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

    func testContractBStartPromiseDoesNotPublishReadyBeforeManagedListener() async throws {
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
        XCTAssertEqual(state.host, "0.0.0.0")
        XCTAssertEqual(state.port, endpoint.port)
        let endpointPort = try XCTUnwrap(endpoint.port)
        let listeners = try systemListeners(on: endpointPort)
        XCTAssertTrue(listeners.contains("*:\(endpointPort)"), listeners)
        XCTAssertFalse(listeners.contains("127.0.0.1:"), listeners)

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

    func testContractBOwnershipEndpointScopesRuntimeOwnedInternalPages()
        async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(
                    startDelayMilliseconds: 0,
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
        let endpoint = try await service.ensureReady(from: fixture.sourceURL)
        let (addressData, _) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("auxiliary")
        )
        let address = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: addressData)
                as? [String: Any]
        )
        let port = try XCTUnwrap(address["port"] as? Int)
        let (bridgeData, _) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("bridge-port")
        )
        let bridgeAddress = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bridgeData)
                as? [String: Any]
        )
        let bridgePort = try XCTUnwrap(bridgeAddress["port"] as? Int)
        XCTAssertNotEqual(bridgePort, endpoint.port)
        XCTAssertNotEqual(bridgePort, port)

        func ownershipURL(
            _ rawURL: String,
            purpose: String? = nil
        ) throws -> URL {
            var components = URLComponents(
                url: endpoint.appendingPathComponent(
                    "__okvideo/owned-loopback"
                ),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "url", value: rawURL)]
            if let purpose {
                components?.queryItems?.append(
                    URLQueryItem(name: "purpose", value: purpose)
                )
            }
            return try XCTUnwrap(components?.url)
        }

        let (ownedData, ownedResponse) = try await URLSession.shared.data(
            from: ownershipURL(
                "http://192.168.1.114:\(port)/website"
            )
        )
        XCTAssertEqual((ownedResponse as? HTTPURLResponse)?.statusCode, 200)
        let ownedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: ownedData)
                as? [String: Any]
        )
        let normalizedURL = try XCTUnwrap(
            URL(string: ownedObject["url"] as? String ?? "")
        )
        XCTAssertEqual(normalizedURL.host, "127.0.0.1")
        XCTAssertEqual(normalizedURL.port, port)
        XCTAssertEqual(normalizedURL.path, "/website")

        let (_, wrongPathResponse) = try await URLSession.shared.data(
            from: ownershipURL(
                "http://192.168.1.114:\(port)/ordinary-media"
            )
        )
        XCTAssertEqual(
            (wrongPathResponse as? HTTPURLResponse)?.statusCode,
            404
        )
        let (internalPageData, internalPageResponse) = try await URLSession.shared
            .data(
                from: ownershipURL(
                    "http://192.168.1.114:\(port)/douer",
                    purpose: "internal-webview"
                )
            )
        XCTAssertEqual(
            (internalPageResponse as? HTTPURLResponse)?.statusCode,
            200
        )
        let internalPageObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: internalPageData)
                as? [String: Any]
        )
        let internalPageURL = try XCTUnwrap(
            URL(string: internalPageObject["url"] as? String ?? "")
        )
        XCTAssertEqual(internalPageURL.host, "127.0.0.1")
        XCTAssertEqual(internalPageURL.port, port)
        XCTAssertEqual(internalPageURL.path, "/douer")
        let (_, unownedResponse) = try await URLSession.shared.data(
            from: ownershipURL(
                "http://192.168.1.114:1/douer",
                purpose: "internal-webview"
            )
        )
        XCTAssertEqual((unownedResponse as? HTTPURLResponse)?.statusCode, 404)
        let (_, bridgeResponse) = try await URLSession.shared.data(
            from: ownershipURL(
                "http://127.0.0.1:\(bridgePort)/website",
                purpose: "internal-webview"
            )
        )
        XCTAssertEqual((bridgeResponse as? HTTPURLResponse)?.statusCode, 404)

        let (websiteData, websiteResponse) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("website")
        )
        let websiteHTML = try XCTUnwrap(String(data: websiteData, encoding: .utf8))
        XCTAssertEqual(
            (websiteResponse as? HTTPURLResponse)?.expectedContentLength,
            Int64(websiteData.count)
        )
        XCTAssertFalse(websiteHTML.contains("lib.baomitu.com"))
        XCTAssertTrue(
            websiteHTML.contains(
                "https://cdn.jsdelivr.net/npm/react@18.2.0/umd/react.production.min.js"
            )
        )
        await service.stop()
    }

    func testContractBInitializationSaveDoesNotCompleteAuthorization() async throws {
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
            url: endpoint.appendingPathComponent("authorization-sequence")
        )
        request.httpMethod = "POST"
        request.setValue(
            invocationID,
            forHTTPHeaderField: "X-OKVideo-Invocation-ID"
        )

        let (_, businessResponse) = try await URLSession.shared.data(for: request)
        let businessHTTP = try XCTUnwrap(businessResponse as? HTTPURLResponse)
        let encoded = try XCTUnwrap(
            businessHTTP.value(forHTTPHeaderField: "X-OKVideo-Host-Message")
        )
        let challengeData = try XCTUnwrap(Data(base64Encoded: encoded))
        let challenge = try XCTUnwrap(
            JSONSerialization.jsonObject(with: challengeData) as? [String: Any]
        )
        let challengeOptions = try XCTUnwrap(
            challenge["opt"] as? [String: Any]
        )
        XCTAssertEqual(challenge["action"] as? String, "openInternalWebview")
        XCTAssertEqual(challengeOptions["provider"] as? String, "fixture-cloud")
        XCTAssertEqual(challengeOptions["transport"] as? String, "qr")
        XCTAssertEqual(challengeOptions["requestID"] as? String, invocationID)

        var pollComponents = URLComponents(
            url: endpoint.appendingPathComponent(
                "__okvideo/host-message/\(invocationID)"
            ),
            resolvingAgainstBaseURL: false
        )
        pollComponents?.queryItems = [URLQueryItem(name: "wait", value: "1000")]
        let (completionData, completionResponse) = try await URLSession.shared.data(
            from: try XCTUnwrap(pollComponents?.url)
        )
        XCTAssertEqual(
            (completionResponse as? HTTPURLResponse)?.statusCode,
            204
        )
        XCTAssertTrue(completionData.isEmpty)
        await service.stop()
    }

    func testContractBRepeatedIdenticalSaveDoesNotCompleteAuthorization()
        async throws {
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

        for _ in 0..<2 {
            let invocationID = UUID().uuidString.lowercased()
            var request = URLRequest(
                url: endpoint.appendingPathComponent("authorization-sequence")
            )
            request.httpMethod = "POST"
            request.setValue(
                invocationID,
                forHTTPHeaderField: "X-OKVideo-Invocation-ID"
            )
            _ = try await URLSession.shared.data(for: request)
            var pollComponents = URLComponents(
                url: endpoint.appendingPathComponent(
                    "__okvideo/host-message/\(invocationID)"
                ),
                resolvingAgainstBaseURL: false
            )
            pollComponents?.queryItems = [
                URLQueryItem(name: "wait", value: "100")
            ]
            let (data, response) = try await URLSession.shared.data(
                from: try XCTUnwrap(pollComponents?.url)
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
            XCTAssertTrue(data.isEmpty)
        }
        await service.stop()
    }

    func testContractBQueuesOnlyExplicitMatchingAuthorizationCompletion()
        async throws {
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
            url: endpoint.appendingPathComponent("authorization-explicit")
        )
        request.httpMethod = "POST"
        request.setValue(
            invocationID,
            forHTTPHeaderField: "X-OKVideo-Invocation-ID"
        )
        let (_, businessResponse) = try await URLSession.shared.data(for: request)
        XCTAssertNotNil(
            (businessResponse as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "X-OKVideo-Host-Message")
        )

        var pollComponents = URLComponents(
            url: endpoint.appendingPathComponent(
                "__okvideo/host-message/\(invocationID)"
            ),
            resolvingAgainstBaseURL: false
        )
        pollComponents?.queryItems = [URLQueryItem(name: "wait", value: "1000")]
        let (completionData, completionResponse) = try await URLSession.shared.data(
            from: try XCTUnwrap(pollComponents?.url)
        )
        XCTAssertEqual((completionResponse as? HTTPURLResponse)?.statusCode, 200)
        let completion = try XCTUnwrap(
            JSONSerialization.jsonObject(with: completionData) as? [String: Any]
        )
        let options = try XCTUnwrap(completion["opt"] as? [String: Any])
        XCTAssertEqual(completion["action"] as? String, "authorizationCompleted")
        XCTAssertEqual(
            options["challengeID"] as? String,
            "00000000-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(options["requestID"] as? String, invocationID)
        await service.stop()
    }

    func testContractBBridgesSniffResultBackToOriginalNodeRequest() async throws {
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
        var request = URLRequest(url: endpoint.appendingPathComponent("host-sniff"))
        request.httpMethod = "POST"
        request.setValue(invocationID, forHTTPHeaderField: "X-OKVideo-Invocation-ID")
        let businessTask = Task {
            try await URLSession.shared.data(for: request)
        }

        var pollComponents = URLComponents(
            url: endpoint.appendingPathComponent(
                "__okvideo/host-message/\(invocationID)"
            ),
            resolvingAgainstBaseURL: false
        )
        pollComponents?.queryItems = [URLQueryItem(name: "wait", value: "2000")]
        let pollURL = try XCTUnwrap(pollComponents?.url)
        let pollDeadline = Date().addingTimeInterval(3)
        var messageData = Data()
        var pollStatus = 0
        repeat {
            let (data, response) = try await URLSession.shared.data(
                from: pollURL
            )
            pollStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if pollStatus == 200 {
                messageData = data
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < pollDeadline
        guard pollStatus == 200 else {
            businessTask.cancel()
            await service.stop()
            return XCTFail("Contract B sniff message was not published in time")
        }
        let message = try XCTUnwrap(
            JSONSerialization.jsonObject(with: messageData) as? [String: Any]
        )
        XCTAssertEqual(message["action"] as? String, "sniff")
        let requestID = try XCTUnwrap(message["requestID"] as? String)
        let options = try XCTUnwrap(message["opt"] as? [String: Any])
        XCTAssertEqual(options["timeout"] as? Int, 10_000)

        let replyURL = endpoint
            .appendingPathComponent("__okvideo")
            .appendingPathComponent("host-message-reply")
            .appendingPathComponent(invocationID)
            .appendingPathComponent(requestID)
        var reply = URLRequest(url: replyURL)
        reply.httpMethod = "POST"
        reply.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reply.httpBody = Data(
            #"{"url":"https://media.example/video.m3u8","headers":{"referer":"https://page.example/"}}"#.utf8
        )
        let (_, replyResponse) = try await URLSession.shared.data(for: reply)
        XCTAssertEqual((replyResponse as? HTTPURLResponse)?.statusCode, 200)

        let (businessData, businessResponse) = try await businessTask.value
        XCTAssertEqual((businessResponse as? HTTPURLResponse)?.statusCode, 200)
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: businessData) as? [String: Any]
        )
        XCTAssertEqual(result["url"] as? String, "https://media.example/video.m3u8")
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

    func testContractBLateCloudToastIsScopedAndBecomesConfigurationChallenge()
        async throws {
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
        let clientConfiguration = URLSessionConfiguration.ephemeral
        clientConfiguration.connectionProxyDictionary = [:]
        let client = URLSessionHTTPClient(configuration: clientConfiguration)
        let firstSite = SiteConfiguration(
            key: "first_catpaw_cloud",
            name: "First CatPaw Cloud",
            type: 3,
            api: "/spider/contract_b/3",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let secondSite = SiteConfiguration(
            key: "second_catpaw_cloud",
            name: "Second CatPaw Cloud",
            type: 4,
            api: "/spider/renamed/73",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let firstProvider = try NodeHTTPSpiderSiteProvider(
            site: firstSite,
            baseURL: endpoint,
            httpClient: client
        )
        let secondProvider = try NodeHTTPSpiderSiteProvider(
            site: secondSite,
            baseURL: endpoint,
            httpClient: client
        )

        let firstStartedAt = Date()
        let (_, firstResponse) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent(
                "spider/contract_b/3/proxy/auth-toast"
            )
        )
        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 200)
        let firstAuthorization = await firstProvider
            .consumeLatePlaybackAuthorization(
                flag: "夸克/直链",
                notBefore: firstStartedAt,
                waitMilliseconds: 0
            )
        XCTAssertEqual(
            firstAuthorization?.websiteURL.absoluteString,
            endpoint.appendingPathComponent("website").absoluteString
        )
        XCTAssertTrue(firstAuthorization?.message.contains("夸克") == true)

        let ordinaryStartedAt = Date()
        _ = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent(
                "spider/contract_b/3/proxy/info-toast"
            )
        )
        let ordinaryAuthorization = await firstProvider
            .consumeLatePlaybackAuthorization(
                flag: "夸克/直链",
                notBefore: ordinaryStartedAt,
                waitMilliseconds: 0
            )
        XCTAssertNil(ordinaryAuthorization)

        let shareTokenStartedAt = Date()
        _ = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent(
                "spider/contract_b/3/proxy/stoken-toast"
            )
        )
        let shareTokenAuthorization = await firstProvider
            .consumeLatePlaybackAuthorization(
                flag: "夸克/直链",
                notBefore: shareTokenStartedAt,
                waitMilliseconds: 0
            )
        XCTAssertNil(shareTokenAuthorization)

        let staleStartedAt = Date()
        _ = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent(
                "spider/contract_b/3/proxy/auth-toast"
            )
        )
        try await Task.sleep(nanoseconds: 2_000_000)
        let staleAuthorization = await firstProvider
            .consumeLatePlaybackAuthorization(
                flag: "夸克/直链",
                notBefore: max(Date(), staleStartedAt),
                waitMilliseconds: 0
            )
        XCTAssertNil(staleAuthorization)

        let secondStartedAt = Date()
        _ = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent(
                "spider/renamed/73/proxy/guest-toast"
            )
        )
        let crossWired = await firstProvider.consumeLatePlaybackAuthorization(
            flag: "夸克/直链",
            notBefore: secondStartedAt,
            waitMilliseconds: 0
        )
        XCTAssertNil(crossWired)
        let secondAuthorization = await secondProvider
            .consumeLatePlaybackAuthorization(
                flag: "夸克/直链",
                notBefore: secondStartedAt,
                waitMilliseconds: 0
            )
        XCTAssertEqual(
            secondAuthorization?.websiteURL.absoluteString,
            endpoint.appendingPathComponent("website").absoluteString
        )

        let aliToastStartedAt = Date()
        _ = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent(
                "spider/contract_b/3/proxy/ali-toast"
            )
        )
        let aliToastAuthorization = await firstProvider
            .consumeLatePlaybackAuthorization(
                flag: "阿里/直链",
                notBefore: aliToastStartedAt,
                waitMilliseconds: 0
            )
        XCTAssertTrue(
            aliToastAuthorization?.message.contains("阿里云盘") == true
        )
        await service.stop()
    }

    func testContractBProxyAuthorizationResponseBecomesConfigurationChallenge()
        async throws {
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
        let clientConfiguration = URLSessionConfiguration.ephemeral
        clientConfiguration.connectionProxyDictionary = [:]
        let provider = try NodeHTTPSpiderSiteProvider(
            site: SiteConfiguration(
                key: "ali_proxy_authorization",
                name: "Ali Proxy Authorization",
                type: 3,
                api: "/spider/contract_b/3",
                extra: ["okNodeRuntime": .bool(true)]
            ),
            baseURL: endpoint,
            httpClient: URLSessionHTTPClient(configuration: clientConfiguration)
        )

        let bodyFailureStartedAt = Date()
        let (_, bodyFailureResponse) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent(
                "proxy/ali/missing-download-authorization"
            )
        )
        XCTAssertEqual(
            (bodyFailureResponse as? HTTPURLResponse)?.statusCode,
            500
        )
        let bodyAuthorization = await provider.consumeLatePlaybackAuthorization(
            flag: "阿里/直链",
            notBefore: bodyFailureStartedAt,
            waitMilliseconds: 0
        )
        XCTAssertEqual(
            bodyAuthorization?.websiteURL.absoluteString,
            endpoint.appendingPathComponent("website").absoluteString
        )
        XCTAssertTrue(bodyAuthorization?.message.contains("无法获取下载链接") == true)

        let ordinaryFailureStartedAt = Date()
        let (_, ordinaryFailureResponse) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("proxy/ali/format-error")
        )
        XCTAssertEqual(
            (ordinaryFailureResponse as? HTTPURLResponse)?.statusCode,
            500
        )
        let ordinaryAuthorization = await provider.consumeLatePlaybackAuthorization(
            flag: "阿里/直链",
            notBefore: ordinaryFailureStartedAt,
            waitMilliseconds: 0
        )
        XCTAssertNil(ordinaryAuthorization)

        let forbiddenStartedAt = Date()
        let (_, forbiddenResponse) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("proxy/ali/forbidden")
        )
        XCTAssertEqual((forbiddenResponse as? HTTPURLResponse)?.statusCode, 403)
        let forbiddenAuthorization = await provider.consumeLatePlaybackAuthorization(
            flag: "阿里/直链",
            notBefore: forbiddenStartedAt,
            waitMilliseconds: 0
        )
        XCTAssertTrue(forbiddenAuthorization?.message.contains("HTTP 403") == true)
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
        let configurationID = UUID()

        let firstEndpoint = try await service.ensureReady(
            from: fixture.sourceURL,
            configurationID: configurationID
        )
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
        let namespace = NodeRuntimeProfileNamespace(
            configurationID: configurationID,
            descriptor: descriptor
        )
        let profileURL = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeProfiles")
            .appendingPathComponent(namespace.storageKey)
            .appendingPathComponent(
            "contract-b-profile.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL.path))

        let unrelatedURL = try XCTUnwrap(URL(
            string: "https://fixture.invalid/index.js.md5#source=another-source&version=7"
        ))
        let unrelatedDescriptor = try NodeBundleSourceDescriptor(
            url: unrelatedURL
        )
        let unrelatedNamespace = NodeRuntimeProfileNamespace(
            configurationID: configurationID,
            descriptor: unrelatedDescriptor
        )
        XCTAssertNotEqual(namespace.storageKey, unrelatedNamespace.storageKey)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.applicationSupportDirectory
                .appendingPathComponent("NodeProfiles")
                .appendingPathComponent(unrelatedNamespace.storageKey)
                .appendingPathComponent("contract-b-profile.json")
                .path
        ))

        let secondEndpoint = try await service.ensureReady(
            from: fixture.sourceURL,
            configurationID: configurationID
        )
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

    func testContractBImportedFullProfileBecomesStartupConfiguration() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8
            ),
            sourceFragment: "source=profile-import-fixture&version=1"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )
        let configurationID = UUID()
        _ = try await service.ensureReady(
            from: fixture.sourceURL,
            configurationID: configurationID
        )
        let profileData = Data(
            #"{"sites":{"list":[{"key":"alist-mounted","enable":true}]},"pans":{"list":[]},"danmu":{"urls":[],"autoPush":false},"color":[],"secretMarker":"profile-only"}"#.utf8
        )

        _ = try await service.importProfile(
            profileData,
            from: fixture.sourceURL,
            configurationID: configurationID
        )
        guard case .running(let endpoint) = await service.currentStatus() else {
            return XCTFail("profile import should restart into running state")
        }
        let (startupData, _) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("startup-config")
        )
        let startupConfig = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: startupData) as? [String: Any]
        )
        XCTAssertEqual(startupConfig["secretMarker"] as? String, "profile-only")

        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let namespace = NodeRuntimeProfileNamespace(
            configurationID: configurationID,
            descriptor: descriptor
        )
        let profileURL = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeProfiles")
            .appendingPathComponent(namespace.storageKey)
            .appendingPathComponent("contract-b-profile.json")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: profileURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        await service.stop()
    }

    func testContractBProfileNamespaceSurvivesBundleVersionAndPinChanges() throws {
        let configurationID = UUID()
        let first = try NodeBundleSourceDescriptor(url: XCTUnwrap(URL(
            string: "https://fixture.invalid/index.js.md5#source=publisher-a&version=7&sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )))
        let upgraded = try NodeBundleSourceDescriptor(url: XCTUnwrap(URL(
            string: "https://fixture.invalid/index.js.md5#source=publisher-a&version=8&sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )))
        XCTAssertNotEqual(first.cacheKey, upgraded.cacheKey)
        XCTAssertEqual(
            NodeRuntimeProfileNamespace(
                configurationID: configurationID,
                descriptor: first
            ).storageKey,
            NodeRuntimeProfileNamespace(
                configurationID: configurationID,
                descriptor: upgraded
            ).storageKey
        )
        XCTAssertNotEqual(
            NodeRuntimeProfileNamespace(
                configurationID: configurationID,
                descriptor: first
            ).storageKey,
            NodeRuntimeProfileNamespace(
                configurationID: UUID(),
                descriptor: first
            ).storageKey
        )
    }

    func testContractBProfileMigratesLegacyHashDirectoryWithBackup() async throws {
        let fixture = try makeLegacyCacheFixture(
            script: Data(
                nodeContractBFixtureScript(startDelayMilliseconds: 0).utf8
            ),
            sourceFragment: "source=migration-fixture&version=9"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let descriptor = try NodeBundleSourceDescriptor(url: fixture.sourceURL)
        let legacyRuntime = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeRuntime")
            .appendingPathComponent(descriptor.cacheKey)
        try FileManager.default.createDirectory(
            at: legacyRuntime,
            withIntermediateDirectories: true
        )
        let legacyProfile = legacyRuntime.appendingPathComponent(
            "contract-b-profile.json"
        )
        try Data(
            #"{"marker":"legacy","privateValue":"legacy-cookie"}"#.utf8
        ).write(to: legacyProfile)
        let configurationID = UUID()
        let service = makeOfflineRuntime(
            fixture: fixture,
            nodeExecutableURL: try testNodeExecutableURL(),
            readinessTimeout: 5,
            readinessPollInterval: 0.02
        )

        let endpoint = try await service.ensureReady(
            from: fixture.sourceURL,
            configurationID: configurationID
        )
        let (readData, _) = try await URLSession.shared.data(
            from: endpoint.appendingPathComponent("profile-read")
        )
        let profile = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: readData) as? [String: String]
        )
        XCTAssertEqual(profile["marker"], "legacy")
        XCTAssertEqual(profile["privateValue"], "legacy-cookie")

        let namespace = NodeRuntimeProfileNamespace(
            configurationID: configurationID,
            descriptor: descriptor
        )
        let profileDirectory = fixture.applicationSupportDirectory
            .appendingPathComponent("NodeProfiles")
            .appendingPathComponent(namespace.storageKey)
        let backups = try FileManager.default.contentsOfDirectory(
            at: profileDirectory.appendingPathComponent("Backups"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].lastPathComponent.hasPrefix(
            "contract-b-profile-"
        ))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: profileDirectory
                .appendingPathComponent("contract-b-profile.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
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
                XCTAssertTrue(listeners.contains("*:\(endpointPort)"), "\(name): \(listeners)")
                XCTAssertFalse(listeners.contains("127.0.0.1:"), "\(name): \(listeners)")
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
            const runtimePort = Number(process.env.DEV_HTTP_PORT);
            if (!catDartServerPort() || catDartServerPort() === runtimePort) {
              throw new Error('Dart bridge must use a distinct loopback port');
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
                } else if (request.url === '/startup-config') {
                  response.end(JSON.stringify(config));
                } else if (request.url === '/spider/contract_b/3/home') {
                  response.end(JSON.stringify({class:[],list:[]}));
                } else if (request.url === '/auxiliary') {
                  response.end(JSON.stringify(auxiliary && auxiliary.address()));
                } else if (request.url === '/bridge-port') {
                  response.end(JSON.stringify({port: catDartServerPort()}));
                } else if (request.url === '/website') {
                  const html = '<!doctype html><script src="https://lib.baomitu.com/react/18.2.0/umd/react.production.min.js"></script>';
                  response.setHeader('Content-Type', 'text/html; charset=utf-8');
                  response.setHeader('Content-Length', Buffer.byteLength(html));
                  response.end(html);
                } else if (request.url === '/proxy/ali/missing-download-authorization') {
                  response.statusCode = 500;
                  response.setHeader('Content-Type', 'text/plain; charset=utf-8');
                  response.write('无法获取下载');
                  response.end('链接，请检查授权');
                } else if (request.url === '/proxy/ali/format-error') {
                  response.statusCode = 500;
                  response.setHeader('Content-Type', 'text/plain; charset=utf-8');
                  response.end('unrecognized file format');
                } else if (request.url === '/proxy/ali/forbidden') {
                  response.statusCode = 403;
                  response.setHeader('Content-Type', 'text/plain; charset=utf-8');
                  response.end();
                } else if (/^\/spider\/[^/]+\/[^/]+\/proxy\/(auth|guest|info|stoken|ali)-toast$/.test(request.url)) {
                  const toastKind = request.url.split('/').pop();
                  const message = toastKind === 'auth-toast'
                    ? '夸克token已过期，请前往【配置】站源进行配置'
                    : toastKind === 'guest-toast'
                      ? 'require login [guest]'
                      : toastKind === 'stoken-toast'
                        ? '夸克 stoken 41016 expired'
                        : toastKind === 'ali-toast'
                          ? '阿里云盘 token 已失效，请重新授权'
                          : '普通播放提示';
                  fetch(`http://127.0.0.1:${catDartServerPort()}/msg`, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({
                      action: 'toast',
                      opt: {
                        message,
                        duration: 5
                      }
                    })
                  }).then(async (hostResponse) => {
                    response.statusCode = hostResponse.status;
                    response.end(JSON.stringify({ok: hostResponse.ok}));
                  }).catch(() => {
                    response.statusCode = 500;
                    response.end(JSON.stringify({ok:false}));
                  });
                } else if (request.url === '/host-action') {
                  const hostPort = catDartServerPort();
                  fetch(`http://127.0.0.1:${hostPort}/msg`, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({
                      action: 'openInternalWebview',
                      opt: {url: `http://192.168.1.88:${runtimePort}/website`}
                    })
                  }).then(() => response.end(JSON.stringify({ok:true})))
                    .catch(() => {
                      response.statusCode = 500;
                      response.end(JSON.stringify({ok:false}));
                    });
                } else if (request.url === '/host-sniff') {
                  fetch(`http://127.0.0.1:${catDartServerPort()}/msg`, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({
                      action: 'sniff',
                      opt: {
                        url: 'https://page.example/player',
                        timeout: 10000,
                        rule: '\\.m3u8',
                        headers: {'User-Agent':'fixture'}
                      }
                    })
                  }).then(async (hostResponse) => {
                    response.statusCode = hostResponse.status;
                    response.end(await hostResponse.text());
                  }).catch(() => {
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
                      opt: {url: `http://127.0.0.1:${runtimePort}/website/${marker}`}
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
                      opt: {url: `http://127.0.0.1:${runtimePort}/website`}
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
                } else if (request.url === '/authorization-sequence' ||
                           request.url === '/authorization-explicit') {
                  const hostURL = `http://127.0.0.1:${catDartServerPort()}/msg`;
                  const challengeID = '00000000-0000-0000-0000-000000000001';
                  const explicitCompletion = request.url === '/authorization-explicit';
                  fetch(hostURL, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({
                      action: 'openInternalWebview',
                      opt: {
                        url: `http://127.0.0.1:${runtimePort}/website`,
                        challengeID,
                        provider: 'fixture-cloud',
                        transport: 'qr'
                      }
                    })
                  }).then(() => fetch(hostURL, {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({
                      action: 'saveProfile',
                      opt: {authorized: true}
                    })
                  })).then(() => {
                    if (!explicitCompletion) return null;
                    return fetch(hostURL, {
                      method: 'POST',
                      headers: {'Content-Type':'application/json'},
                      body: JSON.stringify({
                        action: 'authorizationCompleted',
                        opt: {challengeID, provider: 'fixture-cloud'}
                      })
                    });
                  }).then(() => {
                    response.end(JSON.stringify({ok:true}));
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
        XCTAssertEqual(
            paths.filter { $0.hasSuffix("/init") }.count,
            1,
            "provider/business init failures must not be retried blindly"
        )
        XCTAssertFalse(paths.contains { $0.hasSuffix("/home") })
    }

    func testNodeSearchDoesNotRetryProviderBusinessFailure() async throws {
        let client = NodeSearchRetryHTTPClient(mode: .businessFailure)
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        do {
            _ = try await provider.search(keyword: "fixture", page: 1, quick: false)
            XCTFail("provider business failure must be surfaced")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("业务拒绝"))
        }
        let searchCount = await client.searchCount
        XCTAssertEqual(searchCount, 1)
    }

    func testNodeSearchAttemptsRouteWhenSearchableMetadataIsZero() async throws {
        let client = NodeLifecycleRecordingHTTPClient(initStatusCode: 404)
        let site = SiteConfiguration(
            key: "nodejs_searchable_zero",
            name: "Utility-Looking Node Site",
            type: 3,
            api: "/spider/utility/3",
            searchable: 0,
            extra: ["okNodeRuntime": .bool(true)]
        )
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        _ = try await provider.search(keyword: "fixture", page: 1, quick: false)

        let paths = await client.requestPaths()
        XCTAssertEqual(paths.filter { $0.hasSuffix("/search") }.count, 1)
    }

    func testNodeSearchPublishesTransient503ForAggregateRetry() async throws {
        let client = NodeSearchRetryHTTPClient(mode: .transient503)
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        do {
            _ = try await provider.search(
                keyword: "fixture",
                page: 1,
                quick: false
            )
            XCTFail("provider must leave retry scheduling to MultiSiteSearch")
        } catch let error as SiteSearchError {
            XCTAssertEqual(error.category, .upstreamUnavailable)
            XCTAssertTrue(error.isRetryable)
        }
        let searchCount = await client.searchCount
        XCTAssertEqual(searchCount, 1)
    }

    func testNodeSearchPreservesWrappedConnectionResetForAggregateRetry() async throws {
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
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"message":"read ECONNRESET"}"#.utf8)
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        do {
            _ = try await provider.search(
                keyword: "fixture",
                page: 1,
                quick: false
            )
            XCTFail("wrapped connection reset must be surfaced")
        } catch let error as SiteSearchError {
            XCTAssertEqual(error.category, .transport)
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testNodeSearchOnlyClassifiesExactFastifySearch404AsUnsupported() async throws {
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
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"message":"Route POST:/spider/fixture/3/search not found"}"#.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        do {
            _ = try await provider.search(keyword: "fixture", page: 1, quick: false)
            XCTFail("missing route must fail")
        } catch let error as SiteSearchError {
            XCTAssertEqual(error.category, .unsupportedRoute)
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testNodeSearchDoesNotMisclassifyGenericUpstream404AsMissingRoute() async throws {
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
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"message":"upstream video not found"}"#.utf8)
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        do {
            _ = try await provider.search(keyword: "fixture", page: 1, quick: false)
            XCTFail("upstream 404 must fail")
        } catch let error as SiteSearchError {
            XCTAssertEqual(error.category, .provider)
            XCTAssertFalse(error.isRetryable)
        }
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

    func testCatPawAuthorizationAcceptsAttestedAuxiliaryRuntimePage() async throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let auxiliaryURL = "http://127.0.0.1:19321/douer"
        let client = NodeProviderStubHTTPClient { request in
            XCTAssertEqual(request.url.path, "/__okvideo/owned-loopback")
            let queryItems = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )?.queryItems
            XCTAssertEqual(
                queryItems?.first(where: { $0.name == "url" })?.value,
                auxiliaryURL
            )
            XCTAssertEqual(
                queryItems?.first(where: { $0.name == "purpose" })?.value,
                "internal-webview"
            )
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"url":"http://127.0.0.1:19321/douer"}"#.utf8)
            )
        }
        let bridge = CatPawHostMessageBridge(httpClient: client)
        let coordinator = CatPawAuthorizationCoordinator(
            site: SiteConfiguration(
                key: "nodejs_auxiliary",
                name: "弹幕|服务",
                type: 4,
                api: "/spider/auxiliary/4"
            ),
            hostMessageBridge: bridge
        )
        let authorization = try await coordinator.authorizationRequired(
            hostMessage: CatPawHostMessage(
                action: "openInternalWebview",
                requestID: nil,
                opt: .object(["url": .string(auxiliaryURL)])
            ),
            invocationID: "12345678-auxiliary",
            baseURL: baseURL
        )

        XCTAssertEqual(authorization.websiteURL.absoluteString, auxiliaryURL)
        XCTAssertTrue(authorization.message.contains("内部页面"))
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

    func testNodePlayerPreparesBaiduRedirectWithProviderHeaders() async throws {
        let gatewayURL = "https://d.pcs.baidu.com/file/opaque?sign=runtime-only"
        let finalURL = "https://appall01.baidupcs.com/file/opaque?sign=runtime-only"
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            if request.url.absoluteString == gatewayURL {
                XCTAssertEqual(
                    request.redirectedHeaderFields,
                    ["Range", "Referer", "User-Agent"]
                )
                XCTAssertEqual(request.headers["Range"], "bytes=0-0")
                XCTAssertEqual(request.headers["User-Agent"], "BaiduNetdisk")
                XCTAssertEqual(
                    request.headers["Referer"],
                    "https://pan.baidu.com/"
                )
                return HTTPResponse(
                    url: try XCTUnwrap(URL(string: finalURL)),
                    statusCode: 206,
                    headers: [
                        "Content-Type": "video/mp4",
                        "Content-Range": "bytes 0-0/4096"
                    ],
                    body: Data([0])
                )
            }
            XCTAssertTrue(request.url.path.hasSuffix("/play"))
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"parse":0,"url":["原画","https://d.pcs.baidu.com/file/opaque?sign=runtime-only"],"header":{"User-Agent":"BaiduNetdisk","Referer":"https://pan.baidu.com/"}}"#.utf8
                )
            )
        }
        let site = SiteConfiguration(
            key: "nodejs_baidu_fixture",
            name: "Baidu Fixture",
            type: 3,
            api: "/spider/baidu-fixture/3",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let result = try await provider.player(
            flag: "百度",
            episodeURL: "opaque-episode"
        )

        XCTAssertEqual(result.url, finalURL)
        XCTAssertEqual(result.qualities.map(\.url), [finalURL])
        XCTAssertEqual(result.headers["User-Agent"], "BaiduNetdisk")
        XCTAssertEqual(result.headers["Referer"], "https://pan.baidu.com/")
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
        XCTAssertEqual(result.mediaSession?.rangePolicy, .forward)
        XCTAssertEqual(result.mediaSession?.transport, .compatibilityDirect)
    }

    func testNodePlayerRoutesOpaqueCloudDirectLinkFailureToConfiguration()
        async throws {
        let site = SiteConfiguration(
            key: "nodejs_tgsou",
            name: "TG 搜",
            type: 3,
            api: "/spider/tgsou/3",
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
            XCTAssertTrue(request.url.path.hasSuffix("/play"))
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"parse":0,"url":[],"error":"百度网盘获取原画直链失败"}"#.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        do {
            _ = try await provider.player(
                flag: "百度网盘",
                episodeURL: "opaque-episode"
            )
            XCTFail("缺少百度授权时不应打开 0 KB 播放器")
        } catch let authorization as NodeWebAuthorizationRequired {
            XCTAssertEqual(
                authorization.websiteURL.absoluteString,
                "http://127.0.0.1:18988/website"
            )
            XCTAssertTrue(authorization.message.contains("百度网盘"))
        }
    }

    func testNodePlayerPreservesImmediateHostConfigurationMessage() async throws {
        let site = SiteConfiguration(
            key: "nodejs_cloud_fixture",
            name: "Cloud Fixture",
            type: 3,
            api: "/spider/cloud/3",
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
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "X-OKVideo-Host-Message": hostMessage
                ],
                body: Data(#"{"parse":0,"url":[]}"#.utf8)
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        do {
            _ = try await provider.player(
                flag: "云盘",
                episodeURL: "opaque-episode"
            )
            XCTFail("播放接口的宿主配置消息不应被丢弃")
        } catch let authorization as NodeWebAuthorizationRequired {
            XCTAssertEqual(
                authorization.websiteURL.absoluteString,
                "http://127.0.0.1:18988/website"
            )
        }
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

    func testNodeHomePromotesOwnedWebsiteCategoryAndItsImplicitCards()
        async throws {
        let categoryID = "http://192.168.1.114:50205/website"
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            if request.url.path == "/__okvideo/owned-loopback" {
                XCTAssertEqual(
                    URLComponents(
                        url: request.url,
                        resolvingAgainstBaseURL: false
                    )?.queryItems?.first(where: { $0.name == "url" })?.value,
                    categoryID
                )
                return HTTPResponse(
                    url: request.url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        #"{"url":"http://127.0.0.1:50205/website"}"#.utf8
                    )
                )
            }
            if request.url.path.hasSuffix("/home") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        """
                        {"class":[{"type_id":"\(categoryID)","type_name":"配置"}],"list":[]}
                        """.utf8
                    )
                )
            }
            if request.url.path.hasSuffix("/homeVod") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"list":[]}"#.utf8)
                )
            }
            if request.url.path.hasSuffix("/category") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        #"{"list":[{"vod_id":"qr","vod_name":"扫码配置"},{"vod_id":"click","vod_name":"点击配置"}],"page":1,"pagecount":1}"#.utf8
                    )
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
            throw HTTPClientError.statusCode(404)
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let home = try await provider.home()
        XCTAssertEqual(home.categories.first?.id, categoryID)
        XCTAssertEqual(home.categories.first?.resolvedContentKind, .action)

        let page = try await provider.actionCategory(
            id: categoryID,
            page: 1,
            filters: [:]
        )
        XCTAssertEqual(page.items.map(\.videoID), ["qr", "click"])
        XCTAssertTrue(
            page.items.allSatisfy { $0.resolvedContentKind == .action }
        )
    }

    func testNodeHomeRejectsWebsiteCategoryOwnedByAnotherPort() async throws {
        let categoryID = "http://192.168.1.114:50206/website"
        let client = NodeProviderStubHTTPClient { request in
            if request.url.path.hasSuffix("/init") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 404,
                    headers: [:],
                    body: Data()
                )
            }
            if request.url.path == "/__okvideo/owned-loopback" {
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
                body: request.url.path.hasSuffix("/home")
                    ? Data(
                        """
                        {"class":[{"type_id":"\(categoryID)","type_name":"外部页面"}],"list":[]}
                        """.utf8
                    )
                    : Data(#"{"list":[]}"#.utf8)
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let home = try await provider.home()

        XCTAssertEqual(home.categories.first?.resolvedContentKind, .media)
        XCTAssertTrue(home.actionItems.isEmpty)
    }

    func testNodeCategoryPreservesExplicitActionAndFolderBeforeDetail()
        async throws {
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
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"list":[{"vod_id":"media","vod_name":"影片"},{"vod_id":"configure","vod_name":"配置","action":"login"},{"vod_id":"folder","vod_name":"目录","cate":{}}],"page":1,"pagecount":1}"#.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let page = try await provider.category(
            id: "ordinary",
            page: 1,
            filters: [:]
        )

        XCTAssertEqual(page.items.map(\.videoID), ["media", "configure", "folder"])
        XCTAssertEqual(page.items[1].resolvedContentKind, .action)
        XCTAssertTrue(page.items[2].isFolder)
    }

    func testNodePlaceholderDetailWaitsForCorrelatedLateWebMessage()
        async throws {
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
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        #"{"action":"openInternalWebview","opt":{"url":"http://127.0.0.1:18988/website"}}"#.utf8
                    )
                )
            }
            XCTAssertTrue(request.url.path.hasSuffix("/detail"))
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"{"list":[{"vod_id":"implicit","vod_name":"配置占位"}]}"#.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: nodeLifecycleFixtureSite,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )
        let summary = VideoSummary(
            siteKey: nodeLifecycleFixtureSite.key,
            siteName: nodeLifecycleFixtureSite.name,
            videoID: "implicit",
            title: "配置占位"
        )

        do {
            _ = try await provider.select(summary: summary)
            XCTFail("占位详情之后到达的配置消息不应丢失")
        } catch let authorization as NodeWebAuthorizationRequired {
            XCTAssertEqual(
                authorization.websiteURL.absoluteString,
                "http://127.0.0.1:18988/website"
            )
        }
    }

    func testNodeConfigurationWebViewAllowsOnlyExactRuntimeOrigin() throws {
        let origin = try XCTUnwrap(
            URL(string: "http://127.0.0.1:50205/website")
        )
        XCTAssertTrue(
            NodeConfigurationNavigationPolicy.isOwnedRuntimeURL(
                try XCTUnwrap(
                    URL(string: "http://127.0.0.1:50205/website/settings")
                ),
                origin: origin
            )
        )
        XCTAssertFalse(
            NodeConfigurationNavigationPolicy.isOwnedRuntimeURL(
                try XCTUnwrap(
                    URL(string: "http://127.0.0.1:50206/website")
                ),
                origin: origin
            )
        )
        XCTAssertFalse(
            NodeConfigurationNavigationPolicy.isOwnedRuntimeURL(
                try XCTUnwrap(
                    URL(string: "http://localhost:50205/website")
                ),
                origin: origin
            )
        )
        XCTAssertFalse(
            NodeConfigurationNavigationPolicy.isOwnedRuntimeURL(
                try XCTUnwrap(
                    URL(string: "https://127.0.0.1:50205/website")
                ),
                origin: origin
            )
        )
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
        XCTAssertNil(result.resourceReference)
        XCTAssertEqual(
            result.mediaSession?.resourceReference.providerKind,
            "node-http-spider-runtime"
        )
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
        XCTAssertEqual(result.mediaSession?.rangePolicy, .providerDefined)
        XCTAssertNil(replayStore.replay(for: "episode"))
    }

    func testNodePlaybackMapsOfficialJS2PWebProxyToCurrentRuntime() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))

        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizePlaybackURL(
                "js2p://_WEB_/proxy/hls/ffm3u8/segment.m3u8?token=abc#part",
                baseURL: baseURL
            ),
            "http://127.0.0.1:18988/proxy/hls/ffm3u8/segment.m3u8?token=abc#part"
        )
        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizePlaybackURL(
                "js2p://external.example/proxy/hls/media.m3u8",
                baseURL: baseURL
            ),
            "js2p://external.example/proxy/hls/media.m3u8"
        )
        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizePlaybackURL(
                "js2p://_WEB_/website",
                baseURL: baseURL
            ),
            "js2p://_WEB_/website"
        )
        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizePlaybackURL(
                "/proxy/hls/a?token=x&url=https%3A%2F%2Fmedia.example%2Fa.m3u8#part",
                baseURL: baseURL
            ),
            "http://127.0.0.1:18988/proxy/hls/a?token=x&url=https%3A%2F%2Fmedia.example%2Fa.m3u8#part"
        )
        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizePlaybackURL(
                "/spider/key/3/proxy?header=hello+world&token=a%2Bb&token=c%252Fd",
                baseURL: baseURL
            ),
            "http://127.0.0.1:18988/spider/key/3/proxy?header=hello+world&token=a%2Bb&token=c%252Fd"
        )
        // Non-CatPaw direct media and other loopback bridges are deliberately
        // outside this resolver so TVBox and cloud transports retain their
        // existing ownership and request semantics.
        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizePlaybackURL(
                "https://media.example/video.m3u8?token=a%2Bb",
                baseURL: baseURL
            ),
            "https://media.example/video.m3u8?token=a%2Bb"
        )
        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizePlaybackURL(
                "http://127.0.0.1:9978/proxy/media/session-id",
                baseURL: baseURL
            ),
            "http://127.0.0.1:9978/proxy/media/session-id"
        )
    }

    func testNodePlaybackLeaseIsStrictlyScopedToCatPawRuntimeProxy() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        func session(
            url: String,
            transport: PlaybackMediaSession.Transport = .providerLoopback,
            providerKind: String = "node-http-spider-runtime"
        ) -> PlaybackMediaSession {
            PlaybackMediaSession(
                sessionID: UUID().uuidString,
                transport: transport,
                mediaURL: url,
                resourceReference: PlaybackResourceReference(
                    configurationIdentity: "configuration",
                    siteIdentity: "site",
                    providerKind: providerKind,
                    providerVersion: 1,
                    stableResourceLocator: "runtime-locator",
                    sourceIdentity: "source",
                    episodeIdentity: "episode",
                    stability: .providerReplay
                )
            )
        }

        XCTAssertTrue(
            NodeRuntimePlaybackLeasePolicy.owns(
                session(
                    url: "http://127.0.0.1:18988/spider/key/3/proxy/media"
                ),
                serviceBaseURL: baseURL
            )
        )
        XCTAssertTrue(
            NodeRuntimePlaybackLeasePolicy.owns(
                session(url: "http://127.0.0.1:18988/proxy/hls/item.m3u8"),
                serviceBaseURL: baseURL
            )
        )
        XCTAssertFalse(
            NodeRuntimePlaybackLeasePolicy.owns(
                session(
                    url: "http://127.0.0.1:9978/proxy/media/tvbox",
                    providerKind: "android-dex-spider"
                ),
                serviceBaseURL: baseURL
            )
        )
        XCTAssertFalse(
            NodeRuntimePlaybackLeasePolicy.owns(
                session(url: "https://media.example/video.m3u8"),
                serviceBaseURL: baseURL
            )
        )
        XCTAssertFalse(
            NodeRuntimePlaybackLeasePolicy.owns(
                session(
                    url: "http://127.0.0.1:18988/proxy/hls/item.m3u8",
                    transport: .compatibilityDirect
                ),
                serviceBaseURL: baseURL
            )
        )
    }

    func testNodePosterRebindsCatPawLANProxyToCurrentRuntime() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:55709/"))
        let posterURL = try XCTUnwrap(
            URL(
                string: "http://192.168.1.114:55709/spider/baseset/3/proxy/"
                    + "aHR0cDovLzE5Mi4xNjguMS4xMTQ6NTU3MDkvd2Vic2l0ZQ=="
            )
        )

        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizeRuntimePosterURL(
                posterURL,
                baseURL: baseURL
            )?.absoluteString,
            "http://127.0.0.1:55709/spider/baseset/3/proxy/"
                + "aHR0cDovLzE5Mi4xNjguMS4xMTQ6NTU3MDkvd2Vic2l0ZQ=="
        )
        XCTAssertEqual(
            NodeHTTPSpiderSiteProvider.normalizeRuntimePosterURL(
                URL(string: "https://images.example.invalid/poster.jpg"),
                baseURL: baseURL
            )?.absoluteString,
            "https://images.example.invalid/poster.jpg"
        )
    }

    func testNodePlayerKeepsProviderOrderedRelayWithoutTransportProbe()
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
        XCTAssertNil(result.resourceReference)
        XCTAssertEqual(
            result.mediaSession?.resourceReference.configurationIdentity,
            configurationIdentity
        )
        XCTAssertNil(replayStore.replay(for: "episode"))
        XCTAssertEqual(result.mediaSession?.rangePolicy, .providerDefined)
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
    }

    func testNodePlayerKeepsProviderOrderedQuarkRelayAheadOfOriginal()
        async throws {
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 4,
            api: "/spider/fixture/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let relayURL =
            "http://127.0.0.1:18988/spider/fixture/4/proxy/stream?id=1"
        let originalURL = "https://media.example.invalid/original?id=1"
        let client = NodeProviderStubHTTPClient { request in
            HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    """
                    {"parse":0,"url":["Provider relay","\(relayURL)","原画","\(originalURL)"]}
                    """.utf8
                )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let result = try await provider.player(
            flag: "夸克网盘",
            episodeURL: "episode"
        )

        XCTAssertEqual(result.url, relayURL)
        XCTAssertEqual(result.qualities.map(\.url), [relayURL, originalURL])
        XCTAssertEqual(result.mediaSession?.transport, .providerLoopback)
        XCTAssertEqual(result.mediaSession?.rangePolicy, .providerDefined)
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
    }

    func testNodePlayerKeepsFirstCloudTransportWithoutDuplicateRangeProbe()
        async throws {
        let directURL = "https://media.example.invalid/original?id=1"
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 4,
            api: "/spider/fixture/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            if request.url.absoluteString == directURL {
                XCTAssertEqual(request.headers["Range"], "bytes=0-0")
                return HTTPResponse(
                    url: request.url,
                    statusCode: 206,
                    headers: [
                        "Content-Type": "video/mp4",
                        "Content-Range": "bytes 0-0/4096"
                    ],
                    body: Data([0])
                )
            }
            return HTTPResponse(
                url: request.url,
                statusCode: request.url.path.hasSuffix("/init") ? 404 : 200,
                headers: ["Content-Type": "application/json"],
                body: request.url.path.hasSuffix("/init")
                    ? Data()
                    : Data(
                        #"{"parse":0,"url":["Provider relay","http://127.0.0.1:18988/spider/fixture/4/proxy/stream?id=1","Original","https://media.example.invalid/original?id=1"]}"#.utf8
                    )
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client,
            configurationIdentity: UUID().uuidString.lowercased()
        )

        let result = try await provider.player(flag: "direct", episodeURL: "episode")

        XCTAssertEqual(
            result.url,
            "http://127.0.0.1:18988/spider/fixture/4/proxy/stream?id=1"
        )
        XCTAssertEqual(result.mediaSession?.transport, .providerLoopback)
        XCTAssertEqual(result.mediaSession?.rangePolicy, .providerDefined)
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
    }

    func testNodePlayerLeavesHLSSeekabilityToProviderAndPlayer() async throws {
        let hlsURL = "https://media.example.invalid/master.m3u8?token=fixture"
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 4,
            api: "/spider/fixture/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            if request.url.absoluteString == hlsURL {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                    body: Data(
                        """
                        #EXTM3U
                        #EXT-X-PLAYLIST-TYPE:VOD
                        #EXTINF:10,
                        0.ts
                        #EXTINF:10,
                        1.ts
                        #EXTINF:10,
                        2.ts
                        #EXT-X-ENDLIST
                        """.utf8
                    )
                )
            }
            if request.url.path.hasSuffix("/1.ts") {
                XCTAssertEqual(request.headers["Range"], "bytes=0-65535")
                return HTTPResponse(
                    url: request.url,
                    statusCode: 206,
                    headers: ["Content-Type": "video/mp2t"],
                    body: Data([0x47, 0x40, 0x00, 0x10])
                )
            }
            return HTTPResponse(
                url: request.url,
                statusCode: request.url.path.hasSuffix("/init") ? 404 : 200,
                headers: ["Content-Type": "application/json"],
                body: request.url.path.hasSuffix("/init")
                    ? Data()
                    : Data(#"{"parse":0,"url":"https://media.example.invalid/master.m3u8?token=fixture"}"#.utf8)
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client,
            configurationIdentity: UUID().uuidString.lowercased()
        )

        let result = try await provider.player(flag: "hls", episodeURL: "episode")

        XCTAssertEqual(result.url, hlsURL)
        XCTAssertEqual(result.mediaSession?.rangePolicy, .providerDefined)
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
    }

    func testNodePlayerDoesNotProbeSequentialHLSBeforePlayback() async throws {
        let hlsURL = "https://media.example.invalid/linear.m3u8"
        let site = SiteConfiguration(
            key: "nodejs_fixture",
            name: "Fixture",
            type: 4,
            api: "/spider/fixture/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { request in
            if request.url.absoluteString == hlsURL {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 200,
                    headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                    body: Data(
                        """
                        #EXTM3U
                        #EXT-X-PLAYLIST-TYPE:VOD
                        #EXTINF:10,
                        0.ts
                        #EXTINF:10,
                        1.ts
                        #EXT-X-ENDLIST
                        """.utf8
                    )
                )
            }
            if request.url.path.hasSuffix("/1.ts") {
                return HTTPResponse(
                    url: request.url,
                    statusCode: 403,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":"expired"}"#.utf8)
                )
            }
            return HTTPResponse(
                url: request.url,
                statusCode: request.url.path.hasSuffix("/init") ? 404 : 200,
                headers: ["Content-Type": "application/json"],
                body: request.url.path.hasSuffix("/init")
                    ? Data()
                    : Data(#"{"parse":0,"url":"https://media.example.invalid/linear.m3u8"}"#.utf8)
            )
        }
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:18988/")),
            httpClient: client
        )

        let result = try await provider.player(flag: "hls", episodeURL: "episode")

        XCTAssertEqual(result.mediaSession?.rangePolicy, .providerDefined)
        XCTAssertEqual(result.validationPolicy, .playerAuthoritative)
    }

    func testNodePlayerKeepsProviderOrderForRemoteTransports()
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
            "https://media.example.invalid/relay"
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
        XCTAssertNil(
            passcodeStore.passcode(
                for: QuarkEpisodeReference.credentialAccount(for: identity)
            ),
            "the host must not persist extraction codes as credentials"
        )
    }

    func testNodePlayerRefreshesDurableQuarkHistoryBeforeSpiderPlay() async throws {
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .none)
        let provider = try makeNodeProvider(httpClient: client)
        let durable = QuarkEpisodeReference.durableHistoryReference(
            try makeQuarkEpisodeReference(stoken: "expired-stoken")
        )

        _ = try await provider.player(flag: "夸克", episodeURL: durable)
        let requests = await client.capturedRequests()
        XCTAssertEqual(requests.filter {
            $0.url == QuarkEpisodeReference.shareTokenURL
        }.count, 1)
        let playRequest = try XCTUnwrap(
            requests.first { $0.url.path.hasSuffix("/play") }
        )
        XCTAssertEqual(
            try quarkStoken(from: nodeEpisodeID(from: playRequest)),
            "fresh-stoken"
        )
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

    func obsolete_testNodePlayerWrapsExplicitGenericProviderStableReference()
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

    func obsolete_testNodeGenericStableReferencePersistsAndRefreshesAfterRestart()
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
        let fallbackClient = NodeStableReferenceHTTPClient(
            stableLocator: nil,
            detailEpisode: "fresh-provider-episode",
            detailSourceName: "provider-line"
        )
        let fallbackProvider = try makeGenericNodeProvider(
            httpClient: fallbackClient,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )
        let fallback = try await fallbackProvider.refreshPlayback(
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
        XCTAssertEqual(fallback.episode.url, "fresh-provider-episode")
        let fallbackRequests = await fallbackClient.capturedRequests()
        XCTAssertTrue(fallbackRequests.contains {
            $0.url.path.hasSuffix("/detail")
        })
        XCTAssertTrue(fallbackRequests.contains {
            $0.url.path.hasSuffix("/play")
        })
    }

    func obsolete_testNodePlayerKeepsCompatibilityReplayCapabilityOutOfHistory()
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

    func obsolete_testNodeSecureReplayReferenceRefreshesExactResourceAfterRestart()
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
            $0.url.path.hasSuffix("/init")
                || $0.url.path.hasSuffix("/play")
                || $0.url.path.hasPrefix("/src/down/")
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

    func obsolete_testNodeSecureReplayReferenceFallsBackToCurrentDetailWhenStoreMissing()
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
        let refreshClient = NodeStableReferenceHTTPClient(
            stableLocator: nil,
            detailEpisode: "fresh-episode-42"
        )
        let restartedProvider = try makeGenericNodeProvider(
            httpClient: refreshClient,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: NodePlaybackReplayMemoryStore()
        )

        let refreshed = try await restartedProvider.refreshPlayback(
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
        XCTAssertEqual(refreshed.episode.url, "fresh-episode-42")

        let requests = await refreshClient.capturedRequests()
        XCTAssertTrue(requests.contains {
            $0.url.path.hasSuffix("/detail")
        })
        XCTAssertTrue(requests.contains { $0.url.path.hasSuffix("/play") })
        XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/search") })
    }

    func obsolete_testNodeLoopbackPlayFailsClosedWhenSecureReplayCannotBeStored()
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
            mediaProbe: AcceptingPlaybackMediaProbe()
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

    func obsolete_testNodeProviderPrefersCurrentQuarkPasscodeOverStoredValue() async throws {
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

    func obsolete_testNodeProviderRefreshesExplicit41016OnceAndRetriesPlayOnce() async throws {
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

    func obsolete_testNodeProviderRecoversFromLegacyMissingTaskErrorWithoutBlindRetry() async throws {
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

    func obsolete_testQuarkRefreshFailurePreservesOriginalErrorCode() async throws {
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

    func testNodeGenericPlaybackKeepsHistorySecretFreeWithoutReplayStore()
        async throws {
        let provider = try makeGenericNodeProvider(
            httpClient: NodeStableReferenceHTTPClient(stableLocator: nil),
            configurationIdentity: UUID().uuidString.lowercased()
        )

        let result = try await provider.player(
            flag: "cloud-original",
            episodeURL: "opaque-file-42?authorization=runtime-only"
        )

        XCTAssertNil(result.resourceReference)
        XCTAssertEqual(result.mediaSession?.transport, .providerLoopback)
        XCTAssertEqual(
            result.mediaSession?.resourceReference.providerKind,
            "node-http-spider-runtime"
        )
        XCTAssertTrue(
            result.mediaSession?.resourceReference.stableResourceLocator
                .hasPrefix("runtime-v1.") == true
        )
        XCTAssertNil(
            PlaybackPersistencePolicy.sanitizedProviderResourceReference(
                result.mediaSession?.resourceReference
            )
        )
        XCTAssertNil(
            provider.captureHistoryPlaybackResourceReference(
                videoID: "detail?id=42&session=runtime-only",
                flag: "cloud-original",
                episode: PlayEpisode(
                    name: "第 1 集",
                    url: "opaque-file-42?authorization=runtime-only"
                ),
                episodeIndex: 0
            ),
            "production-default providers must not persist credential-shaped replay data"
        )
    }

    func testNodeDefaultReplayStoreKeepsOnlyCredentialFreeHistoryIdentity()
        throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let provider = try makeGenericNodeProvider(
            httpClient: NodeStableReferenceHTTPClient(stableLocator: nil),
            configurationIdentity: configurationIdentity
        )
        let reference = try XCTUnwrap(
            provider.captureHistoryPlaybackResourceReference(
                videoID: "stable-video-42",
                flag: "cloud-original",
                episode: PlayEpisode(name: "第 1 集", url: "stable-file-42"),
                episodeIndex: 0
            )
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(reference),
            as: UTF8.self
        )

        XCTAssertTrue(reference.stableResourceLocator.hasPrefix("ndr2."))
        XCTAssertTrue(provider.acceptsPlaybackResourceReference(reference))
        XCTAssertFalse(encoded.contains("authorization"))
        XCTAssertFalse(encoded.contains("runtime-only"))
    }

    func testNodeDefaultReplayStoreIgnoresExistingProtectedHistoryHandle()
        throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let provider = try makeGenericNodeProvider(
            httpClient: NodeStableReferenceHTTPClient(stableLocator: nil),
            configurationIdentity: configurationIdentity
        )
        let reference = PlaybackResourceReference(
            configurationIdentity: configurationIdentity,
            siteIdentity: "nodejs_stable_fixture",
            providerKind: "node-http-spider",
            providerVersion: 2,
            stableResourceLocator: "nhr2." + String(repeating: "a", count: 64),
            sourceIdentity: "source",
            episodeIdentity: "episode",
            stability: .providerStable
        )

        XCTAssertFalse(provider.acceptsPlaybackResourceReference(reference))
    }

    func testNodeExpiredCloudTokenRefreshesShareTokenAndRetriesOnce()
        async throws {
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .expiredStoken)
        let provider = try makeNodeProvider(httpClient: client)
        let episode = try makeQuarkEpisodeReference(stoken: "expired-stoken")

        _ = try await provider.player(flag: "夸克", episodeURL: episode)

        let requests = await client.capturedRequests()
        XCTAssertEqual(
            requests.filter { $0.url.path.hasSuffix("/play") }.count,
            2
        )
        XCTAssertEqual(requests.filter {
            $0.url == QuarkEpisodeReference.shareTokenURL
        }.count, 1)
    }

    func testNodeDetailCapturesSecretFreeQuarkReferenceBeforePlayback()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let episode = try makeQuarkEpisodeReference(
            stoken: "detail-only-stoken",
            passcode: "2468"
        )
        let client = QuarkRefreshHTTPClient(
            firstPlayFailure: .none,
            detailEpisode: episode
        )
        let provider = try makeNodeProvider(
            httpClient: client,
            configurationIdentity: configurationIdentity
        )

        let detail = try await provider.detail(id: "session-scoped-video")
        let captured = try XCTUnwrap(
            detail.playSources.first?.episodes.first?
                .providerResourceReference
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(captured),
            as: UTF8.self
        ).lowercased()

        XCTAssertTrue(provider.acceptsPlaybackResourceReference(captured))
        XCTAssertTrue(captured.stableResourceLocator.hasPrefix("qhr1."))
        XCTAssertEqual(
            QuarkEpisodeReference.identity(from: captured.stableResourceLocator),
            QuarkEpisodeReference.identity(from: episode)
        )
        for forbidden in ["detail-only-stoken", "2468", "playtoken", "cookie"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }

        // Recreate the provider to model a complete app restart. The old
        // session-scoped video ID is deliberately unusable; the persisted
        // provider/share/file identity must go straight to token refresh and
        // Spider play without detail or title search.
        let persisted = try JSONDecoder().decode(
            PlaybackResourceReference.self,
            from: JSONEncoder().encode(captured)
        )
        let restartedClient = QuarkRefreshHTTPClient(firstPlayFailure: .none)
        let restartedProvider = try makeNodeProvider(
            httpClient: restartedClient,
            configurationIdentity: configurationIdentity
        )
        let refreshed = try await restartedProvider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: "expired-session-scoped-video",
                title: "Fixture（臻彩）",
                sourceIdentity: persisted.sourceIdentity,
                resourceIdentity: persisted.episodeIdentity,
                sourceName: "夸克",
                episodeName: "原画",
                providerResourceReference: persisted
            )
        )
        let restartedRequests = await restartedClient.capturedRequests()
        XCTAssertEqual(refreshed.playbackResult.resourceReference, persisted)
        XCTAssertFalse(restartedRequests.contains {
            $0.url.path.hasSuffix("/detail") || $0.url.path.hasSuffix("/search")
        })
        XCTAssertEqual(restartedRequests.filter {
            $0.url == QuarkEpisodeReference.shareTokenURL
        }.count, 1)
        XCTAssertEqual(restartedRequests.filter {
            $0.url.path.hasSuffix("/play")
        }.count, 1)
    }

    func testNodeHistoryRefreshLoadsCurrentDetailBeforePlayer() async throws {
        let client = NodeStableReferenceHTTPClient(
            stableLocator: nil,
            detailEpisode: "fresh-episode-42",
            detailSourceName: "cloud-original"
        )
        let provider = try makeGenericNodeProvider(
            httpClient: client,
            configurationIdentity: UUID().uuidString.lowercased()
        )

        let refreshed = try await provider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: "history-video",
                title: "重复标题",
                sourceIdentity: "obsolete-source-identity",
                resourceIdentity: "obsolete-resource-identity",
                sourceName: "cloud-original",
                episodeName: "历史分集",
                episodeReference: "nhr1.obsolete",
                providerResourceReference: nil
            )
        )

        XCTAssertEqual(refreshed.episode.url, "fresh-episode-42")
        XCTAssertTrue(refreshed.playbackResult.mediaSession?.refreshPerformed == true)
        let requests = await client.capturedRequests()
        let detailIndex = try XCTUnwrap(
            requests.firstIndex { $0.url.path.hasSuffix("/detail") }
        )
        let playIndex = try XCTUnwrap(
            requests.firstIndex { $0.url.path.hasSuffix("/play") }
        )
        XCTAssertLessThan(detailIndex, playIndex)
    }

    func testCatPawVideoHistoryReplaysExactProviderIdentityBeforePlay()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let replayStore = NodePlaybackReplayMemoryStore()
        let episodeID = "https://provider.invalid/share/file-42?token=runtime-only"
        let credentialShapedVideoID =
            "https://provider.invalid/detail?id=42&session=runtime-only"
        func site(profileRevision: String) -> SiteConfiguration {
            SiteConfiguration(
                key: "nodejs_stable_fixture",
                name: "Stable Node Fixture",
                type: 4,
                api: "/spider/stable-fixture/4",
                extra: [
                    "okNodeRuntime": .bool(true),
                    "okNodeBundleIdentity": .string("bundle-stable"),
                    "okNodeProfileIdentity": .string("profile-stable"),
                    "okNodeProfileRevision": .string(profileRevision)
                ]
            )
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let initialProvider = try NodeHTTPSpiderSiteProvider(
            site: site(profileRevision: "revision-a"),
            baseURL: baseURL,
            httpClient: NodeStableReferenceHTTPClient(stableLocator: nil),
            playbackReplayStore: replayStore,
            configurationIdentity: configurationIdentity
        )
        let reference = try XCTUnwrap(
            initialProvider.captureHistoryPlaybackResourceReference(
                videoID: credentialShapedVideoID,
                flag: "cloud-original",
                episode: PlayEpisode(name: "第 1 集", url: episodeID),
                episodeIndex: 0
            )
        )
        let persisted = String(
            decoding: try JSONEncoder().encode(reference),
            as: UTF8.self
        )

        XCTAssertTrue(reference.stableResourceLocator.hasPrefix("nhr2."))
        XCTAssertFalse(persisted.contains(episodeID))
        XCTAssertFalse(persisted.contains("runtime-only"))
        XCTAssertEqual(
            PlaybackPersistencePolicy.sanitizedProviderResourceReference(
                reference
            ),
            reference
        )
        XCTAssertEqual(
            replayStore.replay(for: reference.stableResourceLocator)?.videoID,
            credentialShapedVideoID
        )
        let persistedVideoID = NodePlaybackReplayReference
            .persistedOpaqueIdentity(
                credentialShapedVideoID,
                namespace: "catpaw-video-vod-id"
            )
        XCTAssertTrue(persistedVideoID.hasPrefix("cph2."))
        XCTAssertFalse(persistedVideoID.contains("runtime-only"))
        XCTAssertEqual(
            NodePlaybackReplayReference.persistedOpaqueIdentity(
                "中文普通影片标识",
                namespace: "catpaw-video-vod-id"
            ),
            "中文普通影片标识"
        )

        let client = NodeStableReferenceHTTPClient(
            stableLocator: nil,
            detailEpisode: episodeID,
            detailSourceName: "cloud-original"
        )
        let restartedProvider = try NodeHTTPSpiderSiteProvider(
            site: site(profileRevision: "revision-b"),
            baseURL: baseURL,
            httpClient: client,
            playbackReplayStore: replayStore,
            configurationIdentity: configurationIdentity
        )
        XCTAssertTrue(
            restartedProvider.acceptsPlaybackResourceReference(reference),
            "a profile content revision is refresh state, not history identity"
        )

        let refreshed = try await restartedProvider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: "wrong-title-search-id",
                title: "重复标题",
                sourceIdentity: reference.sourceIdentity,
                resourceIdentity: reference.episodeIdentity,
                providerResourceReference: reference
            )
        )
        let requests = await client.capturedRequests()
        let detailIndex = try XCTUnwrap(
            requests.firstIndex { $0.url.path.hasSuffix("/detail") }
        )
        let playIndex = try XCTUnwrap(
            requests.firstIndex { $0.url.path.hasSuffix("/play") }
        )
        XCTAssertLessThan(detailIndex, playIndex)
        XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/search") })
        let detailBody = try XCTUnwrap(requests[detailIndex].body)
        let detailPayload = try JSONDecoder().decode(
            JSONValue.self,
            from: detailBody
        )
        XCTAssertEqual(
            detailPayload.objectValue?["id"]?.stringValue,
            credentialShapedVideoID
        )
        XCTAssertEqual(
            try nodeEpisodeID(from: requests[playIndex]),
            episodeID
        )
        XCTAssertEqual(refreshed.detail.summary.videoID, "history-video")
        XCTAssertEqual(refreshed.playbackResult.resourceReference, reference)
    }

    func testCatPawVideoHistoryUsesFreshEpisodeTokenForSameProviderResource()
        async throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let replayStore = NodePlaybackReplayMemoryStore()
        let oldEpisodeID =
            "https://provider.invalid/share/file-42?quality=original&token=old"
        let freshEpisodeID =
            "https://provider.invalid/share/file-42?quality=original&token=fresh"
        let initialProvider = try makeGenericNodeProvider(
            httpClient: NodeStableReferenceHTTPClient(stableLocator: nil),
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )
        let reference = try XCTUnwrap(
            initialProvider.captureHistoryPlaybackResourceReference(
                videoID: "stable-video-42",
                flag: "cloud-original",
                episode: PlayEpisode(name: "第 1 集", url: oldEpisodeID),
                episodeIndex: 0
            )
        )
        let client = NodeStableReferenceHTTPClient(
            stableLocator: nil,
            detailEpisode: freshEpisodeID,
            detailSourceName: "cloud-original"
        )
        let restartedProvider = try makeGenericNodeProvider(
            httpClient: client,
            configurationIdentity: configurationIdentity,
            playbackReplayStore: replayStore
        )

        let refreshed = try await restartedProvider.refreshPlayback(
            PlaybackRefreshRequest(
                videoID: "obsolete-history-row-id",
                title: "重复标题",
                sourceIdentity: reference.sourceIdentity,
                resourceIdentity: reference.episodeIdentity,
                providerResourceReference: reference
            )
        )
        let requests = await client.capturedRequests()
        let detailIndex = try XCTUnwrap(
            requests.firstIndex { $0.url.path.hasSuffix("/detail") }
        )
        let playIndex = try XCTUnwrap(
            requests.firstIndex { $0.url.path.hasSuffix("/play") }
        )

        XCTAssertLessThan(detailIndex, playIndex)
        XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/search") })
        XCTAssertEqual(try nodeEpisodeID(from: requests[playIndex]), freshEpisodeID)
        XCTAssertEqual(refreshed.episode.url, freshEpisodeID)
        XCTAssertEqual(refreshed.playbackResult.resourceReference, reference)
    }

    func testLegacyNodeReplayReferencesAreNotAccepted() throws {
        let configurationIdentity = UUID().uuidString.lowercased()
        let provider = try makeGenericNodeProvider(
            httpClient: NodeStableReferenceHTTPClient(stableLocator: nil),
            configurationIdentity: configurationIdentity
        )
        for locator in ["nhr1.deadbeef", "npr1.deadbeef"] {
            let reference = PlaybackResourceReference(
                configurationIdentity: configurationIdentity,
                siteIdentity: "nodejs_stable_fixture",
                providerKind: "node-http-spider",
                providerVersion: 1,
                stableResourceLocator: locator,
                sourceIdentity: "source",
                episodeIdentity: "episode",
                stability: .providerStable
            )
            XCTAssertFalse(provider.acceptsPlaybackResourceReference(reference))
            XCTAssertNil(
                PlaybackPersistencePolicy.sanitizedProviderResourceReference(
                    reference
                )
            )
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
            NodePlaybackDisabledReplayStore()
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

    func testPlayerTimelineFractionsClampPlaybackAndBufferValues() {
        XCTAssertEqual(
            PlayerTimelinePolicy.fraction(value: 30, total: 120),
            0.25
        )
        XCTAssertEqual(
            PlayerTimelinePolicy.fraction(value: 180, total: 120),
            1
        )
        XCTAssertEqual(
            PlayerTimelinePolicy.fraction(value: -10, total: 120),
            0
        )
        XCTAssertEqual(PlayerTimelinePolicy.bufferedFraction(percent: 42), 0.42)
        XCTAssertEqual(PlayerTimelinePolicy.bufferedFraction(percent: 160), 1)
        XCTAssertEqual(PlayerTimelinePolicy.bufferedFraction(percent: -20), 0)
        XCTAssertEqual(
            PlayerTimelinePolicy.bufferedFraction(percent: .nan),
            0
        )
    }

    func testPlayerTimelineDragUsesSingleInsetTrackGeometry() {
        XCTAssertEqual(
            PlayerTimelinePolicy.fraction(
                x: 6,
                width: 212,
                horizontalInset: 6
            ),
            0
        )
        XCTAssertEqual(
            PlayerTimelinePolicy.fraction(
                x: 106,
                width: 212,
                horizontalInset: 6
            ),
            0.5
        )
        XCTAssertEqual(
            PlayerTimelinePolicy.fraction(
                x: 206,
                width: 212,
                horizontalInset: 6
            ),
            1
        )
        XCTAssertEqual(
            PlayerTimelinePolicy.value(fraction: 0.5, total: 4_048),
            2_024
        )
        XCTAssertEqual(
            PlayerTimelinePolicy.value(fraction: 2, total: 100),
            100
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

private actor NodeSearchRetryHTTPClient: HTTPClient {
    enum Mode {
        case businessFailure
        case transient503
    }

    let mode: Mode
    private(set) var searchCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("/init") {
            return HTTPResponse(
                url: request.url,
                statusCode: 404,
                headers: [:],
                body: Data()
            )
        }
        guard request.url.path.hasSuffix("/search") else {
            throw HTTPClientError.statusCode(404)
        }
        searchCount += 1
        switch mode {
        case .businessFailure:
            return HTTPResponse(
                url: request.url,
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"message":"业务拒绝"}"#.utf8)
            )
        case .transient503 where searchCount == 1:
            return HTTPResponse(
                url: request.url,
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"message":"temporarily unavailable"}"#.utf8)
            )
        case .transient503:
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"list":[],"page":1,"pagecount":1}"#.utf8)
            )
        }
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
    private let detailEpisode: String?
    private let detailSourceName: String
    private var requests: [HTTPRequest] = []

    init(
        stableLocator: String?,
        detailEpisode: String? = nil,
        detailSourceName: String = "cloud-original"
    ) {
        self.stableLocator = stableLocator
        self.detailEpisode = detailEpisode
        self.detailSourceName = detailSourceName
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
        if request.url.path.hasSuffix("/detail"),
           let detailEpisode {
            let response: [String: Any] = [
                "list": [[
                    "vod_id": "history-video",
                    "vod_name": "重复标题",
                    "vod_play_from": detailSourceName,
                    "vod_play_url": "历史分集$\(detailEpisode)"
                ]]
            ]
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
    private let detailEpisode: String?
    private var playRequestCount = 0
    private var requests: [HTTPRequest] = []

    init(firstPlayFailure: FirstPlayFailure, detailEpisode: String? = nil) {
        self.firstPlayFailure = firstPlayFailure
        self.detailEpisode = detailEpisode
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
        if request.url.path.hasSuffix("/detail"), let detailEpisode {
            let body = try JSONSerialization.data(
                withJSONObject: [
                    "list": [[
                        "vod_id": "session-scoped-video",
                        "vod_name": "Fixture",
                        "vod_play_from": "夸克",
                        "vod_play_url": "原画$\(detailEpisode)"
                    ]]
                ]
            )
            return HTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: body
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

private struct AcceptingPlaybackMediaProbe: MediaProbe {
    func validate(url: URL, headers: HTTPHeaders) async throws -> Bool {
        true
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
