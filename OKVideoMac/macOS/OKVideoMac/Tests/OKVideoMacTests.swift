import AppKit
import Combine
import CryptoKit
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

final class OKVideoMacTests: XCTestCase {
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

        XCTAssertEqual(SearchSiteScope(setting: scope.settingValue), scope)
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
            try await repository.image(for: url)
        }
        let activeWaiter = Task { @MainActor in
            try await repository.image(for: url)
        }

        cancelledWaiter.cancel()
        _ = try? await cancelledWaiter.value
        let loaded = try await activeWaiter.value

        XCTAssertTrue(repository.cachedImage(for: url) === loaded)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
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
            MainMenuChineseLocalization.title(for: "About OK影视 Mac"),
            "关于 OK影视 Mac"
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
                {"id": "button:0", "title": "停用中"},
                {"id": "button:1", "title": "停用中"}
              ],
              "texts": ["网盘配置"],
              "phase": "chooser",
              "provider": "quark",
              "authenticated": false
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
            ["button:0", "button:1"]
        )
    }

    func testAndroidBridgeLegacyAuthorizationStateStillDecodes() throws {
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

        XCTAssertTrue(state.isQRCode)
        XCTAssertTrue(state.isAuthorizationPrompt)
        XCTAssertTrue(state.actionableControls.isEmpty)
    }

    func testAndroidBridgeRecognizesCredentialPushQRCodeWithoutNewFlag() throws {
        let data = try XCTUnwrap(
            """
            {
              "visible": true,
              "title": "请使用百度网盘 APP 扫码登录",
              "inputCount": 0,
              "imageCount": 1,
              "buttons": [],
              "texts": ["使用微信扫码推送 Cookie 或 Token"],
              "phase": "qr",
              "provider": "baidu",
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

    func testOriginalCloudSourcePrioritizesMatchingSmartFallback() {
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
    }

    func testAndroidBridgeNetworkRequiresConnectedWiFiAndDefaultRoute() {
        XCTAssertTrue(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is connected to \"AndroidWifi\"",
                routes: "default via 10.0.2.2 dev wlan0"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is enabled\nWifi is disconnected",
                routes: "default via 10.0.2.2 dev wlan0"
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeRuntime.networkLooksReady(
                status: "Wifi is connected to \"AndroidWifi\"",
                routes: "10.0.2.0/24 dev wlan0"
            )
        )
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

    func testAndroidDexMonitorsAuthorizationForSettingsAndPlaybackCalls() {
        let contentSite = SiteConfiguration(
            key: "content",
            name: "Content",
            type: 3,
            api: "csp_Content"
        )
        let configurationSite = SiteConfiguration(
            key: "provider_config",
            name: "Provider settings",
            type: 3,
            api: "csp_Config"
        )
        XCTAssertFalse(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "detail",
                site: contentSite
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "detail",
                site: configurationSite
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "action",
                site: contentSite
            )
        )
        XCTAssertTrue(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "play",
                site: contentSite
            )
        )
        XCTAssertFalse(
            AndroidDexBridgeClient.shouldMonitorAuthorization(
                for: "search",
                site: contentSite
            )
        )
    }

    @MainActor
    func testHistoryIsScopedToActiveOnDemandConfiguration() {
        let first = UUID()
        let second = UUID()
        let records = [
            HistoryRecord(
                configurationID: first,
                siteKey: "same-key",
                videoID: "1",
                title: "First"
            ),
            HistoryRecord(
                configurationID: second,
                siteKey: "same-key",
                videoID: "1",
                title: "Second"
            ),
            HistoryRecord(
                siteKey: "same-key",
                videoID: "legacy",
                title: "Legacy"
            )
        ]

        XCTAssertEqual(
            AppState.historyRecords(records, for: first).map(\.title),
            ["First"]
        )
        XCTAssertEqual(
            AppState.historyRecords(records, for: second).map(\.title),
            ["Second"]
        )
        XCTAssertTrue(AppState.historyRecords(records, for: nil).isEmpty)
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
            episodeReference: "episode-token",
            mediaReference: "https://media.example/video.m3u8",
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
        XCTAssertEqual(replay.episode.url, "episode-token")
        XCTAssertEqual(
            replay.media.url.absoluteString,
            "https://media.example/video.m3u8"
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

    func testSearchResultPresentationSortsExactKeywordFirst() {
        let values = [
            VideoSummary(
                siteKey: "a",
                siteName: "A",
                videoID: "1",
                title: "中华揭秘之寻味新疆"
            ),
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

    func testNodeBundleMD5Compatibility() {
        XCTAssertEqual(
            NodeBundleRuntimeService.md5Hex(Data("hello".utf8)),
            "5d41402abc4b2a76b9719d911017c592"
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

    func testNodeConfigurationCenterUsesEmbeddedWebsiteWithoutHTTPAction() async throws {
        let site = SiteConfiguration(
            key: "nodejs_baseset",
            name: "配置|中心",
            type: 4,
            api: "/spider/baseset/4",
            extra: ["okNodeRuntime": .bool(true)]
        )
        let client = NodeProviderStubHTTPClient { _ in
            XCTFail("配置中心不应请求未实现的 spider action")
            throw HTTPClientError.statusCode(500)
        }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18988/"))
        let provider = try NodeHTTPSpiderSiteProvider(
            site: site,
            baseURL: baseURL,
            httpClient: client
        )

        do {
            _ = try await provider.action("node-web-configuration")
            XCTFail("应该打开内嵌配置站点")
        } catch let authorization as NodeWebAuthorizationRequired {
            XCTAssertEqual(authorization.websiteURL.path, "/website")
        }
    }

    func testNodePlayerRewritesRuntimeProxyToLoopback() async throws {
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
            httpClient: client
        )

        let result = try await provider.player(flag: "直链", episodeURL: "episode")

        XCTAssertEqual(
            result.url,
            "http://127.0.0.1:18988/spider/fixture/4/proxy/media?id=1"
        )
    }

    func testQuarkEpisodeReferenceKeepsStableHistoryIdentityWithoutStoken() throws {
        let original = try makeQuarkEpisodeReference(
            stoken: "expired-stoken",
            passcode: "2468"
        )
        let identity = try XCTUnwrap(
            QuarkEpisodeReference.identity(from: original)
        )

        let durable = QuarkEpisodeReference.durableHistoryReference(original)

        XCTAssertEqual(identity.providerID, "quark")
        XCTAssertEqual(identity.shareID, "share-123")
        XCTAssertEqual(identity.fileID, "file-456")
        XCTAssertEqual(QuarkEpisodeReference.identity(from: durable), identity)
        XCTAssertTrue(QuarkEpisodeReference.requiresShareTokenRefresh(durable))
        XCTAssertEqual(try quarkStoken(from: durable), "")
        XCTAssertEqual(QuarkEpisodeReference.passcode(from: durable), "2468")
    }

    func testNodeProviderRefreshesDurableQuarkHistoryBeforePlayback() async throws {
        let client = QuarkRefreshHTTPClient(firstPlayFailure: .none)
        let provider = try makeNodeProvider(httpClient: client)
        let durable = QuarkEpisodeReference.durableHistoryReference(
            try makeQuarkEpisodeReference(stoken: "expired-stoken")
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
            try quarkStoken(from: nodeEpisodeID(from: playRequests[0])),
            "fresh-stoken"
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
        httpClient: HTTPClient
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
            httpClient: httpClient
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

private struct NodeProviderStubHTTPClient: HTTPClient {
    let handler: (HTTPRequest) throws -> HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try handler(request)
    }
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
                #"{"parse":0,"url":"https://media.example.invalid/video.m3u8"}"#.utf8
            )
        )
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
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
    private var count = 0

    init(body: Data, delayNanoseconds: UInt64 = 0) {
        self.body = body
        self.error = nil
        self.delayNanoseconds = delayNanoseconds
    }

    init(error: HTTPClientError, delayNanoseconds: UInt64 = 0) {
        self.body = nil
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
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
