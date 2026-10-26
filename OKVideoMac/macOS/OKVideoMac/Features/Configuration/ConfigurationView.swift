import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

enum ImportURLInput {
    /// Removes only leading/trailing whitespace and newline scalars. Internal
    /// userinfo, host, path, query, and fragment bytes remain untouched.
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func httpURL(from value: String) -> URL? {
        let value = normalized(value)
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

/// A narrowly scoped AppKit bridge for the URL field. `NSTextFieldDelegate`
/// commits the field editor's value to SwiftUI in the same change event, so a
/// paste does not depend on a later focus change to redraw or validate.
struct ImportURLTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("configuration-import-url")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        guard field.stringValue != text else { return }
        field.stringValue = text
        if let editor = field.currentEditor(), editor.string != text {
            editor.string = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = field.currentEditor()?.string ?? field.stringValue
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }
    }
}

/// Presentation labels follow the same URL rule as runtime routing. A file name
/// ending in .js.md5 is not a supported local Node bundle import.
enum ConfigurationPresentationKind: String {
    case tvbox = "TVBox"
    case catpaw = "CatPawOpen"
    case xtream = "Xtream"

    static func resolve(_ record: StoredConfiguration) -> Self {
        if record.sourceKind == .xtream { return .xtream }
        if record.sourceKind == .remote,
           let value = record.sourceValue,
           let url = URL(string: value),
           NodeBundleRuntimeService.supports(url) { return .catpaw }
        return .tvbox
    }
}

private enum ConfigurationSheet: Identifiable {
    case add
    case details(StoredConfiguration)

    var id: String {
        switch self {
        case .add: return "add"
        case .details(let record): return record.id.uuidString
        }
    }
}

struct ConfigurationView: View {
    @EnvironmentObject private var state: AppState
    let embedded: Bool
    var editSearchScope: (() -> Void)?
    @State private var sheet: ConfigurationSheet?
    @State private var pendingDelete: StoredConfiguration?

