import AppKit
import Foundation
import OKVideoCore
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @EnvironmentObject private var state: AppState
    @State private var scrubPosition: Double?
    @State private var controlsVisible = true
    @State private var controlsHovering = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var displayedVolume: Double?
    @State private var pendingVolume: Double?
    @State private var isVolumeEditing = false
    @State private var volumeCommandTask: Task<Void, Never>?
    @State private var activeUtilityPanel: PlayerUtilityPanel?
    @State private var isWindowFullScreen = false
    @State private var isProgressHovering = false
    @State private var progressHoverFraction: Double?
    @State private var lastLiveChannelID: String?
    @State private var isLiveSwitchLoadingDelayElapsed = true
    @State private var liveSwitchLoadingDelayTask: Task<Void, Never>?
    let onWindowChromeRestored: () -> Void

    private let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private let utilityIconSize: CGFloat = 19
    private let utilityButtonSize: CGFloat = 38

    var body: some View {
        ZStack {
            // fullDestroy intentionally leaves no embedded client between
            // sessions. While the next client is being recreated, the normal
            // playback status overlay already explains that transient state;
            // stacking the permanent-unavailable placeholder underneath it
            // makes both labels unreadable.
            if PlayerUnavailablePlaceholderPolicy.shouldShow(
                hasEmbeddedPlayer: state.embeddedPlayer != nil,
                showsStatusOverlay: shouldShowStatusOverlay
            ) {
                unavailablePlayer
            }

            PlayerSurfaceInteractionView(
                onMove: revealControls,
                onDoubleClick: toggleFullScreen
            )

            if controlsVisible {
                Group {
                    if state.isLivePlayback {
                        liveControlReadabilityGradient
                    } else {
                        controlReadabilityGradient
                    }
                }
                .transition(.opacity)
            }

            playbackStatusOverlay

            if state.isLivePlayback {
                livePlayerOverlay
                    .environment(\.colorScheme, .dark)
            } else {
                VStack(spacing: 0) {
                    floatingHeader
                    Spacer(minLength: 24)
                    floatingControls
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .opacity(controlsVisible ? 1 : 0)
                .offset(y: controlsVisible ? 0 : 12)
                .allowsHitTesting(controlsVisible)
                .environment(\.colorScheme, .dark)
            }

            if !state.isLivePlayback,
               controlsVisible,
               let activeUtilityPanel {
                VStack {
                    Spacer(minLength: 24)
                    HStack {
                        Spacer(minLength: 24)
                        utilityPanel(activeUtilityPanel)
                    }
                }
                .padding(.trailing, 18)
                .padding(.bottom, 82)
                .transition(
                    .opacity.combined(with: .move(edge: .bottom))
                )
                .zIndex(50)
                .environment(\.colorScheme, .dark)
            }

            PlayerWindowConfigurator(
                isLivePlayback: state.isLivePlayback,
                controlsVisible: controlsVisible,
                title: playbackDisplayTitle,
                videoAspectRatio: playerVideoAspectRatio,
                onRestore: onWindowChromeRestored,
                onFullScreenChange: { isWindowFullScreen = $0 }
            )
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 800, minHeight: 520)
        .background(Color.clear)
        .onAppear {
            lastLiveChannelID = state.livePlaybackChannel?.id
            revealControls()
        }
        .onDisappear {
            hideControlsTask?.cancel()
            liveSwitchLoadingDelayTask?.cancel()
            liveSwitchLoadingDelayTask = nil
            volumeCommandTask?.cancel()
            volumeCommandTask = nil
            pendingVolume = nil
            activeUtilityPanel = nil
        }
        .onChange(of: state.playerSnapshot.status) { _ in
            revealControls()
        }
        .onChange(of: state.livePlaybackChannel?.id) { channelID in
            handleLiveChannelChange(channelID)
        }
        .animation(
            .easeInOut(duration: 0.22),
            value: controlsVisible
        )
    }

    private var unavailablePlayer: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.slash")
                .font(.system(size: 42))
            Text("内嵌播放器不可用")
                .font(.headline)
            Text("请先构建并打包 libmpv 0.41.0。")
                .foregroundColor(.secondary)
        }
        .foregroundColor(.white)
    }

    private var controlReadabilityGradient: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.52),
                    Color.black.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 96)

            Spacer()

            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.03),
                    Color.black.opacity(0.14)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var liveControlReadabilityGradient: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.58)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 150)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var livePlayerOverlay: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Spacer(minLength: 80)
                    liveChannelInfoCard
                }
                .padding(.trailing, 52)

                Spacer(minLength: 40)

                HStack {
                    livePrimaryControls
                    Spacer()
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 24)
            .padding(.bottom, 26)

            Button {
                Task { await state.closePlayer() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.96))
            .background(Color.black.opacity(0.46))
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            .padding(.top, 16)
            .padding(.trailing, 20)
            .help("退出直播")
            .onHover { inside in
                controlsHovering = inside
                inside ? keepControlsVisible() : scheduleControlsHide()
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .offset(y: controlsVisible ? 0 : 10)
        .allowsHitTesting(controlsVisible)
    }

    private var liveChannelInfoCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(state.livePlaybackDisplayTitle)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)

                Text(liveStreamSummary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("正在播放")
                        .foregroundColor(.white.opacity(0.72))
                    Text(state.livePlaybackProgrammes.current?.title ?? "直播节目")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("即将播放")
                        .foregroundColor(.white.opacity(0.72))
                    Text(state.livePlaybackProgrammes.next?.title ?? "--")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "tv")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.64), lineWidth: 2.5)
                }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 430)
        .background(Color.black.opacity(0.28))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .onHover { inside in
            controlsHovering = inside
            inside ? keepControlsVisible() : scheduleControlsHide()
        }
    }

    private var livePrimaryControls: some View {
        HStack(spacing: 12) {
            liveChannelNavigationButton(
                offset: -1,
                systemImage: "chevron.up",
                help: "上一个频道（↑）"
            )

            liveChannelNavigationButton(
                offset: 1,
                systemImage: "chevron.down",
                help: "下一个频道（↓）"
            )

            Button {
                Task { await state.togglePlayPause() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(isPaused ? "播放" : "暂停")

            Button {
                Task { await state.togglePlayerMute() }
            } label: {
                Image(
                    systemName: state.playerSnapshot.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill"
                )
                .font(.system(size: 21, weight: .medium))
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help(state.playerSnapshot.isMuted ? "取消静音" : "静音")

            Label("直播", systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.94))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.28))
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .onHover { inside in
            controlsHovering = inside
            inside ? keepControlsVisible() : scheduleControlsHide()
        }
    }

    private func liveChannelNavigationButton(
        offset: Int,
        systemImage: String,
        help: String
    ) -> some View {
        Button {
            Task { await state.switchLiveChannel(by: offset) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.10))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!state.canSwitchLiveChannel)
        .opacity(state.canSwitchLiveChannel ? 1 : 0.38)
        .help(help)
    }

    private var liveStreamSummary: String {
        guard let channel = state.livePlaybackChannel else { return "直播" }
        let format = state.livePlaybackStream?.format?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return [
            format?.isEmpty == false ? format : nil,
            channel.groupName,
            "\(channel.streams.count) 条线路"
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var playbackDisplayTitle: String {
        let contentTitle = state.currentPlaybackContentTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let episode = state.currentPlaybackEpisode else {
            return contentTitle?.isEmpty == false
                ? contentTitle!
                : state.currentPlaybackTitle
        }

        let presentation = state.currentPlayerEpisodePresentation
            ?? EpisodeNameParser.presentation(for: episode)
        guard let contentTitle, !contentTitle.isEmpty else {
            return presentation.displayName
        }
        if presentation.seasonNumber != nil
            || presentation.episodeNumber != nil
            || presentation.isSpecial {
            return "\(contentTitle) · \(presentation.displayName)"
        }
        return contentTitle
    }

    private var playerVideoAspectRatio: Double? {
        if let override = state.playerAspectRatio {
            let parts = override.split(separator: ":")
            if parts.count == 2,
               let width = Double(parts[0]),
               let height = Double(parts[1]),
               width > 0,
               height > 0 {
                return width / height
            }
        }
        let width = state.playerSnapshot.videoWidth
        let height = state.playerSnapshot.videoHeight
        guard width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    private func episodePanelDisplayName(
        _ presentation: EpisodePresentation
    ) -> String {
        if let number = presentation.episodeNumber {
            return "第 \(number) 集"
        }
        return presentation.displayName
    }

    private var floatingHeader: some View {
        ZStack {
            Text(playbackDisplayTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: 760)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.82), radius: 4, y: 1)

            HStack(spacing: 12) {
                if state.playbackResolutionState != .playing {
                    statusPill
                        .layoutPriority(1)
                }

                Spacer(minLength: 24)

                Button {
                    Task { await state.closePlayer() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                        .shadow(color: .black.opacity(0.82), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.96))
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.black.opacity(0.16), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                }
                .help("退出播放")
            }
        }
        .frame(maxWidth: .infinity)
        .onHover { inside in
            controlsHovering = inside
            inside ? keepControlsVisible() : scheduleControlsHide()
        }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            if !isFailed {
                ProgressView()
                    .controlSize(.mini)
                    .progressViewStyle(
                        CircularProgressViewStyle(tint: .white)
                    )
            }
            Text(state.playbackStageDescription)
                .lineLimit(1)
            Text("·")
                .foregroundColor(.white.opacity(0.5))
            Text(state.playerNetworkSpeedDescription)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundColor(.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.20), in: Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var playbackStatusOverlay: some View {
        if shouldShowStatusOverlay {
            VStack(spacing: 12) {
                if isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.orange)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .progressViewStyle(
                            CircularProgressViewStyle(tint: .white)
                        )
                }

                Text(state.playbackStageDescription)
                    .font(.headline)
                Text(state.playerNetworkSpeedDescription)
                    .font(.body.monospacedDigit())

                if let attempt = state.currentPlaybackAttempt {
                    Text(
                        "\(attempt.sourceName) · "
                            + "\(attempt.parserName ?? "直链") · "
                            + "尝试 \(attempt.number)"
                    )
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.66))
                }

                if isFailed, let message = state.playbackFailureSummary {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.66))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .frame(maxWidth: 560)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 500)
            .shadow(color: .black.opacity(0.72), radius: 3, y: 1)
        }
    }

    private var floatingControls: some View {
        VStack(spacing: 2) {
            progressControls
                .padding(.horizontal, 3)

            if case .buffering = state.playerSnapshot.status {
                ProgressView(
                    value: state.playerSnapshot.bufferedPercent,
                    total: 100
                )
                .tint(playerAccentColor)
                .controlSize(.mini)
                .frame(height: 2)
            }

            ZStack {
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        volumeControls
                        Text(
                            "\(formatTime(displayedPosition)) / "
                                + formatTime(state.playerSnapshot.duration)
                        )
                        .font(
                            .system(size: 12, weight: .semibold)
                            .monospacedDigit()
                        )
                        .foregroundColor(.white.opacity(0.94))
                        .shadow(color: .black.opacity(0.48), radius: 2, y: 1)
                        .lineLimit(1)
                    }
                    .frame(minWidth: 230, alignment: .leading)

                    Spacer(minLength: 8)
                    utilityControls
                }

                transportControls
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .padding(.top, 1)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { inside in
            controlsHovering = inside
            inside ? keepControlsVisible() : scheduleControlsHide()
        }
    }

    private var progressControls: some View {
        Slider(
            value: Binding(
                get: { displayedPosition },
                set: { scrubPosition = $0 }
            ),
            in: 0...max(state.playerSnapshot.duration, 1),
            onEditingChanged: { editing in
                if editing {
                    keepControlsVisible()
                } else {
                    commitScrubPosition()
                    scheduleControlsHide()
                }
            }
        )
        .tint(playerAccentColor)
        .controlSize(.mini)
        .frame(height: 12)
        .scaleEffect(x: 1, y: isProgressHovering ? 1.55 : 1)
        .shadow(
            color: playerAccentColor.opacity(isProgressHovering ? 0.42 : 0),
            radius: isProgressHovering ? 5 : 0
        )
        .animation(
            .easeOut(duration: 0.16),
            value: isProgressHovering
        )
        .contentShape(Rectangle().inset(by: -5))
        .background {
            ProgressHoverTrackingView { fraction in
                progressHoverFraction = fraction
                isProgressHovering = fraction != nil
                if fraction != nil {
                    keepControlsVisible()
                } else {
                    scheduleControlsHide()
                }
            }
        }
        .overlay {
            GeometryReader { geometry in
                if let fraction = progressHoverFraction,
                   let time = PlayerProgressHoverPolicy.time(
                       fraction: fraction,
                       duration: state.playerSnapshot.duration
                   ) {
                    Text(formatTime(time))
                        .font(
                            .system(size: 11, weight: .semibold)
                                .monospacedDigit()
                        )
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(Color.black.opacity(0.68))
                        .background(.ultraThinMaterial)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.32), radius: 6, y: 2)
                        .position(
                            x: PlayerProgressHoverPolicy.tooltipCenterX(
                                fraction: fraction,
                                width: geometry.size.width,
                                tooltipWidth: 58
                            ),
                            y: -13
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: progressHoverFraction != nil)
    }

    private func commitScrubPosition() {
        guard let position = scrubPosition else { return }
        Task { @MainActor in
            await state.seek(to: position)
            // Keep the thumb at the requested position until AppState has
            // published its optimistic seek snapshot. Clearing it before the
            // asynchronous seek caused the slider to fall back to a stale
            // player position even though mpv had already moved the video.
            if scrubPosition == position {
                scrubPosition = nil
            }
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 7) {
            playerIconButton(
                systemImage: state.playerSnapshot.isMuted
                    ? "speaker.slash.fill"
                    : "speaker.wave.2.fill",
                help: state.playerSnapshot.isMuted ? "取消静音" : "静音"
            ) {
                Task { await state.togglePlayerMute() }
            }

            Slider(
                value: Binding(
                    get: { displayedVolume ?? state.playerSnapshot.volume },
                    set: enqueuePlayerVolume
                ),
                in: 0...100,
                onEditingChanged: { editing in
                    isVolumeEditing = editing
                    if editing {
                        keepControlsVisible()
                    } else {
                        enqueuePlayerVolume(
                            displayedVolume ?? state.playerSnapshot.volume
                        )
                        scheduleControlsHide()
                    }
                }
            )
            .tint(.white)
            .controlSize(.mini)
            .frame(width: 76)
        }
    }

    private func enqueuePlayerVolume(_ volume: Double) {
        let clampedVolume = min(max(volume, 0), 100)
        displayedVolume = clampedVolume
        pendingVolume = clampedVolume
        guard volumeCommandTask == nil else { return }
        volumeCommandTask = Task { @MainActor in
            await drainPendingVolumeChanges()
        }
    }

    @MainActor
    private func drainPendingVolumeChanges() async {
        while !Task.isCancelled, let volume = pendingVolume {
            pendingVolume = nil
            await state.setPlayerVolume(volume)
            do {
                // About 16 updates per second remains visually continuous and
                // prevents a drag from flooding libmpv's serial command queue.
                try await Task.sleep(nanoseconds: 60_000_000)
            } catch {
                break
            }
        }
        volumeCommandTask = nil
        if !Task.isCancelled, pendingVolume != nil {
            volumeCommandTask = Task { @MainActor in
                await drainPendingVolumeChanges()
            }
        } else if !isVolumeEditing {
            displayedVolume = nil
        }
    }

    private var transportControls: some View {
        HStack(spacing: 6) {
            playerIconButton(
                systemImage: "backward.end.fill",
                help: "上一集",
                disabled: !state.hasPreviousEpisode
            ) {
                Task { await state.playAdjacentEpisode(offset: -1) }
            }

            playerIconButton(
                systemImage: "gobackward.10",
                help: "快退 10 秒"
            ) {
                Task { await state.seek(by: -10) }
            }

            Button {
                Task { await state.togglePlayPause() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.96))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    .modifier(PlayerControlHoverEffect())
            }
            .buttonStyle(.plain)
            .foregroundColor(Color.black.opacity(0.86))
            .keyboardShortcut(.space, modifiers: [])
            .help(isPaused ? "播放" : "暂停")

            playerIconButton(
                systemImage: "goforward.10",
                help: "快进 10 秒"
            ) {
                Task { await state.seek(by: 10) }
            }

            playerIconButton(
                systemImage: "forward.end.fill",
                help: "下一集",
                disabled: !state.hasNextEpisode
            ) {
                Task { await state.playAdjacentEpisode(offset: 1) }
            }
        }
    }

    private var utilityControls: some View {
        HStack(spacing: 3) {
            utilityPanelButton(
                systemImage: "list.bullet",
                panel: .episodes,
                help: "选择剧集"
            )
            utilityPanelButton(
                systemImage: "waveform",
                panel: .audio,
                help: "音轨"
            )
            utilityPanelButton(
                systemImage: "captions.bubble",
                panel: .subtitles,
                help: state.playerSubtitlesEnabled ? "字幕已开启" : "字幕已关闭"
            )
            utilityPanelButton(
                systemImage: "gearshape",
                panel: .settings,
                help: "播放设置"
            )

            playerIconButton(
                systemImage: isWindowFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: isWindowFullScreen ? "退出全屏" : "进入全屏"
            ) {
                toggleFullScreen()
            }
        }
    }

    private func utilityPanelButton(
        systemImage: String,
        panel: PlayerUtilityPanel,
        help: String
    ) -> some View {
        let isActive = activeUtilityPanel == panel
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                activeUtilityPanel = isActive ? nil : panel
            }
            keepControlsVisible()
        } label: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: utilityIconSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isActive ? 1 : 0.96))
                .frame(width: utilityButtonSize, height: utilityButtonSize)
                .contentShape(Rectangle())
                .modifier(PlayerControlHoverEffect())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func utilityPanel(_ panel: PlayerUtilityPanel) -> some View {
        switch panel {
        case .episodes:
            episodePanel
        case .audio:
            audioTrackPanel
        case .subtitles:
            subtitlePanel
        case .settings:
            playbackSettingsPanel
        }
    }

    private var episodePanel: some View {
        let presentations = state.playerEpisodePresentations
        return playerPanel(width: 500) {
            VStack(alignment: .leading, spacing: 12) {
                panelHeader(
                    title: "选集",
                    detail: "共 \(presentations.count) 集"
                )

                if presentations.isEmpty {
                    panelEmptyState("暂无分集")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(
                                columns: [
                                    GridItem(
                                        .adaptive(minimum: 82, maximum: 118),
                                        spacing: 8
                                    )
                                ],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(presentations) { presentation in
                                let selected = presentation.id
                                    == state.currentPlayerEpisodeID
                                Button {
                                    activeUtilityPanel = nil
                                    Task {
                                        await state.playPlayerEpisode(
                                            presentation.episode
                                        )
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(
                                            episodePanelDisplayName(
                                                presentation
                                            )
                                        )
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        if selected {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.bold())
                                        }
                                    }
                                    .foregroundColor(.white.opacity(selected ? 1 : 0.88))
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(
                                        selected
                                            ? playerAccentColor.opacity(0.58)
                                            : Color.white.opacity(0.055),
                                        in: RoundedRectangle(
                                            cornerRadius: 8,
                                            style: .continuous
                                        )
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                Color.white.opacity(
                                                    selected ? 0.16 : 0.055
                                                ),
                                                lineWidth: 1
                                            )
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(selected)
                                .help(presentation.originalName)
                                .id(presentation.id)
                                }
                            }
                        }
                        .onAppear {
                            guard let selected = state.currentPlayerEpisodeID else {
                                return
                            }
                            DispatchQueue.main.async {
                                proxy.scrollTo(selected, anchor: .center)
                            }
                        }
                    }
                    .frame(
                        height: min(
                            286,
                            max(
                                54,
                                CGFloat(
                                    ceil(Double(presentations.count) / 5.0)
                                ) * 54
                            )
                        )
                    )
                }
            }
        }
    }

    private var audioTrackPanel: some View {
        let tracks = state.playerSnapshot.tracks.filter { $0.type == .audio }
        return playerPanel(width: 340) {
            VStack(alignment: .leading, spacing: 10) {
                panelHeader(title: "音轨", detail: "\(tracks.count) 条")
                if tracks.isEmpty {
                    panelEmptyState("没有可选音轨")
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(tracks) { track in
                                panelSelectionButton(
                                    title: trackLabel(track),
                                    selected: track.isSelected
                                ) {
                                    Task { await state.selectPlayerTrack(track) }
                                }
                            }
                        }
                    }
                    .frame(
                        height: min(
                            260,
                            max(44, CGFloat(tracks.count) * 39)
                        )
                    )
                }
            }
        }
    }

    private var subtitlePanel: some View {
        let tracks = state.playerSnapshot.tracks.filter {
            $0.type == .subtitle
        }
        return playerPanel(width: 360) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        panelHeader(title: "字幕", detail: "\(tracks.count) 条")
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { state.playerSubtitlesEnabled },
                                set: { enabled in
                                    guard enabled != state.playerSubtitlesEnabled else {
                                        return
                                    }
                                    Task { await state.togglePlayerSubtitles() }
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(tracks.isEmpty)
                    }

                    if tracks.isEmpty {
                        panelEmptyState("没有内嵌字幕")
                    } else {
                        VStack(spacing: 5) {
                            ForEach(tracks) { track in
                                panelSelectionButton(
                                    title: trackLabel(track),
                                    selected: state.selectedPlayerSubtitleTrackID
                                        == track.id
                                ) {
                                    Task { await state.selectPlayerTrack(track) }
                                }
                            }
                        }
                    }

                    panelDivider
                    Text("字幕设置")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.58))
                    panelStepperRow(
                        title: "大小",
                        value: "\(Int(state.playerSubtitleScale * 100))%",
                        decrease: {
                            Task { await state.adjustPlayerSubtitleScale(by: -0.1) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitleScale(by: 0.1) }
                        }
                    )
                    panelStepperRow(
                        title: "位置",
                        value: "\(Int(state.playerSubtitlePosition))",
                        decrease: {
                            Task { await state.adjustPlayerSubtitlePosition(by: -5) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitlePosition(by: 5) }
                        }
                    )
                    panelStepperRow(
                        title: "描边",
                        value: String(format: "%.1f", state.playerSubtitleBorderSize),
                        decrease: {
                            Task { await state.adjustPlayerSubtitleBorderSize(by: -0.5) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitleBorderSize(by: 0.5) }
                        }
                    )
                    panelStepperRow(
                        title: "延迟",
                        value: String(format: "%.1f 秒", state.playerSubtitleDelay),
                        decrease: {
                            Task { await state.adjustPlayerSubtitleDelay(by: -0.5) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitleDelay(by: 0.5) }
                        }
                    )

                    panelDivider
                    HStack(spacing: 8) {
                        panelActionButton("恢复默认") {
                            Task { await state.resetPlayerSubtitleSettings() }
                        }
                        panelActionButton("加载外部字幕…") {
                            chooseSubtitle()
                        }
                    }
                }
            }
            .frame(height: 420)
        }
    }

    private var playbackSettingsPanel: some View {
        playerPanel(width: 370) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: "播放设置", detail: nil)

                    HStack {
                        Text("自动播放下一集")
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { state.autoPlayNextEpisode },
                                set: { enabled in
                                    Task {
                                        await state.setAutoPlayNextEpisode(enabled)
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    if state.playbackQualities.count > 1 {
                        panelDivider
                        panelOptionGrid(
                            title: "清晰度",
                            values: state.playbackQualities.map { $0.name },
                            selected: state.selectedPlaybackQualityName
                        ) { selectedName in
                            guard let quality = state.playbackQualities.first(
                                where: { $0.name == selectedName }
                            ) else { return }
                            Task { await state.switchPlaybackQuality(quality) }
                        }
                    }

                    panelDivider
                    panelOptionGrid(
                        title: "播放速度",
                        values: speeds.map(formatPlaybackSpeed),
                        selected: formatPlaybackSpeed(state.playerSnapshot.speed)
                    ) { selectedSpeed in
                        guard let index = speeds.map(formatPlaybackSpeed)
                            .firstIndex(of: selectedSpeed) else { return }
                        Task { await state.setPlayerSpeed(speeds[index]) }
                    }

                    panelOptionGrid(
                        title: "画面比例",
                        values: ["自动", "16:9", "4:3", "2.35:1"],
                        selected: state.playerAspectRatio ?? "自动"
                    ) { ratio in
                        Task {
                            await state.setPlayerAspectRatio(
                                ratio == "自动" ? nil : ratio
                            )
                        }
                    }

                    HStack {
                        Text("硬件解码")
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { state.playerHardwareDecoding },
                                set: { _ in
                                    Task { await state.togglePlayerHardwareDecoding() }
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    panelStepperRow(
                        title: "音频延迟",
                        value: String(format: "%.1f 秒", state.playerAudioDelay),
                        decrease: {
                            Task { await state.adjustPlayerAudioDelay(by: -0.1) }
                        },
                        increase: {
                            Task { await state.adjustPlayerAudioDelay(by: 0.1) }
                        }
                    )

                    panelDivider
                    panelActionButton("保存截图…") {
                        chooseScreenshotLocation()
                    }
                }
            }
            .frame(height: 430)
        }
    }

    private func playerPanel<Content: View>(
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(14)
            .frame(width: width)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.38))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .environment(\.colorScheme, .dark)
            .onHover { inside in
                controlsHovering = inside
                inside ? keepControlsVisible() : scheduleControlsHide()
            }
    }

    private func panelHeader(title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if let detail {
                Text("· \(detail)")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.58))
            }
        }
        .foregroundColor(.white.opacity(0.92))
    }

    private func panelEmptyState(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.54))
            .frame(maxWidth: .infinity, minHeight: 56)
    }

    private func panelSelectionButton(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark" : "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(
                        selected ? playerAccentColor : .white.opacity(0.22)
                    )
                    .frame(width: 14)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(selected ? 0.96 : 0.78))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                selected ? Color.white.opacity(0.075) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private func panelStepperRow(
        title: String,
        value: String,
        decrease: @escaping () -> Void,
        increase: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundColor(.white.opacity(0.76))
            Spacer()
            Text(value)
                .foregroundColor(.white.opacity(0.56))
                .monospacedDigit()
            panelIconAction("minus", action: decrease)
            panelIconAction("plus", action: increase)
        }
        .font(.system(size: 13))
    }

    private func panelIconAction(
        _ systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.bold())
                .frame(width: 28, height: 26)
                .background(
                    Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.82))
    }

    private func panelActionButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
    }

    private func panelOptionGrid(
        title: String,
        values: [String],
        selected: String?,
        action: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.58))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 66), spacing: 6)],
                spacing: 6
            ) {
                ForEach(values, id: \.self) { value in
                    let isSelected = selected == value
                    Button(value) { action(value) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isSelected ? 1 : 0.76))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            isSelected
                                ? playerAccentColor.opacity(0.46)
                                : Color.white.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
            }
        }
    }

    private var episodeMenu: some View {
        Menu {
            if state.playerEpisodes.isEmpty {
                Text("暂无分集")
            } else {
                ForEach(state.playerEpisodes) { episode in
                    Button {
                        Task { await state.playPlayerEpisode(episode) }
                    } label: {
                        if episode.id == state.currentPlayerEpisodeID {
                            Label(episode.name, systemImage: "checkmark")
                        } else {
                            Text(episode.name)
                        }
                    }
                    .disabled(episode.id == state.currentPlayerEpisodeID)
                }
            }
        } label: {
            utilityMenuIcon("list.bullet")
        }
        .playerUtilityMenuStyle()
        .fixedSize()
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .help("选择剧集")
    }

    private func playerIconButton(
        systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: utilityIconSize, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: utilityButtonSize, height: utilityButtonSize)
                .contentShape(Circle())
                .modifier(PlayerControlHoverEffect(enabled: !disabled))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.30 : 1)
        .disabled(disabled)
        .help(help)
    }

    private func utilityMenuIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: utilityIconSize, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: utilityButtonSize, height: utilityButtonSize)
            .contentShape(Rectangle())
            .modifier(PlayerControlHoverEffect())
    }

    private var isFailed: Bool {
        if case .failed = state.playerSnapshot.status {
            return true
        }
        return state.playbackResolutionState == .failed
            || state.playbackResolutionState == .exhausted
    }

    private var shouldShowStatusOverlay: Bool {
        if isFailed {
            return true
        }
        if state.isLivePlayback,
           !isLiveSwitchLoadingDelayElapsed,
           LiveSwitchLoadingIndicatorPolicy.isTransient(
               status: state.playerSnapshot.status
           ) {
            return false
        }
        switch state.playbackResolutionState {
        case .restoringHistory, .resolving, .validating, .loading, .retrying:
            return true
        case .idle, .playing, .exhausted, .failed:
            break
        }
        switch state.playerSnapshot.status {
        case .loading, .buffering:
            return true
        default:
            return false
        }
    }

    private func handleLiveChannelChange(_ channelID: String?) {
        defer { lastLiveChannelID = channelID }
        guard state.isLivePlayback,
              let previousChannelID = lastLiveChannelID,
              let channelID,
              previousChannelID != channelID else {
            return
        }

        liveSwitchLoadingDelayTask?.cancel()
        isLiveSwitchLoadingDelayElapsed = false
        liveSwitchLoadingDelayTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: LiveSwitchLoadingIndicatorPolicy
                        .delayNanoseconds
                )
                try Task.checkCancellation()
                guard state.isLivePlayback,
                      state.livePlaybackChannel?.id == channelID else {
                    return
                }
                isLiveSwitchLoadingDelayElapsed = true
                liveSwitchLoadingDelayTask = nil
            } catch {
                return
            }
        }
    }

    private var displayedPosition: Double {
        min(
            max(scrubPosition ?? state.playerSnapshot.position, 0),
            max(state.playerSnapshot.duration, 1)
        )
    }

    private var isPaused: Bool {
        if case .paused = state.playerSnapshot.status {
            return true
        }
        return false
    }

    private var shouldAutoHideControls: Bool {
        PlayerControlVisibilityPolicy.shouldAutoHide(
            isLivePlayback: state.isLivePlayback,
            controlsHovering: controlsHovering,
            isFailed: isFailed,
            isPlaying: {
                if case .playing = state.playerSnapshot.status { return true }
                return false
            }()
        )
    }

    private func revealControls() {
        hideControlsTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.18)) {
                controlsVisible = true
            }
        }
        scheduleControlsHide()
    }

    private func keepControlsVisible() {
        hideControlsTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.18)) {
                controlsVisible = true
            }
        }
        if state.isLivePlayback {
            scheduleControlsHide()
        }
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard shouldAutoHideControls else { return }
        hideControlsTask = Task {
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
                try Task.checkCancellation()
                await MainActor.run {
                    guard shouldAutoHideControls else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        controlsVisible = false
                        activeUtilityPanel = nil
                    }
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            } catch {
                return
            }
        }
    }

    private func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    private func trackMenu(
        systemImage: String,
        title: String,
        type: MediaTrackType,
        emptyMessage: String
    ) -> some View {
        let tracks = state.playerSnapshot.tracks.filter { $0.type == type }
        return Menu {
            if tracks.isEmpty {
                Text(emptyMessage)
            } else {
                ForEach(tracks) { track in
                    Button {
                        Task { await state.selectPlayerTrack(track) }
                    } label: {
                        if track.isSelected {
                            Label(trackLabel(track), systemImage: "checkmark")
                        } else {
                            Text(trackLabel(track))
                        }
                    }
                }
            }
            if type == .subtitle {
                Divider()
                Button("加载外部字幕…") {
                    chooseSubtitle()
                }
            }
        } label: {
            utilityMenuIcon(systemImage)
        }
        .playerUtilityMenuStyle()
        .fixedSize()
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .help(title)
    }

    private var subtitleMenu: some View {
        let tracks = state.playerSnapshot.tracks.filter {
            $0.type == .subtitle
        }
        return Menu {
            Toggle(
                "显示字幕",
                isOn: Binding(
                    get: { state.playerSubtitlesEnabled },
                    set: { enabled in
                        guard enabled != state.playerSubtitlesEnabled else { return }
                        Task { await state.togglePlayerSubtitles() }
                    }
                )
            )
            .disabled(tracks.isEmpty)

            Divider()
            if tracks.isEmpty {
                Text("没有内嵌字幕")
            } else {
                ForEach(tracks) { track in
                    Toggle(
                        trackLabel(track),
                        isOn: Binding(
                            get: {
                                state.selectedPlayerSubtitleTrackID == track.id
                            },
                            set: { selected in
                                if selected {
                                    Task { await state.selectPlayerTrack(track) }
                                } else if state.playerSubtitlesEnabled,
                                          track.isSelected {
                                    Task { await state.togglePlayerSubtitles() }
                                }
                            }
                        )
                    )
                    .help(
                        state.selectedPlayerSubtitleTrackID == track.id
                            ? "当前选择的字幕"
                            : "选择此字幕"
                    )
                }
            }

            Divider()
            Menu("字幕设置") {
                Menu("大小 · \(Int(state.playerSubtitleScale * 100))%") {
                    Button("缩小 10%") {
                        Task { await state.adjustPlayerSubtitleScale(by: -0.1) }
                    }
                    Button("放大 10%") {
                        Task { await state.adjustPlayerSubtitleScale(by: 0.1) }
                    }
                }
                Menu("位置 · \(Int(state.playerSubtitlePosition))") {
                    Button("上移") {
                        Task { await state.adjustPlayerSubtitlePosition(by: -5) }
                    }
                    Button("下移") {
                        Task { await state.adjustPlayerSubtitlePosition(by: 5) }
                    }
                }
                Menu("描边 · \(state.playerSubtitleBorderSize, specifier: "%.1f")") {
                    Button("减小描边") {
                        Task { await state.adjustPlayerSubtitleBorderSize(by: -0.5) }
                    }
                    Button("增大描边") {
                        Task { await state.adjustPlayerSubtitleBorderSize(by: 0.5) }
                    }
                }
                Menu("延迟 · \(state.playerSubtitleDelay, specifier: "%.1f") 秒") {
                    Button("字幕提前 0.5 秒") {
                        Task { await state.adjustPlayerSubtitleDelay(by: -0.5) }
                    }
                    Button("字幕延后 0.5 秒") {
                        Task { await state.adjustPlayerSubtitleDelay(by: 0.5) }
                    }
                }
                Divider()
                Button("恢复默认字幕设置") {
                    Task { await state.resetPlayerSubtitleSettings() }
                }
            }
            Button("加载外部字幕…") {
                chooseSubtitle()
            }
        } label: {
            utilityMenuIcon("captions.bubble")
        }
        .playerUtilityMenuStyle()
        .fixedSize()
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .help(state.playerSubtitlesEnabled ? "字幕已开启" : "字幕已关闭")
    }

    private var playbackOptionsMenu: some View {
        Menu {
            Toggle(
                "自动播放下一集",
                isOn: Binding(
                    get: { state.autoPlayNextEpisode },
                    set: { enabled in
                        Task { await state.setAutoPlayNextEpisode(enabled) }
                    }
                )
            )

            Divider()

            if state.playbackQualities.count > 1 {
                Menu(
                    "清晰度 · "
                        + (state.isSwitchingPlaybackQuality
                            ? "切换中"
                            : state.selectedPlaybackQualityName ?? "自动")
                ) {
                    ForEach(state.playbackQualities) { quality in
                        Button {
                            Task { await state.switchPlaybackQuality(quality) }
                        } label: {
                            if quality.id == state.selectedPlaybackQualityID {
                                Label(quality.name, systemImage: "checkmark")
                            } else {
                                Text(quality.name)
                            }
                        }
                        .disabled(quality.id == state.selectedPlaybackQualityID)
                    }
                }
                .disabled(state.isSwitchingPlaybackQuality)

                Divider()
            }

            Menu("播放速度 · \(formatPlaybackSpeed(state.playerSnapshot.speed))") {
                ForEach(speeds, id: \.self) { speed in
                    Button(formatPlaybackSpeed(speed)) {
                        Task { await state.setPlayerSpeed(speed) }
                    }
                }
            }

            Divider()

            Menu("画面比例") {
                Button("自动") {
                    Task { await state.setPlayerAspectRatio(nil) }
                }
                ForEach(["16:9", "4:3", "2.35:1"], id: \.self) { ratio in
                    Button(ratio) {
                        Task { await state.setPlayerAspectRatio(ratio) }
                    }
                }
            }
            Button(
                state.playerHardwareDecoding ? "关闭硬件解码" : "开启硬件解码"
            ) {
                Task { await state.togglePlayerHardwareDecoding() }
            }
            Divider()
            Group {
                Button("音频提前 0.1 秒") {
                    Task { await state.adjustPlayerAudioDelay(by: -0.1) }
                }
                Button("音频延后 0.1 秒") {
                    Task { await state.adjustPlayerAudioDelay(by: 0.1) }
                }
                Text("音频延迟 \(state.playerAudioDelay, specifier: "%.1f") 秒")
            }

            Divider()

            Button("保存截图…") {
                chooseScreenshotLocation()
            }
        } label: {
            utilityMenuIcon("gearshape")
        }
        .playerUtilityMenuStyle()
        .fixedSize()
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .help("播放设置")
    }

    private var playerAccentColor: Color {
        Color(red: 0.24, green: 0.64, blue: 0.94)
    }

    private func formatPlaybackSpeed(_ speed: Double) -> String {
        String(format: "%.2g×", speed)
    }

    private func trackLabel(_ track: MediaTrack) -> String {
        if let language = track.language {
            return "\(track.title) (\(language))"
        }
        return track.title
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.title = "选择字幕"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await state.addPlayerSubtitle(url) }
        }
    }

    private func chooseScreenshotLocation() {
        let panel = NSSavePanel()
        panel.title = "保存播放截图"
        panel.nameFieldStringValue = "OKVideoMac-Screenshot.png"
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "webp"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await state.savePlayerScreenshot(to: url) }
        }
    }
}

