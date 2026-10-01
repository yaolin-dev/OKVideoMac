import AppKit
import Foundation
import OKVideoCore
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playerSnapshotState: PlayerSnapshotState
    @State private var scrubPosition: Double?
    @State private var controlsVisible = true
    @StateObject private var controlTooltip = PlayerControlTooltipState()
    @State private var controlsHovering = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isVolumeEditing = false
    @State private var isCompactVolumePresented = false
    @State private var isLiveVolumeControlPresented = false
    @State private var isLiveVolumeHovering = false
    @State private var activeUtilityPanel: PlayerUtilityPanel?
    @State private var inspectedPlayerEpisode: EpisodePresentation?
    @State private var playerEpisodeLocateRevision = 0
    @State private var playerEpisodePageIndex = 0
    @State private var isWindowFullScreen = false
    @State private var fullscreenTopInset: CGFloat = 0
    @State private var isFullScreenTransitioning = false
    @State private var settledViewportSize: CGSize?
    @State private var frozenViewportSize: CGSize?
    @State private var progressHoverRevision = 0
    @State private var progressHoverFraction: Double?
    @State private var liveLoadingVisible = false
    @State private var liveLoadingSlow = false
    @State private var playbackActivityOverlayVisible = false
    @State private var playbackActivityOverlayTask: Task<Void, Never>?
    let onWindowChromeRestored: () -> Void

    init(
        playerSnapshotState: PlayerSnapshotState,
        onWindowChromeRestored: @escaping () -> Void
    ) {
        self.playerSnapshotState = playerSnapshotState
        self.onWindowChromeRestored = onWindowChromeRestored
    }

    private let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private let utilityIconSize: CGFloat = 18
    private let utilityButtonSize: CGFloat = 38

    var body: some View {
        GeometryReader { geometry in
            let layout = PlayerOverlayLayout(
                viewportSize: frozenViewportSize ?? geometry.size,
                timeLabelWidth: playbackTimeWidth
            )
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
                onDoubleClick: handleSurfaceDoubleClick
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

            if state.playerSnapshot.status == .ended && !state.isLivePlayback {
                playbackEndedOverlay
            }

            playbackStatusOverlay
                .allowsHitTesting(isFailed || liveLoadingSlow || state.hasHistoryPlaybackChoices)

            if state.isLivePlayback,
               let notice = state.livePlaybackNotice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                        .padding(.bottom, controlsVisible ? 92 : 28)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(45)
            }

            if !state.isLivePlayback,
               let prompt = state.playbackEndingSkipPrompt {
                endingSkipPromptOverlay(prompt)
                    .zIndex(46)
            }

            if state.isLivePlayback {
                livePlayerOverlay
                    .environment(\.colorScheme, .dark)
            } else {
                VStack(spacing: 0) {
                    floatingHeader
                    Spacer(minLength: 24)
                    floatingControls(layout: layout)
                }
                .padding(.horizontal, 18)
                .padding(.top, max(10, fullscreenTopInset))
                .padding(.bottom, layout.bottomInset)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible && !isFullScreenTransitioning)
                .environment(\.colorScheme, .dark)
            }

            if !state.isLivePlayback,
               controlsVisible,
               let activeUtilityPanel {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    HStack(spacing: 0) {
                        Spacer(minLength: 24)
                        utilityPanel(activeUtilityPanel, maximumSize: layout.panelMaximumSize)
                    }
                }
                .padding(.trailing, layout.panelTrailingInset)
                .padding(.bottom, layout.panelBottomInset)
                .transition(.identity)
                .zIndex(50)
                .environment(\.colorScheme, .dark)
            }

            PlayerWindowConfigurator(
                isLivePlayback: state.isLivePlayback,
                controlsVisible: controlsVisible,
                title: playbackDisplayTitle,
                // Media changes are rendered inside the existing viewport.
                // Do not resize or move the user's window when late metadata,
                // a new episode, or a different route reports another ratio.
                videoAspectRatio: nil,
                onRestore: onWindowChromeRestored,
                onFullScreenChange: { fullScreen in
                    isWindowFullScreen = fullScreen
                    fullscreenTopInset = fullScreen ? (NSApp.keyWindow?.screen?.safeAreaInsets.top ?? 0) : 0
                },
                onTransitionChange: handleFullScreenTransition
            )
                .frame(width: 0, height: 0)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .onAppear { settledViewportSize = geometry.size }
        .onChange(of: geometry.size) { size in
            if !isFullScreenTransitioning { settledViewportSize = size }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .modifier(PlayerProgressPreviewOverlay(
            fraction: progressPreviewFraction,
            text: progressPreviewFraction.flatMap { PlayerProgressHoverPolicy.time(fraction: $0, duration: state.playerSnapshot.duration) }.map(formatTime)
        ))
        .modifier(PlayerControlTooltipOverlay(model: controlTooltip))
        .onChange(of: controlsVisible) { visible in
            if !visible { dismissProgressPreview() }
            updateTooltipAvailability()
        }
        .onChange(of: state.playbackPresentationID) { _ in
            dismissProgressPreview(); scrubPosition = nil; controlTooltip.dismiss()
        }
        .onChange(of: state.isPlayerWindowKey) { if !$0 { dismissProgressPreview(); controlTooltip.dismiss() } }
        .onChange(of: scrubPosition != nil) { _ in updateTooltipAvailability() }
        .onChange(of: isFullScreenTransitioning) { _ in updateTooltipAvailability() }
        .onAppear {
            revealControls()
            updatePlaybackActivityOverlay(
                isActive: hasTransientPlaybackActivity
            )
        }
        .onDisappear {
            dismissProgressPreview()
            controlTooltip.dismiss()
            hideControlsTask?.cancel()
            isLiveVolumeControlPresented = false
            isCompactVolumePresented = false
            isLiveVolumeHovering = false
            activeUtilityPanel = nil
            inspectedPlayerEpisode = nil
            playbackActivityOverlayTask?.cancel()
            playbackActivityOverlayTask = nil
            playbackActivityOverlayVisible = false
        }
        .task(id: liveLoadingTaskID) {
            liveLoadingVisible = false
            liveLoadingSlow = false
            guard isLiveWaiting else { return }
            do {
                try await Task.sleep(nanoseconds: LiveLoadingPresentationPolicy.delayNanoseconds)
                try Task.checkCancellation()
                guard isLiveWaiting else { return }
                liveLoadingVisible = true
                try await Task.sleep(nanoseconds: LiveLoadingPresentationPolicy.slowDelayNanoseconds - LiveLoadingPresentationPolicy.delayNanoseconds)
                try Task.checkCancellation()
                guard isLiveWaiting else { return }
                liveLoadingSlow = true
            } catch { return }
        }
        .onChange(of: state.playerSnapshot.status) { _ in
            revealControls()
        }
        .onChange(of: hasTransientPlaybackActivity) { isActive in
            updatePlaybackActivityOverlay(isActive: isActive)
        }
        .onChange(of: activeUtilityPanel) { panel in
            controlTooltip.dismiss()
            if panel != .episodes {
                inspectedPlayerEpisode = nil
            }
            panel == nil ? scheduleControlsHide() : keepControlsVisible()
        }
        .onChange(of: isCompactVolumePresented) { presented in
            presented ? keepControlsVisible() : scheduleControlsHide()
        }
        .onChange(of: state.currentPlayerEpisodeID) { _ in
            inspectedPlayerEpisode = nil
            if activeUtilityPanel == .episodes {
                alignPlayerEpisodePageWithCurrentEpisode()
            }
        }
        .onChange(of: state.playerEpisodePresentations) { _ in
            if activeUtilityPanel == .episodes {
                alignPlayerEpisodePageWithCurrentEpisode()
            }
        }
        .onChange(of: state.shortcutPlayerEscapeRequest) { _ in
            handleEscapeShortcut()
        }
        .animation(
            reduceMotion || isFullScreenTransitioning ? nil : .easeInOut(duration: 0.18),
            value: controlsVisible
        )
    }

    private var playbackEndedOverlay: some View {
        VStack(spacing: 14) {
            Text(L10n.string("player.ended.title", fallback: "Playback Finished"))
                .font(.headline)
            HStack(spacing: 12) {
                Button(L10n.string("player.ended.replay", fallback: "Replay")) {
                    Task { await state.togglePlayPause() }
                }.buttonStyle(.borderedProminent)
                if state.hasNextEpisode {
                    Button(state.nextPlayerResourceTitle) {
                        Task { await state.playAdjacentEpisode(offset: 1) }
                    }.buttonStyle(.bordered)
                }
            }
            if state.isRestoringPlayerEpisodeList || state.isPlayerEpisodeListPreparing {
                Text(L10n.string("player.ended.preparing", fallback: "Preparing the episode list…"))
            } else if state.isPlayerEpisodeListIncomplete {
                Button(L10n.string("player.ended.reload-list", fallback: "Reload episode list")) { state.retryPlayerEpisodeList() }
            } else if !state.hasNextEpisode {
                Text(L10n.string("player.ended.no-next", fallback: "No next episode is available in this playback line and version."))
            }
        }
        .font(.callout).foregroundStyle(.white)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
    }

    private var unavailablePlayer: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.slash")
                .font(.system(size: 42))
            Text(L10n.string("player.unavailable.title", fallback: "Built-in Player Unavailable"))
                .font(.headline)
            Text(L10n.string("player.unavailable.message", fallback: "Build and package libmpv 0.41.0 first."))
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
                    Color.black.opacity(0.20),
                    Color.black.opacity(0.68)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 190)
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
                    Color.black.opacity(0.54)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 132)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var livePlayerOverlay: some View {
        GeometryReader { geometry in
            let metrics = LivePlayerOverlayMetrics(
                viewportSize: geometry.size
            )
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Spacer(minLength: metrics.minimumTopSpace)
                    HStack(alignment: .bottom) {
                        livePrimaryControls(metrics: metrics)
                        Spacer(minLength: metrics.minimumControlSeparation)
                        liveFullScreenButton(metrics: metrics)
                    }
                    .padding(.horizontal, metrics.outerHorizontalPadding)
                    .padding(.bottom, metrics.outerBottomPadding)
                }

                liveChannelInfoCard
                    .padding(.top, max(24, metrics.outerBottomPadding))
                    .padding(.trailing, metrics.outerHorizontalPadding)
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .offset(y: controlsVisible || reduceMotion ? 0 : 10)
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

                if let channel = state.livePlaybackChannel, let source = state.livePlaybackSourceID {
                    LiveNowNextView(epg: state.liveEPG, channel: channel, source: source)
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

    private func livePrimaryControls(
        metrics: LivePlayerOverlayMetrics
    ) -> some View {
        HStack(alignment: .bottom, spacing: metrics.controlSpacing) {
            liveBroadcastIndicator(metrics: metrics)

            Button {
                Task { await state.togglePlayPause() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(
                        .system(
                            size: metrics.primaryIconSize,
                            weight: .semibold
                        )
                    )
                    .frame(
                        width: metrics.controlDiameter,
                        height: metrics.controlDiameter
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isPaused
                    ? L10n.string("common.play", fallback: "Play")
                    : L10n.string("common.pause", fallback: "Pause")
            )
            .playerControlHelp(
                isPaused
                    ? L10n.string("common.play", fallback: "Play")
                    : L10n.string("common.pause", fallback: "Pause")
            )
            .modifier(PlayerControlHoverEffect())

            liveVolumeControl(metrics: metrics)
        }
        .foregroundColor(.white.opacity(0.96))
        .onHover { inside in
            controlsHovering = inside
            inside ? keepControlsVisible() : scheduleControlsHide()
        }
    }

    private func liveBroadcastIndicator(
        metrics: LivePlayerOverlayMetrics
    ) -> some View {
        ZStack {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(
                    .system(
                        size: metrics.liveIconSize,
                        weight: .semibold
                    )
                )
            Circle()
                .fill(Color.red)
                .frame(
                    width: metrics.liveDotDiameter,
                    height: metrics.liveDotDiameter
                )
        }
        .frame(
            width: metrics.controlDiameter,
            height: metrics.controlDiameter
        )
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("player.live", fallback: "Live"))
        .playerControlHelp(L10n.string("player.live", fallback: "Live"))
    }

    private func liveVolumeControl(
        metrics: LivePlayerOverlayMetrics
    ) -> some View {
        VStack(spacing: metrics.volumePopoverSpacing) {
            if isLiveVolumeControlPresented {
                Slider(
                    value: Binding(
                        get: {
                            state.playerAudioPreference.volume
                        },
                        set: enqueueLivePlayerVolume
                    ),
                    in: 0...130,
                    onEditingChanged: { editing in
                        isVolumeEditing = editing
                        if editing {
                            keepControlsVisible()
                        } else {
                            enqueueLivePlayerVolume(
                                state.playerAudioPreference.volume
                            )
                            if !isLiveVolumeHovering {
                                isLiveVolumeControlPresented = false
                            }
                            scheduleControlsHide()
                        }
                    }
                )
                .tint(.white)
                .controlSize(.mini)
                .frame(width: metrics.volumeSliderWidth)
                .padding(.horizontal, metrics.volumePopoverHorizontalPadding)
                .padding(.vertical, metrics.volumePopoverVerticalPadding)
                .background(Color.black.opacity(0.42))
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.34), radius: 8, y: 3)
                .transition(
                    .opacity.combined(with: .move(edge: .bottom))
                )
            }

            Button {
                Task { await state.togglePlayerMute() }
            } label: {
                Image(
                    systemName: state.playerAudioPreference.muted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill"
                )
                .font(
                    .system(
                        size: metrics.secondaryIconSize,
                        weight: .medium
                    )
                )
                .frame(
                    width: metrics.controlDiameter,
                    height: metrics.controlDiameter
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                state.playerAudioPreference.muted
                    ? L10n.string("player.unmute", fallback: "Unmute")
                    : L10n.string("player.mute-volume", fallback: "Mute and Volume")
            )
            .playerControlHelp(
                state.playerAudioPreference.muted
                    ? L10n.string("player.unmute", fallback: "Unmute")
                    : L10n.string("player.mute-volume", fallback: "Mute and Volume")
            )
            .modifier(PlayerControlHoverEffect())
        }
        .onHover { inside in
            isLiveVolumeHovering = inside
            if inside {
                isLiveVolumeControlPresented = true
            } else if !isVolumeEditing {
                isLiveVolumeControlPresented = false
            }
        }
        .animation(
            .easeOut(duration: 0.16),
            value: isLiveVolumeControlPresented
        )
        // Keep the permanent icon row fixed while the wider slider temporarily
        // overflows above the speaker button.
        .frame(width: metrics.controlDiameter, alignment: .bottom)
    }

    private func liveFullScreenButton(
        metrics: LivePlayerOverlayMetrics
    ) -> some View {
        Button {
            toggleFullScreen()
        } label: {
            Image(
                systemName: isWindowFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
            .font(
                .system(
                    size: metrics.secondaryIconSize,
                    weight: .medium
                )
            )
            .frame(
                width: metrics.controlDiameter,
                height: metrics.controlDiameter
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isWindowFullScreen
                ? L10n.string("player.exit-full-screen", fallback: "Exit Full Screen")
                : L10n.string("player.enter-full-screen", fallback: "Enter Full Screen")
        )
        .foregroundColor(.white.opacity(0.96))
        .playerControlHelp(
            isWindowFullScreen
                ? L10n.string("player.exit-full-screen", fallback: "Exit Full Screen")
                : L10n.string("player.enter-full-screen", fallback: "Enter Full Screen")
        )
        .modifier(PlayerControlHoverEffect())
        .onHover { inside in
            controlsHovering = inside
            inside ? keepControlsVisible() : scheduleControlsHide()
        }
    }

    private func enqueueLivePlayerVolume(_ volume: Double) {
        state.requestPlayerVolume(volume)
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
        return PlayerEpisodeTitlePolicy.title(content: contentTitle, resource: presentation.displayName)
    }

    private var liveStreamSummary: String {
        guard let channel = state.livePlaybackChannel else {
            return L10n.string("player.live", fallback: "Live")
        }
        let format = state.livePlaybackStream?.format?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return [
            format?.isEmpty == false ? format : nil,
            channel.groupName,
            L10n.string("player.stream-count", fallback: "%d streams", channel.streams.count)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func episodePanelDisplayName(
        _ presentation: EpisodePresentation
    ) -> String {
        presentation.displayName
    }

    private var floatingHeader: some View {
        VStack(spacing: 5) {
            PlayerTitleView(
                title: state.currentPlaybackContentTitle ?? state.currentPlaybackTitle,
                episode: state.currentPlayerEpisodePresentation.flatMap {
                    $0.displayName == state.currentPlaybackContentTitle ? nil : $0.displayName
                }
            )
            .help(playbackDisplayTitle)
            // Reserve equal space for native window buttons on the left and
            // the opposite edge, keeping long titles genuinely centered.
            .padding(.horizontal, 90)
            .frame(height: 28)

            if state.playbackResolutionState != .playing, !shouldShowStatusOverlay {
                statusPill
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
                AppActivityIndicator(size: .mini, tint: .white)
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
        .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
    }

    @ViewBuilder
    private var playbackStatusOverlay: some View {
        if shouldShowStatusOverlay {
            VStack(spacing: 10) {
                if !isFailed && !state.hasHistoryPlaybackChoices {
                    AppActivityIndicator(size: .small, tint: .white)
                }
                Text(isFailed ? L10n.string("player.stage.failed", fallback: "Playback Failed")
                    : state.isLivePlayback
                        ? (liveLoadingSlow ? L10n.string("live.loading-slow", fallback: "Connection is taking longer than usual")
                           : L10n.string("live.loading-channel", fallback: "Loading %@…", state.livePlaybackChannel?.name ?? ""))
                        : state.playbackStageDescription)
                    .font(.headline)
                if !isFailed {
                    Text(state.playerNetworkSpeedDescription)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.78))
                }

                if isFailed, let message = state.playbackFailureSummary {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.66))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .frame(maxWidth: 560)
                }

                if state.hasHistoryPlaybackChoices {
                    Text(state.playbackFailureSummary ?? L10n.string("player.history.choose-recovery", fallback: "Choose the stream and episode to restore"))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(state.historyPlaybackChoices) { choice in
                                Button {
                                    state.chooseHistoryPlayback(choice.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.title)
                                            .font(.callout.weight(.semibold))
                                            .lineLimit(1)
                                        Text(choice.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .frame(maxWidth: 620, maxHeight: 230)

                    Button(L10n.string("player.history.cancel-recovery", fallback: "Cancel Restore")) {
                        state.cancelHistoryPlaybackChoices()
                    }
                    .buttonStyle(.bordered)
                }

                if (isFailed || liveLoadingSlow), state.canRetryCurrentPlayback,
                   !state.canRetryHistoryPlayback, !state.canOpenNodeConfigurationForPlaybackFailure {
                    HStack(spacing: 12) {
                        Button(L10n.string("common.retry", fallback: "Try Again")) {
                            Task { await state.retryCurrentPlayback() }
                        }
                        .buttonStyle(.borderedProminent)
                        if state.isLivePlayback {
                            Button(L10n.string("live.next-channel", fallback: "Next Channel")) {
                                Task { await state.switchLiveChannel(by: 1) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if isFailed, state.canRetryHistoryPlayback {
                    HStack(spacing: 10) {
                        Button(L10n.string("common.retry", fallback: "Try Again")) {
                            state.retryHistoryPlayback()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(L10n.string("player.return-history", fallback: "Return to History")) {
                            state.returnToHistoryAfterPlaybackFailure()
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.regular)
                    .padding(.top, 2)
                }

                if isFailed,
                   state.canOpenNodeConfigurationForPlaybackFailure {
                    if !state.canRetryHistoryPlayback {
                        Button(L10n.string("common.retry", fallback: "Try Again")) {
                            state.retryNodePlaybackFailure()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(L10n.string("player.open-cloud-authorization", fallback: "Open Cloud Authorization Settings")) {
                        state.openNodeConfigurationForPlaybackFailure()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 2)
                }
            }
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: state.hasHistoryPlaybackChoices ? 560 : 420)
            .padding(24)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .transition(.opacity)
        }
    }

    private func floatingControls(layout: PlayerOverlayLayout) -> some View {
        VStack(spacing: 3) {
            progressControls
            PlayerControlRow(layout: layout) {
                HStack(spacing: 10) {
                    if layout.mode == .expanded { volumeControls }
                    else { compactVolumeButton }
                    playbackTimeLabel
                }
            } transport: {
                transportControls
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            } trailing: {
                if layout.showsAllTools { utilityControls }
                else {
                    HStack(spacing: 3) {
                        compactUtilityMenu
                        fullScreenButton
                    }
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 9)
        .frame(width: layout.controlWidth)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { inside in
            controlsHovering = inside
            inside ? keepControlsVisible() : scheduleControlsHide()
        }
    }

    private var playbackTimeText: String {
        "\(formatTime(displayedPosition)) / \(formatTime(state.playerSnapshot.duration))"
    }

    private var playbackTimeWidth: CGFloat {
        PlayerOverlayLayout.timeWidth(playbackTimeText)
    }

    private var playbackTimeLabel: some View {
        Text(playbackTimeText)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.9))
            .frame(width: playbackTimeWidth, alignment: .leading)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func updateTooltipAvailability() {
        controlTooltip.setEnabled(controlsVisible && !isFullScreenTransitioning && scrubPosition == nil)
    }

    private var compactVolumeButton: some View {
        Button {
            isCompactVolumePresented.toggle()
            keepControlsVisible()
        } label: {
            utilityMenuIcon(state.playerAudioPreference.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("player.volume", fallback: "Volume"))
        .playerControlHelp(L10n.string("player.volume", fallback: "Volume"))
        .popover(isPresented: $isCompactVolumePresented, arrowEdge: .top) {
            volumeControls.padding(12).environment(\.colorScheme, .dark)
        }
    }

    private var compactUtilityMenu: some View {
        Menu {
            compactPanelAction(.episodes, title: state.playerResourcePanelTitle)
            compactPanelAction(.audio, title: L10n.string("player.audio-tracks", fallback: "Audio Tracks"))
            compactPanelAction(.subtitles, title: L10n.string("player.subtitles", fallback: "Subtitles"))
            compactPanelAction(.danmaku, title: "弹幕")
            compactPanelAction(.settings, title: L10n.string("player.settings", fallback: "Playback Settings"))
        } label: {
            utilityMenuIcon("ellipsis.circle")
        }
        .playerUtilityMenuStyle()
        .fixedSize()
        .playerControlHelp(L10n.string("common.more", fallback: "More"))
        .accessibilityLabel(L10n.string("common.more", fallback: "More"))
    }

    private func compactPanelAction(_ panel: PlayerUtilityPanel, title: String) -> some View {
        Button(title) {
            inspectedPlayerEpisode = nil
            if panel == .episodes { alignPlayerEpisodePageWithCurrentEpisode() }
            activeUtilityPanel = panel
            keepControlsVisible()
        }
    }

    private var isProgressHovering: Bool {
        progressHoverFraction != nil || scrubPosition != nil
    }

    private var progressPreviewFraction: Double? {
        guard controlsVisible, state.isPlayerWindowKey, !isFullScreenTransitioning, state.canSeekPlayback else { return nil }
        if let scrubPosition {
            return PlayerTimelinePolicy.fraction(value: scrubPosition, total: state.playerSnapshot.duration)
        }
        return progressHoverFraction
    }

    private func dismissProgressPreview() {
        progressHoverFraction = nil
        progressHoverRevision &+= 1
    }

    private var progressControls: some View {
        PlayerTimelineControl(
            value: Binding(
                get: { displayedPosition },
                set: { scrubPosition = $0 }
            ),
            total: max(state.playerSnapshot.duration, 1),
            bufferedPercent: state.playerSnapshot.bufferedPercent,
            accentColor: playerAccentColor,
            isEmphasized: isProgressHovering,
            onEditingChanged: { editing in
                if editing {
                    keepControlsVisible()
                } else {
                    commitScrubPosition()
                    scheduleControlsHide()
                }
            }
        )
        .disabled(!state.canSeekPlayback)
        .frame(height: 24)
        .shadow(
            color: playerAccentColor.opacity(isProgressHovering ? 0.18 : 0),
            radius: isProgressHovering ? 5 : 0
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isProgressHovering
        )
        .contentShape(Rectangle())
        .background {
            ProgressHoverTrackingView(
                isEnabled: controlsVisible && !isFullScreenTransitioning && state.canSeekPlayback,
                revision: progressHoverRevision
            ) { fraction in
                progressHoverFraction = fraction
                if fraction != nil {
                    keepControlsVisible()
                } else {
                    scheduleControlsHide()
                }
            }
        }
        .anchorPreference(key: PlayerProgressTrackAnchorKey.self, value: .bounds) { $0 }
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
                systemImage: state.playerAudioPreference.muted
                    ? "speaker.slash.fill"
                    : "speaker.wave.2.fill",
                help: state.playerAudioPreference.muted
                    ? L10n.string("player.unmute", fallback: "Unmute")
                    : L10n.string("player.mute", fallback: "Mute")
            ) {
                Task { await state.togglePlayerMute() }
            }

            Slider(
                value: Binding(
                    get: { state.playerAudioPreference.volume },
                    set: enqueuePlayerVolume
                ),
                in: 0...130,
                onEditingChanged: { editing in
                    isVolumeEditing = editing
                    if editing {
                        keepControlsVisible()
                    } else {
                        enqueuePlayerVolume(
                            state.playerAudioPreference.volume
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
        state.requestPlayerVolume(volume)
    }

    private func adjacentResourceHelp(previous: Bool) -> String {
        let title = previous ? state.previousPlayerResourceTitle : state.nextPlayerResourceTitle
        if previous ? state.hasPreviousEpisode : state.hasNextEpisode { return title }
        if state.isPlayerEpisodeListPreparing {
            return title + " · " + L10n.string("player.queue.preparing", fallback: "Loading episode list")
        }
        if state.playerEpisodes.isEmpty {
            return title + " · " + L10n.string("player.queue.unavailable", fallback: "No episode list available")
        }
        return title + " · " + L10n.string("player.queue.no-adjacent", fallback: "No adjacent episode available")
    }

    private var transportControls: some View {
        HStack(spacing: 6) {
            playerIconButton(
                systemImage: "backward.end.fill",
                help: adjacentResourceHelp(previous: true),
                disabled: !state.hasPreviousEpisode
            ) {
                Task { await state.playAdjacentEpisode(offset: -1) }
            }

            playerIconButton(
                systemImage: "gobackward.10",
                help: state.canSeekPlayback
                    ? L10n.string("player.seek-back-10", fallback: "Back 10 Seconds")
                    : L10n.string("player.seek-unavailable", fallback: "Seeking is unavailable for this stream"),
                disabled: !state.canSeekPlayback
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
            .playerControlHelp(
                isPaused
                    ? L10n.string("common.play", fallback: "Play")
                    : L10n.string("common.pause", fallback: "Pause")
            )

            playerIconButton(
                systemImage: "goforward.10",
                help: state.canSeekPlayback
                    ? L10n.string("player.seek-forward-10", fallback: "Forward 10 Seconds")
                    : L10n.string("player.seek-unavailable", fallback: "Seeking is unavailable for this stream"),
                disabled: !state.canSeekPlayback
            ) {
                Task { await state.seek(by: 10) }
            }

            playerIconButton(
                systemImage: "forward.end.fill",
                help: adjacentResourceHelp(previous: false),
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
                help: state.playerResourcePanelTitle
            )
            utilityPanelButton(
                systemImage: "waveform",
                panel: .audio,
                help: L10n.string("player.audio-tracks", fallback: "Audio Tracks")
            )
            utilityPanelButton(
                systemImage: "captions.bubble",
                panel: .subtitles,
                help: state.playerSubtitlesEnabled
                    ? L10n.string("player.subtitles.on", fallback: "Subtitles On")
                    : L10n.string("player.subtitles.off", fallback: "Subtitles Off")
            )
            utilityPanelButton(
                systemImage: "text.bubble",
                panel: .danmaku,
                help: state.danmaku.isEnabled ? "弹幕已开启" : "弹幕已关闭"
            )
            utilityPanelButton(
                systemImage: "gearshape",
                panel: .settings,
                help: L10n.string("player.settings", fallback: "Playback Settings")
            )

            fullScreenButton
        }
    }

    private var fullScreenButton: some View {
            playerIconButton(
                systemImage: isWindowFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: isWindowFullScreen
                    ? L10n.string("player.exit-full-screen", fallback: "Exit Full Screen")
                    : L10n.string("player.enter-full-screen", fallback: "Enter Full Screen")
            ) {
                toggleFullScreen()
            }
    }

    private func utilityPanelButton(
        systemImage: String,
        panel: PlayerUtilityPanel,
        help: String
    ) -> some View {
        let isActive = activeUtilityPanel == panel
        return Button {
            if isActive || panel != .episodes {
                inspectedPlayerEpisode = nil
            }
            if panel == .episodes, !isActive {
                alignPlayerEpisodePageWithCurrentEpisode()
            }
            // This is a direct manipulation control. Publish the panel in the
            // same event turn so its first button can be hit immediately.
            activeUtilityPanel = isActive ? nil : panel
            keepControlsVisible()
        } label: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: utilityIconSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(isActive ? 1 : 0.96))
                .frame(width: utilityButtonSize, height: utilityButtonSize)
                .contentShape(Rectangle())
                .modifier(PlayerControlHoverEffect())
        }
        .buttonStyle(.plain)
        .playerControlHelp(help)
        .accessibilityLabel(help)
        .accessibilityValue(
            isActive
                ? L10n.string("player.panel.open", fallback: "Panel Open")
                : L10n.string("player.panel.closed", fallback: "Panel Closed")
        )
    }

    @ViewBuilder
    private func utilityPanel(_ panel: PlayerUtilityPanel, maximumSize: CGSize) -> some View {
        switch panel {
        case .episodes:
            episodePanel(maximumSize: maximumSize)
        case .audio:
            audioTrackPanel(maximumSize: maximumSize)
        case .subtitles:
            subtitlePanel(maximumSize: maximumSize)
        case .danmaku:
            danmakuPanel(maximumSize: maximumSize)
        case .settings:
            playbackSettingsPanel(maximumSize: maximumSize)
        }
    }

    private func danmakuPanel(maximumSize: CGSize) -> some View {
        playerPanel(width: 390, maximumSize: maximumSize) {
            PlayerDanmakuPanel(
                coordinator: state.danmaku,
                importXML: chooseDanmakuXML
            )
        }
    }

    private func episodePanel(maximumSize: CGSize) -> some View {
        let presentations = state.playerEpisodePresentations
        let pageCount = PlayerEpisodePagePolicy.pages(presentations).count
        let selectionSessionID = state.playerEpisodeSelectionSessionID
        let safePageIndex = min(max(0, playerEpisodePageIndex), max(0, pageCount - 1))
        let pagePresentations = PlayerEpisodePagePolicy.page(
            presentations,
            pageIndex: safePageIndex
        )
        return playerPanel(width: 500, maximumSize: maximumSize, scrollContent: false) {
            VStack(alignment: .leading, spacing: 12) {
                panelHeader(
                    title: state.playerResourcePanelTitle,
                    detail: state.playerResourceCountText
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string(state.hasLoadedPlayerEpisode ? "player.episode.now" : "player.episode.pending", fallback: "Current Resource: %@", state.currentPlayerEpisodePresentation?.displayName ?? state.currentPlaybackTitle))
                        .font(.callout.weight(.semibold)).lineLimit(2)
                    HStack {
                        Text([state.currentPlayerSourceName, state.currentPlayerVersionText].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(L10n.string("player.episode.locate", fallback: "Locate Current")) {
                            alignPlayerEpisodePageWithCurrentEpisode()
                            playerEpisodeLocateRevision += 1
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    if state.isRestoringPlayerEpisodeList {
                        Text(L10n.string("player.episode.restoring", fallback: "Restoring episode list…")).font(.caption)
                    } else if state.isPlayerEpisodeListIncomplete {
                        HStack {
                            Text(L10n.string("player.episode.partial", fallback: "Only the current resource was restored")).font(.caption)
                            Button(L10n.string("common.retry", fallback: "Retry")) { state.retryPlayerEpisodeList() }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    if !state.canSelectPlayerEpisode {
                        Text(L10n.string("player.episode.switching", fallback: "Preparing playback; selection will be available shortly")).font(.caption)
                    } else if state.canRetryPlayerEpisode {
                        Button(L10n.string("player.episode.retry", fallback: "Retry Playback")) {
                            Task {
                                if let episode = state.currentPlaybackEpisode {
                                    await state.playPlayerEpisode(episode, expectedSessionID: selectionSessionID)
                                }
                            }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                if state.isPlayerEpisodeListPreparing {
                    HStack(spacing: 9) {
                        AppActivityIndicator(size: .small, tint: .white)
                        Text(L10n.string("player.organizing-episodes", fallback: "Organizing episodes…"))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.62))
                    }
                    .frame(maxWidth: .infinity, minHeight: 74)
                } else if presentations.isEmpty {
                    panelEmptyState(L10n.string("player.no-episodes", fallback: "No Episodes"))
                } else {
                    if pageCount > 1 {
                        playerEpisodePageControls(
                            presentations: presentations,
                            pageCount: pageCount,
                            selectedPageIndex: safePageIndex
                        )
                    }

                    PlayerEpisodeGrid(
                        presentations: pagePresentations,
                        selectedEpisodeID: state.currentPlayerEpisodeID,
                        accentColor: playerAccentColor,
                        displayName: episodePanelDisplayName,
                        onPlay: { presentation in
                            inspectedPlayerEpisode = nil
                            Task {
                                await state.playPlayerEpisode(presentation.episode, expectedSessionID: selectionSessionID)
                            }
                        },
                        onInspect: { presentation in
                            inspectedPlayerEpisode = presentation
                        },
                        selectionEnabled: state.canSelectPlayerEpisode,
                        canRetrySelected: state.canRetryPlayerEpisode,
                        locateRevision: playerEpisodeLocateRevision,
                        selectionSessionID: selectionSessionID
                    )
                    .equatable()
                    .frame(
                        height: min(max(44, maximumSize.height - (inspectedPlayerEpisode == nil ? 235 : 375)),
                            PlayerEpisodePanelLayoutPolicy.gridHeight(
                                episodeCount: pagePresentations.count,
                                showsInspector: inspectedPlayerEpisode != nil,
                                width: min(500, maximumSize.width) - 28,
                                minimumCellWidth: pagePresentations.contains { $0.episodeNumber == nil } ? 150 : 110
                            ))
                    )

                    if let inspectedPlayerEpisode {
                        PlayerEpisodeOriginalNameInspector(
                            originalName: inspectedPlayerEpisode.originalName,
                            onClose: { self.inspectedPlayerEpisode = nil }
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
    }

    private func playerEpisodePageControls(
        presentations: [EpisodePresentation],
        pageCount: Int,
        selectedPageIndex: Int
    ) -> some View {
        HStack(spacing: 8) {
            Text(L10n.string("detail.episode-range", fallback: "Episode Range"))
                .font(.caption)
                .foregroundColor(.white.opacity(0.58))

            Picker(
                L10n.string("detail.episode-range", fallback: "Episode Range"),
                selection: $playerEpisodePageIndex
            ) {
                ForEach(0..<pageCount, id: \.self) { pageIndex in
                    Text(
                        PlayerEpisodePagePolicy.title(
                            presentations: presentations,
                            pageIndex: pageIndex
                        )
                    )
                    .tag(pageIndex)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 190)

            Button {
                inspectedPlayerEpisode = nil
                playerEpisodePageIndex = max(0, selectedPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedPageIndex == 0)

            Button {
                inspectedPlayerEpisode = nil
                playerEpisodePageIndex = min(
                    pageCount - 1,
                    selectedPageIndex + 1
                )
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedPageIndex >= pageCount - 1)

            Spacer(minLength: 0)
        }
    }

    private func alignPlayerEpisodePageWithCurrentEpisode() {
        playerEpisodePageIndex = PlayerEpisodePagePolicy.pageIndex(
            presentations: state.playerEpisodePresentations,
            selectedEpisodeID: state.currentPlayerEpisodeID
        )
    }

    private func audioTrackPanel(maximumSize: CGSize) -> some View {
        let tracks = state.playerSnapshot.tracks.filter { $0.type == .audio }
        return playerPanel(width: 340, maximumSize: maximumSize) {
            VStack(alignment: .leading, spacing: 10) {
                panelHeader(
                    title: L10n.string("player.audio-tracks", fallback: "Audio Tracks"),
                    detail: L10n.string("player.track-count", fallback: "%d tracks", tracks.count)
                )
                if tracks.isEmpty {
                    panelEmptyState(L10n.string("player.no-audio-tracks", fallback: "No Audio Tracks"))
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
                            min(260, max(44, maximumSize.height - 110)),
                            max(44, CGFloat(tracks.count) * 39)
                        )
                    )
                }
            }
        }
    }

    private func subtitlePanel(maximumSize: CGSize) -> some View {
        let tracks = state.playerSnapshot.tracks.filter {
            $0.type == .subtitle
        }
        return playerPanel(width: 360, maximumSize: maximumSize) {
            Group {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        panelHeader(
                            title: L10n.string("player.subtitles", fallback: "Subtitles"),
                            detail: L10n.string("player.track-count", fallback: "%d tracks", tracks.count)
                        )
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
                        panelEmptyState(L10n.string("player.no-embedded-subtitles", fallback: "No Embedded Subtitles"))
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
                    Text(L10n.string("player.subtitle-settings", fallback: "Subtitle Settings"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.58))
                    panelStepperRow(
                        title: L10n.string("player.subtitle-size", fallback: "Size"),
                        value: "\(Int(state.playerSubtitleScale * 100))%",
                        decrease: {
                            Task { await state.adjustPlayerSubtitleScale(by: -0.1) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitleScale(by: 0.1) }
                        }
                    )
                    panelStepperRow(
                        title: L10n.string("player.subtitle-position", fallback: "Position"),
                        value: "\(Int(state.playerSubtitlePosition))",
                        decrease: {
                            Task { await state.adjustPlayerSubtitlePosition(by: -5) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitlePosition(by: 5) }
                        }
                    )
                    panelStepperRow(
                        title: L10n.string("player.subtitle-outline", fallback: "Outline"),
                        value: String(format: "%.1f", state.playerSubtitleBorderSize),
                        decrease: {
                            Task { await state.adjustPlayerSubtitleBorderSize(by: -0.5) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitleBorderSize(by: 0.5) }
                        }
                    )
                    panelStepperRow(
                        title: L10n.string("player.delay", fallback: "Delay"),
                        value: L10n.string("player.seconds", fallback: "%.1f sec", state.playerSubtitleDelay),
                        decrease: {
                            Task { await state.adjustPlayerSubtitleDelay(by: -0.5) }
                        },
                        increase: {
                            Task { await state.adjustPlayerSubtitleDelay(by: 0.5) }
                        }
                    )

                    panelDivider
                    HStack(spacing: 8) {
                        panelActionButton(L10n.string("common.restore-default", fallback: "Restore Defaults")) {
                            Task { await state.resetPlayerSubtitleSettings() }
                        }
                        panelActionButton(L10n.string("player.load-external-subtitles", fallback: "Load External Subtitles…")) {
                            chooseSubtitle()
                        }
                    }
                }
            }
        }
    }

    private func playbackSettingsPanel(maximumSize: CGSize) -> some View {
        playerPanel(width: 370, maximumSize: maximumSize) {
            Group {
                VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: L10n.string("player.settings", fallback: "Playback Settings"), detail: nil)

                    HStack {
                        Text(L10n.string("player.autoplay-next", fallback: "Autoplay Next Episode"))
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

                    panelDivider

                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            L10n.string(
                                "player.skip.title",
                                fallback: "Skip Opening and Ending"
                            )
                        )
                        .font(.system(size: 13, weight: .semibold))

                        Toggle(
                            L10n.string(
                                "player.skip.all-episodes",
                                fallback: "Apply to All Episodes on This Line"
                            ),
                            isOn: Binding(
                                get: {
                                    state.playbackSkipAppliesToAllEpisodes
                                },
                                set: {
                                    state.setPlaybackSkipAppliesToAllEpisodes($0)
                                }
                            )
                        )
                        .toggleStyle(.checkbox)

                        playbackSkipEditorRow(
                            title: L10n.string(
                                "player.skip.opening",
                                fallback: "Opening"
                            ),
                            value: state.playbackSkipOpeningEnd,
                            enabled: state.playbackSkipOpeningEnabled,
                            setTitle: L10n.string(
                                "player.skip.set-opening",
                                fallback: "Set Current Position as Opening End"
                            ),
                            canMark: state.canMarkPlaybackOpening,
                            setEnabled: { enabled in
                                Task {
                                    await state.setPlaybackOpeningSkipEnabled(
                                        enabled
                                    )
                                }
                            },
                            adjust: { delta in
                                Task {
                                    await state.adjustPlaybackOpening(by: delta)
                                }
                            },
                            mark: {
                                Task {
                                    await state.markPlaybackOpeningAtCurrentPosition()
                                }
                            }
                        )

                        playbackSkipEditorRow(
                            title: L10n.string(
                                "player.skip.ending",
                                fallback: "Ending"
                            ),
                            value: state.playbackSkipEndingDuration,
                            enabled: state.playbackSkipEndingEnabled,
                            setTitle: L10n.string(
                                "player.skip.set-ending",
                                fallback: "Set Current Position as Ending Start"
                            ),
                            canMark: state.canMarkPlaybackEnding,
                            setEnabled: { enabled in
                                Task {
                                    await state.setPlaybackEndingSkipEnabled(
                                        enabled
                                    )
                                }
                            },
                            adjust: { delta in
                                Task {
                                    await state.adjustPlaybackEnding(by: delta)
                                }
                            },
                            mark: {
                                Task {
                                    await state.markPlaybackEndingAtCurrentPosition()
                                }
                            }
                        )

                        Button(
                            L10n.string(
                                "player.skip.clear",
                                fallback: "Clear These Skip Points"
                            )
                        ) {
                            Task {
                                await state.clearSelectedPlaybackSkipRule()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    if state.playbackQualities.count > 1 {
                        panelDivider
                        panelOptionGrid(
                            title: L10n.string("player.quality", fallback: "Quality"),
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
                        title: L10n.string("player.speed", fallback: "Playback Speed"),
                        values: speeds.map(formatPlaybackSpeed),
                        selected: formatPlaybackSpeed(state.playerSnapshot.speed)
                    ) { selectedSpeed in
                        guard let index = speeds.map(formatPlaybackSpeed)
                            .firstIndex(of: selectedSpeed) else { return }
                        Task { await state.setPlayerSpeed(speeds[index]) }
                    }

                    panelOptionGrid(
                        title: L10n.string("player.aspect-ratio", fallback: "Aspect Ratio"),
                        values: ["automatic", "16:9", "4:3", "2.35:1"],
                        selected: state.playerAspectRatio ?? "automatic",
                        displayTitle: { value in
                            value == "automatic"
                                ? L10n.string("common.automatic", fallback: "Automatic")
                                : value
                        }
                    ) { ratio in
                        Task {
                            await state.setPlayerAspectRatio(
                                ratio == "automatic" ? nil : ratio
                            )
                        }
                    }

                    HStack {
                        Text(L10n.string("player.hardware-decoding", fallback: "Hardware Decoding"))
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
                        title: L10n.string("player.audio-delay", fallback: "Audio Delay"),
                        value: L10n.string("player.seconds", fallback: "%.1f sec", state.playerAudioDelay),
                        decrease: {
                            Task { await state.adjustPlayerAudioDelay(by: -0.1) }
                        },
                        increase: {
                            Task { await state.adjustPlayerAudioDelay(by: 0.1) }
                        }
                    )

                    panelDivider
                    panelActionButton(L10n.string("player.save-screenshot", fallback: "Save Screenshot…")) {
                        chooseScreenshotLocation()
                    }
                }
            }
        }
    }

    private func playbackSkipEditorRow(
        title: String,
        value: TimeInterval?,
        enabled: Bool,
        setTitle: String,
        canMark: Bool,
        setEnabled: @escaping (Bool) -> Void,
        adjust: @escaping (TimeInterval) -> Void,
        mark: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(
                    title,
                    isOn: Binding(
                        get: { enabled },
                        set: setEnabled
                    )
                )
                .toggleStyle(.checkbox)
                .disabled(value == nil)

                Spacer()

                Button { adjust(-1) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(value == nil)

                Text(
                    value.map(formatTime)
                        ?? L10n.string(
                            "player.skip.not-set",
                            fallback: "Not Set"
                        )
                )
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(minWidth: 52)

                Button { adjust(1) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(value == nil)
            }

            Button(setTitle, action: mark)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canMark)
        }
    }

    private func endingSkipPromptOverlay(
        _ prompt: PlaybackEndingSkipPrompt
    ) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(
                    prompt.willAdvanceAutomatically
                        ? L10n.string(
                            "player.skip.ending-countdown",
                            fallback: "Skipping ending in %d seconds",
                            prompt.secondsUntilBoundary
                        )
                        : L10n.string(
                            "player.skip.ending-ready",
                            fallback: "Ending reached"
                        )
                )
                .font(.callout.weight(.semibold))

                Button(
                    L10n.string(
                        "player.skip.now",
                        fallback: "Skip Now"
                    )
                ) {
                    state.skipEndingNow()
                }
                .buttonStyle(.borderedProminent)

                Button(
                    L10n.string(
                        "player.skip.cancel-current",
                        fallback: "Don't Skip This Episode"
                    )
                ) {
                    state.suppressEndingSkipForCurrentPlayback()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .environment(\.colorScheme, .dark)
            .padding(.bottom, controlsVisible ? 100 : 28)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func playerPanel<Content: View>(
        width: CGFloat,
        maximumSize: CGSize,
        scrollContent: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Button {
                    activeUtilityPanel = nil
                    scheduleControlsHide()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .playerControlHelp(L10n.string("common.close", fallback: "Close"))
                .accessibilityLabel(L10n.string("common.close", fallback: "Close"))
            }
            if scrollContent {
                PlayerUtilityPanelContent(maximumHeight: max(1, maximumSize.height - 64)) { content() }
            } else {
                content()
            }
        }
            .padding(14)
            .frame(width: min(width, maximumSize.width))
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
        displayTitle: @escaping (String) -> String = { $0 },
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
                    Button(displayTitle(value)) { action(value) }
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

    private func playerIconButton(
        systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: utilityIconSize, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: utilityButtonSize, height: utilityButtonSize)
                .contentShape(Circle())
                .modifier(PlayerControlHoverEffect(enabled: !disabled))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.30 : 1)
        .disabled(disabled)
        .playerControlHelp(help)
    }

    private func utilityMenuIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: utilityIconSize, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: utilityButtonSize, height: utilityButtonSize)
            .contentShape(Rectangle())
            .modifier(PlayerControlHoverEffect())
    }

    private var isFailed: Bool {
        if state.isLivePlayback {
            if state.hasExhaustedLivePlayback { return true }
            if state.isRecoveringLivePlayback { return false }
        }
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
        if state.isLivePlayback { return liveLoadingVisible && isLiveWaiting }
        switch state.playbackResolutionState {
        case .restoringHistory, .resolving, .validating, .loading, .retrying:
            return true
        case .idle, .playing, .exhausted, .failed:
            break
        }
        switch state.playerSnapshot.status {
        case .loading:
            return true
        default:
            return playbackActivityOverlayVisible
        }
    }

    private var isLiveWaiting: Bool {
        state.isLivePlayback && !isFailed && LiveLoadingPresentationPolicy.isWaiting(
            snapshot: state.playerSnapshot, recovering: state.isRecoveringLivePlayback,
            exhausted: state.hasExhaustedLivePlayback, hasStarted: state.hasCurrentPlaybackStarted)
    }

    private var liveLoadingTaskID: String {
        "\(state.playbackPresentationID)-\(isLiveWaiting)"
    }

    private var hasTransientPlaybackActivity: Bool {
        PlayerActivityOverlayPolicy.isActive(
            snapshot: state.playerSnapshot
        )
    }

    private func updatePlaybackActivityOverlay(isActive: Bool) {
        playbackActivityOverlayTask?.cancel()
        playbackActivityOverlayTask = nil

        if isActive {
            guard !playbackActivityOverlayVisible else { return }
            playbackActivityOverlayTask = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: PlayerActivityOverlayPolicy
                            .presentationDelayNanoseconds
                    )
                    try Task.checkCancellation()
                    guard hasTransientPlaybackActivity else { return }
                    playbackActivityOverlayVisible = true
                } catch {
                    return
                }
            }
            return
        }

        // Once the current seek/cache wait ends, hide immediately. The delay
        // before showing already prevents flicker; a minimum visible duration
        // would obscure frames after playback has recovered.
        playbackActivityOverlayVisible = false
    }

    private var displayedPosition: Double {
        min(
            max(scrubPosition ?? state.playerSnapshot.position, 0),
            max(state.playerSnapshot.duration, 1)
        )
    }

    private var isPaused: Bool {
        state.playerSnapshot.status == .paused || state.playerSnapshot.status == .ended
    }

    private var shouldAutoHideControls: Bool {
        PlayerControlVisibilityPolicy.shouldAutoHide(
            isLivePlayback: state.isLivePlayback,
            controlsHovering: controlsHovering,
            isFailed: isFailed,
            keepsControlsVisible: isFullScreenTransitioning || activeUtilityPanel != nil || isCompactVolumePresented || isVolumeEditing || scrubPosition != nil,
            isPlaying: {
                if case .playing = state.playerSnapshot.status { return true }
                return false
            }()
        )
    }

    private func revealControls() {
        guard !isFullScreenTransitioning else { return }
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

    private func handleFullScreenTransition(_ transitioning: Bool) {
        guard isFullScreenTransitioning != transitioning else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFullScreenTransitioning = transitioning
            frozenViewportSize = transitioning ? settledViewportSize : nil
            dismissProgressPreview()
            controlTooltip.dismiss()
            controlsHovering = false
            activeUtilityPanel = nil
            isCompactVolumePresented = false
        }
        if transitioning { hideControlsTask?.cancel() }
        else { scheduleControlsHide() }
    }

    private func toggleFullScreen() {
        state.togglePlayerFullScreen()
    }

    private func handleSurfaceDoubleClick() {
        if activeUtilityPanel != nil {
            inspectedPlayerEpisode = nil
            activeUtilityPanel = nil
        }
        toggleFullScreen()
    }

    private func handleEscapeShortcut() {
        if activeUtilityPanel != nil {
            inspectedPlayerEpisode = nil
            activeUtilityPanel = nil
            return
        }
        if isWindowFullScreen {
            toggleFullScreen()
        }
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
                Button(L10n.string("player.load-external-subtitles", fallback: "Load External Subtitles…")) {
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
        .playerControlHelp(title)
    }

    private var subtitleMenu: some View {
        let tracks = state.playerSnapshot.tracks.filter {
            $0.type == .subtitle
        }
        return Menu {
            Toggle(
                L10n.string("player.show-subtitles", fallback: "Show Subtitles"),
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
                Text(L10n.string("player.no-embedded-subtitles", fallback: "No Embedded Subtitles"))
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
                    .playerControlHelp(
                        state.selectedPlayerSubtitleTrackID == track.id
                            ? L10n.string("player.subtitle.current", fallback: "Current Subtitle")
                            : L10n.string("player.subtitle.choose", fallback: "Choose This Subtitle")
                    )
                }
            }

            Divider()
            Menu(L10n.string("player.subtitle-settings", fallback: "Subtitle Settings")) {
                Menu(L10n.string("player.subtitle-size-value", fallback: "Size · %d%%", Int(state.playerSubtitleScale * 100))) {
                    Button(L10n.string("player.subtitle-smaller", fallback: "Decrease 10%")) {
                        Task { await state.adjustPlayerSubtitleScale(by: -0.1) }
                    }
                    Button(L10n.string("player.subtitle-larger", fallback: "Increase 10%")) {
                        Task { await state.adjustPlayerSubtitleScale(by: 0.1) }
                    }
                }
                Menu(L10n.string("player.subtitle-position-value", fallback: "Position · %d", Int(state.playerSubtitlePosition))) {
                    Button(L10n.string("player.subtitle-move-up", fallback: "Move Up")) {
                        Task { await state.adjustPlayerSubtitlePosition(by: -5) }
                    }
                    Button(L10n.string("player.subtitle-move-down", fallback: "Move Down")) {
                        Task { await state.adjustPlayerSubtitlePosition(by: 5) }
                    }
                }
                Menu(L10n.string("player.subtitle-outline-value", fallback: "Outline · %.1f", state.playerSubtitleBorderSize)) {
                    Button(L10n.string("player.subtitle-outline-decrease", fallback: "Decrease Outline")) {
                        Task { await state.adjustPlayerSubtitleBorderSize(by: -0.5) }
                    }
                    Button(L10n.string("player.subtitle-outline-increase", fallback: "Increase Outline")) {
                        Task { await state.adjustPlayerSubtitleBorderSize(by: 0.5) }
                    }
                }
                Menu(L10n.string("player.subtitle-delay-value", fallback: "Delay · %.1f sec", state.playerSubtitleDelay)) {
                    Button(L10n.string("player.subtitle-earlier", fallback: "Subtitles 0.5 Seconds Earlier")) {
                        Task { await state.adjustPlayerSubtitleDelay(by: -0.5) }
                    }
                    Button(L10n.string("player.subtitle-later", fallback: "Subtitles 0.5 Seconds Later")) {
                        Task { await state.adjustPlayerSubtitleDelay(by: 0.5) }
                    }
                }
                Divider()
                Button(L10n.string("player.subtitle-restore-defaults", fallback: "Restore Default Subtitle Settings")) {
                    Task { await state.resetPlayerSubtitleSettings() }
                }
            }
            Button(L10n.string("player.load-external-subtitles", fallback: "Load External Subtitles…")) {
                chooseSubtitle()
            }
        } label: {
            utilityMenuIcon("captions.bubble")
        }
        .playerUtilityMenuStyle()
        .fixedSize()
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .playerControlHelp(
            state.playerSubtitlesEnabled
                ? L10n.string("player.subtitles.on", fallback: "Subtitles On")
                : L10n.string("player.subtitles.off", fallback: "Subtitles Off")
        )
    }

    private var playbackOptionsMenu: some View {
        Menu {
            Toggle(
                L10n.string("player.autoplay-next", fallback: "Autoplay Next Episode"),
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
                    L10n.string("player.quality", fallback: "Quality") + " · "
                        + (state.isSwitchingPlaybackQuality
                            ? L10n.string("player.switching", fallback: "Switching")
                            : state.selectedPlaybackQualityName
                                ?? L10n.string("common.automatic", fallback: "Automatic"))
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

            Menu(L10n.string("player.speed-value", fallback: "Playback Speed · %@", formatPlaybackSpeed(state.playerSnapshot.speed))) {
                ForEach(speeds, id: \.self) { speed in
                    Button(formatPlaybackSpeed(speed)) {
                        Task { await state.setPlayerSpeed(speed) }
                    }
                }
            }

            Divider()

            Menu(L10n.string("player.aspect-ratio", fallback: "Aspect Ratio")) {
                Button(L10n.string("common.automatic", fallback: "Automatic")) {
                    Task { await state.setPlayerAspectRatio(nil) }
                }
                ForEach(["16:9", "4:3", "2.35:1"], id: \.self) { ratio in
                    Button(ratio) {
                        Task { await state.setPlayerAspectRatio(ratio) }
                    }
                }
            }
            Button(
                state.playerHardwareDecoding
                    ? L10n.string("player.hardware-decoding.disable", fallback: "Disable Hardware Decoding")
                    : L10n.string("player.hardware-decoding.enable", fallback: "Enable Hardware Decoding")
            ) {
                Task { await state.togglePlayerHardwareDecoding() }
            }
            Divider()
            Group {
                Button(L10n.string("player.audio-earlier", fallback: "Audio 0.1 Seconds Earlier")) {
                    Task { await state.adjustPlayerAudioDelay(by: -0.1) }
                }
                Button(L10n.string("player.audio-later", fallback: "Audio 0.1 Seconds Later")) {
                    Task { await state.adjustPlayerAudioDelay(by: 0.1) }
                }
                Text(L10n.string("player.audio-delay-value", fallback: "Audio Delay %.1f sec", state.playerAudioDelay))
            }

            Divider()

            Button(L10n.string("player.save-screenshot", fallback: "Save Screenshot…")) {
                chooseScreenshotLocation()
            }
        } label: {
            utilityMenuIcon("gearshape")
        }
        .playerUtilityMenuStyle()
        .fixedSize()
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .playerControlHelp(L10n.string("player.settings", fallback: "Playback Settings"))
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
        panel.title = L10n.string("player.choose-subtitle", fallback: "Choose Subtitles")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await state.addPlayerSubtitle(url) }
        }
    }

    private func chooseDanmakuXML() {
        let panel = NSOpenPanel()
        panel.title = "选择 Bilibili XML 弹幕"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["xml"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            state.danmaku.importXML(from: url)
        }
    }

    private func chooseScreenshotLocation() {
        let panel = NSSavePanel()
        panel.title = L10n.string("player.save-screenshot.title", fallback: "Save Playback Screenshot")
        panel.nameFieldStringValue = "OKVideoMac-Screenshot.png"
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "webp"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await state.savePlayerScreenshot(to: url) }
        }
    }
}

struct LivePlayerOverlayMetrics: Equatable {
    let scale: CGFloat

    init(viewportSize: CGSize) {
        let widthScale = viewportSize.width / 1_280
        let heightScale = viewportSize.height / 720
        scale = min(max(min(widthScale, heightScale), 0.80), 1.10)
    }

    var controlDiameter: CGFloat { max(34, 40 * scale) }
    var primaryIconSize: CGFloat { max(18, 20 * scale) }
    var secondaryIconSize: CGFloat { max(17, 19 * scale) }
    var liveIconSize: CGFloat { max(18, 21 * scale) }
    var liveDotDiameter: CGFloat { max(5, 6 * scale) }
    var controlSpacing: CGFloat { max(9, 12 * scale) }
    var volumeSliderWidth: CGFloat { max(76, 92 * scale) }
    var volumePopoverSpacing: CGFloat { max(7, 9 * scale) }
    var volumePopoverHorizontalPadding: CGFloat { max(9, 11 * scale) }
    var volumePopoverVerticalPadding: CGFloat { max(6, 7 * scale) }
    var outerHorizontalPadding: CGFloat { max(18, 26 * scale) }
    var outerBottomPadding: CGFloat { max(16, 24 * scale) }
    var minimumTopSpace: CGFloat { max(40, 64 * scale) }
    var minimumControlSeparation: CGFloat { max(36, 52 * scale) }
}

enum PlayerEpisodeOriginalNamePresentationMode: Equatable {
    case panelInspector
}

struct PlayerEpisodeGrid: View, Equatable {
    let presentations: [EpisodePresentation]
    let selectedEpisodeID: String?
    let accentColor: Color
    let displayName: (EpisodePresentation) -> String
    let onPlay: (EpisodePresentation) -> Void
    let onInspect: (EpisodePresentation) -> Void
    var selectionEnabled = true
    var canRetrySelected = false
    var locateRevision = 0
    var selectionSessionID: UUID? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentations == rhs.presentations
            && lhs.selectedEpisodeID == rhs.selectedEpisodeID
            && lhs.selectionEnabled == rhs.selectionEnabled
            && lhs.canRetrySelected == rhs.canRetrySelected
            && lhs.locateRevision == rhs.locateRevision
            && lhs.selectionSessionID == rhs.selectionSessionID
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: presentations.contains { $0.episodeNumber == nil } ? 150 : 110),
                        spacing: 8
                    )
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(presentations) { presentation in
                    let selected = presentation.id == selectedEpisodeID
                    PlayerEpisodeButton(
                        presentation: presentation,
                        displayName: displayName(presentation),
                        selected: selected,
                        accentColor: accentColor,
                        onPlay: {
                            guard !selected || canRetrySelected else { return }
                            onPlay(presentation)
                        },
                        onInspect: { onInspect(presentation) }
                    )
                    .id(presentation.id)
                    .disabled(!selectionEnabled)
                }
            }
        }
        .task(id: "\(selectedEpisodeID ?? "")/\(locateRevision)/\(presentations.first?.id ?? "")") {
            await Task.yield()
            guard !Task.isCancelled, let selectedEpisodeID,
                  presentations.contains(where: { $0.id == selectedEpisodeID }) else { return }
            proxy.scrollTo(selectedEpisodeID, anchor: .center)
        }
        }
    }
}

struct PlayerEpisodeButton: View {
    let presentation: EpisodePresentation
    let displayName: String
    let selected: Bool
    let accentColor: Color
    let onPlay: () -> Void
    let onInspect: () -> Void
    let originalNamePresentationMode: PlayerEpisodeOriginalNamePresentationMode = .panelInspector

    var body: some View {
        Button(action: onPlay) {
            VStack(spacing: 4) {
                Text(presentation.episodeNumber.map { L10n.string("episode.number", fallback: "Episode %d", $0) } ?? displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                let labels = PlaybackResourceAnalyzer.analyze(presentation.episode).versionLabels
                if !labels.isEmpty {
                    Text(labels.joined(separator: " · ")).font(.system(size: 10)).lineLimit(1)
                }

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundColor(.white.opacity(selected ? 1 : 0.92))
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(
                selected
                    ? accentColor.opacity(0.58)
                    : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(selected ? 0.16 : 0.08))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.string("detail.original-name.view-short", fallback: "View Original Name")) {
                // Defer the state mutation until AppKit has dismissed the
                // context menu. This keeps the inspector transition stable.
                DispatchQueue.main.async(execute: onInspect)
            }

            Button(L10n.string("detail.original-name.copy", fallback: "Copy Original Name")) {
                PlayerEpisodeOriginalNameActions.copy(
                    presentation.originalName
                )
            }
        }
        .help(presentation.originalName)
        .accessibilityLabel(displayName + (selected ? " · " + L10n.string("player.episode.current", fallback: "Currently Playing") : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(L10n.string("detail.original-name.hint", fallback: "Right-click to view or copy the original name"))
    }
}

enum PlayerEpisodeOriginalNameActions {
    static func copy(
        _ originalName: String,
        to pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(originalName, forType: .string)
    }
}

struct PlayerEpisodeOriginalNameInspector: View {
    let originalName: String
    let onClose: () -> Void
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label(L10n.string("detail.file-info", fallback: "File Information"), systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.94))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.62))
                .playerControlHelp(L10n.string("detail.file-info.close", fallback: "Close File Information"))
            }

            Text(L10n.string("detail.original-name", fallback: "Original Name"))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))

            ScrollView(.vertical, showsIndicators: true) {
                Text(originalName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 34, maxHeight: 64)
            .background(
                Color.black.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )

            HStack {
                Button {
                    PlayerEpisodeOriginalNameActions.copy(originalName)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        didCopy = false
                    }
                } label: {
                    Label(
                        didCopy
                            ? L10n.string("common.copied", fallback: "Copied")
                            : L10n.string("detail.copy-name", fallback: "Copy Name"),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text(L10n.string("player.original-name.hint", fallback: "Right-click an episode to view or copy its original name"))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(10)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.09))
        }
    }
}

enum PlayerEpisodePanelLayoutPolicy {
    static func gridHeight(
        episodeCount: Int,
        showsInspector: Bool,
        width: CGFloat = 472,
        minimumCellWidth: CGFloat = 110
    ) -> CGFloat {
        let columns = max(1, Int((width + 8) / (minimumCellWidth + 8)))
        let rowCount = Int(ceil(Double(max(episodeCount, 1)) / Double(columns)))
        let regularHeight = min(286, max(62, CGFloat(rowCount) * 70 - 8))
        return showsInspector ? min(regularHeight, 196) : regularHeight
    }
}

enum PlayerEpisodePagePolicy {
    static let pageSize = 50

    static func pageCount(episodeCount: Int) -> Int {
        guard episodeCount > 0 else { return 0 }
        return Int(ceil(Double(episodeCount) / Double(pageSize)))
    }

    static func clampedPageIndex(
        _ pageIndex: Int,
        episodeCount: Int
    ) -> Int {
        let count = pageCount(episodeCount: episodeCount)
        guard count > 0 else { return 0 }
        return min(max(pageIndex, 0), count - 1)
    }

    static func pages(_ presentations: [EpisodePresentation]) -> [[EpisodePresentation]] {
        var pages: [[EpisodePresentation]] = []
        for value in presentations {
            if let last = pages.last, let first = last.first,
               last.count < pageSize, first.seasonNumber == value.seasonNumber,
               (first.episodeNumber == nil) == (value.episodeNumber == nil) {
                pages[pages.count - 1].append(value)
            } else { pages.append([value]) }
        }
        return pages
    }
    static func page(_ presentations: [EpisodePresentation], pageIndex: Int) -> [EpisodePresentation] {
        let values = pages(presentations)
        return values.isEmpty ? [] : values[min(max(0, pageIndex), values.count - 1)]
    }
    static func pageIndex(presentations: [EpisodePresentation], selectedEpisodeID: String?) -> Int {
        pages(presentations).firstIndex { $0.contains { $0.id == selectedEpisodeID } } ?? 0
    }

    static func title(
        presentations: [EpisodePresentation],
        pageIndex: Int
    ) -> String {
        let values = page(presentations, pageIndex: pageIndex)
        guard let first = values.first, let last = values.last else {
            return L10n.string("player.no-episodes", fallback: "No Episodes")
        }
        if let firstNumber = first.episodeNumber,
           let lastNumber = last.episodeNumber {
            if let season = first.seasonNumber {
                return L10n.string("episode.range.season", fallback: "Season %d · Episodes %d–%d", season, firstNumber, lastNumber)
            }
            return L10n.string("episode.range", fallback: "Episodes %d–%d", firstNumber, lastNumber)
        }
        let safeIndex = clampedPageIndex(
            pageIndex,
            episodeCount: presentations.count
        )
        let start = (presentations.firstIndex { $0.id == first.id } ?? safeIndex * pageSize) + 1
        let end = start + values.count - 1
        return L10n.string("player.item-range", fallback: "Items %d–%d", start, end)
    }
}

private enum PlayerUtilityPanel: Equatable {
    case episodes
    case audio
    case subtitles
    case danmaku
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

/// ScrollView normally accepts all proposed height. Measure its natural
/// content instead so short panels hug their controls and long ones scroll.
struct PlayerUtilityPanelContent<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PlayerUtilityPanelHeightKey.self,
                                           value: geometry.size.height)
                })
        }
        .frame(height: min(maximumHeight, max(1, contentHeight)), alignment: .top)
        .onPreferenceChange(PlayerUtilityPanelHeightKey.self) { height in
            if height.isFinite, height > 0, abs(height - contentHeight) > 0.5 {
                contentHeight = height
            }
        }
    }
}

private struct PlayerUtilityPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PlayerTitleView: View {
    let title: String
    let episode: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
            if let episode, !episode.isEmpty {
                Text("· " + episode)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 180)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .foregroundColor(.white.opacity(0.94))
        .frame(maxWidth: 760)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

struct PlayerOverlayLayout {
    enum Mode { case expanded, compactVolume, compactTools, stacked }
    let viewportSize: CGSize
    var timeLabelWidth: CGFloat = 106
    static let transportWidth: CGFloat = 216
    var horizontalInset: CGFloat { 18 + max(0, viewportSize.width - 800) * 0.05 }
    var controlWidth: CGFloat { max(1, viewportSize.width - horizontalInset * 2) }
    var bottomInset: CGFloat { min(36, max(20, viewportSize.height * 0.025)) }
    var innerWidth: CGFloat { max(1, controlWidth - 24) }
    var sideWidth: CGFloat { max(0, (innerWidth - Self.transportWidth - 24) / 2) }
    var mode: Mode {
        if sideWidth >= max(243, 121 + 10 + timeLabelWidth) { return .expanded }
        if sideWidth >= max(243, 38 + 10 + timeLabelWidth) { return .compactVolume }
        if sideWidth >= max(79, 38 + 10 + timeLabelWidth) { return .compactTools }
        return .stacked
    }
    var showsAllTools: Bool { mode == .expanded || mode == .compactVolume }
    var isCompact: Bool { mode != .expanded }
    var panelBottomInset: CGFloat { bottomInset + (mode == .stacked ? 138 : 93) }
    var panelTrailingInset: CGFloat { max(18, (viewportSize.width - controlWidth) / 2) }
    var panelMaximumSize: CGSize {
        CGSize(width: max(1, controlWidth), height: max(1, min(560, viewportSize.height - panelBottomInset - 24)))
    }
    static func timeWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]).width) + 2
    }
}