    init(embedded: Bool = false, editSearchScope: (() -> Void)? = nil) { self.embedded = embedded; self.editSearchScope = editSearchScope }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 20) { content }.padding(24) }
            }
        }
        .navigationTitle(embedded ? L10n.string(.sectionSettings) : L10n.string("configuration.title", fallback: "Video Providers"))
        .sheet(item: $sheet) { destination in
            switch destination {
            case .add:
                ProviderAddSheet(isPresented: sheetBinding)
                    .environmentObject(state)
                    .frame(width: 620, height: 570)
            case .details(let record):
                ProviderDetailsSheet(record: record, isPresented: sheetBinding)
                    .environmentObject(state)
                    .frame(width: 620, height: 570)
            }
        }
        .alert(item: $pendingDelete) { record in
            Alert(
                title: Text(L10n.string("configuration.delete.title", fallback: "Delete “%@”?", record.name)),
                message: Text(L10n.string("configuration.delete.message", fallback: "Favorites and history will not be deleted with the configuration.")),
                primaryButton: .destructive(Text(L10n.string("common.delete", fallback: "Delete"))) {
                    Task { await state.deleteConfiguration(record.id) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })
    }

    @ViewBuilder private var content: some View {
        SourceSwitchFeedbackView(feedback: state.configurationSwitchFeedback)
        SettingsCard {
            SettingsControlRow(
                icon: "plus", color: .indigo,
                title: L10n.string("providers.add", fallback: "Add Provider"),
                subtitle: L10n.string("providers.add.subtitle", fallback: "Use a link, a TVBox configuration file, or an Xtream account.")
            ) {
                Button(L10n.string("common.add", fallback: "Add…")) { sheet = .add }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isLoading)
                    .accessibilityIdentifier("provider-add")
            }
        }

        if let active = state.activeConfigurationRecord {
            SettingsSectionTitle(L10n.string("configuration.active", fallback: "Active"))
            SettingsCard {
                SettingsControlRow(
                    icon: "checkmark.circle.fill", color: .green,
                    title: active.name,
                    subtitle: L10n.string("providers.current.subtitle", fallback: "%@ · Used for the video home page and search", ConfigurationPresentationKind.resolve(active).rawValue)
                ) {
                    if active.sourceKind == .remote {
                        if state.refreshingConfigurationID == active.id {
                            ProgressView().controlSize(.small)
                            Button(L10n.string("common.cancel", fallback: "Cancel")) { state.cancelConfigurationRefresh() }
                                .disabled(state.isCommittingConfigurationRefresh)
                        } else {
                            Button(L10n.string("providers.update", fallback: "Update")) {
                                Task { await state.refreshActiveConfiguration() }
                            }
                            .disabled(state.isSwitchingConfiguration)
                        }
                    }
                    Button(L10n.string("providers.details", fallback: "Details")) { sheet = .details(active) }
                    Menu {
                        Button(L10n.string("common.export", fallback: "Export")) { exportConfiguration(active, state: state) }
                        Button(role: .destructive) { pendingDelete = active } label: { Text(L10n.string("common.delete", fallback: "Delete")) }
                            .disabled(state.isLoading)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(L10n.string("providers.more", fallback: "More Actions"))
                }
            }
        }

        if let message = state.configurationRefreshMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }

        if let editSearchScope {
            SettingsCard {
                SettingsControlRow(icon: "magnifyingglass", color: .secondary,
                    title: SettingsL10n.string("settings.search.default-scope.section", "Default Search Scope"),
                    subtitle: state.activeConfigurationRecord == nil
                        ? SettingsL10n.string("settings.providers.import-first", "Import and enable a video provider configuration first")
                        : state.searchScopeSummary + " · " + SettingsL10n.string("settings.organized.sources.scope.next", "This configuration · next search")) {
                    Button(SettingsL10n.string("settings.organized.common.edit", "Edit…"), action: editSearchScope)
                        .disabled(state.activeConfigurationRecord == nil)
                }
            }.settingsAnchor("search-scope")
        }

        SettingsSectionTitle(state.activeConfigurationRecord == nil ? SettingsL10n.string("settings.organized.sources.configurations", "Video Configurations") : SettingsL10n.string("settings.organized.sources.other", "Other Configurations"))
        SettingsCard {
            if state.configurations.filter({ !$0.isActive }).isEmpty {
                Text(state.configurations.isEmpty ? L10n.string("providers.empty", fallback: "Add a provider above to start watching.") : SettingsL10n.string("settings.organized.sources.no-other", "No other configurations have been added."))
                    .foregroundColor(.secondary).padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(state.configurations.filter { !$0.isActive }.enumerated()), id: \.element.id) { index, record in
                    HStack(spacing: 12) {
                        SettingsRowIcon(systemImage: record.isActive ? "checkmark.circle.fill" : "doc.text.fill", color: record.isActive ? .green : .indigo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name).font(.system(size: 13)).lineLimit(2)
                            Text(ConfigurationPresentationKind.resolve(record).rawValue)
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 8)
                        if record.isActive {
                            Text(L10n.string("configuration.active", fallback: "Active"))
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Button(L10n.string("configuration.activate", fallback: "Use This Provider")) {
                                Task { await state.activateConfiguration(record.id) }
                            }
                            .disabled(state.isLoading)
                        }
                        Button(L10n.string("providers.details", fallback: "Details")) { sheet = .details(record) }
                        Menu {
                            Button(L10n.string("common.export", fallback: "Export")) { exportConfiguration(record, state: state) }
                            Button(role: .destructive) { pendingDelete = record } label: {
                                Text(L10n.string("common.delete", fallback: "Delete"))
                            }
                            .disabled(state.isLoading)
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(L10n.string("providers.more", fallback: "More Actions"))
                    }
                    .padding(12)
                    if index < state.configurations.filter { !$0.isActive }.count - 1 { SettingsDivider() }
                }
            }
        }
        Text(L10n.string("providers.list.help", fallback: "Each provider may contain several sites. Choose a site on the video home page."))
            .font(.caption).foregroundColor(.secondary)
    }
}

