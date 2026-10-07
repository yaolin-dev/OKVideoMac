import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

/// Keep the existing settings status row live without observing progress on
/// the entire SettingsView/AppState. Rendering and text remain unchanged.
private struct LiveSourceValidationStatusObserver<Content: View>: View {
    @ObservedObject var activity: LiveValidationActivityModel
    let sourceID: UUID
    @ViewBuilder let content: (LiveSourceValidationStatus) -> Content

    var body: some View {
        if let status = activity.statuses[sourceID] { content(status) }
    }
}

private enum SettingsL10n {
    static func string(
        _ key: String,
        _ fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        AppLocalizer.shared.string(
            L10nKey(rawValue: key),
            fallback: fallback,
            arguments: arguments
        )
    }
}

private enum SettingsLanguageAlert: String, Identifiable {
    case restartRequired
    case restartFailed
    case updateInProgress

    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var navigation: SettingsNavigationState
    @State private var posterCacheSize = SettingsL10n.string(
        "settings.cache.calculating",
        "Calculating…"
    )
    @State private var pendingBackupImport: PortableBackupPreview?
    @State private var isBackupBusy = false
    @State private var backupOperationMessage: String?
    @State private var languageMode = AppLanguagePreferenceStore().load()
    @State private var languageAlert: SettingsLanguageAlert?