/// Equal side columns keep transport centered even with long timestamps.
/// The narrowest mode places transport on its own row before any overlap.
struct PlayerControlRow<Leading: View, Transport: View, Trailing: View>: View {
    let layout: PlayerOverlayLayout
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let transport: () -> Transport
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if layout.mode == .stacked {
            VStack(spacing: 5) {
                transport().frame(width: PlayerOverlayLayout.transportWidth)
                HStack(spacing: 12) {
                    leading()
                    Spacer(minLength: 12)
                    trailing()
                }
            }
        } else {
            HStack(spacing: 12) {
                leading().frame(width: layout.sideWidth, alignment: .leading)
                transport().frame(width: PlayerOverlayLayout.transportWidth)
                trailing().frame(width: layout.sideWidth, alignment: .trailing)
            }
        }
    }
}

enum PlayerControlVisibilityPolicy {
    static func shouldAutoHide(
        isLivePlayback: Bool,
        controlsHovering: Bool,
        isFailed: Bool,
        keepsControlsVisible: Bool = false,
        isPlaying: Bool
    ) -> Bool {
        guard !isFailed, !keepsControlsVisible else { return false }
        // A live picture should return to a clean, cursor-free surface even
        // when the pointer is parked over a card or control. Only real mouse
        // movement should reveal the overlay again.
        if isLivePlayback { return true }
        return !controlsHovering && isPlaying
    }
}

