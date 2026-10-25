import OKVideoCore
import SwiftUI

struct SourceSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @State private var editingScope = false
    var body: some View {
        SettingsPage(title: SettingsPane.configurations.title,
            subtitle: SettingsL10n.string("settings.organized.sources.subtitle", "Manage configurations and their default search sites")) {
            ConfigurationView(embedded: true, editSearchScope: { editingScope = true })
                .settingsAnchor("providers")
        }
        .sheet(isPresented: $editingScope) {
            SearchScopeSettingsEditor(configurationID: state.activeConfigurationRecord?.id)
        }
    }
}

struct SearchScopeSettingsEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let configurationID: UUID?
    @State private var mode: SearchSiteScopeMode = .all
    @State private var selectedKeys: Set<String> = []
    @State private var filterText = ""
    @State private var original = SearchSiteScope(mode: .all, selectedSiteKeys: [])
    @State private var isSaving = false
    @State private var discardChanges = false
    @State private var errorMessage: String?
    private var draft: SearchSiteScope { .init(mode: mode, selectedSiteKeys: selectedKeys) }
    private var hasChanges: Bool { draft != original }
    private var configurationIsCurrent: Bool { configurationID != nil && configurationID == state.activeConfigurationRecord?.id }
    private var valid: Bool {
        mode == .all || !SearchSiteScopePolicy.effectiveSiteKeys(scope: draft, options: state.searchScopeSiteOptions).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSheetHeader(title: SettingsL10n.string("settings.search.default-scope.section", "Default Search Scope"),
                subtitle: state.activeConfigurationRecord?.name ?? SettingsL10n.string("settings.common.not-set", "Not Set"))
            Text(SettingsL10n.string("settings.organized.search.scope.help", "Saved for this configuration only. Changes apply to the next Home or Search request."))
                .font(.callout).foregroundStyle(.secondary)
            SearchScopeEditorContent(options: state.searchScopeSiteOptions, mode: $mode,
                selectedKeys: $selectedKeys, filterText: $filterText)
                .frame(minHeight: 300, maxHeight: .infinity)
                .disabled(isSaving || !configurationIsCurrent)
            if !configurationIsCurrent {
                Text(SettingsL10n.string("settings.organized.search.scope.changed", "The active configuration changed. Close this editor and reopen it for the new configuration."))
                    .font(.callout).foregroundStyle(.orange)
            }
            if !valid { Text(SettingsL10n.string("settings.search.minimum-one", "Select at least one available provider")).font(.caption).foregroundStyle(.red) }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            Text(SettingsL10n.string("settings.search.note.result-filter", "The Result Providers control only filters existing results and does not make new network requests."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(SettingsL10n.string("settings.search.restore-all", "Restore All Providers")) { mode = .all; selectedKeys = [] }
                Spacer()
                Button(SettingsL10n.string("settings.common.cancel", "Cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(SettingsL10n.string("settings.common.save", "Save")) { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!valid || !hasChanges || !configurationIsCurrent)
            }.disabled(isSaving)
        }
        .padding(24).frame(width: 680, height: 620)
        .interactiveDismissDisabled(hasChanges || isSaving)
        .onAppear {
            original = state.searchSiteScope; mode = original.mode; selectedKeys = original.selectedSiteKeys
        }
        .alert(SettingsL10n.string("settings.organized.draft.discard.title", "Discard Unsaved Changes?"), isPresented: $discardChanges) {
            Button(SettingsL10n.string("settings.organized.draft.keep", "Keep Editing"), role: .cancel) {}
            Button(SettingsL10n.string("settings.organized.draft.discard", "Discard Changes"), role: .destructive) { dismiss() }
        }
    }
    private func close() { if hasChanges { discardChanges = true } else { dismiss() } }
    private func save() {
        guard configurationIsCurrent, valid, !isSaving else { return }
        isSaving = true; errorMessage = nil
        let value = draft
        Task {
            if await state.saveSearchSiteScope(value) { original = value; dismiss() }
            else { errorMessage = state.presentedError?.message ?? SettingsL10n.string("settings.organized.draft.failed", "Unable to save. Your previous settings were kept.") }
            isSaving = false
        }
    }
}