@MainActor
private func exportConfiguration(_ record: StoredConfiguration, state: AppState) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(record.name).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try state.exportData(for: record, to: url) }
    catch {
        state.presentedError = UserFacingError(
            title: L10n.string("configuration.export.failed", fallback: "Export Failed"),
            message: RuntimeUserFacingMessageMapper.message(for: error)
        )
    }
}

private struct ProviderAddSheet: View {
    private enum Method { case link, file, account }
    @Binding var isPresented: Bool
    @State private var method: Method?

    var body: some View {
        Group {
            switch method {
            case .link:
                ConfigurationImportSheet(isPresented: $isPresented, initialMode: .remote, onBack: { method = nil })
            case .file:
                ConfigurationImportSheet(isPresented: $isPresented, initialMode: .file, onBack: { method = nil })
            case .account:
                XtreamProviderEditorSheet(isPresented: $isPresented, record: nil, onBack: { method = nil })
            case nil:
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.string("providers.add", fallback: "Add Provider")).font(.title2.bold())
                    Text(L10n.string("providers.choose-method", fallback: "Choose the information you received from your provider."))
                        .foregroundColor(.secondary)
                    SettingsCard {
                        choice(.link, icon: "link", title: "providers.method.link", fallback: "Add Using a Link", subtitle: "providers.method.link.help", help: "TVBox / CatPawOpen · Paste a configuration link")
                        SettingsDivider()
                        choice(.file, icon: "folder", title: "providers.method.file", fallback: "Import a Configuration File", subtitle: "providers.method.file.help", help: "TVBox · Choose a JSON or text configuration from this Mac")
                        SettingsDivider()
                        choice(.account, icon: "person.crop.circle", title: "providers.method.account", fallback: "Sign In with an Account", subtitle: "providers.method.account.help", help: "Xtream · Server address, username, and password")
                    }
                    Spacer()
                    HStack { Spacer(); Button(L10n.string(.commonCancel)) { isPresented = false } }
                }.padding(22)
            }
        }
    }

    private func choice(_ value: Method, icon: String, title: String, fallback: String, subtitle: String, help: String) -> some View {
        Button { method = value } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundColor(.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string(title, fallback: fallback)).font(.headline)
                    Text(L10n.string(subtitle, fallback: help)).font(.callout).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ProviderDetailsSheet: View {
    @EnvironmentObject private var state: AppState
    let record: StoredConfiguration
    @Binding var isPresented: Bool
    @State private var editingAccount = false
    @State private var showingProfileImporter = false
    @State private var supportsProfile = false
    @State private var importingProfile = false
    @State private var fileError: UserFacingError?

    private var currentRecord: StoredConfiguration {
        state.configurations.first(where: { $0.id == record.id }) ?? record
    }
    private var kind: ConfigurationPresentationKind { .resolve(currentRecord) }
    private var isActive: Bool { state.activeConfigurationRecord?.id == record.id }

    var body: some View {
        Group {
            if editingAccount {
                XtreamProviderEditorSheet(isPresented: $isPresented, record: currentRecord, onBack: { editingAccount = false })
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text(currentRecord.name).font(.title2.bold())
                    Text(kind.rawValue).foregroundColor(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            SettingsCard {
                                SettingsControlRow(icon: "doc.text", color: .indigo,
                                    title: L10n.string("providers.connection", fallback: "Connection"),
                                    subtitle: sourceDescription) { EmptyView() }
                            }
                            if kind == .xtream {
                                Button(L10n.string("providers.edit-account", fallback: "Edit Server and Account…")) { editingAccount = true }
                                Text(L10n.string("xtream.security-note", fallback: "Credentials are stored only in this Mac’s Keychain. Configuration exports and portable backups never contain them."))
                                    .font(.caption).foregroundColor(.secondary)
                            } else if kind == .catpaw {
                                Text(L10n.string("providers.catpaw.help", fallback: "When a site needs a cloud account, opening or playing it will guide you through sign-in."))
                                    .foregroundColor(.secondary)
                                if isActive && supportsProfile {
                                    SettingsCard {
                                        SettingsControlRow(icon: "person.crop.circle.badge.plus", color: .orange,
                                            title: L10n.string("providers.catpaw.import", fallback: "Import CatPaw Settings"),
                                            subtitle: L10n.string("providers.catpaw.import.help", fallback: "Use test0.db.json to replace this provider’s saved site, account, and cloud settings.")) {
                                            Button(L10n.string("common.choose", fallback: "Choose…")) { showingProfileImporter = true }
                                                .disabled(importingProfile || state.isLoading)
                                        }
                                    }
                                } else {
                                    Text(L10n.string(isActive ? "providers.catpaw.unavailable" : "providers.catpaw.activate-first",
                                        fallback: isActive ? "Settings-file import is available when a compatible CatPaw runtime is ready." : "Use this provider first to manage its CatPaw settings."))
                                        .font(.caption).foregroundColor(.secondary)
                                    if isActive {
                                        Button(L10n.string("providers.check-again", fallback: "Check Again")) {
                                            Task { supportsProfile = await state.canImportCatPawSettings(for: record.id) }
                                        }
                                    }
                                }
                                if importingProfile { ProgressView() }
                            } else if currentRecord.sourceKind != .remote {
                                Text(L10n.string("providers.local.update-help", fallback: "To update this provider, add the new configuration file or text."))
                                    .foregroundColor(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button(L10n.string("common.export", fallback: "Export")) { exportConfiguration(currentRecord, state: state) }
                        Spacer()
                        Button(L10n.string("common.done", fallback: "Done")) { isPresented = false }
                            .keyboardShortcut(.defaultAction).disabled(importingProfile)
                    }
                }.padding(22)
            }
        }
        .interactiveDismissDisabled(importingProfile)
        .task(id: state.activeConfigurationRecord?.id) {
            supportsProfile = await state.canImportCatPawSettings(for: record.id)
        }
        // A single importer owned by this sheet; ordinary configuration files
        // have a separate owner in ConfigurationImportSheet.
        .fileImporter(isPresented: $showingProfileImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                guard isActive else { return }
                importingProfile = true
                Task {
                    await state.importCatPawProfile(from: url)
                    importingProfile = false
                    supportsProfile = await state.canImportCatPawSettings(for: record.id)
                }
            case .failure(let error):
                fileError = UserFacingError(title: L10n.string("configuration.file-selection.failed", fallback: "Unable to Select File"), message: RuntimeUserFacingMessageMapper.message(for: error))
            }
        }
        .alert(item: $fileError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text(L10n.string(.commonOK))))
        }
    }

    private var sourceDescription: String {
        if let value = currentRecord.sourceValue {
            if currentRecord.sourceKind == .localFile { return URL(fileURLWithPath: value).lastPathComponent }
            if let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") { return LogRedactor.url(url) }
        }
        return L10n.string("configuration.source.pasted", fallback: "Pasted Content")
    }
}

