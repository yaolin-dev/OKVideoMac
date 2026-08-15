import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

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

            if state.configurations.isEmpty {
                EmptyStateView(
                    systemImage: "doc.badge.plus",
                    title: "没有点播配置",
                    message: "这里仅管理 FongMi 点播配置；直播源请到“设置 → 直播源”单独添加。"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入 FongMi 点播配置")
                .font(.title2)
            Text("支持 JSON 以及 FongMi 图片/Base64 包装格式；直播列表不会在这里导入。")
                .font(.callout)
                .foregroundColor(.secondary)
            Picker("方式", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextField("点播配置名称（可选）", text: $name)
            if mode == .remote {
                TextField("https://example.com/config.json", text: $remoteURL)
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
                TextField("相对资源基准 URL（可选）", text: $baseURL)
            }
            Spacer()
            HStack {
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                Button("导入") {
                    importValue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding(22)
    }

    private var canImport: Bool {
        switch mode {
        case .remote:
            guard let url = URL(string: remoteURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return false
            }
            return true
        case .pasted:
            return !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func importValue() {
        let source: ConfigurationSource
        switch mode {
        case .remote:
            guard let url = URL(string: remoteURL) else { return }
            source = .remote(url)
        case .pasted:
            source = .pasted(
                text: pastedText,
                baseURL: baseURL.isEmpty ? nil : URL(string: baseURL)
            )
        }
        Task {
            let succeeded = await state.importConfiguration(source: source, name: name)
            if succeeded {
                isPresented = false
            }
        }
    }
}