enum PlayerActivityOverlayPolicy {
    /// Avoid flashing an indicator for seeks that complete within one or two
    /// rendered frames, while still acknowledging a real network/decoder wait.
    static let presentationDelayNanoseconds: UInt64 = 200_000_000

    static func isActive(snapshot: PlayerSnapshot) -> Bool {
        if snapshot.isSeeking || snapshot.isPausedForCache {
            return true
        }
        if case .buffering = snapshot.status {
            return true
        }
        return false
    }
}

enum LiveLoadingPresentationPolicy {
    static let delayNanoseconds: UInt64 = 600_000_000
    static let slowDelayNanoseconds: UInt64 = 5_000_000_000
    static func isWaiting(snapshot: PlayerSnapshot, recovering: Bool, exhausted: Bool, hasStarted: Bool = true) -> Bool {
        if exhausted { return false }
        if recovering { return true }
        switch snapshot.status {
        case .loading, .buffering: return true
        case .paused, .failed, .ended, .stopped: return false
        default: return !hasStarted || snapshot.isPausedForCache
        }
    }
}

enum LiveSwitchLoadingIndicatorPolicy {
    static func shouldKeepPreviousFrameClean(
        isLivePlayback: Bool,
        holdsPreviousFrame: Bool,
        status: PlayerStatus,
        elapsed: TimeInterval = 0
    ) -> Bool {
        guard isLivePlayback, holdsPreviousFrame, elapsed < 0.6 else { return false }
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
    enum MouseDownAction: Equatable {
        case performDoubleClick
        case ignore
    }

    static func action(
        clickCount: Int,
        buttonNumber: Int
    ) -> MouseDownAction {
        guard buttonNumber == 0 else { return .ignore }
        switch clickCount {
        case 2:
            return .performDoubleClick
        default:
            return .ignore
        }
    }

    static func togglesFullScreen(
        clickCount: Int,
        buttonNumber: Int
    ) -> Bool {
        action(
            clickCount: clickCount,
            buttonNumber: buttonNumber
        ) == .performDoubleClick
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
        switch PlayerSurfaceGesture.action(
            clickCount: event.clickCount,
            buttonNumber: event.buttonNumber
        ) {
        case .performDoubleClick:
            onDoubleClick?()
        case .ignore:
            break
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
    var onTransitionChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onRestore: onRestore,
            onFullScreenChange: onFullScreenChange,
            onTransitionChange: onTransitionChange
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
        context.coordinator.onTransitionChange = onTransitionChange
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
        @MainActor
        private final class WindowLifetime {
            var isClosing = false
            let id = UUID()
        }

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
        private var contentAspectRatio = NSSize.zero
        private var closeButtonWasHidden = false
        private var miniaturizeButtonWasHidden = false
        private var zoomButtonWasHidden = false
        private var desiredConfiguration: AppliedConfiguration?
        private var appliedConfiguration: AppliedConfiguration?
        private let configurationKey = UUID()
        private var hasAppliedStaticChrome = false
        private var fullScreenObservers: [NSObjectProtocol] = []
        private var liveResizeObserver: NSObjectProtocol?
        private var windowWillCloseObserver: NSObjectProtocol?
        private var windowLifetime: WindowLifetime?
        var onRestore: () -> Void
        var onFullScreenChange: (Bool) -> Void
        var onTransitionChange: (Bool) -> Void

        init(
            onRestore: @escaping () -> Void,
            onFullScreenChange: @escaping (Bool) -> Void = { _ in },
            onTransitionChange: @escaping (Bool) -> Void = { _ in }
        ) {
            self.onRestore = onRestore
            self.onFullScreenChange = onFullScreenChange
            self.onTransitionChange = onTransitionChange
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else {
                restore()
                return
            }
            guard window !== newWindow else { return }
            restore()
            window = newWindow
            let lifetime = WindowLifetime()
            windowLifetime = lifetime
            WindowTransitionCoordinator.state(for: newWindow).chromeOwner = lifetime.id
            hasAppliedStaticChrome = false
            observeFullScreenChanges(for: newWindow)
            observeLiveResizeEnd(for: newWindow)
            observeWindowWillClose(for: newWindow, lifetime: lifetime)
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
                  windowLifetime?.isClosing != true,
                  desiredConfiguration == configuration else {
                return
            }
            let transition = WindowTransitionCoordinator.state(for: window)
            guard transition.canApplyChrome,
                  transition.chromeOwner == windowLifetime?.id else { return }

            // Static chrome belongs to the window lifetime, not the control
            // overlay's visibility. Configure it only in stable windowed mode.
            if !hasAppliedStaticChrome && transition.canChangeGeometry {
                Self.withPreservedOuterFrame(of: window) {
                    if !window.styleMask.contains(.fullSizeContentView) {
                        window.styleMask.insert(.fullSizeContentView)
                    }
                    if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
                    if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
                    if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
                    if window.backgroundColor != .black { window.backgroundColor = .black }
                    if !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }
                    if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
                }
                hasAppliedStaticChrome = true
            }
            if window.title != configuration.title { window.title = configuration.title }
            let movable = !configuration.controlsVisible
            if window.isMovableByWindowBackground != movable {
                window.isMovableByWindowBackground = movable
            }
            if configuration.controlsVisible {
                restoreStandardWindowButtonVisibility(on: window)
            } else {
                setStandardWindowButtonsHidden(true, on: window)
            }

            if let ratio = configuration.videoAspectRatio,
               (!Self.aspectRatiosMatch(
                    appliedConfiguration?.videoAspectRatio,
                    ratio
               ) || !Self.aspectRatiosMatch(
                    window.contentAspectRatio,
                    ratio
               )) {
                Self.applyAspectRatio(ratio, to: window)
            }
            appliedConfiguration = configuration
            Self.markWindowForRefresh(
                window,
                lifetime: windowLifetime
            )
        }

        func restore() {
            guard let window else { return }
            WindowTransitionCoordinator.state(for: window).cancel(configurationKey)
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
            let savedContentAspectRatio = contentAspectRatio
            let savedCloseButtonWasHidden = closeButtonWasHidden
            let savedMiniaturizeButtonWasHidden = miniaturizeButtonWasHidden
            let savedZoomButtonWasHidden = zoomButtonWasHidden
            let lifetime = windowLifetime
            let willCloseObserver = windowWillCloseObserver
            desiredConfiguration = nil
            appliedConfiguration = nil
            self.window = nil
            windowLifetime = nil
            windowWillCloseObserver = nil

            // NSViewRepresentable update/dismantle callbacks can run inside a
            // SwiftUI layout transaction. Forcing synchronous layout or display
            // here re-enters that transaction and has produced repeatable
            // swift_beginAccess crashes. Mark the window dirty on the next run
            // loop instead and let AppKit own the display cycle.
            let onRestore = self.onRestore
            Self.restoreWhenWindowIsStable(
                    window,
                    lifetime: lifetime
                ) { window in
                    defer {
                        if let willCloseObserver {
                            NotificationCenter.default.removeObserver(
                                willCloseObserver
                            )
                        }
                    }
                    guard let window,
                          WindowTransitionCoordinator.state(for: window).chromeOwner == lifetime?.id else {
                        onRestore()
                        return
                    }
                    WindowTransitionCoordinator.state(for: window).chromeOwner = nil
                    Self.withPreservedOuterFrame(of: window) {
                        if savedHadFullSizeContentView != window.styleMask.contains(.fullSizeContentView) {
                            if savedHadFullSizeContentView {
                                window.styleMask.insert(.fullSizeContentView)
                            } else {
                                window.styleMask.remove(.fullSizeContentView)
                            }
                        }
                        window.titlebarAppearsTransparent =
                            savedTitlebarAppearsTransparent
                        window.titleVisibility = savedTitleVisibility
                        if let savedToolbarWasVisible {
                            window.toolbar?.isVisible = savedToolbarWasVisible
                        }
                        if let savedBackgroundColor {
                            window.backgroundColor = savedBackgroundColor
                        }
                        window.isMovableByWindowBackground =
                            savedIsMovableByWindowBackground
                        window.acceptsMouseMovedEvents =
                            savedAcceptsMouseMovedEvents
                        window.titlebarSeparatorStyle =
                            savedTitlebarSeparatorStyle
                        window.title = savedWindowTitle
                        window.contentAspectRatio = savedContentAspectRatio
                        window.standardWindowButton(.closeButton)?.isHidden =
                            savedCloseButtonWasHidden
                        window.standardWindowButton(
                            .miniaturizeButton
                        )?.isHidden = savedMiniaturizeButtonWasHidden
                        window.standardWindowButton(.zoomButton)?.isHidden =
                            savedZoomButtonWasHidden
                    }
                    Self.markWindowForRefresh(window, lifetime: lifetime)
                    onRestore()
                }
        }

        private static func withPreservedOuterFrame(
            of window: NSWindow,
            mutations: () -> Void
        ) {
            guard WindowTransitionCoordinator.state(for: window).canChangeGeometry else { return }
            let outerFrame = window.frame
            mutations()
            guard !window.styleMask.contains(.fullScreen),
                  !window.inLiveResize,
                  window.frame != outerFrame else { return }
            // Toolbar/titlebar mutations can ask AppKit to preserve the old
            // content size by changing the outer frame. Restore the frame from
            // this same stable transaction; it is the user's current frame,
            // never a pre-playback frame or a video-derived aspect ratio.
            window.setFrame(outerFrame, display: false)
        }

        private static func aspectRatiosMatch(
            _ lhs: Double?,
            _ rhs: Double
        ) -> Bool {
            guard let lhs, lhs.isFinite, lhs > 0 else { return false }
            return abs(lhs - rhs) < 0.0001
        }

        private static func aspectRatiosMatch(
            _ lhs: NSSize,
            _ rhs: Double
        ) -> Bool {
            guard lhs.width.isFinite,
                  lhs.height.isFinite,
                  lhs.width > 0,
                  lhs.height > 0 else { return false }
            return abs(Double(lhs.width / lhs.height) - rhs) < 0.0001
        }

        private static func applyAspectRatio(
            _ aspectRatio: Double,
            to window: NSWindow
        ) {
            guard aspectRatio.isFinite,
                  aspectRatio > 0,
                  WindowTransitionCoordinator.state(for: window).canChangeGeometry else { return }
            // An episode or route can publish dimensions after playback has
            // already started. Only update the constraint used for future
            // manual resizes; never move or resize the current outer frame.
            // mpv letterboxes the media inside the unchanged viewport.
            window.contentAspectRatio = NSSize(
                width: aspectRatio,
                height: 1
            )
        }

        private static func restoreWhenWindowIsStable(
            _ window: NSWindow?,
            lifetime: WindowLifetime?,
            completion: @escaping (NSWindow?) -> Void
        ) {
            guard let window,
                  lifetime?.isClosing != true else {
                completion(nil)
                return
            }
            WindowTransitionCoordinator.state(for: window).whenStable(
                key: UUID(), windowedOnly: true
            ) { stableWindow in
                completion(lifetime?.isClosing == true ? nil : stableWindow)
            }
        }

        private func scheduleWindowConfiguration(
            _ configuration: AppliedConfiguration,
            for window: NSWindow
        ) {
            WindowTransitionCoordinator.state(for: window).whenStable(key: configurationKey) {
                [weak self] stableWindow in
                guard let self, let stableWindow else { return }
                self.apply(configuration, to: stableWindow)
            }
        }

        private func setStandardWindowButtonsHidden(_ hidden: Bool, on window: NSWindow) {
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind), button.isHidden != hidden {
                    button.isHidden = hidden
                }
            }
        }

