import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct PlaybackSettingsPane: View {
    @EnvironmentObject private var state: AppState
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