private enum PlayerUtilityPanel: Equatable {
    case episodes
    case audio
    case subtitles
    case settings
}

private extension View {
    @ViewBuilder
    func playerUtilityMenuStyle() -> some View {
        if #available(macOS 13.0, *) {
            self
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
        } else {
            self.menuStyle(
                BorderlessButtonMenuStyle(showsMenuIndicator: false)
            )
        }
    }
}

enum PlayerControlVisibilityPolicy {
    static func shouldAutoHide(
        isLivePlayback: Bool,
        controlsHovering: Bool,
        isFailed: Bool,
        isPlaying: Bool
    ) -> Bool {
        guard !isFailed else { return false }
        // A live picture should return to a clean, cursor-free surface even
        // when the pointer is parked over a card or control. Only real mouse
        // movement should reveal the overlay again.
        if isLivePlayback { return true }
        return !controlsHovering && isPlaying
    }
}

enum LiveSwitchLoadingIndicatorPolicy {
    static let delayNanoseconds: UInt64 = 280_000_000

    static func isTransient(status: PlayerStatus) -> Bool {
        switch status {
        case .loading, .buffering:
            return true
        default:
            return false
        }
    }
}

enum PlayerUnavailablePlaceholderPolicy {
    static func shouldShow(
        hasEmbeddedPlayer: Bool,
        showsStatusOverlay: Bool
    ) -> Bool {
        !hasEmbeddedPlayer && !showsStatusOverlay
    }
}

