import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct PlaybackSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(MediaProxyPreference.key) private var mediaUsesSystemProxy = false
    var body: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.playback.title", "Playback"),
            subtitle: SettingsL10n.string("settings.playback.subtitle", "Player status and playback options")
        ) {
            SettingsSectionTitle(SettingsL10n.string("settings.playback.section", "Player"))
            SettingsCard {
                SettingsControlRow(
                    icon: "cpu.fill",
                    color: .purple,
                    title: SettingsL10n.string("settings.playback.hardware-decoding.title", "Hardware Decoding"),
                    subtitle: SettingsL10n.string("settings.playback.hardware-decoding.subtitle", "Prefer system hardware decoding during playback")
                ) {
                    Toggle(SettingsL10n.string("settings.playback.hardware-decoding.title", "Hardware Decoding"), isOn: Binding(get: { state.playerHardwareDecoding }, set: { enabled in
                        guard enabled != state.playerHardwareDecoding else { return }
                        Task { await state.setPlayerHardwareDecoding(enabled) }
                    })).labelsHidden().toggleStyle(.switch)
                }

                SettingsDivider()

                SettingsControlRow(
                    icon: "forward.end.fill",
                    color: .blue,
                    title: SettingsL10n.string("settings.playback.autoplay.title", "Autoplay Next Episode"),
                    subtitle: SettingsL10n.string("settings.playback.autoplay.subtitle", "Play the next episode after the current episode ends naturally")
                ) {
                    Toggle(
                        SettingsL10n.string("settings.playback.autoplay.title", "Autoplay Next Episode"),
                        isOn: Binding(
                            get: { state.autoPlayNextEpisode },
                            set: { enabled in
                                Task { await state.setAutoPlayNextEpisode(enabled) }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }.settingsAnchor("playback")

            SettingsSectionTitle(SettingsL10n.string("settings.playback.network.section", "Network"))
            SettingsCard {
                SettingsControlRow(icon: "network", color: .blue,
                    title: SettingsL10n.string("settings.playback.network.proxy", "Use System Proxy for Media"),
                    subtitle: SettingsL10n.string("settings.playback.network.help", "Use the current HTTP/HTTPS system proxy for supported media connections. When off, connect directly. Movie details, posters and sign-in keep their existing network settings.")) {
                    Toggle(SettingsL10n.string("settings.playback.network.proxy", "Use System Proxy for Media"), isOn: $mediaUsesSystemProxy)
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings.playback.media-proxy")
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(SettingsL10n.string("settings.playback.network.scope", "Applies when playback is loaded again. Source-managed downloads may not support this setting. This switch does not bypass a system VPN."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let route = state.playerSnapshot.mediaNetworkRoute, state.isPlayerPresented {
                        HStack {
                            Text(SettingsL10n.string("settings.playback.network.current", "Current Media Connection"))
                            Spacer()
                            Text(route.title).foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                    }
                    if let applied = state.playerSnapshot.mediaProxyPreference, applied != mediaUsesSystemProxy, state.canRetryCurrentPlayback {
                        HStack {
                            Text(SettingsL10n.string("settings.playback.network.pending", "The new setting will apply after reloading playback."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(state.isLivePlayback
                                ? L10n.string("player.episode.retry", fallback: "Retry Playback")
                                : SettingsL10n.string("settings.playback.network.reload", "Reload and Keep Position")) {
                                Task { await state.retryCurrentPlayback(preserveProgress: true) }
                            }.disabled(state.playerSnapshot.isSeeking)
                        }
                    }
                }.padding(12)
            }.settingsAnchor("media-network")

            SettingsCard {
                PlayerWindowSettingsControl(preferences: state.playerWindowPreferences,
                    setMode: state.setPlayerWindowMode,
                    restoreDefault: { state.restoreDefaultWindowLayout(.playerWindow) })
            }.settingsAnchor("player-window")
            SettingsDisclosure("playback-info", title: SettingsL10n.string("settings.organized.playback.information", "Playback Information")) {
                SettingsInfoRow(
                    icon: "play.rectangle.fill",
                    color: .pink,
                    title: SettingsL10n.string("settings.playback.status.title", "Current Status"),
                    subtitle: SettingsL10n.string("settings.playback.backend.detail", "Built-in libmpv playback backend"),
                    value: state.playerStatusDescription
                )



            }

            Group {
                Text(
                    SettingsL10n.string("settings.playback.controls.note", "Use the floating controls during playback to adjust audio tracks, subtitles, speed, aspect ratio, and delay.")
                )
                .font(.system(size: 11)).foregroundColor(.secondary)
                .padding(.horizontal, 12)
            }
        }
    }

}

private struct PlayerWindowSettingsControl: View {
    @ObservedObject var preferences: PlayerWindowPreferenceStore
    let setMode: (PlayerWindowMode) -> Void
    let restoreDefault: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsControlRow(icon: "macwindow", color: .secondary,
                title: SettingsL10n.string("settings.player-window.title", "Player Window"), subtitle: subtitle) {
                Picker(SettingsL10n.string("settings.player-window.mode.label", "Player Window Mode"),
                    selection: Binding(get: { preferences.preference.mode }, set: setMode)) {
                    ForEach(PlayerWindowMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 210)
            }
            SettingsDivider()
            HStack(spacing: 12) {
                Text(SettingsL10n.string("settings.player-window.restore.help", "Clear the saved player window size, position, and mode"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(SettingsL10n.string("settings.common.restore-default", "Restore Default"), action: restoreDefault)
                    .fixedSize()
            }.padding(12)
        }
    }

    private var subtitle: String {
        switch preferences.preference.mode {
        case .automaticAspect:
            return SettingsL10n.string("settings.player-window.automatic.subtitle", "Remember the window position and viewing scale; adjust height to the video aspect ratio")
        case .fixedFrame:
            return SettingsL10n.string("settings.player-window.fixed.subtitle", "Restore the exact previous width and height; different aspect ratios may show letterboxing")
        }
    }
}

