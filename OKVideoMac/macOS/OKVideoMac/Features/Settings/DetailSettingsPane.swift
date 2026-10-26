import AppKit
import AndroidRuntimeKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct DetailSettingsPane: View {
    @ObservedObject var runtime: TMDBNetworkRuntime = .shared
    var body: some View {
        SettingsPage(title: SettingsPane.details.title,
            subtitle: SettingsL10n.string("settings.organized.details.subtitle", "Presentation, metadata connection, and matching rules")) {
            SettingsSectionTitle(SettingsL10n.string("settings.organized.details.presentation", "Presentation"))
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.string("detail.presentation.title", fallback: "Detail Page Style"))
                        Spacer(minLength: 16)
                        DetailPresentationPicker(runtime: runtime)
                    }
                    Text(L10n.string("detail.presentation.automatic-help", fallback: "Use original details until a saved credential and both TMDB connections are ready."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(TMDBPresentationStatus.title(runtime.presentationDecision))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.detail-presentation-status")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.settingsAnchor("detail-style")
            SettingsSectionTitle(SettingsL10n.string("settings.organized.tmdb.connection", "TMDB Connection"))
            SettingsCard { TMDBConnectionSummary(runtime: runtime) }.settingsAnchor("tmdb-connection")
            SettingsSectionTitle(SettingsL10n.string("settings.organized.tmdb.matching", "Matching Rules"))
            SettingsCard { TMDBRelaxedMatchingSetting() }.settingsAnchor("matching")
        }
    }
}

private struct TMDBConnectionSummary: View {
    @ObservedObject var runtime: TMDBNetworkRuntime = .shared
    @State private var showingEditor = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("tmdb.direct.enabled", fallback: "Load TMDB information directly"))
                Spacer()
                Toggle(L10n.string("tmdb.direct.enabled", fallback: "Load TMDB information directly"),
                isOn: Binding(get: { runtime.enabled }, set: { value in Task { await runtime.setEnabled(value) } }))
                .toggleStyle(.switch).labelsHidden().disabled(runtime.busy)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(runtime.credentialKind == nil
                        ? L10n.string("tmdb.direct.not-configured", fallback: "Not configured · source playback remains available")
                        : L10n.string("tmdb.direct.configured", fallback: "Saved in Keychain · connects directly to TMDB"))
                    if let links = runtime.links {
                        Text("API: " + TMDBConnectionStatus.title(links.metadata) + " · " +
                            L10n.string("tmdb.direct.images", fallback: "Images") + ": " + TMDBConnectionStatus.title(links.images))
                    } else {
                        Text(SettingsL10n.string("settings.organized.tmdb.not-tested", "Connection not checked"))
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button(runtime.credentialKind == nil
                    ? SettingsL10n.string("settings.organized.tmdb.configure", "Configure…")
                    : SettingsL10n.string("settings.organized.tmdb.manage", "Manage…")) { showingEditor = true }
            }
            Text(SettingsL10n.string("settings.organized.tmdb.scope", "Automatic selection uses TMDB only when the API and image connections are ready. The current page keeps its layout."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
        .sheet(isPresented: $showingEditor) { TMDBDirectSettings(runtime: runtime) }
    }
}

enum TMDBConnectionStatus {
    static func title(_ link: TMDBAvailabilitySnapshot.Link) -> String {
        func text(_ key: String, _ fallback: String) -> String { L10n.string("tmdb.direct." + key, fallback: fallback) }
        if link.checking { return text("checking", "Checking…") }
        if link.state == .available, link.validUntil <= ProcessInfo.processInfo.systemUptime { return text("unknown", "Not checked") }
        switch link.state {
        case .available: return text("available", "Connected")
        case .unknown: return text("unknown", "Not checked")
        case .unavailable:
            switch link.failure {
            case .configuration: return text("status-auth", "Credential rejected")
            case .rateLimited: return text("status-rate", "Rate limited; waiting")
            case .server: return text("status-server", "Service unavailable")
            case .invalidResponse: return text("status-response", "Unexpected response")
            default: return text("status-network", "Connection failed")
            }
        }
    }
}