private struct XtreamProviderEditorSheet: View {
    private enum Operation { case testing, saving }
    private enum OperationStatus: Equatable {
        case success(String)
        case failure(String)
    }

    @EnvironmentObject private var state: AppState
    @Binding var isPresented: Bool
    let record: StoredConfiguration?
    let onBack: (() -> Void)?
    @State private var displayName: String
    @State private var serverURL: String
    @State private var username = ""
    @State private var password = ""
    @State private var operationTask: Task<Void, Never>?
    @State private var operation: Operation?
    @State private var status: OperationStatus?

    init(
        isPresented: Binding<Bool>,
        record: StoredConfiguration?,
        onBack: (() -> Void)? = nil
    ) {
        _isPresented = isPresented
        self.record = record
        self.onBack = onBack
        let descriptor = record.flatMap {
            try? XtreamProviderConfiguration(data: $0.rawData)
        }
        _displayName = State(initialValue: descriptor?.displayName ?? "")
        _serverURL = State(
            initialValue: descriptor?.serverBaseURL.absoluteString ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                record == nil
                    ? L10n.string(
                        "xtream.add.title",
                        fallback: "Add Xtream Provider"
                    )
                    : L10n.string(
                        "xtream.edit.title",
                        fallback: "Edit Xtream Provider"
                    )
            )
            .font(.title2)

            Text(
                L10n.string(
                    "xtream.editor.subtitle",
                    fallback: "Native Movies, Series, Search, and Basic Live TV."
                )
            )
            .font(.callout)
            .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                editorField(
                    label: L10n.string("xtream.name", fallback: "Name")
                ) {
                    TextField(
                        L10n.string(
                            "xtream.name.placeholder",
                            fallback: "My Xtream Provider"
                        ),
                        text: $displayName
                    )
                }
                editorField(
                    label: L10n.string(
                        "xtream.server-url",
                        fallback: "Server URL"
                    )
                ) {
                    TextField(
                        "https://provider.example:8443/iptv",
                        text: $serverURL
                    )
                }
                editorField(
                    label: L10n.string(
                        "xtream.username",
                        fallback: "Username"
                    )
                ) {
                    TextField("", text: $username)
                        .textContentType(.username)
                }
                editorField(
                    label: L10n.string(
                        "xtream.password",
                        fallback: "Password"
                    )
                ) {
                    SecureField("", text: $password)
                        .textContentType(.password)
                }
            }.disabled(isBusy)