        private func restoreStandardWindowButtonVisibility(on window: NSWindow) {
            let states: [(NSWindow.ButtonType, Bool)] = [
                (.closeButton, closeButtonWasHidden), (.miniaturizeButton, miniaturizeButtonWasHidden),
                (.zoomButton, zoomButtonWasHidden)
            ]
            for (kind, hidden) in states {
                if let button = window.standardWindowButton(kind), button.isHidden != hidden {
                    button.isHidden = hidden
                }
            }
        }

        private func observeFullScreenChanges(for window: NSWindow) {
            removeFullScreenObservers()
            let center = NotificationCenter.default
            for name in [
                NSWindow.willEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                WindowTransitionCoordinator.didFailFullScreen
            ] {
                fullScreenObservers.append(
                    center.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self, weak window] note in
                        MainActor.assumeIsolated {
                            guard let self,
                                  let window,
                                  self.window === window else { return }
                            let transitioning = note.name == NSWindow.willEnterFullScreenNotification || note.name == NSWindow.willExitFullScreenNotification
                            self.onTransitionChange(transitioning)
                            if transitioning { return }
                            self.onFullScreenChange(
                                window.styleMask.contains(.fullScreen)
                            )
                            if let configuration = self.desiredConfiguration {
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

        private func observeWindowWillClose(
            for window: NSWindow,
            lifetime: WindowLifetime
        ) {
            if let windowWillCloseObserver {
                NotificationCenter.default.removeObserver(
                    windowWillCloseObserver
                )
            }
            windowWillCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak lifetime] _ in
                MainActor.assumeIsolated {
                    lifetime?.isClosing = true
                }
            }
        }

        private static func markWindowForRefresh(
            _ window: NSWindow?,
            lifetime: WindowLifetime?
        ) {
            guard let window,
                  lifetime?.isClosing != true,
                  WindowTransitionCoordinator.state(for: window).canApplyChrome,
                  let contentView = window.contentView else { return }
            // AppKit performs layout and invokes reshape on the actual surface.
            // Never synchronously lay out the SwiftUI tree from a chrome update.
            contentView.needsDisplay = true
            window.invalidateCursorRects(for: contentView)
        }

    }
}

enum PlayerWindowAspectPolicy {
    static func aspectRatio(
        isLivePlayback: Bool,
        override: String?,
        videoWidth: Int,
        videoHeight: Int
    ) -> Double? {
        if let override,
           let ratio = parsedAspectRatio(override) {
            return ratio
        }
        guard videoWidth > 0, videoHeight > 0 else { return nil }
        let ratio = Double(videoWidth) / Double(videoHeight)
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

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
        let maximumWidth = min(maximum.width, maximum.height * ratio)
        guard maximumWidth.isFinite, maximumWidth > 0 else { return nil }
        let minimumWidth = min(
            max(minimum.width, minimum.height * ratio),
            maximumWidth
        )

        func candidate(width: CGFloat) -> NSSize {
            let boundedWidth = min(max(width, minimumWidth), maximumWidth)
            return NSSize(
                width: boundedWidth,
                height: boundedWidth / ratio
            )
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

    private static func parsedAspectRatio(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0 else { return nil }
        return width / height
    }
}

struct PlayerProgressTrackAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// Draw outside the controls' hierarchy: panel/background clipping cannot cut
/// off the timestamp. The track anchor also survives window/fullscreen resize.
struct PlayerProgressPreviewOverlay: ViewModifier {
    let fraction: Double?
    let text: String?
    static let height: CGFloat = 28
    static func width(for text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        ]).width) + 20
    }
    static func rect(track: CGRect, viewport: CGSize, fraction: Double, text: String) -> CGRect {
        let width = min(Self.width(for: text), max(1, viewport.width - 16))
        let x = track.minX + PlayerProgressHoverPolicy.tooltipCenterX(fraction: fraction,
            width: track.width, tooltipWidth: width)
        return CGRect(x: min(max(x - width / 2, 8), max(8, viewport.width - width - 8)),
            y: max(8, track.minY - height - 8), width: width, height: height)
    }
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PlayerProgressTrackAnchorKey.self) { anchor in
            GeometryReader { geometry in
                if let anchor, let fraction, let text {
                    let rect = Self.rect(track: geometry[anchor], viewport: geometry.size, fraction: fraction, text: text)
                    Text(text)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .frame(width: rect.width, height: rect.height)
                        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityHidden(true)
                        .transaction { $0.disablesAnimations = true }
                }
            }.allowsHitTesting(false)
        }
    }
}

