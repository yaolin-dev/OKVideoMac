import AppKit
import Foundation
import OKVideoCore

/// Explicit developer invocation in an isolated acceptance bundle only. Uses
/// the normal history resolver, window/render ownership and player APIs.
/// The input contains selectors/times, never media URLs or credentials.
@MainActor
enum SeekAcceptanceHarness {
    struct Sample: Decodable {
        let title: String
        let episode: Int
        let episodePattern: String?
        let targets: [Double]

        func matches(_ candidate: PlayEpisode) -> Bool {
            if let episodePattern {
                return candidate.name.range(of: episodePattern, options: .regularExpression) != nil
            }
            return EpisodeNameParser.presentation(for: candidate).episodeNumber == episode
        }
    }
    struct Configuration: Decodable {
        let samples: [Sample]
        let repetitions: Int
        let replayHistory: Bool?
    }
    struct Observation: Codable {
        let sample: Int
        let repetition: Int
        let stage: String
        let outcome: String
        let target: Double?
        let position: Double
        let duration: Double
        let elapsed: Double
    }
    private static var started = false

    /// Decode-and-rebuild a strict report, even if a misconfigured diagnostic
    /// build returns an upstream JSON error instead of our audit response.
    nonisolated static func sanitizedAudit(_ data: Data) -> Data? {
        guard data.count <= 16_384,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = value["outcome"] as? String,
              ["completed", "incomplete", "unsupported_owner_proxy"].contains(outcome),
              let reads = value["reads"] as? [[String: Any]], reads.count <= 5 else { return nil }
        var output: [String: Any] = ["outcome": outcome]
        var safeReads: [[String: Any]] = []
        for read in reads {
            var safe: [String: Any] = [:]
            for name in ["offset", "budget", "status", "bytes"] {
                guard let n = read[name] as? NSNumber, n.doubleValue.isFinite, n.int64Value >= 0 else { return nil }
                safe[name] = n.int64Value
            }
            for name in ["contentRange", "contentLength"] {
                guard let text = read[name] as? String, text.count <= 96,
                      text.range(of: #"^(unknown|invalid|(?:bytes:)?[0-9*/-]+)$"#, options: .regularExpression) != nil else { return nil }
                safe[name] = text
            }
            guard let digest = read["sha256"] as? String,
                  digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let path = read["path"] as? String,
                  ["upstream_head", "upstream_overlap", "bridge_overlap", "upstream_tail", "upstream_tail_repeat"].contains(path),
                  let eof = read["eof"] as? Bool else { return nil }
            safe["sha256"] = digest; safe["path"] = path; safe["eof"] = eof
            if let signature = read["containerSignature"] as? String {
                guard ["ebml", "iso_bmff", "other"].contains(signature) else { return nil }
                safe["containerSignature"] = signature
            }
            safeReads.append(safe)
        }
        output["reads"] = safeReads
        for name in ["overlapEqual", "bridgeBytesEqual", "bridgeOverlapEqual", "tailRepeatEqual", "candidateTailEOF"] {
            if let flag = value[name] as? Bool { output[name] = flag }
        }
        for name in ["overlapBytes", "bridgeOverlapBytes", "candidateLength"] {
            if let n = value[name] as? NSNumber, n.int64Value >= 0 { output[name] = n.int64Value }
        }
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }

    static func runIfRequested(_ state: AppState) async {
        guard !started,
              ProcessInfo.processInfo.environment["OKVIDEOMAC_SEEK_ACCEPTANCE"] == "1",
              let workspace = try? AppEnvironment.acceptanceWorkspace() else { return }
        started = true
        let input = workspace.root.appendingPathComponent("SeekAcceptance.json")
        let output = workspace.root.appendingPathComponent("SeekAcceptanceResults.json")
        var observations: [Observation] = []
        func record(_ sample: Int, _ repetition: Int, _ stage: String,
                    _ outcome: String, _ target: Double?, _ elapsed: Double) {
            let snapshot = state.playerSnapshot
            observations.append(Observation(sample: sample, repetition: repetition,
                stage: stage, outcome: outcome, target: target,
                position: snapshot.position, duration: snapshot.duration, elapsed: elapsed))
            if let bytes = try? JSONEncoder().encode(observations) {
                try? bytes.write(to: output, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            }
            NSLog("SeekAcceptance sample=%d repetition=%d stage=%@ outcome=%@ position=%.3f duration=%.3f elapsed=%.3f",
                  sample, repetition, stage, outcome, snapshot.position, snapshot.duration, elapsed)
        }
        guard let data = try? Data(contentsOf: input), data.count < 16_384,
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              (1...3).contains(config.repetitions), (1...4).contains(config.samples.count),
              config.samples.allSatisfy({ (1...1000).contains($0.episode)
                  && ($0.episodePattern?.count ?? 0) <= 128
                  && $0.targets.count <= 8 && $0.targets.allSatisfy { $0.isFinite && $0 >= 0 } }) else {
            record(0, 0, "configuration", "invalid", nil, 0)
            return
        }
        // Freeze selectors before playback updates history in this disposable DB.
        let history = state.history
        for (index, sample) in config.samples.enumerated() {
            let matches = history.filter { $0.title == sample.title }
            guard matches.count == 1, let item = matches.first else {
                record(index, 0, "history_selection", "not_unique", nil, 0)
                continue
            }
            for repetition in 0..<config.repetitions {
                await state.closePlayer()
                guard let owner = item.configurationID else {
                    record(index, repetition, "configuration_owner", "missing", nil, 0)
                    continue
                }
                if state.activeConfigurationRecord?.id != owner {
                    await state.activateConfiguration(owner)
                }
                if config.replayHistory == true {
                    state.requestHistoryPlayback(item)
                } else {
                    // Resolve a complete current detail first. Replaying a one-file
                    // history recipe can start a different episode before selection.
                    await state.loadDetail(VideoSummary(siteKey: item.siteKey,
                        siteName: "", videoID: item.playbackReference?.navigationRecipe?.detailID ?? item.videoID,
                        title: item.title, posterURL: nil))
                    guard let detail = state.selectedDetail else {
                        record(index, repetition, "detail", "unavailable", nil, 0)
                        continue
                    }
                    let sources = detail.playSources.filter { $0.name == item.sourceName }
                    guard sources.count == 1, let source = sources.first else {
                        record(index, repetition, "source_selection", "not_unique", nil, 0)
                        continue
                    }
                    let episodes = source.episodes.filter(sample.matches)
                    guard episodes.count == 1, let episode = episodes.first else {
                        record(index, repetition, "episode_selection", "not_unique", nil, 0)
                        continue
                    }
                    await state.startPlayback(detail: detail, source: source, episode: episode, configurationID: owner)
                }
                let loaded = await waitForProgress(state, target: nil, budget: 180)
                record(index, repetition, "load", loaded.0, nil, loaded.1)
                guard loaded.0 == "passed" else { continue }
                guard state.currentPlaybackContentTitle == sample.title,
                      state.currentPlaybackEpisode.map(sample.matches) == true else {
                    record(index, repetition, "identity", "mismatch", nil, 0)
                    continue
                }
                let relativeTarget = state.playerSnapshot.position + 10
                await state.seek(by: 10)
                let relative = await waitForProgress(state, target: relativeTarget, budget: 40)
                record(index, repetition, "relative_10", relative.0, relativeTarget, relative.1)
                guard relative.0 == "passed" else { continue }
                var absoluteChecksPassed = true
                for target in sample.targets {
                    guard target < state.playerSnapshot.duration - 30 else {
                        record(index, repetition, "absolute", "outside_budget", target, 0)
                        absoluteChecksPassed = false
                        break
                    }
                    await state.seek(to: target)
                    let result = await waitForProgress(state, target: target, budget: 45)
                    record(index, repetition, "absolute", result.0, target, result.1)
                    if result.0 != "passed" { absoluteChecksPassed = false; break }
                }
                // The production seek API returns once the command is issued
                // for these media. Issue replacements before waiting for real
                // playback; only the final target can satisfy this check.
                if absoluteChecksPassed, sample.targets.count >= 3 {
                    let burst = Array(sample.targets.prefix(3))
                    for target in burst {
                        await state.seek(to: target)
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let result = await waitForProgress(state, target: burst.last, budget: 45)
                    record(index, repetition, "rapid_replacement", result.0, burst.last, result.1)
                }
                if let rawAudit = await state.seekAcceptanceReadAudit(), let audit = sanitizedAudit(rawAudit) {
                    let path = workspace.root.appendingPathComponent("RangeAudit-\(index)-\(repetition).json")
                    try? audit.write(to: path, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                }
            }
        }
        await state.closePlayer()
        record(-1, -1, "run", "finished", nil, 0)
    }

    /// A restart notification or optimistic target is insufficient: require
    /// five seconds of advancing playback, outside seeking/buffering/EOF.
    /// The generous 20s keyframe window is a harness bound, not player policy.
    private static func waitForProgress(_ state: AppState, target: Double?, budget: Double) async -> (String, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        var previous: Double?
        var advance = 0.0
        while ProcessInfo.processInfo.systemUptime - start < budget {
            if Task.isCancelled { return ("cancelled", ProcessInfo.processInfo.systemUptime - start) }
            let snapshot = state.playerSnapshot
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            switch snapshot.status {
            case .failed: return ("failed", elapsed)
            case .ended, .stopped: return ("unexpected_end", elapsed)
            default: break
            }
            let inRange = target.map { snapshot.position >= max(0, $0 - 20)
                && snapshot.position <= $0 + 20 } ?? true
            if snapshot.status == .playing, !snapshot.isSeeking, !snapshot.isPausedForCache,
               snapshot.videoWidth > 0, snapshot.position < snapshot.duration - 3, inRange {
                if let previous {
                    let delta = snapshot.position - previous
                    if delta > 0 && delta < 2 { advance += delta }
                    else if delta < 0 || delta >= 2 { advance = 0 }
                }
                previous = snapshot.position
                if advance >= 5 { return ("passed", elapsed) }
            } else { previous = nil; advance = 0 }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return ("budget_exhausted", ProcessInfo.processInfo.systemUptime - start)
    }
}
