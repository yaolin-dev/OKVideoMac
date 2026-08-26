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

struct ConfigurationView: View {
    @EnvironmentObject private var state: AppState
    let embedded: Bool
    @State private var showingImport = false
    @State private var showingFileImporter = false
    @State private var pendingDelete: StoredConfiguration?

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                embeddedContent
            } else {
                standaloneContent
            }
        }
        .navigationTitle(embedded ? "设置" : "点播配置")
        .sheet(isPresented: $showingImport) {
            ConfigurationImportSheet(isPresented: $showingImport)
                .environmentObject(state)
                .frame(width: 620, height: 470)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        _ = await state.importConfiguration(
                            source: .localFile(url),
                            name: url.deletingPathExtension().lastPathComponent
                        )
                    }
                }
            case .failure(let error):
                state.presentedError = UserFacingError(
                    title: "无法选择文件",
                    message: error.localizedDescription
                )
            }
        }
        .alert(
            item: $pendingDelete
        ) { record in
            Alert(
                title: Text("删除“\(record.name)”？"),
                message: Text("收藏和历史不会随配置删除。"),
                primaryButton: .destructive(Text("删除")) {
                    Task { await state.deleteConfiguration(record.id) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var standaloneContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingImport = true
                } label: {
                    Label("导入点播配置", systemImage: "plus")
                }
                Button {
                    showingFileImporter = true
                } label: {
                    Label("选择点播配置文件", systemImage: "folder")
                }
                Spacer()
                Button {
                    Task { await state.refreshActiveConfiguration() }
                } label: {
                    Label("刷新当前点播配置", systemImage: "arrow.clockwise")
                }
                .disabled(state.activeConfigurationRecord?.sourceKind != .remote)
            }
            .padding()

            Divider()

            SourceSwitchFeedbackView(
                feedback: state.configurationSwitchFeedback
            )
            .padding(.horizontal)
            .padding(.top, 8)

            if state.configurations.isEmpty {
                EmptyStateView(
                    systemImage: "doc.badge.plus",
                    title: "没有点播配置",
                    message: "这里仅管理点播配置；直播源请到“设置 → 直播源”单独添加。"
                )
            } else {
                List {
                    ForEach(state.configurations) { record in
                        ConfigurationRow(record: record) {
                            Task { await state.activateConfiguration(record.id) }
                        } export: {
                            export(record)
                        } delete: {
                            pendingDelete = record
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var embeddedContent: some View {
        SourceSwitchFeedbackView(
            feedback: state.configurationSwitchFeedback
        )
        .padding(.bottom, 4)

        SettingsSectionTitle("导入与更新")
        SettingsCard {
            SettingsControlRow(
                icon: "plus",
                color: .indigo,
                title: "导入点播配置",
                subtitle: "通过 URL 或粘贴内容导入点播配置。"
            ) {
                Button("导入…") {
                    showingImport = true
                }
            }

            SettingsDivider()

            SettingsControlRow(
                icon: "folder.fill",
                color: .blue,
                title: "选择配置文件",
                subtitle: "从本机导入 JSON 或文本配置"
            ) {
                Button("选择…") {
                    showingFileImporter = true
                }
            }

            SettingsDivider()

            SettingsControlRow(
                icon: "arrow.clockwise",
                color: .teal,
                title: "刷新当前配置",
                subtitle: "重新下载并载入当前远程配置"
            ) {
                Button("刷新") {
                    Task { await state.refreshActiveConfiguration() }
                }
                .disabled(state.activeConfigurationRecord?.sourceKind != .remote)
            }
        }

        SettingsSectionTitle("已导入配置")
        SettingsCard {
            if state.configurations.isEmpty {
                Label(
                    "还没有点播配置，可先从上方导入。",
                    systemImage: "doc.badge.plus"
                )
                .foregroundColor(.secondary)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(state.configurations.enumerated()), id: \.element.id) {
                    index, record in
                    ConfigurationRow(
                        record: record,
                        cardStyle: true
                    ) {
                        Task { await state.activateConfiguration(record.id) }
                    } export: {
                        export(record)
                    } delete: {
                        pendingDelete = record
                    }

                    if index < state.configurations.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private func export(_ record: StoredConfiguration) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(record.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.exportData(for: record, to: url)
        } catch {
            state.presentedError = UserFacingError(
                title: "导出失败",
                message: error.localizedDescription
            )
        }
    }
}

private struct ConfigurationRow: View {
    let record: StoredConfiguration
    var cardStyle = false
    let activate: () -> Void
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if cardStyle {
                SettingsRowIcon(
                    systemImage: record.isActive
                        ? "checkmark.circle.fill"
                        : "doc.text.fill",
                    color: record.isActive ? .green : .indigo
                )
            } else {
                Image(systemName: record.isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(record.isActive ? .accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.headline)
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if record.isActive, cardStyle {
                Text("当前使用")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !record.isActive {
                Button("启用", action: activate)
            }
            Button("导出", action: export)
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, cardStyle ? 16 : 0)
        .padding(.vertical, cardStyle ? 14 : 5)
    }

    private var sourceDescription: String {
        switch record.sourceKind {
        case .remote:
            guard let value = record.sourceValue,
                  let url = URL(string: value) else {
                return "远程 URL"
            }
            return LogRedactor.url(url)
        case .localFile: return record.sourceValue ?? "本地文件"
        case .pasted: return "粘贴内容"
        }
    }
}

private struct ConfigurationImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case remote = "URL"
        case pasted = "粘贴内容"

        var id: String { rawValue }
    }

    @EnvironmentObject private var state: AppState
    @Binding var isPresented: Bool
    @State private var mode: Mode = .remote
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
                Text("导入点播配置")
                    .font(.title2)
                Text("支持 JSON、有限 JSONC、图片或 Base64 包装格式；完成后可选择同步其中的直播列表。")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Picker("方式", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isSubmitting)

                TextField("点播配置名称（可选）", text: $name)
                    .disabled(isSubmitting)
                if mode == .remote {
                    ImportURLTextField(
                        text: $remoteURL,
                        placeholder: "https://example.com/config.json"
                    )
                    .frame(height: 22)
                    .disabled(isSubmitting)
                    Text("普通配置允许 HTTP/HTTPS。远程 Node bundle 建议 HTTPS；最终为 HTTP 时需在 .js.md5 地址后附 #sha256=<64位哈希>，可再附 &source=<源ID>&version=<版本>。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    TextEditor(text: $pastedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .disabled(isSubmitting)
                    TextField("相对资源基准 URL（可选）", text: $baseURL)
                        .disabled(isSubmitting)
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
                    Spacer()
                    Button("取消") {
                        cancelOrDismiss()
                    }
                    .disabled(isCommitInProgress)
                    Button {
                        importValue()
                    } label: {
                        if isSubmitting {
                            HStack(spacing: 6) {
                                AppActivityIndicator(size: .small)
                                Text("导入中")
                            }
                        } else {
                            Text("导入")
                        }
                    }
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
        .onDisappear {
            detachActiveImport()
        }
        .alert(item: $importError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var canImport: Bool {
        guard !isSubmitting else { return false }
        switch mode {
        case .remote:
            return ImportURLInput.httpURL(from: remoteURL) != nil
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
            Label("配置导入成功", systemImage: "checkmark.circle.fill")
                .font(.title2)
                .foregroundColor(.green)
            Text(summary.configurationName)
                .font(.headline)
            Text(
                "已识别 \(summary.siteCount) 个站点："
                    + "\(summary.javaDexSiteCount) 个需要 Android Bridge，"
                    + "\(summary.javaScriptSiteCount) 个使用 JavaScript，"
                    + "\(summary.otherSiteCount) 个使用其他内置能力。"
            )
            .fixedSize(horizontal: false, vertical: true)

            if summary.androidBridgeUnavailable,
               summary.javaDexSiteCount > 0 {
                Label(
                    "Android Bridge 当前不可用，\(summary.javaDexSiteCount) 个 Java/Dex 站点已导入但暂时不能运行。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if summary.liveCount > 0 {
                Text(
                    "另外发现 \(summary.liveCount) 个直播配置；"
                        + "其中 \(summary.synchronizableLiveCount) 个可同步到“直播源”。"
                        + (summary.unsupportedLiveCount > 0
                            ? " \(summary.unsupportedLiveCount) 个动态直播插件暂不支持同步。"
                            : "")
                )
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let liveSyncResult {
                Label(
                    "直播源同步完成：新增 \(liveSyncResult.importedCount) 个，"
                        + "跳过 \(liveSyncResult.skippedCount) 个，"
                        + "失败 \(liveSyncResult.failedCount) 个。",
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
                Button("完成") {
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
                                Text("正在同步")
                            }
                        } else {
                            Text("同步直播源")
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