enum PlayerProgressHoverPolicy {
    static func fraction(x: CGFloat, width: CGFloat) -> Double? {
        guard width.isFinite, width > 0, x.isFinite else { return nil }
        return PlayerTimelinePolicy.fraction(x: x, width: width, horizontalInset: 6)
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

enum PlayerTimelinePolicy {
    static func fraction(value: Double, total: Double) -> Double {
        guard value.isFinite,
              total.isFinite,
              total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    static func bufferedFraction(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(1, max(0, percent / 100))
    }

    static func value(fraction: Double, total: Double) -> Double {
        guard fraction.isFinite,
              total.isFinite,
              total > 0 else { return 0 }
        return min(1, max(0, fraction)) * total
    }

    static func fraction(
        x: CGFloat,
        width: CGFloat,
        horizontalInset: CGFloat
    ) -> Double {
        guard x.isFinite,
              width.isFinite,
              horizontalInset.isFinite else { return 0 }
        let inset = min(max(horizontalInset, 0), max(width / 2, 0))
        let trackWidth = width - (inset * 2)
        guard trackWidth > 0 else { return 0 }
        return min(1, max(0, Double((x - inset) / trackWidth)))
    }
}

struct PlayerTimelineControl: View {
    @Binding var value: Double
    let total: Double
    let bufferedPercent: Double
    let accentColor: Color
    let isEmphasized: Bool
    let onEditingChanged: (Bool) -> Void

    @State private var isEditing = false

    private let thumbDiameter: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let playedFraction = PlayerTimelinePolicy.fraction(
                value: value,
                total: total
            )
            let bufferedFraction = PlayerTimelinePolicy.bufferedFraction(
                percent: bufferedPercent
            )
            let horizontalInset = thumbDiameter / 2
            let trackWidth = max(geometry.size.width - thumbDiameter, 0)
            let trackHeight: CGFloat = isEmphasized ? 5 : 3
            let playedWidth = trackWidth * CGFloat(playedFraction)
            let bufferedWidth = trackWidth * CGFloat(bufferedFraction)
            let thumbX = horizontalInset + playedWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: trackWidth, height: trackHeight)
                    .offset(x: horizontalInset)

                Capsule()
                    .fill(Color.white.opacity(0.40))
                    .frame(width: bufferedWidth, height: trackHeight)
                    .offset(x: horizontalInset)

                Capsule()
                    .fill(accentColor)
                    .frame(width: playedWidth, height: trackHeight)
                    .offset(x: horizontalInset)

                Circle()
                    .fill(Color.white)
                    .overlay {
                        Circle()
                            .stroke(accentColor.opacity(0.82), lineWidth: 1.5)
                    }
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.48), radius: 2, y: 1)
                    .position(x: thumbX, y: geometry.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        let fraction = PlayerTimelinePolicy.fraction(
                            x: gesture.location.x,
                            width: geometry.size.width,
                            horizontalInset: horizontalInset
                        )
                        value = PlayerTimelinePolicy.value(
                            fraction: fraction,
                            total: total
                        )
                    }
                    .onEnded { _ in
                        finishEditing()
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string("history.playback-progress", fallback: "Playback Progress"))
        .accessibilityValue(
            "\(Int((PlayerTimelinePolicy.fraction(value: value, total: total) * 100).rounded()))%"
        )
        .accessibilityAdjustableAction { direction in
            let step = min(max(total * 0.01, 5), 30)
            switch direction {
            case .increment:
                adjustValue(by: step)
            case .decrement:
                adjustValue(by: -step)
            @unknown default:
                break
            }
        }
        .onDisappear {
            finishEditing()
        }
    }

    private func adjustValue(by offset: Double) {
        onEditingChanged(true)
        value = min(max(value + offset, 0), max(total, 0))
        onEditingChanged(false)
    }

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        onEditingChanged(false)
    }
}