            Text(
                record == nil
                    ? L10n.string(
                        "xtream.security-note",
                        fallback: "Credentials are stored only in this Mac’s Keychain. Configuration exports and portable backups never contain them."
                    )
                    : L10n.string(
                        "xtream.edit.credentials-note",
                        fallback: "For security, enter the username and password again before saving changes."
                    )
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let status {
                switch status {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            }

            Spacer()
            HStack {
                if let onBack {
                    Button(L10n.string("providers.back", fallback: "Back"), action: onBack)
                        .disabled(isBusy)
                }
                Spacer()
                Button(L10n.string(.commonCancel)) {
                    operationTask?.cancel()
                    operationTask = nil
                    isPresented = false
                }.disabled(operation == .saving && state.isCommittingXtreamProvider)
                Button {
                    testConnection()
                } label: {
                    if operation == .testing {
                        HStack(spacing: 6) {
                            AppActivityIndicator(size: .small)
                            Text(L10n.string("xtream.testing", fallback: "Testing"))
                        }
                    } else {
                        Text(
                            L10n.string(
                                "xtream.test-connection",
                                fallback: "Test Connection"
                            )
                        )
                    }
                }
                .disabled(!connectionFieldsAreValid || isBusy)
                Button {
                    save()
                } label: {
                    if operation == .saving {
                        HStack(spacing: 6) {
                            AppActivityIndicator(size: .small)
                            Text(SettingsL10n.string("settings.operation.saving", "Saving…"))
                        }
                    } else {
                        Text(record == nil ? L10n.string("providers.add-use", fallback: "Add and Use") : L10n.string("common.save", fallback: "Save"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!formIsValid || isBusy)
            }
        }
        .padding(22)
        .interactiveDismissDisabled(isBusy)
        .onChange(of: displayName) { _ in status = nil }
        .onChange(of: serverURL) { _ in status = nil }
        .onChange(of: username) { _ in status = nil }
        .onChange(of: password) { _ in status = nil }
        .onDisappear {
            if !state.isCommittingXtreamProvider { operationTask?.cancel() }
            operationTask = nil
        }
    }

    private var isBusy: Bool { operationTask != nil }

    private func editorField<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 105, alignment: .trailing)
            content()
        }
    }