enum TMDBPresentationStatus {
    static func title(_ decision: TMDBPresentationDecision) -> String {
        switch decision {
        case .originalPreference:
            return L10n.string("detail.presentation.status-original", fallback: "Always using original details, as selected.")
        case .serviceDisabled:
            return L10n.string("detail.presentation.status-disabled", fallback: "Using original details: the TMDB connection is off.")
        case .loadingCredential:
            return L10n.string("detail.presentation.status-loading", fallback: "Using original details while reading the credential.")
        case .missingCredential:
            return L10n.string("detail.presentation.status-missing", fallback: "Using original details: no TMDB credential is configured.")
        case .unchecked:
            return L10n.string("detail.presentation.status-unchecked", fallback: "Using original details until both connections are verified.")
        case .checking:
            return L10n.string("detail.presentation.status-checking", fallback: "Using original details while checking the connection.")
        case .connectionUnavailable:
            return L10n.string("detail.presentation.status-unavailable", fallback: "Using original details: the API or image connection is unavailable.")
        case .ready:
            return L10n.string("detail.presentation.status-ready", fallback: "TMDB is ready. Automatic selection applies on the next detail page.")
        }
    }
}

struct DetailPresentationPicker: View {
    @ObservedObject var runtime: TMDBNetworkRuntime = .shared
    var body: some View {
        Picker(L10n.string("detail.presentation.title", fallback: "Detail Page Style"),
            selection: Binding(get: { runtime.preference }, set: { runtime.setPreference($0) })) {
            Text(L10n.string("detail.presentation.automatic", fallback: "Automatic (Recommended)")).tag(TMDBPresentationPreference.automatic)
            Text(L10n.string("detail.presentation.always-original", fallback: "Always Original")).tag(TMDBPresentationPreference.original)
        }
        .labelsHidden().pickerStyle(.menu).frame(width: 200)
        .accessibilityIdentifier("settings.detail-presentation")
    }
}


