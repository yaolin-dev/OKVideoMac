import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct AboutSettingsPane: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        SettingsPage(title: SettingsPane.about.title, subtitle: SettingsL10n.string("settings.organized.about.subtitle", "Version, updates, and acknowledgements")) {
            AppUpdateSettingsSection()
                .settingsAnchor("updates")
            SettingsSectionTitle(SettingsL10n.string("settings.organized.about.application", "Application Information"))
            SettingsCard {
                SettingsInfoRow(icon: "desktopcomputer", color: .secondary,
                    title: SettingsL10n.string("settings.organized.about.system", "System"), subtitle: state.systemDescription, value: state.architectureDescription)
            }
            SettingsDisclosure("credits", title: SettingsL10n.string("settings.organized.about.credits", "Acknowledgements & Scope")) {
                TMDBAttributionView(expanded: true).padding(16)
                Text(SettingsL10n.string("settings.advanced.security.no-content", "The app does not include media providers, accounts, cookies, resolver URLs, or DRM keys."))
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
                Text(SettingsL10n.string("settings.advanced.security.compatibility", "The minimum supported system is macOS 12.0. DRM, TVBus, and ForceTech are not executed."))
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            }
        }
    }
}

struct AppUpdateSettingsSection: View {
    @ObservedObject private var updates = AppUpdateCoordinator.shared

    var body: some View {
        SettingsSectionTitle(L10n.string("updates.title", fallback: "Software Updates"))
        SettingsCard {
            SettingsControlRow(icon: "arrow.triangle.2.circlepath", color: .blue,
                title: L10n.string("updates.automatic", fallback: "Automatically Check for Updates"),
                subtitle: L10n.string("updates.consent-note", fallback: "Checks once a day. Download and installation require your confirmation.")) {
                Toggle(L10n.string("updates.automatic", fallback: "Automatically Check for Updates"),
                    isOn: Binding(get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticChecks))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!updates.canCheckForUpdates)
            }
            SettingsDivider()
            SettingsControlRow(icon: "app.badge", color: .indigo,
                title: versionTitle, subtitle: status) {
                Button(L10n.string("updates.check", fallback: "Check for Updates…")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            if let error = updates.configurationError {
                Text(error).font(.caption).foregroundColor(.red).padding(18)
            }
        }
    }
    private var versionTitle: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "OKVideoMac \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
    private var status: String {
        if updates.configuration == nil {
            return L10n.string("updates.unconfigured", fallback: "This build has no update feed configured.")
        }
        var message = updates.configuration?.channel == "local-test"
            ? L10n.string("updates.local-channel", fallback: "Local test channel · Keep the local update server running.")
            : L10n.string("updates.stable-channel", fallback: "Stable channel")
        if let version = updates.availableVersion {
            message += " · " + L10n.string("updates.available", fallback: "Update Available") + " " + version
        } else if let date = updates.lastCheckDate {
            message += " · " + L10n.string("updates.last-check", fallback: "Last checked") + " " + date.formatted(date: .abbreviated, time: .shortened)
        }
        return message
    }
}

