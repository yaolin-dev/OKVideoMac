
// Appended only to the disposable instrumented AppState.swift. This fixture
// supplies local media/metadata; cleanup and persistence remain production code.
extension AppState {
    func updateProbeHistory() async throws -> [HistoryRecord] {
        guard let environment else { throw AppError.unsupported("Missing real environment") }
        return try await environment.database.history()
    }

    func updateProbePreparePlayback() async throws {
        guard let environment, environment.player.renderPlayer != nil else {
            throw AppError.unsupported("Real libmpv failed to initialize")
        }
        let databaseURL = await environment.database.databaseURL
        ProbeLog.record("real_environment_ready", ["database": databaseURL.path,
            "player": environment.player.runtimeDescription])
        if ProbeLog.scenario == "idle" { return }
        let configuration = StoredConfiguration(name: "Updater fixture", sourceKind: .pasted,
            rawData: Data("{\"sites\":[]}".utf8), isActive: true)
        try await environment.database.saveConfiguration(configuration)
        activeConfigurationRecord = configuration
        let mediaURL = ProbeLog.root.appendingPathComponent("silent.wav")
        let episode = PlayEpisode(name: "Local silent audio", url: mediaURL.absoluteString)
        let source = PlaySource(name: "Local fixture", episodes: [episode])
        let detail = VideoDetail(summary: VideoSummary(siteKey: "update-fixture", siteName: "Local",
            videoID: "silent-audio", title: "Updater local audio fixture"), playSources: [source])
        let media = ResolvedMedia(url: mediaURL, headers: [:], siteKey: "update-fixture",
            sourceName: source.name, episodeName: episode.name)
        let request = UUID()
        activePlayerRequestID = request; playbackSessionID = request
        historyProgressCheckpoint.reset(owner: request)
        activePlayback = ActivePlaybackContext(configurationID: configuration.id, detail: detail,
            source: source, episode: episode, media: media, requestID: request)
        try await environment.player.setMuted(true)
        try await environment.player.load(media, startPosition: 17.5, requestID: request)
        let end = ProcessInfo.processInfo.systemUptime + 20
        var observedStart: Double?
        while ProcessInfo.processInfo.systemUptime < end {
            if case .failed(let reason) = playerSnapshot.status { throw AppError.unsupported(reason) }
            if playerSnapshot.status == .playing && PlayerHistoryProgressCheckpoint.isReliable(playerSnapshot)
                && playerSnapshot.duration > 30 {
                if observedStart == nil { observedStart = playerSnapshot.position }
                if playerSnapshot.position - observedStart! >= 0.5 { break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let observedStart, playerSnapshot.position - observedStart >= 0.5,
              PlayerHistoryProgressCheckpoint.isReliable(playerSnapshot) else {
            throw AppError.unsupported("No advancing, history-reliable native playback")
        }
        if ProbeLog.scenario == "paused" {
            try await environment.player.pause()
            let end = ProcessInfo.processInfo.systemUptime + 3
            while playerSnapshot.status != .paused && ProcessInfo.processInfo.systemUptime < end {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            precondition(playerSnapshot.status == .paused)
        }
        ProbeLog.record("real_playback_verified", ["status": String(describing: playerSnapshot.status),
            "position": playerSnapshot.position, "duration": playerSnapshot.duration,
            "historyReliable": PlayerHistoryProgressCheckpoint.isReliable(playerSnapshot)])
    }
}
