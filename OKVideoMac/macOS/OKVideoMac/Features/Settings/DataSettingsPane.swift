import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct DataSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: SettingsNavigationState
    @State private var posterCacheSize = SettingsL10n.string("settings.cache.calculating", "Calculating…")
    @State private var pendingHistoryDeletion: [HistoryRecord]?
    @State private var historyDeletionName = ""
    @State private var pendingRetention: Int?
    private let diagnostics = AppLaunchSession.current?.diagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(SettingsL10n.string("settings.organized.data.sections", "Data Categories"), selection: $navigation.dataTab) {
                ForEach(SettingsDataTab.allCases) { tab in Text(tab.title).tag(tab) }
            }.labelsHidden().pickerStyle(.segmented).disabled(state.isBackupBusy).frame(maxWidth: 440).padding(.horizontal, 32).padding(.top, 4).padding(.bottom, 12)
            switch navigation.dataTab {
            case .privacy: privacySettings
            case .storage: cacheSettings
            case .backup: backupSettings
            }
        }
        .sheet(item: $state.pendingBackupImport) { preview in
            PortableBackupImportPreviewSheet(preview: preview,
                cancel: { state.pendingBackupImport = nil },
                confirm: { state.pendingBackupImport = nil; importPortableBackup(from: preview.fileURL) })
                .frame(width: 560, height: 440)
        }
        .alert(SettingsL10n.string("settings.organized.history.clear.title", "Clear Watch History?"), isPresented: Binding(get: { pendingHistoryDeletion != nil }, set: { if !$0 { pendingHistoryDeletion = nil } })) {
            Button(SettingsL10n.string("settings.common.cancel", "Cancel"), role: .cancel) {}
            Button(SettingsL10n.string("settings.organized.history.clear", "Clear Watch History"), role: .destructive) {
                if let records = pendingHistoryDeletion { Task { await state.deleteHistory(records: records) } }
                pendingHistoryDeletion = nil
            }
        } message: {
            Text(historyDeletionName + "\n" + SettingsL10n.string("settings.organized.history.clear.message", "Only the listed configuration’s watch history will be removed. Favorites and other configurations are kept. This cannot be undone."))
        }
        .alert(SettingsL10n.string("settings.organized.history.retention.title", "Shorten History Retention?"), isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button(SettingsL10n.string("settings.common.cancel", "Cancel"), role: .cancel) { pendingRetention = nil }
            Button(SettingsL10n.string("settings.organized.history.retention.confirm", "Apply Retention"), role: .destructive) {
                if let days = pendingRetention { Task { await state.setHistoryRetentionDays(days) } }
                pendingRetention = nil
            }
        } message: { Text(SettingsL10n.string("settings.organized.history.retention.message", "Existing history older than the selected period will also be removed.")) }
    }

    private var privacySettings: some View {
        SettingsPage(title: SettingsDataTab.privacy.title, subtitle: SettingsL10n.string("settings.organized.privacy.subtitle", "Applies to this Mac and all configurations")) {
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
                                if value < state.historyRetentionDays { pendingRetention = value }
                                else { Task { await state.setHistoryRetentionDays(value) } }
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
            }.settingsAnchor("history")

            historyCard
            if let diagnostics {
                SettingsSectionTitle(SettingsL10n.string("settings.organized.privacy.diagnostics", "Crash Reports"))
                SettingsCard { CrashDiagnosticsControls(diagnostics: diagnostics).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                    .settingsAnchor("crash-reports")
            }
        }
    }
    private var cacheSettings: some View {
        SettingsPage(
            title: SettingsDataTab.storage.title,
            subtitle: SettingsL10n.string("settings.organized.storage.subtitle", "Manage images stored on this Mac")
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
                        Button(SettingsL10n.string("settings.organized.cache.clear", "Clear Image Cache")) {
                            Task {
                                _ = await state.clearPosterCache()
                                await refreshCacheSize()
                            }
                        }.disabled(state.isClearingPosterCache)
                        if state.isClearingPosterCache { ProgressView().controlSize(.small) }
                    }
                }
            }.settingsAnchor("image-cache")
            if let cacheMessage = state.posterCacheOperationMessage { Text(cacheMessage).font(.caption).foregroundStyle(.secondary) }

            SettingsCard {
                SettingsControlRow(icon: "externaldrive", color: .secondary,
                    title: SettingsL10n.string("settings.android.section.title", "Android Compatibility"),
                    subtitle: SettingsL10n.string("settings.organized.storage.android.help", "Component storage and maintenance are managed with the runtime.")) {
                    Button(SettingsL10n.string("settings.organized.storage.android.manage", "Manage…")) {
                        navigation.select(.advanced, sectionID: "maintenance")
                    }
                }
            }
        }
        .task { await refreshCacheSize() }
    }

    @ViewBuilder private var historyCard: some View {
            SettingsSectionTitle(SettingsL10n.string("settings.cache.history.section", "Watch History"))
            WatchHistoryObserver(history: state.watchHistory) { records in
                SettingsCard {
                    SettingsControlRow(
                        icon: "clock.fill",
                        color: .blue,
                        title: SettingsL10n.string("settings.cache.history.title", "Watch History"),
                        subtitle: (state.activeConfigurationRecord?.name ?? SettingsL10n.string("settings.common.not-set", "Not Set")) + " · " +
                            SettingsL10n.string("settings.cache.history.count", "%d records saved", records.count)
                    ) {
                        Button(SettingsL10n.string("settings.organized.history.clear", "Clear Watch History"), role: .destructive) {
                            historyDeletionName = state.activeConfigurationRecord?.name ?? ""
                            pendingHistoryDeletion = records
                        }
                        .disabled(records.isEmpty)
                    }
                }
            }
    }

    private var backupSettings: some View {
        SettingsPage(
            title: SettingsDataTab.backup.title,
            subtitle: SettingsL10n.string("settings.organized.backup.subtitle", "Back up the active configuration and its associated data")
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
                WatchHistoryObserver(history: state.watchHistory) { records in
                    SettingsInfoRow(
                        icon: "clock.arrow.circlepath",
                        color: .blue,
                        title: SettingsL10n.string("settings.backup.history.title", "Related Watch History"),
                        subtitle: SettingsL10n.string("settings.backup.history.detail", "Includes source, episode, playback position, and watch time"),
                        value: SettingsL10n.string("settings.common.item-count", "%d items", AppState.historyRecords(records, for: state.activeConfigurationRecord?.id).count)
                    )
                }
                SettingsDivider()
                SettingsInfoRow(icon: "star", color: .blue, title: L10n.string(.sectionFavorites),
                    subtitle: SettingsL10n.string("settings.organized.backup.favorites.help", "Includes favorites owned by this configuration. Unconfirmed sources and other configurations are excluded."),
                    value: String(state.favorites.filter { $0.configurationID != nil && $0.configurationID == state.activeConfigurationRecord?.id }.count))
            }

            SettingsSectionTitle(SettingsL10n.string("settings.backup.manual.section", "Manual Backup"))
            SettingsCard {
                SettingsControlRow(
                    icon: "square.and.arrow.up.fill",
                    color: .teal,
                    title: SettingsL10n.string("settings.organized.backup.current", "Back Up Current Configuration"),
                    subtitle: SettingsL10n.string("settings.backup.export.subtitle", "Create a version-validated .okvideobackup file")
                ) {
                    Button(SettingsL10n.string("settings.common.export", "Export…")) {
                        exportPortableBackup()
                    }
                    .disabled(
                        state.isBackupBusy || state.activeConfigurationRecord == nil
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
                    .disabled(state.isBackupBusy)
                }
            }.settingsAnchor("backup")

            Text(SettingsL10n.string("settings.organized.backup.not-whole-app", "This is a configuration backup, not a complete backup of the application."))
                .font(.caption).foregroundStyle(.secondary)

            if state.isBackupBusy || state.backupOperationMessage != nil {
                SettingsSectionTitle(SettingsL10n.string("settings.common.status", "Status"))
                SettingsCard {
                    HStack(spacing: 10) {
                        if state.isBackupBusy {
                            AppActivityIndicator(size: .small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        Text(
                            state.isBackupBusy
                                ? SettingsL10n.string("settings.backup.processing", "Validating and processing the backup…")
                                : state.backupOperationMessage ?? ""
                        )
                        .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(16)
                }
            }

            SettingsDisclosure("backup-scope", title: SettingsL10n.string("settings.organized.backup.scope", "Included Data & Exclusions")) {
                Text(SettingsL10n.string("settings.organized.backup.includes", "Includes this configuration’s history, favorites, skip rules, completion markers, and saved danmaku bindings."))
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
                Label(
                    SettingsL10n.string("settings.backup.security.message", "Backups do not export Keychain items, cloud account status, QR codes, temporary playback URLs, or Android virtual machine data. Original configuration text is included and may contain private provider URLs. The file is not encrypted, so store it securely. If cloud authorization is no longer valid after a restore, the player will request it again."),
                    systemImage: "lock.shield.fill"
                )
                .foregroundColor(.secondary)
                .padding(18)
            }
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

    private func exportPortableBackup() {
        guard !state.isBackupBusy else { return }
        guard let record = state.activeConfigurationRecord else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.okVideoBackup]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = portableBackupFileName(for: record.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.backupOperationMessage = nil
        Task { @MainActor in
            do {
                let preview = try await state.exportPortableBackup(to: url)
                state.backupOperationMessage = SettingsL10n.string(
                    "settings.backup.export.success",
                    "Exported “%@” with %d history items.",
                    preview.configurationName,
                    preview.historyCount
                ) + " · " + SettingsL10n.string("settings.organized.backup.favorites.count", "%d favorites", preview.favoriteCount)
            } catch {
                state.backupOperationMessage = RuntimeUserFacingMessageMapper.message(for: error)
                state.presentedError = UserFacingError(
                    title: SettingsL10n.string("settings.backup.export.failed", "Backup Export Failed"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

    private func choosePortableBackup() {
        guard !state.isBackupBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.okVideoBackup]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = SettingsL10n.string("settings.backup.validate", "Validate Backup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.backupOperationMessage = nil
        Task { @MainActor in
            do {
                state.pendingBackupImport = try await state.inspectPortableBackup(
                    at: url
                )
            } catch {
                state.backupOperationMessage = RuntimeUserFacingMessageMapper.message(for: error)
                state.presentedError = UserFacingError(
                    title: SettingsL10n.string("settings.backup.read.failed", "Unable to Read Backup"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
    }

    private func importPortableBackup(from url: URL) {
        guard !state.isBackupBusy else { return }
        state.backupOperationMessage = nil
        Task { @MainActor in
            do {
                let summary = try await state.importPortableBackup(from: url)
                let safetyText = summary.safetyBackupURL == nil
                    ? ""
                    : SettingsL10n.string("settings.backup.restore.safety-suffix", " Your previous data was saved as a safety backup.")
                state.backupOperationMessage = SettingsL10n.string(
                    "settings.backup.restore.success",
                    "Restored “%@”. Checked %d history items and added or updated %d.%@",
                    summary.configurationName,
                    summary.historyCount,
                    summary.changedHistoryCount,
                    safetyText
                )
            } catch {
                state.backupOperationMessage = RuntimeUserFacingMessageMapper.message(for: error)
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
    }}

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

