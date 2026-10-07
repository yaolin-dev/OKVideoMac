
// Test data/provider injection only; production resolution, native media events,
// adjacency, window mounting, transition, and shutdown paths remain unchanged.
extension AppState {
    func navigationProbeRun() async throws {
        guard let environment, environment.player.renderPlayer != nil else { throw AppError.unsupported("Missing native environment") }
        let record = StoredConfiguration(name: "Episode navigation fixture", sourceKind: .pasted, rawData: Data("{\"sites\":[]}".utf8), isActive: true)
        try await environment.database.saveConfiguration(record)
        activeConfigurationRecord = record
        let episodes = (1...17).map { index in
            PlayEpisode(name: index == 17 ? "[2GB]E16.mp4" : "[1GB]E\(index).mp4",
                url: NavigationProbe.root.appendingPathComponent("\(index).wav").absoluteString)
        }
        let source = PlaySource(name: "Local duplicate E16", episodes: episodes)
        let detail = VideoDetail(summary: VideoSummary(siteKey: "navigation-fixture", siteName: "Fixture", videoID: "duplicate-16", title: "Episode Navigation Acceptance", categoryName: "剧情 悬疑 犯罪"), playSources: [source])
        let provider = NavigationProvider(fixture: detail)
        providers = [provider.site.key: provider]
        activeConfiguration = FongMiConfiguration(sites: [provider.site])
        autoPlayNextEpisode = true
        try await environment.player.setMuted(true)
        await startPlayback(detail: detail, source: source, episode: episodes[13], configurationID: record.id)
        try await NavigationProbe.wait("real E14 playback and next button") {
            self.currentPlayerEpisodeID == episodes[13].id && self.playerSnapshot.status == .playing && self.playerSnapshot.position > 0.3 && self.hasNextEpisode
        }
        try NavigationProbe.check(playerEpisodeNavigation(offset: 1) == .available(episodes[14]) && hasPreviousEpisode, "E14 resolves previous E13 and next E15")
        await togglePlayPause()
        try await NavigationProbe.wait("pause", seconds: 4) { self.playerSnapshot.status == .paused }
        await seek(to: 2)
        try await NavigationProbe.wait("seek while paused", seconds: 4) { abs(self.playerSnapshot.position - 2) < 0.3 }
        await togglePlayPause()
        try await NavigationProbe.wait("resume", seconds: 4) { self.playerSnapshot.status == .playing }
        try await NavigationProbe.wait("natural EOF E14 automatically loads E15") {
            self.currentPlayerEpisodeID == episodes[14].id && self.playerSnapshot.status == .playing && self.playerSnapshot.position > 0.3
        }
        try NavigationProbe.check(playerEpisodeNavigation(offset: 1) == .choice(Array(episodes.suffix(2))), "E15 exposes both E16 choices")
        try await NavigationProbe.wait("natural EOF E15 remains ended") { self.playerSnapshot.status == .ended }
        try await Task.sleep(nanoseconds: 500_000_000)
        try NavigationProbe.check(currentPlayerEpisodeID == episodes[14].id && playerEpisodeNavigationChoice == nil, "automatic ambiguity neither skips nor opens modal")
        await playAdjacentEpisode(offset: 1)
        try NavigationProbe.check(playerEpisodeNavigationChoice?.episodes == Array(episodes.suffix(2)), "manual next requests resource choice")
        NavigationProbe.record("choice_panel_ready")
        // Leave the actual player panel available for an accessibility check.
        try await Task.sleep(nanoseconds: 12_000_000_000)
        await playPlayerEpisode(episodes[16], expectedSessionID: playerEpisodeSelectionSessionID)
        try await NavigationProbe.wait("user-selected second E16 plays") {
            self.currentPlayerEpisodeID == episodes[16].id && self.playerSnapshot.status == .playing && self.playerSnapshot.position > 0.3
        }
        try NavigationProbe.check(!hasNextEpisode && playerEpisodeNavigationChoice == nil && hasPreviousEpisode, "selected E16 has previous E15 and true end boundary")
        await seek(to: 18)
        try await NavigationProbe.wait("selected E16 seek persisted", seconds: 5) { self.playerSnapshot.position >= 18 && PlayerHistoryProgressCheckpoint.isReliable(self.playerSnapshot) }
        await closePlayer()
        try NavigationProbe.check(!isPlayerPresented && !hasNextEpisode && playerEpisodeNavigationChoice == nil, "close clears navigation")
        let history = try await environment.database.history()
        try NavigationProbe.check(history.contains { $0.episodeName == episodes[16].name && $0.position >= 18 }, "history retains exact selected upload and progress")
        for round in 0..<3 {
            await startPlayback(detail: detail, source: source, episode: episodes[13], configurationID: record.id)
            try await NavigationProbe.wait("reopen E14 round \(round)") { self.currentPlayerEpisodeID == episodes[13].id && self.playerSnapshot.status == .playing && self.hasNextEpisode }
            await playAdjacentEpisode(offset: 1)
            try await NavigationProbe.wait("manual next E15 round \(round)") { self.currentPlayerEpisodeID == episodes[14].id && self.playerSnapshot.status == .playing }
            await closePlayer()
        }
        NavigationProbe.record("history_and_reopen_verified")
    }
}