struct TMDBRelaxedMatchingSetting: View {
    @AppStorage(TMDBMatchingPreferences.key) private var enabled = false
    @State private var detailsExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("tmdb.match.relaxed.title", fallback: "Relaxed Detail Matching"))
                Text(SettingsL10n.string("settings.organized.tmdb.match.short", "Allows a unique title match when source information is incomplete."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(L10n.string("tmdb.match.relaxed.title", fallback: "Relaxed Detail Matching"), isOn: $enabled)
                .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("tmdb.match.relaxed-setting")
        }.padding(12)
        SettingsDivider()
        SettingsDisclosureHeader(id: "matching-details",
            title: SettingsL10n.string("settings.organized.tmdb.match.help", "Matching Details"),
            expanded: $detailsExpanded)
        if detailsExpanded {
            Text(L10n.string("tmdb.match.relaxed.explanation", fallback: "When source information is incomplete, automatically use the only TMDB movie or series with a matching title. Incorrect matches are possible; you can change the match in More. Explicit conflicts still require review."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        }
    }
}
private struct TMDBDirectSettings: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var runtime: TMDBNetworkRuntime = .shared
    @State private var kind = TMDBCredential.Kind.readAccessToken
    @State private var value = ""
    @State private var operation: Task<Void, Never>?
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    private func text(_ key: String, _ fallback: String) -> String { L10n.string("tmdb.direct." + key, fallback: fallback) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSheetHeader(title: SettingsL10n.string("settings.organized.tmdb.connection", "TMDB Connection"),
                subtitle: SettingsL10n.string("settings.organized.tmdb.editor.subtitle", "Configure credentials and test the connection"))
            Text(text("explanation", "Use your own TMDB credential. Information connects directly to TMDB; credentials stay in this Mac’s Keychain. Source playback works without it."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(text("credential-type", "Credential type"), selection: $kind) {
                    Text("API Read Access Token").tag(TMDBCredential.Kind.readAccessToken)
                    Text("API Key (v3)").tag(TMDBCredential.Kind.apiKey)
                }.disabled(runtime.busy).frame(maxWidth: 380)
                Spacer(minLength: 0)
                Link(text("apply", "Get a TMDB credential"), destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            }
            SecureField(runtime.credentialKind == nil ? text("paste", "Paste your credential") : text("replace", "A credential is saved. Paste here to replace it."), text: $value)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tmdb.direct.credential")
                .disabled(runtime.busy)
            HStack {
                Button(text("save", "Verify & Save")) {
                    operation = Task { if await runtime.validateAndSave(kind: kind, value: value) { value = "" } }
                }.disabled(runtime.busy || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(text("check", "Check API & Images")) { operation = Task { await runtime.checkConnections() } }
                    .disabled(runtime.busy || runtime.credentialKind == nil || !runtime.enabled)
                Button(text("delete", "Delete Credential"), role: .destructive) { confirmDelete = true }
                    .disabled(runtime.busy || runtime.credentialKind == nil)
                if runtime.busy { ProgressView().controlSize(.small) }
                if runtime.canCancelOperation && operation != nil {
                    Button(SettingsL10n.string("settings.common.cancel", "Cancel")) { operation?.cancel() }
                }
            }
            Text(runtime.isLoadingCredential ? text("loading-credential", "Reading the credential from Keychain…") : runtime.credentialKind == nil ? text("not-configured", "Not configured · source playback remains available") : text("configured", "Saved in Keychain · connects directly to TMDB"))
                .font(.caption).foregroundStyle(.secondary)
            if runtime.busy && !runtime.canCancelOperation && !runtime.isLoadingCredential {
                Text(text("finishing", "Finishing the credential change; closing this window will let it complete."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = runtime.message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if let links = runtime.links {
                HStack(spacing: 24) {
                    Label("API: " + TMDBConnectionStatus.title(links.metadata), systemImage: "doc.text")
                    Label(text("images", "Images") + ": " + TMDBConnectionStatus.title(links.images), systemImage: "photo")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.top, 8)
            HStack {
                Spacer()
                Button(SettingsL10n.string("settings.organized.common.done", "Done")) {
                    if value.isEmpty || (runtime.busy && !runtime.canCancelOperation) { dismiss() }
                    else { confirmDiscard = true }
                }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 590)
        .interactiveDismissDisabled(!value.isEmpty)
        .onAppear { if let saved = runtime.credentialKind { kind = saved } }
        .onChange(of: runtime.credentialKind) { saved in
            if value.isEmpty, let saved { kind = saved }
        }
        .onDisappear { if runtime.canCancelOperation { operation?.cancel() }; value = "" }
        .alert(SettingsL10n.string("settings.organized.tmdb.delete.title", "Delete TMDB Credential?"), isPresented: $confirmDelete) {
            Button(SettingsL10n.string("settings.common.cancel", "Cancel"), role: .cancel) {}
            Button(text("delete", "Delete Credential"), role: .destructive) {
                value = ""; operation = Task { await runtime.deleteCredential() }
            }
        } message: {
            Text(SettingsL10n.string("settings.organized.tmdb.delete.message", "The credential will be removed from this Mac’s Keychain. New TMDB requests will require configuration again. Cached details and source playback remain available."))
        }
        .alert(SettingsL10n.string("settings.organized.draft.discard.title", "Discard Unsaved Changes?"), isPresented: $confirmDiscard) {
            Button(SettingsL10n.string("settings.organized.draft.keep", "Keep Editing"), role: .cancel) {}
            Button(SettingsL10n.string("settings.organized.draft.discard", "Discard Changes"), role: .destructive) { value = ""; dismiss() }
        }
    }
}
