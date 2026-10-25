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

private struct EPGSettingsSection: View {
    @EnvironmentObject private var state: AppState
    @State private var editingURL = false
    @State private var errorMessage: String?
    var body: some View {
        SettingsSectionTitle(SettingsL10n.string("settings.organized.epg.defaults", "Programme Guide Defaults"))
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                Text(SettingsL10n.string("settings.epg.enabled", "Automatically Load EPG"))
                Spacer()
                Toggle(SettingsL10n.string("settings.epg.enabled", "Automatically Load EPG"), isOn: Binding(
                    get: { state.epgPreferences.automaticEPGEnabled },
                    set: { enabled in
                        var next = state.epgPreferences; next.automaticEPGEnabled = enabled
                        Task {
                            errorMessage = await state.saveEPGPreferences(next) ? nil : state.presentedError?.message
                        }
                    }
                )).toggleStyle(.switch).labelsHidden()
                }
                Text(SettingsL10n.string("settings.organized.epg.global.help", "This switch applies to all imported live sources. Automatic sources use an embedded guide first, then the default address below."))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SettingsL10n.string("settings.epg.default-url", "Default EPG Address"))
                        Text(state.epgPreferences.defaultEPGURL?.isEmpty == false
                            ? SettingsL10n.string("settings.organized.epg.default.configured", "Custom default address configured")
                            : SettingsL10n.string("settings.organized.epg.default.none", "No fallback address configured"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(SettingsL10n.string("settings.organized.common.edit", "Edit…")) { editingURL = true }
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }.padding(12).disabled(state.isSavingEPGPreferences)
        }.settingsAnchor("epg")
        .sheet(isPresented: $editingURL) { DefaultEPGEditor() }
    }
}

private struct DefaultEPGEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var original = ""
    @State private var errorMessage: String?
    @State private var discard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSheetHeader(title: SettingsL10n.string("settings.epg.default-url", "Default EPG Address"),
                subtitle: SettingsL10n.string("settings.epg.default-help", "HTTP/HTTPS XMLTV or XMLTV.gz. Used only when an automatic source has no embedded EPG. Changes take effect after saving."))
            TextField("https://example.com/guide.xml.gz", text: $url).textFieldStyle(.roundedBorder)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(SettingsL10n.string("settings.organized.epg.default.clear", "Clear Address")) { url = "" }
                Spacer()
                Button(SettingsL10n.string("settings.common.cancel", "Cancel")) {
                    if url != original { discard = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(SettingsL10n.string("settings.common.save", "Save")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(url == original)
            }
        }.padding(24).frame(width: 540).disabled(state.isSavingEPGPreferences)
        .interactiveDismissDisabled(url != original || state.isSavingEPGPreferences)
        .onAppear { original = state.epgPreferences.defaultEPGURL ?? ""; url = original }
        .alert(SettingsL10n.string("settings.organized.draft.discard.title", "Discard Unsaved Changes?"), isPresented: $discard) {
            Button(SettingsL10n.string("settings.organized.draft.keep", "Keep Editing"), role: .cancel) {}
            Button(SettingsL10n.string("settings.organized.draft.discard", "Discard Changes"), role: .destructive) { dismiss() }
        }
    }
    private func save() {
        var next = state.epgPreferences; next.defaultEPGURL = url
        Task {
            if await state.saveEPGPreferences(next) { dismiss() }
            else { errorMessage = state.presentedError?.message }
        }
    }
}

private struct SourceEPGSettingsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let source: StoredLiveSource
    @State private var discard = false
    private let original: EPGSourcePreference
    @State private var mode: EPGSourceMode
    @State private var urlDraft: String
    @State private var errorMessage: String?

    init(source: StoredLiveSource, preference: EPGSourcePreference) {
        self.source = source
        self.original = preference
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
                Button(SettingsL10n.string("settings.common.cancel", "Cancel")) {
                    if hasChanges { discard = true } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(SettingsL10n.string("settings.epg.save", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480)
        .disabled(state.isSavingEPGPreferences)
        .interactiveDismissDisabled(hasChanges || state.isSavingEPGPreferences)
        .alert(SettingsL10n.string("settings.organized.draft.discard.title", "Discard Unsaved Changes?"), isPresented: $discard) {
            Button(SettingsL10n.string("settings.organized.draft.keep", "Keep Editing"), role: .cancel) {}
            Button(SettingsL10n.string("settings.organized.draft.discard", "Discard Changes"), role: .destructive) { dismiss() }
        }
    }
    private var hasChanges: Bool {
        mode != original.mode || (mode == .custom && urlDraft != (original.customEPGURL ?? ""))
    }
    private func save() {
        guard state.liveSources.contains(where: { $0.id == source.id }) else { dismiss(); return }
        var next = state.epgPreferences
        next.sources[source.id.uuidString] = EPGSourcePreference(mode: mode, customEPGURL: urlDraft)
        errorMessage = nil
        Task {
            if await state.saveEPGPreferences(next) { dismiss() }
            else { errorMessage = state.presentedError?.message }
        }
    }
}

struct LiveSourceSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @State private var showingImport = false
    @State private var showingFileImporter = false
    @State private var pendingDelete: StoredLiveSource?
    @State private var epgEditingSource: StoredLiveSource?

    var body: some View {
        SettingsPage(
            title: SettingsPane.liveSources.title,
            subtitle: SettingsL10n.string("settings.live.subtitle", "Import, refresh, and maintain live TV channel lists")
        ) {
            HStack {
                SettingsSectionTitle(SettingsL10n.string("settings.live.manage.section", "Source Management"))
                Spacer()
                Menu {
                    Button(SettingsL10n.string("settings.live.add-url.title", "Add from URL or Pasted Content")) { showingImport = true }
                    Button(SettingsL10n.string("settings.live.import-file.title", "Import Local Live TV File")) { showingFileImporter = true }
                } label: { Label(SettingsL10n.string("settings.organized.live.add", "Add Live Source"), systemImage: "plus") }
                    .fixedSize()
            }.settingsAnchor("live-sources")

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

            EPGSettingsSection()

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
                    .font(.system(size: 13))
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
                Text(epgSummary(source.id)).font(.caption).foregroundStyle(.secondary)
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

    private func epgSummary(_ id: UUID) -> String {
        switch state.settingsEPGOrigin(for: id) {
        case "off": return SettingsL10n.string("settings.organized.epg.summary.off", "Programme guide: off")
        case "custom": return SettingsL10n.string("settings.organized.epg.summary.custom", "Programme guide: custom address")
        case "embedded": return SettingsL10n.string("settings.organized.epg.summary.embedded", "Programme guide: source address")
        case "global": return SettingsL10n.string("settings.organized.epg.summary.global", "Programme guide: global default")
        case "none": return SettingsL10n.string("settings.organized.epg.summary.none", "Programme guide: no address")
        default: return SettingsL10n.string("settings.organized.epg.summary.automatic", "Programme guide: automatic · source address first")
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