    private var connectionFieldsAreValid: Bool {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty,
              let url = URL(
                string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              (try? XtreamEndpoint(serverURL: url)) != nil else {
            return false
        }
        return true
    }

    private var formIsValid: Bool {
        connectionFieldsAreValid
    }

    private func testConnection() {
        guard operationTask == nil else { return }
        status = nil
        operation = .testing
        operationTask = Task {
            defer { operationTask = nil; operation = nil }
            do {
                let account = try await state.testXtreamProviderConnection(
                    serverURL: serverURL,
                    username: username,
                    password: password
                )
                guard !Task.isCancelled else { return }
                let accountStatus = account.status?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let accountStatus, !accountStatus.isEmpty {
                    status = .success(
                        L10n.string(
                            "xtream.test.success-with-status",
                            fallback: "Connection succeeded. Account status: %@.",
                            accountStatus
                        )
                    )
                } else {
                    status = .success(
                        L10n.string(
                            "xtream.test.success",
                            fallback: "Connection succeeded."
                        )
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = .failure(
                    RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
            operationTask = nil
        }
    }

    private func save() {
        guard operationTask == nil else { return }
        status = nil
        operation = .saving
        operationTask = Task {
            defer { operationTask = nil; operation = nil }
            let succeeded = await state.saveXtreamProvider(
                id: record?.id,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "Xtream")
                    : displayName,
                serverURL: serverURL,
                username: username,
                password: password
            )
            guard !Task.isCancelled else { return }
            operationTask = nil
            if succeeded {
                isPresented = false
            } else {
                status = .failure(
                    L10n.string(
                        "xtream.save.failed.retry",
                        fallback: "The provider could not be saved. Check the fields and try again."
                    )
                )
            }
        }
    }
}

private struct ConfigurationImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case remote
        case file
        case pasted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remote: return L10n.string("providers.link", fallback: "Link")
            case .file: return L10n.string("providers.file", fallback: "File")
            case .pasted:
                return L10n.string("configuration.source.pasted", fallback: "Pasted Content")
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @Binding var isPresented: Bool
    let onBack: () -> Void
    @State private var mode: Mode
    @State private var showingFileImporter = false
    @State private var selectedFile: URL?

    init(isPresented: Binding<Bool>, initialMode: Mode, onBack: @escaping () -> Void) {
        _isPresented = isPresented
        _mode = State(initialValue: initialMode)
        self.onBack = onBack
    }
    @State private var name = ""
    @State private var remoteURL = ""
    @State private var pastedText = ""
    @State private var baseURL = ""
    @State private var importPhase: ConfigurationImportPhase?
    @State private var submissionTask: Task<Void, Never>?
    @State private var activeOperationID: UUID?
    @State private var importError: UserFacingError?
    @State private var importSummary: ConfigurationImportSummary?
    @State private var liveSyncResult: EmbeddedLiveSourceSyncResult?
    @State private var liveSyncTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("configuration.import", fallback: "Import Video Provider Configuration"))
                    .font(.title2)
                Text(L10n.string("providers.import.help", fallback: "Use a TVBox configuration link or file, or a CatPawOpen .js.md5 link."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                Picker(L10n.string("common.method", fallback: "Method"), selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isSubmitting)

                TextField(L10n.string("configuration.name.optional", fallback: "Configuration Name (Optional)"), text: $name)
                    .disabled(isSubmitting)
                if mode == .remote {
                    ImportURLTextField(
                        text: $remoteURL,
                        placeholder: "https://example.com/config.json"
                    )
                    .frame(height: 22)
                    .disabled(isSubmitting)
                    if let url = ImportURLInput.httpURL(from: remoteURL) {
                        Text(L10n.string(NodeBundleRuntimeService.supports(url) ? "providers.link.catpaw" : "providers.link.tvbox",
                            fallback: NodeBundleRuntimeService.supports(url) ? "CatPawOpen link · The app will check compatibility when adding." : "Configuration link · The app will read the TVBox configuration when adding."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    DisclosureGroup(L10n.string("providers.advanced", fallback: "Advanced Options")) {
                        Text(L10n.string("configuration.remote.security-note", fallback: "Standard configurations allow HTTP and HTTPS. HTTPS is recommended for remote Node bundles. For an HTTP bundle, append #sha256=<64-character hash> to the .js.md5 URL; &source=<source ID>&version=<version> are optional."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else if mode == .file {
                    SettingsCard {
                        SettingsControlRow(icon: "folder", color: .blue,
                            title: selectedFile?.lastPathComponent ?? L10n.string("providers.file.select", fallback: "Choose a TVBox Configuration"),
                            subtitle: L10n.string("providers.file.help", fallback: "JSON or text configuration. CatPaw settings files belong in the existing provider’s details.")) {
                            Button(L10n.string("common.choose", fallback: "Choose…")) { showingFileImporter = true }
                                .disabled(isSubmitting)
                                .accessibilityIdentifier("provider-choose-file")
                        }
                    }
                } else {
                    TextEditor(text: $pastedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 130)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .disabled(isSubmitting)
                    DisclosureGroup(L10n.string("providers.advanced", fallback: "Advanced Options")) {
                        TextField(L10n.string("configuration.base-url.optional", fallback: "Relative Resource Base URL (Optional)"), text: $baseURL)
                            .disabled(isSubmitting)
                    }
                }
                Spacer()
                if let importPhase {
                    HStack(spacing: 8) {
                        AppActivityIndicator(size: .small)
                        Text(importPhase.title)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    Button(L10n.string("providers.back", fallback: "Back"), action: onBack)
                        .disabled(isSubmitting)
                    Spacer()
                    Button(L10n.string(.commonCancel)) {
                        cancelOrDismiss()
                    }
                    .disabled(isCommitInProgress)
                    Button {
                        importValue()
                    } label: {
                        if isSubmitting {
                            HStack(spacing: 6) {
                                AppActivityIndicator(size: .small)
                                Text(L10n.string("configuration.importing", fallback: "Importing"))
                            }
                        } else {
                            Text(L10n.string("providers.add-use", fallback: "Add and Use"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
                }
            }

            if let importSummary {
                completionView(importSummary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .padding(22)
        .interactiveDismissDisabled(isCommitInProgress)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .success(let url):
                selectedFile = url
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = url.deletingPathExtension().lastPathComponent
                }
            case .failure(let error):
                importError = UserFacingError(
                    title: L10n.string("configuration.file-selection.failed", fallback: "Unable to Select File"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
        .onDisappear {
            detachActiveImport()
        }
        .alert(item: $importError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text(L10n.string(.commonOK)))
            )
        }
    }

    private var canImport: Bool {
        guard !isSubmitting else { return false }
        switch mode {
        case .remote:
            return ImportURLInput.httpURL(from: remoteURL) != nil
        case .file:
            return selectedFile != nil
        case .pasted:
            return !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private var isCommitInProgress: Bool {
        guard isSubmitting else { return false }
        return importPhase == .saving || importPhase == .activating
    }

    private func importValue() {
        guard !isSubmitting else { return }
        let source: ConfigurationSource
        switch mode {
        case .remote:
            let normalized = ImportURLInput.normalized(remoteURL)
            guard let url = ImportURLInput.httpURL(from: normalized) else { return }
            remoteURL = normalized
            source = .remote(url)
        case .file:
            guard let selectedFile else { return }
            source = .localFile(selectedFile)
        case .pasted:
            let normalizedBaseURL = ImportURLInput.normalized(baseURL)
            source = .pasted(
                text: pastedText,
                baseURL: normalizedBaseURL.isEmpty ? nil : URL(string: normalizedBaseURL)
            )
        }
        let operationID = UUID()
        activeOperationID = operationID
        importError = nil
        importPhase = initialPhase(for: source)
        submissionTask = Task {
            // Keep the file-picker grant alive for the entire asynchronous read.
            let fileURL: URL?
            if case .localFile(let url) = source { fileURL = url } else { fileURL = nil }
            let scoped = fileURL?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { fileURL?.stopAccessingSecurityScopedResource() } }
            let result = await state.importConfigurationForSheet(
                source: source,
                name: name,
                progress: { phase in
                    guard activeOperationID == operationID,
                          !Task.isCancelled else { return }
                    importPhase = phase
                },
                onCommitStarted: {
                    guard activeOperationID == operationID,
                          !Task.isCancelled else { return }
                    importPhase = .saving
                }
            )
            guard activeOperationID == operationID else { return }
            activeOperationID = nil
            submissionTask = nil
            switch result {
            case .success(let summary) where !Task.isCancelled:
                importPhase = nil
                importSummary = summary
            case .failure(let error):
                importPhase = nil
                importError = error
            case .cancelled, .success(_):
                importPhase = nil
            }
        }
    }

    private func cancelOrDismiss() {
        if isSubmitting && !isCommitInProgress {
            cancelActiveImport()
        }
        isPresented = false
    }

    private func cancelActiveImport() {
        guard !isCommitInProgress else { return }
        activeOperationID = nil
        let task = submissionTask
        submissionTask = nil
        importPhase = nil
        task?.cancel()
    }

    private func detachActiveImport() {
        let shouldCancel = isSubmitting && !isCommitInProgress
        activeOperationID = nil
        let task = submissionTask
        submissionTask = nil
        importPhase = nil
        if shouldCancel {
            task?.cancel()
        }
        liveSyncTask?.cancel()
        liveSyncTask = nil
    }

    @ViewBuilder
    private func completionView(
        _ summary: ConfigurationImportSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.string("configuration.import.success", fallback: "Configuration Imported"), systemImage: "checkmark.circle.fill")
                .font(.title2)
                .foregroundColor(.green)
            Text(summary.configurationName)
                .font(.headline)
            Text(L10n.string("providers.import.complete", fallback: "%d sites added. This provider is now in use.", summary.siteCount))
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L10n.string("providers.compatibility-details", fallback: "Compatibility Details")) {
            Text(
                L10n.string(
                    "configuration.import.summary",
                    fallback: "%d providers found: %d require Android Bridge, %d use JavaScript, and %d use other built-in capabilities.",
                    summary.siteCount,
                    summary.javaDexSiteCount,
                    summary.javaScriptSiteCount,
                    summary.otherSiteCount
                )
            )
            .fixedSize(horizontal: false, vertical: true)

            }

            if summary.androidBridgeUnavailable,
               summary.javaDexSiteCount > 0 {
                Label(
                    L10n.string("configuration.import.android-unavailable", fallback: "Android Bridge is unavailable. %d imported Java/Dex providers cannot run yet.", summary.javaDexSiteCount),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if summary.liveCount > 0 {
                Text(L10n.string(
                    "configuration.import.live-summary",
                    fallback: "%d Live TV configurations found; %d can be synced to Live TV Sources.%@",
                    summary.liveCount,
                    summary.synchronizableLiveCount,
                    summary.unsupportedLiveCount > 0
                        ? L10n.string("configuration.import.live-unsupported", fallback: " %d dynamic Live TV plugins cannot be synced yet.", summary.unsupportedLiveCount)
                        : ""
                ))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let liveSyncResult {
                Label(
                    L10n.string(
                        "configuration.import.live-sync-summary",
                        fallback: "Live TV sync finished: %d added, %d skipped, %d failed.",
                        liveSyncResult.importedCount,
                        liveSyncResult.skippedCount,
                        liveSyncResult.failedCount
                    ),
                    systemImage: liveSyncResult.failedCount == 0
                        ? "checkmark.circle"
                        : "exclamationmark.triangle"
                )
                .foregroundColor(
                    liveSyncResult.failedCount == 0 ? .secondary : .orange
                )
            }

            Spacer()
            HStack {
                Spacer()
                Button(L10n.string("common.done", fallback: "Done")) {
                    isPresented = false
                }
                .disabled(liveSyncTask != nil)
                if summary.synchronizableLiveCount > 0,
                   liveSyncResult == nil {
                    Button {
                        synchronizeLives(from: summary)
                    } label: {
                        if liveSyncTask != nil {
                            HStack(spacing: 6) {
                                AppActivityIndicator(size: .small)
                                Text(L10n.string("configuration.syncing", fallback: "Syncing"))
                            }
                        } else {
                            Text(L10n.string("configuration.sync-live", fallback: "Sync Live TV Sources"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(liveSyncTask != nil)
                }
            }
        }
    }

    private func synchronizeLives(
        from summary: ConfigurationImportSummary
    ) {
        guard liveSyncTask == nil else { return }
        liveSyncTask = Task {
            let result = await state.synchronizeEmbeddedLiveSources(
                configurationID: summary.configurationID
            )
            guard !Task.isCancelled else { return }
            liveSyncResult = result
            liveSyncTask = nil
        }
    }

    private func initialPhase(
        for source: ConfigurationSource
    ) -> ConfigurationImportPhase {
        if case .remote(let url) = source {
            return NodeBundleRuntimeService.supports(url)
                ? .startingNodeRuntime
                : .downloadingAndParsing
        }
        return .parsing
    }
}