    init(navigation: SettingsNavigationState) {
        self.navigation = navigation
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color(nsColor: .windowBackgroundColor),
                    Color.purple.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HSplitView {
                settingsSidebar
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 300)
                detailContent
                    .frame(minWidth: 590)
            }
        }
        .navigationTitle("")
        .toolbar {
            PrimaryPageToolbarLeadingContent(
                title: SettingsL10n.string("settings.pane.settings.title", "Settings")
            )
        }
        .task {
            await refreshCacheSize()
        }
        .sheet(item: $pendingBackupImport) { preview in
            PortableBackupImportPreviewSheet(
                preview: preview,
                cancel: {
                    pendingBackupImport = nil
                },
                confirm: {
                    pendingBackupImport = nil
                    importPortableBackup(from: preview.fileURL)
                }
            )
            .frame(width: 520, height: 390)
        }
        .alert(item: $languageAlert) { alert in
            languageAlertPresentation(alert)
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(SettingsPane.allCases) { pane in
                        settingsSidebarButton(pane)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
        }
        .background(.ultraThinMaterial)
    }

    private func settingsSidebarButton(_ pane: SettingsPane) -> some View {
        let isSelected = navigation.selectedPane == pane
        return Button {
            navigation.select(pane)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(pane.color)
                    Image(systemName: pane.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(.body.weight(.semibold))
                    Text(pane.subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.primary.opacity(0.11)
                            : Color.primary.opacity(0.035)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.primary.opacity(0.12)
                            : Color.primary.opacity(0.06)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appInteractiveHover(cornerRadius: 11, selected: isSelected)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch navigation.selectedPane {
        case .general:
            generalSettings
        case .configurations:
            configurationSettings
        case .search:
            SearchSettingsPane()
                .environmentObject(state)
        case .liveSources:
            LiveSourceSettingsPane()
                .environmentObject(state)
        case .playback:
            playbackSettings
        case .cache:
            cacheSettings
        case .backup:
            backupSettings
        case .advanced:
            advancedSettings
        }
    }

    private var generalSettings: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.general.title", "General"),
            subtitle: SettingsL10n.string("settings.general.subtitle", "Appearance, privacy, and history")
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
                    Picker(
                        SettingsL10n.string("settings.appearance.theme.title", "Appearance"),
                        selection: Binding(
                            get: { state.appTheme },
                            set: { value in
                                Task { await state.setAppTheme(value) }
                            }
                        )
                    ) {
                        ForEach(
                            [AppTheme.light, .dark, .system]
                        ) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 270)
                }
            }

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

                SettingsDivider()

                PlayerWindowSettingsControl(
                    preferences: state.playerWindowPreferences,
                    setMode: state.setPlayerWindowMode,
                    restoreDefault: {
                        state.restoreDefaultWindowLayout(.playerWindow)
                    }
                )
            }

            AppUpdateSettingsSection()

            SettingsSectionTitle(SettingsL10n.string("settings.general.privacy.section", "Privacy & History"))
            SettingsCard {
                SettingsControlRow(
                    icon: "eye.slash.fill",
                    color: .indigo,
                    title: SettingsL10n.string("settings.general.incognito.title", "Private Mode"),
                    subtitle: SettingsL10n.string("settings.general.incognito.subtitle", "Do not save new watch history while enabled")
                ) {
                    Toggle(
                        SettingsL10n.string("settings.general.incognito.title", "Private Mode"),
                        isOn: Binding(
                            get: { state.incognitoMode },
                            set: { value in
                                Task { await state.setIncognitoMode(value) }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                SettingsDivider()

                SettingsControlRow(
                    icon: "clock.arrow.circlepath",
                    color: .orange,
                    title: SettingsL10n.string("settings.general.history-retention.title", "History Retention"),
                    subtitle: SettingsL10n.string("settings.general.history-retention.subtitle", "Automatically remove watch history older than the selected period")
                ) {
                    Picker(
                        SettingsL10n.string("settings.general.history-retention.title", "History Retention"),
                        selection: Binding(
                            get: { state.historyRetentionDays },
                            set: { value in
                                Task { await state.setHistoryRetentionDays(value) }
                            }
                        )
                    ) {
                        ForEach(
                            HistoryRetentionPresets.options(
                                including: state.historyRetentionDays
                            ),
                            id: \.self
                        ) { days in
                            Text(HistoryRetentionPresets.title(for: days))
                                .tag(days)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 128)
                }
            }
        }
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

    private var configurationSettings: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.providers.title", "Video Providers"),
            subtitle: SettingsL10n.string("settings.providers.subtitle", "Import, switch, and maintain video provider configurations")
        ) {
            ConfigurationView(embedded: true)
                .environmentObject(state)
        }
    }

    private var playbackSettings: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.playback.title", "Playback"),
            subtitle: SettingsL10n.string("settings.playback.subtitle", "Player status and playback options")
        ) {
            SettingsSectionTitle(SettingsL10n.string("settings.playback.section", "Player"))
            SettingsCard {
                SettingsInfoRow(
                    icon: "play.rectangle.fill",
                    color: .pink,
                    title: SettingsL10n.string("settings.playback.status.title", "Current Status"),
                    subtitle: SettingsL10n.string("settings.playback.backend.detail", "Built-in libmpv playback backend"),
                    value: state.playerStatusDescription
                )

                SettingsDivider()

                SettingsControlRow(
                    icon: "cpu.fill",
                    color: .purple,
                    title: SettingsL10n.string("settings.playback.hardware-decoding.title", "Hardware Decoding"),
                    subtitle: SettingsL10n.string("settings.playback.hardware-decoding.subtitle", "Prefer system hardware decoding during playback")
                ) {
                    Button(state.playerHardwareDecoding ? SettingsL10n.string("settings.common.enabled", "On") : SettingsL10n.string("settings.common.disabled", "Off")) {
                        Task { await state.togglePlayerHardwareDecoding() }
                    }
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
            }

            SettingsSectionTitle(SettingsL10n.string("settings.common.about.section", "About"))
            SettingsCard {
                Label(
                    SettingsL10n.string("settings.playback.controls.note", "Use the floating controls during playback to adjust audio tracks, subtitles, speed, aspect ratio, and delay."),
                    systemImage: "info.circle"
                )
                .foregroundColor(.secondary)
                .padding(18)
            }
        }
    }

    private var cacheSettings: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.cache.title", "Storage"),
            subtitle: SettingsL10n.string("settings.cache.subtitle", "Manage image cache and local history")
        ) {
            SettingsSectionTitle(SettingsL10n.string("settings.cache.images.section", "Image Cache"))
            SettingsCard {
                SettingsControlRow(
                    icon: "photo.on.rectangle.angled",
                    color: .orange,
                    title: SettingsL10n.string("settings.cache.poster.title", "Poster Cache"),
                    subtitle: SettingsL10n.string("settings.cache.poster.subtitle", "Space used by current posters and channel logos")
                ) {
                    HStack(spacing: 12) {
                        Text(posterCacheSize)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        Button(SettingsL10n.string("settings.common.clear", "Clear")) {
                            Task {
                                await state.clearPosterCache()
                                await refreshCacheSize()
                            }
                        }
                    }
                }
            }

            SettingsSectionTitle(SettingsL10n.string("settings.cache.history.section", "Watch History"))
            SettingsCard {
                SettingsControlRow(
                    icon: "clock.fill",
                    color: .blue,
                    title: SettingsL10n.string("settings.cache.history.title", "Watch History"),
                    subtitle: SettingsL10n.string("settings.cache.history.count", "%d records saved", state.history.count)
                ) {
                    Button(SettingsL10n.string("settings.common.clear-all", "Clear All"), role: .destructive) {
                        Task { await state.clearHistory() }
                    }
                    .disabled(state.history.isEmpty)
                }
            }
        }
    }

    private var backupSettings: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.backup.title", "Backup & Restore"),
            subtitle: SettingsL10n.string("settings.backup.subtitle", "Export the current video provider configuration and its watch history")
        ) {
            SettingsSectionTitle(SettingsL10n.string("settings.backup.available.section", "Data Available for Backup"))
            SettingsCard {
                SettingsInfoRow(
                    icon: "doc.badge.gearshape",
                    color: .indigo,
                    title: SettingsL10n.string("settings.backup.configuration.title", "Current Video Provider Configuration"),
                    subtitle: state.activeConfigurationRecord == nil
                        ? SettingsL10n.string("settings.backup.configuration.none", "No video provider configuration is active")
                        : SettingsL10n.string("settings.backup.configuration.available-detail", "Includes the last successfully loaded configuration snapshot"),
                    value: state.activeConfigurationRecord?.name
                        ?? SettingsL10n.string("settings.common.not-set", "Not Set")
                )
                SettingsDivider()
                SettingsInfoRow(
                    icon: "clock.arrow.circlepath",
                    color: .blue,
                    title: SettingsL10n.string("settings.backup.history.title", "Related Watch History"),
                    subtitle: SettingsL10n.string("settings.backup.history.detail", "Includes source, episode, playback position, and watch time"),
                    value: SettingsL10n.string("settings.common.item-count", "%d items", state.history.count)
                )
                SettingsDivider()
                SettingsInfoRow(icon: "star", color: .blue, title: L10n.string(.sectionFavorites),
                    subtitle: L10n.string("favorites.backup.scope", fallback: "Includes favorites owned by this configuration. Unconfirmed sources and other configurations are excluded."),
                    value: String(state.favorites.filter { $0.configurationID != nil && $0.configurationID == state.activeConfigurationRecord?.id }.count))
            }

            SettingsSectionTitle(SettingsL10n.string("settings.backup.manual.section", "Manual Backup"))
            SettingsCard {
                SettingsControlRow(
                    icon: "square.and.arrow.up.fill",
                    color: .teal,
                    title: SettingsL10n.string("settings.backup.export.title", "Export Current Configuration and History"),
                    subtitle: SettingsL10n.string("settings.backup.export.subtitle", "Create a version-validated .okvideobackup file")
                ) {
                    Button(SettingsL10n.string("settings.common.export", "Export…")) {
                        exportPortableBackup()
                    }
                    .disabled(
                        isBackupBusy || state.activeConfigurationRecord == nil
                    )
                }
                SettingsDivider()
                SettingsControlRow(
                    icon: "square.and.arrow.down.fill",
                    color: .orange,
                    title: SettingsL10n.string("settings.backup.restore.title", "Restore from Backup"),
                    subtitle: SettingsL10n.string("settings.backup.restore.subtitle", "Preview the contents and automatically save current data before import")
                ) {
                    Button(SettingsL10n.string("settings.backup.choose", "Choose Backup…")) {
                        choosePortableBackup()
                    }
                    .disabled(isBackupBusy)
                }
            }

            if isBackupBusy || backupOperationMessage != nil {
                SettingsSectionTitle(SettingsL10n.string("settings.common.status", "Status"))
                SettingsCard {
                    HStack(spacing: 10) {
                        if isBackupBusy {
                            AppActivityIndicator(size: .small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        Text(
                            isBackupBusy
                                ? SettingsL10n.string("settings.backup.processing", "Validating and processing the backup…")
                                : backupOperationMessage ?? ""
                        )
                        .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(16)
                }
            }

            SettingsSectionTitle(SettingsL10n.string("settings.backup.security.section", "Security Notes"))
            SettingsCard {
                Label(
                    SettingsL10n.string("settings.backup.security.message", "Backups do not export Keychain items, cloud account status, QR codes, temporary playback URLs, or Android virtual machine data. Original configuration text is included and may contain private provider URLs. The file is not encrypted, so store it securely. If cloud authorization is no longer valid after a restore, the player will request it again."),
                    systemImage: "lock.shield.fill"
                )
                .foregroundColor(.secondary)
                .padding(18)
            }
        }
    }

    private var advancedSettings: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.advanced.title", "Advanced"),
            subtitle: SettingsL10n.string("settings.advanced.subtitle", "Runtime information, diagnostics, and compatibility")
        ) {
            SettingsSectionTitle(SettingsL10n.string("settings.advanced.app-info.section", "App Information"))
            SettingsCard {
                SettingsInfoRow(
                    icon: "app.badge",
                    color: .green,
                    title: SettingsL10n.string("settings.advanced.version.title", "Version"),
                    subtitle: "OKVideoMac",
                    value: state.versionDescription
                )
                SettingsDivider()
                SettingsInfoRow(
                    icon: "desktopcomputer",
                    color: .blue,
                    title: SettingsL10n.string("settings.advanced.environment.title", "Environment"),
                    subtitle: state.systemDescription,
                    value: state.architectureDescription
                )
                SettingsDivider()
                SettingsInfoRow(
                    icon: "square.stack.3d.up.fill",
                    color: .indigo,
                    title: SettingsL10n.string("settings.common.current-configuration", "Current Configuration"),
                    subtitle: state.activeConfigurationRecord == nil
                        ? SettingsL10n.string("settings.advanced.configuration.none", "No video provider configuration has been imported")
                        : SettingsL10n.string("settings.advanced.visible-provider-count", "%d visible providers", state.visibleSites.count),
                    value: state.activeConfigurationRecord?.name
                        ?? SettingsL10n.string("settings.common.not-set", "Not Set")
                )
            }

            SettingsSectionTitle(SettingsL10n.string("settings.diagnostics.section", "Diagnostics"))
            SettingsCard {
                SettingsControlRow(
                    icon: "doc.text.magnifyingglass",
                    color: .teal,
                    title: SettingsL10n.string("settings.diagnostics.title", "Export Diagnostics"),
                    subtitle: SettingsL10n.string("settings.diagnostics.subtitle", "Export redacted runtime status and provider capabilities")
                ) {
                    Button(SettingsL10n.string("settings.common.export", "Export…")) {
                        exportDiagnostics()
                    }
                }
            }

            SettingsSectionTitle(SettingsL10n.string("settings.android.section.title", "Android Compatibility"))
            SettingsCard {
                SettingsControlRow(
                    icon: "arrow.triangle.branch",
                    color: .accentColor,
                    title: SettingsL10n.string("settings.android.current-runtime.title", "Current Runtime"),
                    subtitle: runtimeModeDetail
                ) {
                    Text(state.androidRuntimeModeSnapshot.mode.userFacingName)
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsControlRow(
                    icon: managedRuntimeIcon,
                    color: managedRuntimeColor,
                    title: SettingsL10n.string("settings.android.mode.managed.title", "Managed by OKVideoMac (Recommended)"),
                    subtitle: managedRuntimeDetail
                ) {
                    HStack(spacing: 8) {
                        if state.managedRuntimeInstallationState.isBusy {
                            if let progress = state
                                .managedRuntimeInstallationState.progress {
                                ProgressView(value: progress, total: 1)
                                    .progressViewStyle(.linear)
                                    .frame(width: 100)
                            } else {
                                AppActivityIndicator(size: .small)
                            }
                        }
                        Button(managedRuntimeButtonTitle) {
                            if state.androidRuntimeModeSnapshot.mode == .managed {
                                Task {
                                    await state.showManagedRuntimeInstaller()
                                }
                            } else {
                                Task {
                                    await state.useManagedAndroidRuntime()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            state.managedRuntimeInstallationState.isBusy
                                || state.androidRuntimeStatus.isRunning
                        )
                    }
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 10) {
                    if let storage = state.androidRuntimeStorage {
                        Text(SettingsL10n.string("settings.android.storage.summary", "Components: %@ · Installation cache: %@ · Android user data: %@ · Backups: %@",
                            ByteCountFormatter.string(fromByteCount: storage.componentBytes, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: storage.cacheBytes, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: storage.userDataBytes, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: storage.backupBytes, countStyle: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                        if !storage.isComplete {
                            Text(SettingsL10n.string("settings.android.storage.incomplete", "Storage estimate is incomplete. Unverified files will not be removed."))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            if storage.hasPendingMaintenance {
                                Button(SettingsL10n.string("settings.android.uninstall.retry-cleanup", "Resume Maintenance…")) {
                                    Task { await state.recoverAndroidMaintenanceIfNeeded() }
                                }
                            } else {
                                Button(SettingsL10n.string("settings.android.action.uninstall-runtime", "Uninstall OKVideoMac-managed Components…"), role: .destructive) {
                                    Task { await state.uninstallManagedAndroidRuntime() }
                                }
                                .disabled(storage.componentBytes + storage.cacheBytes + storage.backupBytes == 0)
                            }
                            if state.isAndroidRuntimeBusy { AppActivityIndicator(size: .small) }
                        }
                        .disabled(state.isAndroidRuntimeBusy || state.managedRuntimeInstallationState.isBusy)
                    } else {
                        Text(SettingsL10n.string("settings.android.storage.calculating", "Calculating Android storage…"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = state.androidMaintenanceMessage {
                        Text(message).font(.caption).textSelection(.enabled)
                    }
                    Text(SettingsL10n.string("settings.android.uninstall.keep-user-data", "Uninstall keeps Android sign-in data, user-data backups, private keys, and external SDK files."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)

                SettingsDivider()

                SettingsControlRow(
                    icon: externalRuntimeIcon,
                    color: externalRuntimeColor,
                    title: SettingsL10n.string("settings.android.external.title", "Existing Android SDK"),
                    subtitle: externalRuntimeDetail
                ) {
                    HStack(spacing: 8) {
                        if state.androidRuntimeModeSnapshot.mode != .external,
                           state.androidRuntimeModeSnapshot.externalSDKRoot != nil {
                            Button(SettingsL10n.string("settings.common.use", "Use")) {
                                Task {
                                    await state
                                        .useConfiguredExternalAndroidRuntime()
                                }
                            }
                            .disabled(
                                state.isAndroidRuntimeBusy
                                    || state.androidRuntimeStatus.isRunning
                            )
                        }
                        Button(externalRuntimeButtonTitle) {
                            Task { await state.chooseAndroidSDK() }
                        }
                        .disabled(
                            state.isAndroidRuntimeBusy
                                || state.androidRuntimeStatus.isRunning
                        )
                    }
                }

                SettingsDivider()

                SettingsControlRow(
                    icon: androidRuntimeIcon,
                    color: androidRuntimeColor,
                    title: state.androidRuntimeStatus.title,
                    subtitle: state.androidRuntimeStatus.detail
                ) {
                    HStack(spacing: 8) {
                        if state.isAndroidRuntimeBusy {
                            if let progress = state.androidRuntimeStatus.progress {
                                VStack(alignment: .trailing, spacing: 3) {
                                    ProgressView(value: progress, total: 1)
                                        .progressViewStyle(.linear)
                                        .frame(width: 100)
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                AppActivityIndicator(size: .small)
                            }
                        }

                        Button(SettingsL10n.string("settings.common.check", "Check")) {
                            Task { await state.refreshAndroidRuntimeStatus() }
                        }
                        .disabled(state.isAndroidRuntimeBusy)

                        Button(SettingsL10n.string("settings.android.action.repair-bridge", "Repair Bridge")) {
                            Task { await state.repairAndroidRuntime() }
                        }
                        .disabled(
                            state.isAndroidRuntimeBusy
                                || state.androidRuntimeStatus.phase == .unavailable
                        )

                        Button(SettingsL10n.string("settings.android.action.rebuild-runtime", "Repair Android Runtime…"), role: .destructive) {
                            Task { await state.rebuildAndroidRuntime() }
                        }
                        .disabled(
                            state.isAndroidRuntimeBusy
                        )

                        if state.androidRuntimeStatus.isRunning {
                            Button(SettingsL10n.string("settings.common.stop", "Stop"), role: .destructive) {
                                Task { await state.stopAndroidRuntime() }
                            }
                            .disabled(state.isAndroidRuntimeBusy)
                        } else {
                            Button(SettingsL10n.string("settings.common.start", "Start")) {
                                Task { await state.startAndroidRuntime() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                state.isAndroidRuntimeBusy
                                    || state.androidRuntimeStatus.phase == .unavailable
                            )
                        }
                    }
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        SettingsL10n.string("settings.android.scope.note", "This component is only used by video providers that require an Android Java/Dex runtime. Standard API and JavaScript providers do not start it."),
                        systemImage: "info.circle"
                    )
                    Text(
                        runtimeIsolationDetail
                    )
                    .foregroundColor(.secondary)
                }
                .font(.caption)
                .padding(16)
            }

            SettingsSectionTitle(SettingsL10n.string("settings.advanced.security.section", "Security & Scope"))
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        SettingsL10n.string("settings.advanced.security.no-content", "The app does not include media providers, accounts, cookies, resolver URLs, or DRM keys."),
                        systemImage: "lock.shield"
                    )
                    Text(SettingsL10n.string("settings.advanced.security.compatibility", "The minimum supported system is macOS 12.0. DRM, TVBus, and ForceTech are not executed."))
                        .foregroundColor(.secondary)
                }
                .padding(18)
            }
        }
        .task {
            await state.refreshAndroidStorage()
            while !Task.isCancelled {
                await state.refreshAndroidRuntimeStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var androidRuntimeIcon: String {
        switch state.androidRuntimeStatus.phase {
        case .running: return "checkmark.circle.fill"
        case .starting, .checking, .stopping: return "hourglass"
        case .failed, .unavailable: return "exclamationmark.triangle.fill"
        case .stopped: return "power"
        }
    }

    private var androidRuntimeColor: Color {
        switch state.androidRuntimeStatus.phase {
        case .running: return .green
        case .starting, .checking, .stopping: return .orange
        case .failed, .unavailable: return .red
        case .stopped: return .secondary
        }
    }

    private var runtimeModeDetail: String {
        switch state.androidRuntimeModeSnapshot.mode {
        case .managed:
            return SettingsL10n.string("settings.android.mode.managed.detail", "Android content uses only verified components managed by OKVideoMac")
        case .external:
            return SettingsL10n.string("settings.android.mode.external.detail", "Android content uses only the SDK selected below and never triggers Managed Runtime installation")
        }
    }

    private var externalRuntimeDetail: String {
        guard let root = state.androidRuntimeModeSnapshot.externalSDKRoot else {
            return SettingsL10n.string("settings.android.external.not-configured", "Not configured. Advanced users can select an installed, complete Android SDK.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let displayPath = root.path.hasPrefix(home + "/")
            ? "~/" + root.path.dropFirst(home.count + 1)
            : root.path
        if state.androidRuntimeModeSnapshot.mode != .external {
            return SettingsL10n.string("settings.android.external.saved", "Saved: %@. It will be validated again before switching.", displayPath)
        }
        let stateDetail = state.androidRuntimeModeSnapshot.externalValidation?
            .userFacingStatus
            ?? SettingsL10n.string("settings.android.external.checking", "Checking the existing Android SDK")
        return "\(stateDetail) · \(displayPath)"
    }

    private var externalRuntimeIcon: String {
        guard state.androidRuntimeModeSnapshot.externalSDKRoot != nil else {
            return "externaldrive.badge.questionmark"
        }
        if state.androidRuntimeModeSnapshot.mode != .external {
            return "externaldrive"
        }
        return state.androidRuntimeModeSnapshot.externalValidation?
            .canPrepareRuntime == true
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
    }

    private var externalRuntimeColor: Color {
        guard state.androidRuntimeModeSnapshot.mode == .external else {
            return .secondary
        }
        return state.androidRuntimeModeSnapshot.externalValidation?
            .canPrepareRuntime == true ? .green : .red
    }

    private var externalRuntimeButtonTitle: String {
        state.androidRuntimeModeSnapshot.externalSDKRoot == nil
            ? SettingsL10n.string("settings.common.choose", "Choose…")
            : SettingsL10n.string("settings.common.change", "Change…")
    }

    private var managedRuntimeButtonTitle: String {
        if state.androidRuntimeModeSnapshot.mode != .managed {
            return SettingsL10n.string("settings.android.action.switch-to", "Switch To…")
        }
        return managedRuntimeActionTitle
    }

    private var runtimeIsolationDetail: String {
        switch state.androidRuntimeModeSnapshot.mode {
        case .managed:
            return SettingsL10n.string("settings.android.isolation.managed", "Required files are downloaded on demand to an OKVideoMac private directory. External Android tools are never read or reused.")
        case .external:
            return SettingsL10n.string("settings.android.isolation.external", "ADB and Emulator always come from the selected SDK, while OKVideoMac continues to use its private ADB server, keys, and dedicated AVD.")
        }
    }

    private var managedRuntimeTitle: String {
        switch state.managedRuntimeInstallationState {
        case .ready: return SettingsL10n.string("settings.android.managed.installed", "Android compatibility component installed")
        case .updateAvailable: return SettingsL10n.string("settings.android.managed.update-available", "Android compatibility component update available")
        case .failed, .damaged: return SettingsL10n.string("settings.android.managed.needs-repair", "Android compatibility component needs repair")
        case .incompatible: return SettingsL10n.string("settings.android.managed.incompatible", "Android compatibility component is incompatible")
        case .notInstalled, .available, .cancelled:
            return SettingsL10n.string("settings.android.managed.not-installed", "Android compatibility component not installed")
        default: return SettingsL10n.string("settings.android.managed.processing", "Processing the Android compatibility component")
        }
    }

    private var managedRuntimeDetail: String {
        switch state.managedRuntimeInstallationState {
        case .ready:
            return SettingsL10n.string("settings.android.managed.ready-detail", "Managed independently by OKVideoMac and started only when Dex content needs it")
        case .updateAvailable:
            return SettingsL10n.string("settings.android.managed.update-detail", "A new runtime can be installed. The current runtime remains active until the new version is validated.")
        case .failed(let failure, _), .damaged(let failure, _),
             .incompatible(let failure):
            return ManagedRuntimeFailurePresentationMapper.presentation(
                for: failure
            ).message
        case .downloading(let detail):
            return detail.componentID.map {
                SettingsL10n.string("settings.android.managed.downloading-component", "Downloading: %@", $0)
            } ?? SettingsL10n.string("settings.android.managed.downloading", "Downloading")
        default:
            return SettingsL10n.string("settings.android.managed.on-demand", "You will be prompted the first time content requires Android")
        }
    }

    private var managedRuntimeIcon: String {
        switch state.managedRuntimeInstallationState {
        case .ready: return "checkmark.circle.fill"
        case .failed, .damaged, .incompatible:
            return "exclamationmark.triangle.fill"
        case .updateAvailable: return "arrow.triangle.2.circlepath.circle.fill"
        case .notInstalled, .available, .cancelled:
            return "arrow.down.circle.fill"
        default: return "gearshape.2.fill"
        }
    }

    private var managedRuntimeColor: Color {
        switch state.managedRuntimeInstallationState {
        case .ready: return .green
        case .failed, .damaged, .incompatible: return .red
        case .updateAvailable: return .orange
        case .notInstalled, .available, .cancelled: return .accentColor
        default: return .orange
        }
    }

    private var managedRuntimeActionTitle: String {
        switch state.managedRuntimeInstallationState {
        case .ready: return SettingsL10n.string("settings.common.details", "Details")
        case .updateAvailable: return SettingsL10n.string("settings.common.update", "Update…")
        case .failed, .damaged, .incompatible: return SettingsL10n.string("settings.common.repair", "Repair…")
        default: return SettingsL10n.string("settings.common.install", "Install…")
        }
    }

    private func refreshCacheSize() async {
        let bytes = await Task.detached(priority: .utility) {
            guard let directories = try? AppDirectories() else { return Int64(0) }
            let directory = directories.caches.appendingPathComponent(
                "Posters",
                isDirectory: true
            )
            return Self.directorySize(directory)
        }.value
        posterCacheSize = ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey
                ]
            ), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "OKVideoMac-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await state.exportDiagnostics(to: url)
            } catch {
                state.presentedError = UserFacingError(
                    title: L10n.string("diagnostics.export.failed.title", fallback: "Diagnostics Export Failed"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

    private func exportPortableBackup() {
        guard let record = state.activeConfigurationRecord else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.okVideoBackup]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = portableBackupFileName(for: record.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBackupBusy = true
        backupOperationMessage = nil
        Task { @MainActor in
            defer { isBackupBusy = false }
            do {
                let preview = try await state.exportPortableBackup(to: url)
                backupOperationMessage = SettingsL10n.string(
                    "settings.backup.export.success",
                    "Exported “%@” with %d history items.",
                    preview.configurationName,
                    preview.historyCount
                ) + " · " + L10n.string("favorites.backup.count", fallback: "%d favorites", preview.favoriteCount)
            } catch {
                state.presentedError = UserFacingError(
                    title: SettingsL10n.string("settings.backup.export.failed", "Backup Export Failed"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

    private func choosePortableBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.okVideoBackup]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = SettingsL10n.string("settings.backup.validate", "Validate Backup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBackupBusy = true
        backupOperationMessage = nil
        Task { @MainActor in
            defer { isBackupBusy = false }
            do {
                pendingBackupImport = try await state.inspectPortableBackup(
                    at: url
                )
            } catch {
                state.presentedError = UserFacingError(
                    title: SettingsL10n.string("settings.backup.read.failed", "Unable to Read Backup"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

    private func importPortableBackup(from url: URL) {
        isBackupBusy = true
        backupOperationMessage = nil
        Task { @MainActor in
            defer { isBackupBusy = false }
            do {
                let summary = try await state.importPortableBackup(from: url)
                let safetyText = summary.safetyBackupURL == nil
                    ? ""
                    : SettingsL10n.string("settings.backup.restore.safety-suffix", " Your previous data was saved as a safety backup.")
                backupOperationMessage = SettingsL10n.string(
                    "settings.backup.restore.success",
                    "Restored “%@”. Checked %d history items and added or updated %d.%@",
                    summary.configurationName,
                    summary.historyCount,
                    summary.changedHistoryCount,
                    safetyText
                )
            } catch {
                state.presentedError = UserFacingError(
                    title: SettingsL10n.string("settings.backup.restore.failed", "Backup Restore Failed"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

    private func portableBackupFileName(for configurationName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let normalizedName = configurationName.components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = String(normalizedName.prefix(80))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "OKVideoMac-\(safeName.isEmpty ? "Backup" : safeName)-\(formatter.string(from: Date())).okvideobackup"
    }
}

private struct PortableBackupImportPreviewSheet: View {
    let preview: PortableBackupPreview
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SettingsL10n.string("settings.backup.preview.title", "Restore This Backup?"))
                        .font(.title2.bold())
                    Text(SettingsL10n.string("settings.backup.preview.verified", "The file passed format and integrity validation"))
                        .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 0) {
                previewRow(SettingsL10n.string("settings.backup.preview.configuration", "Video Provider Configuration"), value: preview.configurationName)
                Divider()
                previewRow(
                    SettingsL10n.string("settings.backup.preview.history", "Watch History"),
                    value: SettingsL10n.string("settings.common.item-count", "%d items", preview.historyCount)
                )
                Divider()
                previewRow(L10n.string(.sectionFavorites), value: String(preview.favoriteCount))
                Divider()
                previewRow(
                    SettingsL10n.string("settings.backup.preview.version", "Export Version"),
                    value: "\(preview.appVersion) (\(preview.appBuild))"
                )
                Divider()
                previewRow(
                    SettingsL10n.string("settings.backup.preview.exported-at", "Exported"),
                    value: preview.createdAt.formatted(
                        Date.FormatStyle(
                            date: .abbreviated,
                            time: .shortened,
                            locale: L10n.locale
                        )
                    )
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            Text(SettingsL10n.string("settings.backup.restore.merge-note", "When the same history item exists twice, the record with the newer watch time is kept. Current providers and history are backed up before import. Cloud account authorization is never overwritten."))
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button(SettingsL10n.string("settings.common.cancel", "Cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(SettingsL10n.string("settings.backup.restore.confirm", "Import and Merge"), action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func previewRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SearchSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @State private var mode: SearchSiteScopeMode = .all
    @State private var selectedKeys: Set<String> = []
    @State private var filterText = ""
    @State private var isSaving = false

    private var draft: SearchSiteScope {
        SearchSiteScope(mode: mode, selectedSiteKeys: selectedKeys)
    }

    private var hasValidSelection: Bool {
        mode == .all || !SearchSiteScopePolicy.effectiveSiteKeys(
            scope: draft,
            options: state.searchScopeSiteOptions
        ).isEmpty
    }

    var body: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.search.title", "Search"),
            subtitle: SettingsL10n.string("settings.search.subtitle", "Manage the default provider scope for the current video configuration")
        ) {
            SettingsSectionTitle(SettingsL10n.string("settings.common.current-configuration", "Current Configuration"))
            SettingsCard {
                SettingsControlRow(
                    icon: "doc.badge.gearshape",
                    color: .indigo,
                    title: state.activeConfigurationRecord?.name
                        ?? SettingsL10n.string("settings.providers.none", "No Video Provider Configuration"),
                    subtitle: state.activeConfigurationRecord == nil
                        ? SettingsL10n.string("settings.providers.import-first", "Import and enable a video provider configuration first")
                        : SettingsL10n.string("settings.search.configuration.saved-separately", "Search scope is saved separately for each configuration")
                ) {
                    Text(state.searchScopeSummary)
                        .foregroundColor(.secondary)
                }
            }

            SettingsSectionTitle(SettingsL10n.string("settings.search.default-scope.section", "Default Search Scope"))
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    SearchScopeEditorContent(
                        options: state.searchScopeSiteOptions,
                        mode: $mode,
                        selectedKeys: $selectedKeys,
                        filterText: $filterText
                    )
                    .frame(minHeight: 360, idealHeight: 440)

                    Divider()

                    HStack {
                        Text(
                            state.isSearching
                                ? SettingsL10n.string("settings.search.pending-change", "Changes take effect with the next search. The current search scope remains unchanged.")
                                : SettingsL10n.string("settings.search.default-scope.note", "Home and Search both use this default scope.")
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        Spacer()
                        if !hasValidSelection {
                            Text(SettingsL10n.string("settings.search.minimum-one", "Select at least one available provider"))
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        Button(SettingsL10n.string("settings.search.restore-all", "Restore All Providers")) {
                            mode = .all
                            selectedKeys = []
                        }
                        Button(SettingsL10n.string("settings.common.save", "Save")) {
                            isSaving = true
                            Task {
                                _ = await state.saveSearchSiteScope(draft)
                                isSaving = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            state.activeConfigurationRecord == nil
                                || !hasValidSelection
                                || isSaving
                                || draft == state.searchSiteScope
                        )
                    }
                }
                .padding(16)
            }

            SettingsSectionTitle(SettingsL10n.string("settings.common.about.section", "About"))
            SettingsCard {
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        SettingsL10n.string("settings.search.note.scope", "The search scope determines which providers receive requests."),
                        systemImage: "network"
                    )
                    Label(
                        SettingsL10n.string("settings.search.note.result-filter", "The Result Providers control only filters existing results and does not make new network requests."),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
                .foregroundColor(.secondary)
                .padding(18)
            }
        }
        .task(id: state.activeConfigurationRecord?.id) {
            restoreDraft()
        }
        .onChange(of: state.searchSiteScope) { _ in
            restoreDraft()
        }
    }

    private func restoreDraft() {
        mode = state.searchSiteScope.mode
        selectedKeys = state.searchSiteScope.selectedSiteKeys
        filterText = ""
    }
}

private struct EPGSettingsSection: View {
    @EnvironmentObject private var state: AppState
    @State private var urlDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        SettingsSectionTitle(SettingsL10n.string("settings.epg.title", "EPG / Programme Guide"))
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(SettingsL10n.string("settings.epg.enabled", "Automatically Load EPG"), isOn: Binding(
                    get: { state.epgPreferences.automaticEPGEnabled },
                    set: { enabled in
                        var next = state.epgPreferences
                        next.automaticEPGEnabled = enabled
                        errorMessage = nil
                        Task {
                            if !((await state.saveEPGPreferences(next))) { errorMessage = state.presentedError?.message }
                        }
                    }
                ))
                Text(SettingsL10n.string("settings.epg.enabled-help", "Automatically load current and next programmes for supported live TV sources."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(SettingsL10n.string("settings.epg.default-url", "Default EPG Address"), text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveURL(urlDraft) }
                Text(SettingsL10n.string("settings.epg.default-help", "HTTP/HTTPS XMLTV or XMLTV.gz. Used only when an automatic source has no embedded EPG. Changes take effect after saving."))
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button(SettingsL10n.string("settings.epg.reset", "Restore Default")) { saveURL("") }
                    Spacer()
                    Button(SettingsL10n.string("settings.epg.save", "Save")) { saveURL(urlDraft) }
                }
            }
            .padding(18)
            .disabled(state.isSavingEPGPreferences)
        }
        .onAppear { urlDraft = state.epgPreferences.defaultEPGURL ?? "" }
    }

    private func saveURL(_ value: String) {
        var next = state.epgPreferences
        next.defaultEPGURL = value
        errorMessage = nil
        Task {
            if await state.saveEPGPreferences(next) { urlDraft = state.epgPreferences.defaultEPGURL ?? "" }
            else { errorMessage = state.presentedError?.message }
        }
    }
}

private struct SourceEPGSettingsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let source: StoredLiveSource
    @State private var mode: EPGSourceMode
    @State private var urlDraft: String
    @State private var errorMessage: String?

    init(source: StoredLiveSource, preference: EPGSourcePreference) {
        self.source = source
        _mode = State(initialValue: preference.mode)
        _urlDraft = State(initialValue: preference.customEPGURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(source.name).font(.headline)
            Picker(SettingsL10n.string("settings.epg.title", "EPG / Programme Guide"), selection: $mode) {
                Text(SettingsL10n.string("settings.epg.automatic", "Automatic")).tag(EPGSourceMode.automatic)
                Text(SettingsL10n.string("settings.epg.custom", "Custom")).tag(EPGSourceMode.custom)
                Text(SettingsL10n.string("settings.epg.disabled", "Do Not Use EPG")).tag(EPGSourceMode.disabled)
            }
            if mode == .custom {
                TextField(SettingsL10n.string("settings.epg.custom-url", "EPG URL"), text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
            }
            Text(SettingsL10n.string("settings.epg.automatic-help", "Automatic: embedded M3U EPG → global default → none. The app-wide EPG switch applies to all sources."))
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(SettingsL10n.string("settings.common.cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(SettingsL10n.string("settings.epg.save", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480)
        .disabled(state.isSavingEPGPreferences)
    }

    private func save() {
        var next = state.epgPreferences
        next.sources[source.id.uuidString] = EPGSourcePreference(mode: mode, customEPGURL: urlDraft)
        errorMessage = nil
        Task {
            if await state.saveEPGPreferences(next) { dismiss() }
            else { errorMessage = state.presentedError?.message }
        }
    }
}

private struct LiveSourceSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @State private var showingImport = false
    @State private var showingFileImporter = false
    @State private var pendingDelete: StoredLiveSource?
    @State private var epgEditingSource: StoredLiveSource?

    var body: some View {
        SettingsPage(
            title: SettingsL10n.string("settings.pane.live.title", "Live TV Sources"),
            subtitle: SettingsL10n.string("settings.live.subtitle", "Import, refresh, and maintain live TV channel lists")
        ) {
            EPGSettingsSection()
            SettingsSectionTitle(SettingsL10n.string("settings.live.manage.section", "Source Management"))

            if state.liveSources.isEmpty {
                SettingsCard {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary)
                        Text(SettingsL10n.string("settings.live.empty.title", "No Live TV Sources"))
                            .font(.headline)
                        Text(SettingsL10n.string("settings.live.empty.subtitle", "Supports remote URLs, local M3U/M3U8/TXT/JSON files, and pasted content."))
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                }
            } else {
                SettingsCard {
                    ForEach(Array(state.liveSources.enumerated()), id: \.element.id) {
                        index, source in
                        if index > 0 {
                            SettingsDivider()
                        }
                        sourceRow(source)
                    }
                }
            }

            SettingsSectionTitle(SettingsL10n.string("settings.live.add.section", "Add a Source"))
            SettingsCard {
                SettingsControlRow(
                    icon: "link.badge.plus",
                    color: .teal,
                    title: SettingsL10n.string("settings.live.add-url.title", "Add from URL or Pasted Content"),
                    subtitle: SettingsL10n.string("settings.live.add-url.subtitle", "Remote sources can be downloaded and refreshed again at any time")
                ) {
                    Button(SettingsL10n.string("settings.common.add", "Add…")) {
                        showingImport = true
                    }
                }
                SettingsDivider()
                SettingsControlRow(
                    icon: "folder.fill.badge.plus",
                    color: .blue,
                    title: SettingsL10n.string("settings.live.import-file.title", "Import Local Live TV File"),
                    subtitle: SettingsL10n.string("settings.live.import-file.subtitle", "Supports M3U, M3U8, TXT, and JSON")
                ) {
                    Button(SettingsL10n.string("settings.common.choose-file", "Choose File…")) {
                        showingFileImporter = true
                    }
                }
            }

            SettingsSectionTitle(SettingsL10n.string("settings.common.about.section", "About"))
            SettingsCard {
                Label(
                    SettingsL10n.string("settings.live.management.note", "Use the Live TV page to browse and play channels. Add, remove, and update sources here."),
                    systemImage: "info.circle"
                )
                .foregroundColor(.secondary)
                .padding(18)
            }
        }
        .sheet(isPresented: $showingImport) {
            LiveSourceImportSheet(isPresented: $showingImport)
                .environmentObject(state)
                .frame(width: 620, height: 500)
        }
        .sheet(item: $epgEditingSource) { source in
            SourceEPGSettingsSheet(source: source, preference: state.epgPreferences.source(source.id))
                .environmentObject(state)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: liveFileTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await state.importLiveSource(
                        source: .localFile(url),
                        name: url.deletingPathExtension().lastPathComponent
                    )
                }
            case .failure(let error):
                state.presentedError = UserFacingError(
                    title: SettingsL10n.string("settings.live.file-selection.failed", "Unable to Select Live TV File"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
        .alert(item: $pendingDelete) { source in
            Alert(
                title: Text(SettingsL10n.string("settings.live.delete.title", "Delete “%@”?", source.name)),
                message: Text(SettingsL10n.string("settings.live.delete.message", "Only this live TV source will be removed. Video providers, favorites, and history are unaffected.")),
                primaryButton: .destructive(Text(SettingsL10n.string("settings.common.delete", "Delete"))) {
                    Task { await state.deleteLiveSource(source.id) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func sourceRow(_ source: StoredLiveSource) -> some View {
        HStack(spacing: 13) {
            SettingsRowIcon(
                systemImage: source.sourceKind == .remote
                    ? "network"
                    : source.sourceKind == .localFile
                    ? "doc.fill"
                    : "text.alignleft",
                color: source.sourceKind == .remote ? .teal : .blue
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(sourceDescription(source))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(SettingsL10n.string(
                    "settings.live.updated-at",
                    "Updated %@",
                    source.updatedAt.formatted(
                        Date.FormatStyle(
                            date: .abbreviated,
                            time: .shortened,
                            locale: L10n.locale
                        )
                    )
                ))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                LiveSourceValidationStatusObserver(activity: state.liveValidationActivity, sourceID: source.id) { status in
                    liveSourceValidationStatus(status)
                }
            }
            Spacer()
            Button(SettingsL10n.string("settings.epg.edit", "Programme Guide…")) {
                epgEditingSource = source
            }
            .disabled(state.isSavingEPGPreferences)
            if source.sourceKind == .remote {
                Button {
                    Task { await state.refreshLiveSource(source.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.isLoading)
                .help(SettingsL10n.string("settings.live.refresh.help", "Refresh Live TV Source"))
            }
            Button(role: .destructive) {
                pendingDelete = source
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(SettingsL10n.string("settings.live.delete.help", "Delete Live TV Source"))
        }
        .padding(16)
    }

    @ViewBuilder
    private func liveSourceValidationStatus(
        _ status: LiveSourceValidationStatus
    ) -> some View {
        switch status {
        case .checking(let completed, let total):
            HStack(spacing: 6) {
                AppActivityIndicator(size: .mini)
                Text(SettingsL10n.string("settings.live.health-check.progress", "Checking channels in the background: %d/%d", completed, total))
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        case .processing:
            Label(SettingsL10n.string("live.health-check.processing", "Processing channel check results…"), systemImage: "hourglass")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .cancelled(let completed, let total):
            Label(SettingsL10n.string("live.health-check.cancelled", "Channel check stopped: %d/%d; unchecked channels were kept", completed, total), systemImage: "pause.circle")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .partial(let completed, let total):
            Label(SettingsL10n.string("live.health-check.partial", "Channel check reached its time limit: %d/%d; no partial results applied", completed, total), systemImage: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .completed(let removed, let total):
            Label(
                removed == 0
                    ? SettingsL10n.string("settings.live.health-check.clean", "Checked %d channels; no confirmed failures found", total)
                    : SettingsL10n.string("settings.live.health-check.removed", "Checked %d channels; removed %d recoverable failures", total, removed),
                systemImage: removed == 0
                    ? "checkmark.circle"
                    : "trash.slash"
            )
            .font(.caption2)
            .foregroundColor(.secondary)
        case .failed(let message):
            Label(SettingsL10n.string("settings.live.health-check.failed", "Background check did not finish: %@", message), systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundColor(.orange)
                .lineLimit(2)
        }
    }

    private func sourceDescription(_ source: StoredLiveSource) -> String {
        switch source.sourceKind {
        case .remote:
            guard let value = source.sourceValue,
                  let url = URL(string: value) else {
                return SettingsL10n.string("settings.live.source.remote-url", "Remote URL")
            }
            return LogRedactor.url(url)
        case .localFile:
            return source.sourceValue
                ?? SettingsL10n.string("settings.live.source.local-file", "Local File")
        case .pasted:
            return SettingsL10n.string("settings.live.source.pasted", "Pasted Content")
        }
    }

    private var liveFileTypes: [UTType] {
        var types: [UTType] = [.plainText, .json]
        if let m3u = UTType(filenameExtension: "m3u") {
            types.append(m3u)
        }
        if let m3u8 = UTType(filenameExtension: "m3u8") {
            types.append(m3u8)
        }
        return types
    }
}

private struct PlayerWindowSettingsControl: View {
    @ObservedObject var preferences: PlayerWindowPreferenceStore
    let setMode: (PlayerWindowMode) -> Void
    let restoreDefault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                SettingsRowIcon(
                    systemImage: "play.rectangle.on.rectangle.fill",
                    color: .purple
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(SettingsL10n.string("settings.player-window.title", "Player Window"))
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 45)

                Picker(
                    SettingsL10n.string("settings.player-window.mode.label", "Player Window Mode"),
                    selection: Binding(
                        get: { preferences.preference.mode },
                        set: setMode
                    )
                ) {
                    ForEach(PlayerWindowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 330)

                Button(SettingsL10n.string("settings.common.restore-default", "Restore Default"), action: restoreDefault)
                    .help(SettingsL10n.string("settings.player-window.restore.help", "Clear the saved player window size, position, and mode"))
                    .fixedSize()
            }
        }
        .padding(16)
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

private extension SettingsPane {
    var title: String {
        switch self {
        case .general: return SettingsL10n.string("settings.pane.general.title", "General")
        case .configurations: return SettingsL10n.string("settings.pane.providers.title", "Video Providers")
        case .search: return SettingsL10n.string("settings.pane.search.title", "Search")
        case .liveSources: return SettingsL10n.string("settings.pane.live.title", "Live TV Sources")
        case .playback: return SettingsL10n.string("settings.pane.playback.title", "Playback")
        case .cache: return SettingsL10n.string("settings.pane.cache.title", "Storage")
        case .backup: return SettingsL10n.string("settings.pane.backup.title", "Backup & Restore")
        case .advanced: return SettingsL10n.string("settings.pane.advanced.title", "Advanced")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return SettingsL10n.string("settings.pane.general.subtitle", "Appearance and basic settings")
        case .configurations: return SettingsL10n.string("settings.pane.providers.subtitle", "Import and switch provider sources")
        case .search: return SettingsL10n.string("settings.pane.search.subtitle", "Choose Default Search Providers")
        case .liveSources: return SettingsL10n.string("settings.pane.live.subtitle", "Import and manage live TV sources")
        case .playback: return SettingsL10n.string("settings.pane.playback.subtitle", "Player and playback settings")
        case .cache: return SettingsL10n.string("settings.pane.cache.subtitle", "Manage cache and history")
        case .backup: return SettingsL10n.string("settings.pane.backup.subtitle", "Back up providers and history")
        case .advanced: return SettingsL10n.string("settings.pane.advanced.subtitle", "Diagnostics and runtime information")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .configurations: return "doc.badge.gearshape"
        case .search: return "magnifyingglass.circle.fill"
        case .liveSources: return "dot.radiowaves.left.and.right"
        case .playback: return "play.rectangle.fill"
        case .cache: return "externaldrive.fill"
        case .backup: return "archivebox.fill"
        case .advanced: return "slider.horizontal.3"
        }
    }

    var color: Color {
        switch self {
        case .general: return .blue
        case .configurations: return .indigo
        case .search: return .purple
        case .liveSources: return .teal
        case .playback: return .pink
        case .cache: return .orange
        case .backup: return .cyan
        case .advanced: return .green
        }
    }
}

enum HistoryRetentionPresets {
    static let standardDays = [30, 60, 90, 180, 365, 3_650]

    static func options(including currentDays: Int) -> [Int] {
        guard !standardDays.contains(currentDays) else { return standardDays }
        return (standardDays + [currentDays]).sorted()
    }

    static func title(for days: Int) -> String {
        switch days {
        case 365:
            return SettingsL10n.string("settings.history.retention.one-year", "1 year")
        case 3_650:
            return SettingsL10n.string("settings.history.retention.ten-years", "10 years")
        default:
            return SettingsL10n.string("settings.history.retention.days", "%d days", days)
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content
    private let scrollCoordinateSpace = "settings-page-scroll"

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            BrowserToolbarScrollMarker(
                coordinateSpaceName: scrollCoordinateSpace
            )
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.largeTitle.bold())
                    Text(subtitle)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 4)

                content
            }
            .padding(24)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .browserToolbarScrollSurface(named: scrollCoordinateSpace)
        .background(.thinMaterial)
    }
}

struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .padding(.top, 4)
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }
}

struct SettingsControlRow<Control: View>: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let control: Control

    init(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 13) {
            SettingsRowIcon(systemImage: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            control
        }
        .padding(16)
    }
}

private struct SettingsInfoRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack(spacing: 13) {
            SettingsRowIcon(systemImage: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(16)
    }
}

struct SettingsRowIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 61)
    }
}


private struct AppUpdateSettingsSection: View {
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
