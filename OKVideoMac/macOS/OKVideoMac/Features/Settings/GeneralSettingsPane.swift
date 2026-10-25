import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsLanguageAlert: String, Identifiable {
    case restartRequired
    case restartFailed
    case updateInProgress

    var id: String { rawValue }
}

struct GeneralSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @State private var languageMode = AppLanguagePreferenceStore().load()
    @State private var languageAlert: SettingsLanguageAlert?
    var body: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.general.title", "General"),
            subtitle: SettingsL10n.string("settings.organized.general.subtitle", "Language, appearance, and the main window")
        ) {
            SettingsSectionTitle(SettingsL10n.string("settings.general.appearance.section", "Appearance"))
            SettingsCard {
                SettingsControlRow(
                    icon: "globe",
                    color: .indigo,
                    title: L10n.string(.languageTitle),
                    subtitle: L10n.string(.languageSubtitle)
                ) {
                    Picker(
                        L10n.string(.languageTitle),
                        selection: Binding(
                            get: { languageMode },
                            set: { value in
                                guard value != languageMode else { return }
                                languageMode = value
                                let selection = AppLanguageSelectionController()
                                    .select(
                                        value,
                                        activeLanguage: L10n.language
                                    )
                                languageAlert = selection.requiresRestart
                                    ? .restartRequired
                                    : nil
                            }
                        )
                    ) {
                        ForEach(AppLanguageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                SettingsDivider()

                SettingsControlRow(
                    icon: "paintpalette.fill",
                    color: .blue,
                    title: SettingsL10n.string("settings.appearance.theme.title", "Appearance"),
                    subtitle: SettingsL10n.string("settings.appearance.theme.subtitle", "Choose Light, Dark, or System")
                ) {
                    SettingsAppearancePicker(selection: Binding(
                        get: { state.appTheme },
                        set: { value in Task { await state.setAppTheme(value) } }
                    ))
                }
            }.settingsAnchor("appearance")

            SettingsSectionTitle(SettingsL10n.string("settings.window.section", "Window Layout"))
            SettingsCard {
                SettingsControlRow(
                    icon: "macwindow",
                    color: .teal,
                    title: SettingsL10n.string("settings.window.main.title", "Main Window"),
                    subtitle: SettingsL10n.string("settings.window.main.subtitle", "Automatically remembers its size and position; the default is approximately 1240 × 780")
                ) {
                    Button(SettingsL10n.string("settings.common.restore-default", "Restore Default")) {
                        state.restoreDefaultWindowLayout(.mainWindow)
                    }
                    .help(SettingsL10n.string("settings.window.main.restore.help", "Restore the main window to its default size for the current display and center it"))
                }

            }.settingsAnchor("main-window")
        }
        .alert(item: $languageAlert) { languageAlertPresentation($0) }
    }

    private func languageAlertPresentation(
        _ alert: SettingsLanguageAlert
    ) -> Alert {
        switch alert {
        case .restartRequired:
            return Alert(
                title: Text(L10n.string(.languageRestartTitle)),
                message: Text(L10n.string(.languageRestartMessage)),
                primaryButton: .default(
                    Text(L10n.string(.commonRestart)),
                    action: requestLanguageRestart
                ),
                secondaryButton: .cancel(
                    Text(L10n.string(.languageRestartLater))
                )
            )
        case .updateInProgress:
            return Alert(
                title: Text(L10n.string("updates.busy.title", fallback: "Update in Progress")),
                message: Text(L10n.string("updates.restart-busy", fallback: "Finish the current update before restarting the app.")),
                dismissButton: .default(Text(L10n.string(.commonOK))))
        case .restartFailed:
            return Alert(
                title: Text(L10n.string(.languageRestartFailureTitle)),
                message: Text(L10n.string(.languageRestartFailureMessage)),
                dismissButton: .default(Text(L10n.string(.commonOK)))
            )
        }
    }

    private func requestLanguageRestart() {
        Task { @MainActor in
            do {
                try await AppRelaunchCoordinator.shared.restartApplication()
            } catch AppRelaunchError.updateInProgress {
                languageAlert = .updateInProgress
            } catch {
                languageAlert = .restartFailed
            }
        }
    }

}