struct ProgressHoverTrackingView: NSViewRepresentable {
    let isEnabled: Bool
    let revision: Int
    let onFractionChange: (Double?) -> Void

    func makeNSView(context: Context) -> ProgressHoverTrackingNSView {
        let view = ProgressHoverTrackingNSView()
        view.configure(enabled: isEnabled, revision: revision, onChange: onFractionChange)
        return view
    }

    func updateNSView(_ view: ProgressHoverTrackingNSView, context: Context) {
        view.configure(enabled: isEnabled, revision: revision, onChange: onFractionChange)
    }

    static func dismantleNSView(_ view: ProgressHoverTrackingNSView, coordinator: ()) {
        view.detach()
    }
}

/// Tracks the same rectangular interaction area as the timeline's drag gesture.
/// Reconciles the current pointer rather than trusting queued enter/exit pairs.
class ProgressHoverTrackingNSView: NSView {
    private var onFractionChange: ((Double?) -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    private var revision = 0
    private var publicationRevision = 0
    private var lastFraction: Double?
    private var transitioning = false
    private var waitingForMovement = false

    // Overridable input seams let AppKit lifecycle tests use a deterministic
    // pointer and focus without moving the user's actual cursor.
    var pointerInWindow: NSPoint? { window?.mouseLocationOutsideOfEventStream }
    var isTrackingWindowActive: Bool { window?.isKeyWindow == true }

    func configure(enabled: Bool, revision: Int, onChange: @escaping (Double?) -> Void) {
        onFractionChange = onChange
        let changed = self.enabled != enabled || self.revision != revision
        if self.revision != revision { waitingForMovement = true }
        self.enabled = enabled
        self.revision = revision
        if changed { scheduleReconciliation() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        transitioning = false
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         WindowTransitionCoordinator.didFailFullScreen] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if note.name == NSWindow.willEnterFullScreenNotification || note.name == NSWindow.willExitFullScreenNotification {
                            self.transitioning = true
                        } else if note.name == NSWindow.didEnterFullScreenNotification || note.name == NSWindow.didExitFullScreenNotification || note.name == WindowTransitionCoordinator.didFailFullScreen {
                            self.transitioning = false
                        }
                        self.scheduleReconciliation()
                    }
                })
            }
            // A local monitor also observes movement outside the narrow track,
            // including mouse-up after a drag. It never consumes input events.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.pointerDidMove()
                }
                return event
            }
        }
        scheduleReconciliation()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
        scheduleReconciliation()
    }

    override func mouseEntered(with event: NSEvent) { pointerDidMove() }
    override func mouseMoved(with event: NSEvent) { pointerDidMove() }
    override func mouseExited(with event: NSEvent) { pointerDidMove() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func pointerDidMove() {
        waitingForMovement = false
        scheduleReconciliation()
    }

    func scheduleReconciliation() {
        publicationRevision &+= 1
        let ticket = publicationRevision
        // AppKit may invoke updateTrackingAreas during SwiftUI layout. Publish
        // after that pass, and discard work queued for old geometry/lifetimes.
        DispatchQueue.main.async { [weak self] in
            guard let self, ticket == self.publicationRevision else { return }
            let fraction = self.currentFraction()
            guard fraction != self.lastFraction else { return }
            self.lastFraction = fraction
            self.onFractionChange?(fraction)
        }
    }

    private func currentFraction() -> Double? {
        guard enabled, !transitioning, !waitingForMovement,
              window != nil, isTrackingWindowActive, !isHiddenOrHasHiddenAncestor,
              let location = pointerInWindow else { return nil }
        let point = convert(location, from: nil)
        guard bounds.contains(point), visibleRect.contains(point) else { return nil }
        return PlayerProgressHoverPolicy.fraction(x: point.x - bounds.minX, width: bounds.width)
    }

    func detach() {
        enabled = false
        scheduleReconciliation()
        removeObservers()
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}

final class PlayerControlTooltipState: ObservableObject {
    @Published private(set) var activeID: UUID?
    private var candidateID: UUID?
    private var pending: Task<Void, Never>?
    private var enabled = true
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 350_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func hover(_ id: UUID, inside: Bool) {
        guard inside else {
            if candidateID == id { dismiss() }
            return
        }
        guard enabled, candidateID != id else { return }
        dismiss()
        candidateID = id
        pending = Task { @MainActor [weak self, delayNanoseconds] in
            do { try await Task.sleep(nanoseconds: delayNanoseconds) }
            catch { return }
            guard let self, !Task.isCancelled, self.enabled, self.candidateID == id else { return }
            self.activeID = id
            self.pending = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { dismiss() }
    }

    func dismiss() {
        pending?.cancel(); pending = nil
        candidateID = nil; activeID = nil
    }
    deinit { pending?.cancel() }
}

private struct PlayerControlTooltipEnvironmentKey: EnvironmentKey {
    static let defaultValue: PlayerControlTooltipState? = nil
}

private extension EnvironmentValues {
    var playerControlTooltip: PlayerControlTooltipState? {
        get { self[PlayerControlTooltipEnvironmentKey.self] }
        set { self[PlayerControlTooltipEnvironmentKey.self] = newValue }
    }
}

private struct PlayerControlTooltipAnchor {
    let title: String
    let bounds: Anchor<CGRect>
}

private struct PlayerControlTooltipPreference: PreferenceKey {
    static let defaultValue: [UUID: PlayerControlTooltipAnchor] = [:]
    static func reduce(value: inout [UUID: PlayerControlTooltipAnchor], nextValue: () -> [UUID: PlayerControlTooltipAnchor]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct PlayerControlTooltip: ViewModifier {
    @Environment(\.playerControlTooltip) private var model
    @State private var id: UUID
    let title: String

    init(title: String, id: UUID = UUID()) {
        self.title = title
        _id = State(initialValue: id)
    }

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(title)
            .anchorPreference(key: PlayerControlTooltipPreference.self, value: .bounds) {
                [id: PlayerControlTooltipAnchor(title: title, bounds: $0)]
            }
            .onHover { model?.hover(id, inside: $0) }
            .simultaneousGesture(TapGesture().onEnded { model?.dismiss() })
            .onDisappear { model?.hover(id, inside: false) }
    }
}

private extension View {
    func playerControlHelp(_ title: String) -> some View {
        modifier(PlayerControlTooltip(title: title))
    }
}

struct PlayerControlTooltipOverlay: ViewModifier {
    @ObservedObject var model: PlayerControlTooltipState

    func body(content: Content) -> some View {
        content
            .environment(\.playerControlTooltip, model)
            .overlayPreferenceValue(PlayerControlTooltipPreference.self) { anchors in
                GeometryReader { geometry in
                    if let id = model.activeID, let item = anchors[id] {
                        let rect = geometry[item.bounds]
                        let textWidth = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 16
                        let width = max(0, min(textWidth, 260, geometry.size.width - 16))
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: max(0, width - 16))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                            .position(
                                x: min(max(rect.midX, width / 2 + 8), geometry.size.width - width / 2 - 8),
                                y: rect.minY >= 36 ? rect.minY - 20 : rect.maxY + 20
                            )
                            .accessibilityHidden(true)
                            .transaction { $0.disablesAnimations = true }
                    }
                }
                .allowsHitTesting(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in model.dismiss() }
    }
}

private struct PlayerControlHoverEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .shadow(
                color: .black.opacity(0.16),
                radius: 1,
                y: 1
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.13),
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


enum PlayerEpisodeTitlePolicy {
    static func title(content: String, resource: String) -> String {
        let name = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == content ? content : content + " · " + name
    }
}