enum PlayerSurfaceGesture {
    static func togglesFullScreen(
        clickCount: Int,
        buttonNumber: Int
    ) -> Bool {
        clickCount == 2 && buttonNumber == 0
    }
}

enum PlayerInteractionRatePolicy {
    static let minimumMouseMoveInterval: TimeInterval = 0.08

    static func shouldForwardMouseMove(
        lastForwardedAt: TimeInterval,
        now: TimeInterval,
        minimumInterval: TimeInterval = minimumMouseMoveInterval
    ) -> Bool {
        lastForwardedAt == 0 || now - lastForwardedAt >= minimumInterval
    }
}

enum PlayerSurfaceTrackingPolicy {
    // Do not subscribe to mouseEntered. When the live overlay hides under a
    // stationary pointer, AppKit considers the underlying surface entered;
    // treating that synthetic transition as movement made the overlay reopen
    // forever. Only physical pointer movement should reveal it.
    static let options: NSTrackingArea.Options = [
        .activeInKeyWindow,
        .inVisibleRect,
        .mouseMoved
    ]
}

private struct PlayerSurfaceInteractionView: NSViewRepresentable {
    let onMove: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PlayerSurfaceInteractionNSView {
        let view = PlayerSurfaceInteractionNSView()
        view.onMove = onMove
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(
        _ nsView: PlayerSurfaceInteractionNSView,
        context: Context
    ) {
        nsView.onMove = onMove
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class PlayerSurfaceInteractionNSView: NSView {
    var onMove: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var lastForwardedMoveAt: TimeInterval = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: PlayerSurfaceTrackingPolicy.options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMove(force: false)
    }

    override func mouseDown(with event: NSEvent) {
        forwardMove(force: true)
        if PlayerSurfaceGesture.togglesFullScreen(
            clickCount: event.clickCount,
            buttonNumber: event.buttonNumber
        ) {
            onDoubleClick?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func forwardMove(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || PlayerInteractionRatePolicy.shouldForwardMouseMove(
            lastForwardedAt: lastForwardedMoveAt,
            now: now
        ) else { return }
        lastForwardedMoveAt = now
        onMove?()
    }
}

struct PlayerWindowConfigurator: NSViewRepresentable {
    let isLivePlayback: Bool
    let controlsVisible: Bool
    let title: String
    let videoAspectRatio: Double?
    let onRestore: () -> Void
    let onFullScreenChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onRestore: onRestore,
            onFullScreenChange: onFullScreenChange
        )
    }

    func makeNSView(context: Context) -> WindowConfigurationView {
        let view = WindowConfigurationView()
        view.onWindowChange = { window in
            context.coordinator.attach(to: window)
            context.coordinator.configure(
                isLivePlayback: isLivePlayback,
                controlsVisible: controlsVisible,
                title: title,
                videoAspectRatio: videoAspectRatio
            )
        }
        return view
    }

    func updateNSView(
        _ nsView: WindowConfigurationView,
        context: Context
    ) {
        context.coordinator.onRestore = onRestore
        context.coordinator.onFullScreenChange = onFullScreenChange
        context.coordinator.attach(to: nsView.window)
        context.coordinator.configure(
            isLivePlayback: isLivePlayback,
            controlsVisible: controlsVisible,
            title: title,
            videoAspectRatio: videoAspectRatio
        )
    }

    static func dismantleNSView(
        _ nsView: WindowConfigurationView,
        coordinator: Coordinator
    ) {
        coordinator.restore()
    }

    @MainActor
    final class Coordinator {
        private struct AppliedConfiguration: Equatable {
            let isLivePlayback: Bool
            let controlsVisible: Bool
            let title: String
            let videoAspectRatio: Double?
        }

        private weak var window: NSWindow?
        private var hadFullSizeContentView = false
        private var titlebarAppearsTransparent = false
        private var titleVisibility: NSWindow.TitleVisibility = .visible
        private var toolbarWasVisible: Bool?
        private var backgroundColor: NSColor?
        private var isMovableByWindowBackground = false
        private var acceptsMouseMovedEvents = false
        private var titlebarSeparatorStyle: NSTitlebarSeparatorStyle = .automatic
        private var windowTitle = ""
        private var windowFrame = NSRect.zero
        private var contentAspectRatio = NSSize(width: 0, height: 0)
        private var closeButtonWasHidden = false
        private var miniaturizeButtonWasHidden = false
        private var zoomButtonWasHidden = false
        private var desiredConfiguration: AppliedConfiguration?
        private var appliedConfiguration: AppliedConfiguration?
        private var pendingWindowRefresh: DispatchWorkItem?
        private var fullScreenObservers: [NSObjectProtocol] = []
        private var liveResizeObserver: NSObjectProtocol?
        var onRestore: () -> Void
        var onFullScreenChange: (Bool) -> Void

        init(
            onRestore: @escaping () -> Void,
            onFullScreenChange: @escaping (Bool) -> Void = { _ in }
        ) {
            self.onRestore = onRestore
            self.onFullScreenChange = onFullScreenChange
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else {
                restore()
                return
            }
            guard window !== newWindow else { return }
            restore()
            window = newWindow
            observeFullScreenChanges(for: newWindow)
            observeLiveResizeEnd(for: newWindow)
            DispatchQueue.main.async { [weak self, weak newWindow] in
                guard let self,
                      let newWindow,
                      self.window === newWindow else { return }
                self.onFullScreenChange(
                    newWindow.styleMask.contains(.fullScreen)
                )
            }
            desiredConfiguration = nil
            appliedConfiguration = nil
            hadFullSizeContentView = newWindow.styleMask.contains(
                .fullSizeContentView
            )
            titlebarAppearsTransparent = newWindow.titlebarAppearsTransparent
            titleVisibility = newWindow.titleVisibility
            toolbarWasVisible = newWindow.toolbar?.isVisible
            backgroundColor = newWindow.backgroundColor
            isMovableByWindowBackground = newWindow.isMovableByWindowBackground
            acceptsMouseMovedEvents = newWindow.acceptsMouseMovedEvents
            titlebarSeparatorStyle = newWindow.titlebarSeparatorStyle
            windowTitle = newWindow.title
            windowFrame = newWindow.frame
            contentAspectRatio = newWindow.contentAspectRatio
            closeButtonWasHidden = newWindow.standardWindowButton(
                .closeButton
            )?.isHidden ?? false
            miniaturizeButtonWasHidden = newWindow.standardWindowButton(
                .miniaturizeButton
            )?.isHidden ?? false
            zoomButtonWasHidden = newWindow.standardWindowButton(
                .zoomButton
            )?.isHidden ?? false

            configure(
                isLivePlayback: false,
                controlsVisible: true,
                title: newWindow.title,
                videoAspectRatio: nil
            )
        }

        func configure(
            isLivePlayback: Bool,
            controlsVisible: Bool,
            title: String,
            videoAspectRatio: Double? = nil
        ) {
            guard let window else { return }
            let configuration = AppliedConfiguration(
                isLivePlayback: isLivePlayback,
                controlsVisible: controlsVisible,
                title: title,
                videoAspectRatio: videoAspectRatio
            )
            guard configuration != desiredConfiguration else { return }
            desiredConfiguration = configuration
            scheduleWindowConfiguration(configuration, for: window)
        }

        private func apply(
            _ configuration: AppliedConfiguration,
            to window: NSWindow
        ) {
            guard self.window === window,
                  desiredConfiguration == configuration else {
                return
            }
            // AppKit owns the window frame throughout a live resize. Mutating
            // titlebar style, contentAspectRatio or display state from a
            // SwiftUI update while that transaction is active can re-enter
            // NSWindow's private resize path and terminate with SIGTRAP.
            // Keep the desired configuration and apply it once AppKit posts
            // didEndLiveResize instead.
            guard PlayerWindowMutationPolicy.canApply(
                isInLiveResize: window.inLiveResize
            ) else { return }

            window.toolbar?.isVisible = false
            window.backgroundColor = .black
            window.acceptsMouseMovedEvents = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }

            if window.title != configuration.title {
                window.title = configuration.title
            }

            if appliedConfiguration?.isLivePlayback
                    != configuration.isLivePlayback
                || appliedConfiguration?.controlsVisible
                    != configuration.controlsVisible {
                if configuration.isLivePlayback,
                   configuration.controlsVisible {
                    window.styleMask.remove(.fullSizeContentView)
                    window.titlebarAppearsTransparent = false
                    window.titleVisibility = .visible
                    window.isMovableByWindowBackground = false
                    setStandardWindowButtonsHidden(false, on: window)
                } else {
                    window.styleMask.insert(.fullSizeContentView)
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.isMovableByWindowBackground = true
                    if !configuration.controlsVisible {
                        setStandardWindowButtonsHidden(true, on: window)
                    } else {
                        restoreStandardWindowButtonVisibility(on: window)
                    }
                }
            }
            if let ratio = configuration.videoAspectRatio,
               ratio.isFinite,
               ratio > 0 {
                let targetAspectRatio = NSSize(width: ratio, height: 1)
                if !Self.aspectRatiosMatch(
                    window.contentAspectRatio,
                    targetAspectRatio
                ) {
                    window.contentAspectRatio = targetAspectRatio
                }
                Self.resizeWindowToMatchVideo(
                    aspectRatio: ratio,
                    window: window
                )
            }
            appliedConfiguration = configuration
            Self.markWindowForRefresh(window)
        }

        func restore() {
            guard let window else { return }
            pendingWindowRefresh?.cancel()
            pendingWindowRefresh = nil
            removeFullScreenObservers()
            removeLiveResizeObserver()
            let savedHadFullSizeContentView = hadFullSizeContentView
            let savedTitlebarAppearsTransparent = titlebarAppearsTransparent
            let savedTitleVisibility = titleVisibility
            let savedToolbarWasVisible = toolbarWasVisible
            let savedBackgroundColor = backgroundColor
            let savedIsMovableByWindowBackground = isMovableByWindowBackground
            let savedAcceptsMouseMovedEvents = acceptsMouseMovedEvents
            let savedTitlebarSeparatorStyle = titlebarSeparatorStyle
            let savedWindowTitle = windowTitle
            let savedWindowFrame = windowFrame
            let savedContentAspectRatio = contentAspectRatio
            let savedCloseButtonWasHidden = closeButtonWasHidden
            let savedMiniaturizeButtonWasHidden = miniaturizeButtonWasHidden
            let savedZoomButtonWasHidden = zoomButtonWasHidden
            desiredConfiguration = nil
            appliedConfiguration = nil
            self.window = nil

            // NSViewRepresentable update/dismantle callbacks can run inside a
            // SwiftUI layout transaction. Forcing synchronous layout or display
            // here re-enters that transaction and has produced repeatable
            // swift_beginAccess crashes. Mark the window dirty on the next run
            // loop instead and let AppKit own the display cycle.
            DispatchQueue.main.async { [weak window, onRestore] in
                guard let window else {
                    onRestore()
                    return
                }
                if savedHadFullSizeContentView {
                    window.styleMask.insert(.fullSizeContentView)
                } else {
                    window.styleMask.remove(.fullSizeContentView)
                }
                window.titlebarAppearsTransparent = savedTitlebarAppearsTransparent
                window.titleVisibility = savedTitleVisibility
                if let savedToolbarWasVisible {
                    window.toolbar?.isVisible = savedToolbarWasVisible
                }
                if let savedBackgroundColor {
                    window.backgroundColor = savedBackgroundColor
                }
                window.isMovableByWindowBackground =
                    savedIsMovableByWindowBackground
                window.acceptsMouseMovedEvents = savedAcceptsMouseMovedEvents
                window.titlebarSeparatorStyle = savedTitlebarSeparatorStyle
                window.title = savedWindowTitle
                // Applying a video's aspect ratio changes the actual NSWindow
                // frame as soon as the user resizes it. Clearing that constraint
                // alone leaves the browsing UI in the video's shape, so restore
                // the complete pre-playback frame after removing the constraint.
                window.contentAspectRatio = savedContentAspectRatio
                if !window.styleMask.contains(.fullScreen),
                   !window.inLiveResize,
                   !savedWindowFrame.isEmpty {
                    window.setFrame(savedWindowFrame, display: false)
                }
                window.standardWindowButton(.closeButton)?.isHidden =
                    savedCloseButtonWasHidden
                window.standardWindowButton(.miniaturizeButton)?.isHidden =
                    savedMiniaturizeButtonWasHidden
                window.standardWindowButton(.zoomButton)?.isHidden =
                    savedZoomButtonWasHidden
                Self.markWindowForRefresh(window)
                onRestore()
            }
        }

        private func scheduleWindowConfiguration(
            _ configuration: AppliedConfiguration,
            for window: NSWindow
        ) {
            pendingWindowRefresh?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(configuration, to: window)
            }
            pendingWindowRefresh = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func setStandardWindowButtonsHidden(
            _ hidden: Bool,
            on window: NSWindow
        ) {
            window.standardWindowButton(.closeButton)?.isHidden = hidden
            window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
            window.standardWindowButton(.zoomButton)?.isHidden = hidden
        }

        private func restoreStandardWindowButtonVisibility(on window: NSWindow) {
            window.standardWindowButton(.closeButton)?.isHidden = closeButtonWasHidden
            window.standardWindowButton(.miniaturizeButton)?.isHidden = miniaturizeButtonWasHidden
            window.standardWindowButton(.zoomButton)?.isHidden = zoomButtonWasHidden
        }

        private func observeFullScreenChanges(for window: NSWindow) {
            removeFullScreenObservers()
            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ] {
                fullScreenObservers.append(
                    center.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self, weak window] _ in
                        MainActor.assumeIsolated {
                            guard let self,
                                  let window,
                                  self.window === window else { return }
                            self.onFullScreenChange(
                                window.styleMask.contains(.fullScreen)
                            )
                            if !window.styleMask.contains(.fullScreen),
                               let configuration = self.desiredConfiguration {
                                self.scheduleWindowConfiguration(
                                    configuration,
                                    for: window
                                )
                            }
                        }
                    }
                )
            }
        }

        private func removeFullScreenObservers() {
            let center = NotificationCenter.default
            fullScreenObservers.forEach(center.removeObserver)
            fullScreenObservers.removeAll()
        }

        private func observeLiveResizeEnd(for window: NSWindow) {
            removeLiveResizeObserver()
            liveResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          let window,
                          self.window === window,
                          let configuration = self.desiredConfiguration,
                          configuration != self.appliedConfiguration else {
                        return
                    }
                    self.scheduleWindowConfiguration(configuration, for: window)
                }
            }
        }

        private func removeLiveResizeObserver() {
            guard let liveResizeObserver else { return }
            NotificationCenter.default.removeObserver(liveResizeObserver)
            self.liveResizeObserver = nil
        }

        private static func aspectRatiosMatch(
            _ lhs: NSSize,
            _ rhs: NSSize
        ) -> Bool {
            guard lhs.width > 0,
                  lhs.height > 0,
                  rhs.width > 0,
                  rhs.height > 0 else { return false }
            return abs(
                lhs.width / lhs.height - rhs.width / rhs.height
            ) < 0.0001
        }

        private static func resizeWindowToMatchVideo(
            aspectRatio: Double,
            window: NSWindow
        ) {
            guard !window.styleMask.contains(.fullScreen),
                  !window.inLiveResize else { return }
            let contentRect = window.contentRect(forFrameRect: window.frame)
            guard !aspectRatiosMatch(
                contentRect.size,
                NSSize(width: aspectRatio, height: 1)
            ) else { return }

            let visibleFrame = window.screen?.visibleFrame
            let chromeWidth = max(0, window.frame.width - contentRect.width)
            let chromeHeight = max(0, window.frame.height - contentRect.height)
            let maximumContentSize = NSSize(
                width: max(1, (visibleFrame?.width ?? .greatestFiniteMagnitude) - chromeWidth),
                height: max(1, (visibleFrame?.height ?? .greatestFiniteMagnitude) - chromeHeight)
            )
            guard let targetContentSize = PlayerWindowAspectPolicy.contentSize(
                current: contentRect.size,
                aspectRatio: aspectRatio,
                minimum: window.contentMinSize,
                maximum: maximumContentSize
            ) else { return }

            var targetFrame = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: targetContentSize)
            )
            targetFrame.origin = NSPoint(
                x: window.frame.midX - targetFrame.width / 2,
                y: window.frame.midY - targetFrame.height / 2
            )
            if let visibleFrame {
                targetFrame.origin.x = min(
                    max(targetFrame.origin.x, visibleFrame.minX),
                    visibleFrame.maxX - targetFrame.width
                )
                targetFrame.origin.y = min(
                    max(targetFrame.origin.y, visibleFrame.minY),
                    visibleFrame.maxY - targetFrame.height
                )
            }
            window.setFrame(targetFrame, display: false)
        }

        private static func markWindowForRefresh(_ window: NSWindow?) {
            guard let window,
                  !window.inLiveResize,
                  let contentView = window.contentView else { return }
            contentView.needsLayout = true
            contentView.needsDisplay = true
            contentView.superview?.needsLayout = true
            contentView.superview?.needsDisplay = true
            window.invalidateCursorRects(for: contentView)
            // The style-mask and aspect-ratio mutations above are committed by
            // AppKit after this callback returns. Refresh on the next main-loop
            // turn so SwiftUI lays out against the final content rect, then
            // explicitly update the OpenGL drawable. Without this pass the old
            // framebuffer size can survive until the next manual window resize.
            DispatchQueue.main.async { [weak window] in
                guard let window,
                      !window.inLiveResize,
                      let contentView = window.contentView else { return }
                contentView.needsLayout = true
                contentView.layoutSubtreeIfNeeded()
                synchronizePlayerSurfaces(in: contentView)
                contentView.needsDisplay = true
            }
        }

        private static func synchronizePlayerSurfaces(in view: NSView) {
            if let renderView = view as? MPVOpenGLView {
                renderView.synchronizeDrawableAfterWindowLayout()
            }
            view.subviews.forEach(synchronizePlayerSurfaces(in:))
        }
    }
}

enum PlayerWindowMutationPolicy {
    static func canApply(isInLiveResize: Bool) -> Bool {
        !isInLiveResize
    }
}

enum PlayerWindowAspectPolicy {
    static func contentSize(
        current: NSSize,
        aspectRatio: Double,
        minimum: NSSize = .zero,
        maximum: NSSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    ) -> NSSize? {
        guard current.width.isFinite,
              current.height.isFinite,
              current.width > 0,
              current.height > 0,
              aspectRatio.isFinite,
              aspectRatio > 0 else { return nil }

        let ratio = CGFloat(aspectRatio)
        let boundedMaximumWidth = min(
            maximum.width,
            maximum.height * ratio
        )
        guard boundedMaximumWidth.isFinite,
              boundedMaximumWidth > 0 else { return nil }
        let requiredMinimumWidth = max(
            minimum.width,
            minimum.height * ratio
        )
        let lowerWidth = min(requiredMinimumWidth, boundedMaximumWidth)

        func candidate(width proposedWidth: CGFloat) -> NSSize {
            let width = min(
                max(proposedWidth, lowerWidth),
                boundedMaximumWidth
            )
            return NSSize(width: width, height: width / ratio)
        }

        let preservingWidth = candidate(width: current.width)
        let preservingHeight = candidate(width: current.height * ratio)
        func changeScore(_ size: NSSize) -> CGFloat {
            abs(size.width - current.width) / current.width
                + abs(size.height - current.height) / current.height
        }
        return changeScore(preservingWidth) <= changeScore(preservingHeight)
            ? preservingWidth
            : preservingHeight
    }
}

enum PlayerProgressHoverPolicy {
    static func fraction(x: CGFloat, width: CGFloat) -> Double? {
        guard width.isFinite, width > 0, x.isFinite else { return nil }
        return min(1, max(0, Double(x / width)))
    }

    static func time(fraction: Double, duration: TimeInterval) -> TimeInterval? {
        guard fraction.isFinite,
              duration.isFinite,
              duration > 0 else { return nil }
        return min(1, max(0, fraction)) * duration
    }

    static func tooltipCenterX(
        fraction: Double,
        width: CGFloat,
        tooltipWidth: CGFloat
    ) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        let half = min(max(tooltipWidth / 2, 0), width / 2)
        let raw = CGFloat(min(1, max(0, fraction))) * width
        return min(max(raw, half), width - half)
    }
}

private struct ProgressHoverTrackingView: NSViewRepresentable {
    let onFractionChange: (Double?) -> Void

    func makeNSView(context: Context) -> ProgressHoverTrackingNSView {
        let view = ProgressHoverTrackingNSView()
        view.onFractionChange = onFractionChange
        return view
    }

    func updateNSView(
        _ nsView: ProgressHoverTrackingNSView,
        context: Context
    ) {
        nsView.onFractionChange = onFractionChange
    }
}

private final class ProgressHoverTrackingNSView: NSView {
    var onFractionChange: ((Double?) -> Void)?
    private var trackingAreaReference: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        publishFraction(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        publishFraction(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        onFractionChange?(nil)
    }

    // The tracking view observes pointer motion, while the native Slider below
    // remains responsible for clicks and drag gestures.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func publishFraction(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onFractionChange?(
            PlayerProgressHoverPolicy.fraction(x: point.x, width: bounds.width)
        )
    }
}

private struct PlayerControlHoverEffect: ViewModifier {
    @State private var isHovering = false
    let enabled: Bool

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(enabled && isHovering ? 0.14 : 0),
                in: Circle()
            )
            .scaleEffect(enabled && isHovering ? 1.09 : 1)
            .shadow(
                color: .black.opacity(0.46),
                radius: enabled && isHovering ? 3 : 2,
                y: 1
            )
            .animation(
                .easeOut(duration: 0.13),
                value: isHovering
            )
            .onHover { inside in
                isHovering = enabled && inside
            }
    }
}

final class WindowConfigurationView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            onWindowChange?(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
