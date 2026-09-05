import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var posterCacheSize = "正在计算…"
    @State private var pendingBackupImport: PortableBackupPreview?
    @State private var isBackupBusy = false
    @State private var backupOperationMessage: String?

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
                    .frame(minWidth: 190, idealWidth: 210, maxWidth: 230)
                detailContent
                    .frame(minWidth: 590)
            }
        }
        .navigationTitle("")
        .toolbar {
            PrimaryPageToolbarLeadingContent(title: "设置")
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
        let isSelected = state.selectedSettingsPane == pane
        return Button {
            state.selectedSettingsPane = pane
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
                        .lineLimit(1)
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
        switch state.selectedSettingsPane {
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
            title: "通用",
            subtitle: "外观、隐私和历史记录"
        ) {
            SettingsSectionTitle("外观")
            SettingsCard {
                SettingsControlRow(
                    icon: "paintpalette.fill",
                    color: .blue,
                    title: "界面主题",
                    subtitle: "选择浅色、深色或跟随系统"
                ) {
                    Picker(
                        "界面主题",
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
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 270)
                }
            }

            SettingsSectionTitle("窗口布局")
            SettingsCard {
                SettingsControlRow(
                    icon: "macwindow",
                    color: .teal,
                    title: "主窗口",
                    subtitle: "自动记住大小和位置；默认约为 1240 × 780"
                ) {
                    Button("恢复默认") {
                        state.restoreDefaultWindowLayout(.mainWindow)
                    }
                    .help("将主窗口恢复到适合当前屏幕的默认大小并居中")
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

            SettingsSectionTitle("隐私与记录")
            SettingsCard {
                SettingsControlRow(
                    icon: "eye.slash.fill",
                    color: .indigo,
                    title: "无痕模式",
                    subtitle: "开启后不写入新的观看历史"
                ) {
                    Toggle(
                        "无痕模式",
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
                    title: "历史保留",
                    subtitle: "自动清理超过期限的观看记录"
                ) {
                    Picker(
                        "历史保留",
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

    private var configurationSettings: some View {
        SettingsPage(
            title: "点播配置",
            subtitle: "导入、切换和维护点播配置"
        ) {
            ConfigurationView(embedded: true)
                .environmentObject(state)
        }
    }

    private var playbackSettings: some View {
        SettingsPage(
            title: "视频",
            subtitle: "播放器状态和播放选项"
        ) {
            SettingsSectionTitle("播放器")
            SettingsCard {
                SettingsInfoRow(
                    icon: "play.rectangle.fill",
                    color: .pink,
                    title: "当前状态",
                    subtitle: "内嵌 libmpv 播放后端",
                    value: state.playerStatusDescription
                )

                SettingsDivider()

                SettingsControlRow(
                    icon: "cpu.fill",
                    color: .purple,
                    title: "硬件解码",
                    subtitle: "播放时优先使用系统硬件解码能力"
                ) {
                    Button(state.playerHardwareDecoding ? "已开启" : "已关闭") {
                        Task { await state.togglePlayerHardwareDecoding() }
                    }
                }

                SettingsDivider()

                SettingsControlRow(
                    icon: "forward.end.fill",
                    color: .blue,
                    title: "自动播放下一集",
                    subtitle: "当前一集自然播放结束后继续播放下一集"
                ) {
                    Toggle(
                        "自动播放下一集",
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

            SettingsSectionTitle("说明")
            SettingsCard {
                Label(
                    "音轨、字幕、倍速、画面比例和延迟可在播放时通过悬浮控制栏调整。",
                    systemImage: "info.circle"
                )
                .foregroundColor(.secondary)
                .padding(18)
            }
        }
    }

    private var cacheSettings: some View {
        SettingsPage(
            title: "缓存",
            subtitle: "海报缓存和本地记录管理"
        ) {
            SettingsSectionTitle("图像缓存")
            SettingsCard {
                SettingsControlRow(
                    icon: "photo.on.rectangle.angled",
                    color: .orange,
                    title: "海报缓存",
                    subtitle: "当前海报与频道 Logo 占用空间"
                ) {
                    HStack(spacing: 12) {
                        Text(posterCacheSize)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        Button("清除") {
                            Task {
                                await state.clearPosterCache()
                                await refreshCacheSize()
                            }
                        }
                    }
                }
            }

            SettingsSectionTitle("观看记录")
            SettingsCard {
                SettingsControlRow(
                    icon: "clock.fill",
                    color: .blue,
                    title: "观看历史",
                    subtitle: "当前保存 \(state.history.count) 条记录"
                ) {
                    Button("清空", role: .destructive) {
                        Task { await state.clearHistory() }
                    }
                    .disabled(state.history.isEmpty)
                }
            }
        }
    }

    private var backupSettings: some View {
        SettingsPage(
            title: "备份与恢复",
            subtitle: "导出当前点播配置和对应的观看历史"
        ) {
            SettingsSectionTitle("当前可备份数据")
            SettingsCard {
                SettingsInfoRow(
                    icon: "doc.badge.gearshape",
                    color: .indigo,
                    title: "当前点播配置",
                    subtitle: state.activeConfigurationRecord == nil
                        ? "尚未启用点播配置"
                        : "包含最后一次成功加载的配置快照",
                    value: state.activeConfigurationRecord?.name ?? "未设置"
                )
                SettingsDivider()
                SettingsInfoRow(
                    icon: "clock.arrow.circlepath",
                    color: .blue,
                    title: "对应观看历史",
                    subtitle: "保留线路、分集、播放位置和观看时间",
                    value: "\(state.history.count) 条"
                )
            }

            SettingsSectionTitle("手动备份")
            SettingsCard {
                SettingsControlRow(
                    icon: "square.and.arrow.up.fill",
                    color: .teal,
                    title: "导出当前配置与历史",
                    subtitle: "生成经过版本校验的 .okvideobackup 文件"
                ) {
                    Button("导出…") {
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
                    title: "从备份恢复",
                    subtitle: "导入前会预览内容并自动保存当前数据"
                ) {
                    Button("选择备份…") {
                        choosePortableBackup()
                    }
                    .disabled(isBackupBusy)
                }
            }

            if isBackupBusy || backupOperationMessage != nil {
                SettingsSectionTitle("状态")
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
                                ? "正在校验和处理备份…"
                                : backupOperationMessage ?? ""
                        )
                        .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(16)
                }
            }

            SettingsSectionTitle("安全说明")
            SettingsCard {
                Label(
                    "备份不会额外导出钥匙串、网盘账号状态、二维码、临时播放地址或 Android 虚拟机数据。配置原文会随备份保存，可能包含私人源地址；文件未加密，请妥善保管。恢复后如网盘授权不可用，播放器会重新请求授权。",
                    systemImage: "lock.shield.fill"
                )
                .foregroundColor(.secondary)
                .padding(18)
            }
        }
    }

    private var advancedSettings: some View {
        SettingsPage(
            title: "高级",
            subtitle: "运行信息、诊断与兼容范围"
        ) {
            SettingsSectionTitle("应用信息")
            SettingsCard {
                SettingsInfoRow(
                    icon: "app.badge",
                    color: .green,
                    title: "版本",
                    subtitle: "OKVideoMac",
                    value: state.versionDescription
                )
                SettingsDivider()
                SettingsInfoRow(
                    icon: "desktopcomputer",
                    color: .blue,
                    title: "运行环境",
                    subtitle: state.systemDescription,
                    value: state.architectureDescription
                )
                SettingsDivider()
                SettingsInfoRow(
                    icon: "square.stack.3d.up.fill",
                    color: .indigo,
                    title: "当前配置",
                    subtitle: state.activeConfigurationRecord == nil
                        ? "尚未导入点播配置"
                        : "\(state.visibleSites.count) 个可见站点",
                    value: state.activeConfigurationRecord?.name ?? "未设置"
                )
            }

            SettingsSectionTitle("诊断")
            SettingsCard {
                SettingsControlRow(
                    icon: "doc.text.magnifyingglass",
                    color: .teal,
                    title: "导出诊断信息",
                    subtitle: "导出经过脱敏的运行状态与站点能力"
                ) {
                    Button("导出…") {
                        exportDiagnostics()
                    }
                }
            }

            SettingsSectionTitle("Android 兼容模块")
            SettingsCard {
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

                        Button("检查") {
                            Task { await state.refreshAndroidRuntimeStatus() }
                        }
                        .disabled(state.isAndroidRuntimeBusy)

                        Button("选择 SDK…") {
                            Task { await state.chooseAndroidSDK() }
                        }
                        .disabled(state.isAndroidRuntimeBusy)

                        Button("修复") {
                            Task { await state.repairAndroidRuntime() }
                        }
                        .disabled(
                            state.isAndroidRuntimeBusy
                                || state.androidRuntimeStatus.phase == .unavailable
                        )

                        if state.androidRuntimeStatus.isRunning {
                            Button("停止", role: .destructive) {
                                Task { await state.stopAndroidRuntime() }
                            }
                            .disabled(state.isAndroidRuntimeBusy)
                        } else {
                            Button("启动") {
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
                        "该模块仅用于需要 Android Java/Dex 运行环境的点播站点；普通 API 站点和 JavaScript 站点不需要启动。",
                        systemImage: "info.circle"
                    )
                    Text(
                        "Android 兼容环境仅在需要时启动，退出 OKVideoMac 时会自动关闭。"
                            + "设置页按钮仅用于检查和维护。"
                    )
                    .foregroundColor(.secondary)
                }
                .font(.caption)
                .padding(16)
            }

            SettingsSectionTitle("安全与范围")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "应用不内置影视源、账号、Cookie、解析地址或 DRM 密钥。",
                        systemImage: "lock.shield"
                    )
                    Text("最低系统为 macOS 12.0；DRM、TVBus 和 ForceTech 当前不执行。")
                        .foregroundColor(.secondary)
                }
                .padding(18)
            }
        }
        .task {
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
                    title: "诊断导出失败",
                    message: error.localizedDescription
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
                backupOperationMessage = "已导出“\(preview.configurationName)”和 \(preview.historyCount) 条历史记录。"
            } catch {
                state.presentedError = UserFacingError(
                    title: "备份导出失败",
                    message: error.localizedDescription
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
        panel.prompt = "检查备份"
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
                    title: "无法读取备份",
                    message: error.localizedDescription
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
                    : " 导入前的数据已保存为安全备份。"
                backupOperationMessage = "已恢复“\(summary.configurationName)”，检查 \(summary.historyCount) 条历史，写入或更新 \(summary.changedHistoryCount) 条。\(safetyText)"
            } catch {
                state.presentedError = UserFacingError(
                    title: "备份恢复失败",
                    message: error.localizedDescription
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
                    Text("确认恢复备份")
                        .font(.title2.bold())
                    Text("文件已经通过格式和完整性校验")
                        .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 0) {
                previewRow("点播配置", value: preview.configurationName)
                Divider()
                previewRow("观看历史", value: "\(preview.historyCount) 条")
                Divider()
                previewRow(
                    "导出版本",
                    value: "\(preview.appVersion) (\(preview.appBuild))"
                )
                Divider()
                previewRow(
                    "导出时间",
                    value: preview.createdAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            Text("同一条历史会保留观看时间更新的记录；导入前会自动备份当前配置和历史。网盘账号授权不会被覆盖。")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("导入并合并", action: confirm)
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
            title: "搜索",
            subtitle: "管理当前点播配置默认搜索的站点范围"
        ) {
            SettingsSectionTitle("当前配置")
            SettingsCard {
                SettingsControlRow(
                    icon: "doc.badge.gearshape",
                    color: .indigo,
                    title: state.activeConfigurationRecord?.name ?? "未设置点播配置",
                    subtitle: state.activeConfigurationRecord == nil
                        ? "请先导入并启用一个点播配置"
                        : "搜索范围按配置分别保存，互不影响"
                ) {
                    Text(state.searchScopeSummary)
                        .foregroundColor(.secondary)
                }
            }

            SettingsSectionTitle("默认搜索范围")
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
                                ? "保存后从下一次搜索生效，当前搜索范围保持不变。"
                                : "首页和搜索页都会使用此默认范围。"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        Spacer()
                        if !hasValidSelection {
                            Text("至少选择一个可用站点")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        Button("恢复全部站点") {
                            mode = .all
                            selectedKeys = []
                        }
                        Button("保存") {
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

            SettingsSectionTitle("说明")
            SettingsCard {
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        "搜索范围决定会向哪些站点发起请求。",
                        systemImage: "network"
                    )
                    Label(
                        "搜索结果页的“结果来源”只过滤已有结果，不产生新的网络请求。",
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

private struct LiveSourceSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @State private var showingImport = false
    @State private var showingFileImporter = false
    @State private var pendingDelete: StoredLiveSource?

    var body: some View {
        SettingsPage(
            title: "直播源",
            subtitle: "导入、刷新和维护直播频道列表"
        ) {
            SettingsSectionTitle("来源管理")

            if state.liveSources.isEmpty {
                SettingsCard {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary)
                        Text("尚未添加直播源")
                            .font(.headline)
                        Text("支持远程 URL、本地 M3U/M3U8/TXT/JSON 文件和粘贴内容。")
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

            SettingsSectionTitle("添加来源")
            SettingsCard {
                SettingsControlRow(
                    icon: "link.badge.plus",
                    color: .teal,
                    title: "通过 URL 或粘贴内容添加",
                    subtitle: "远程来源添加后可随时重新下载并刷新"
                ) {
                    Button("添加…") {
                        showingImport = true
                    }
                }
                SettingsDivider()
                SettingsControlRow(
                    icon: "folder.fill.badge.plus",
                    color: .blue,
                    title: "导入本地直播文件",
                    subtitle: "支持 M3U、M3U8、TXT 和 JSON"
                ) {
                    Button("选择文件…") {
                        showingFileImporter = true
                    }
                }
            }

            SettingsSectionTitle("说明")
            SettingsCard {
                Label(
                    "直播页只负责浏览和播放频道；直播源的增删与更新统一在这里完成。",
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
                    title: "无法选择直播文件",
                    message: error.localizedDescription
                )
            }
        }
        .alert(item: $pendingDelete) { source in
            Alert(
                title: Text("删除“\(source.name)”？"),
                message: Text("只删除这条直播源，不会影响点播配置、收藏或历史。"),
                primaryButton: .destructive(Text("删除")) {
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
                Text("更新于 \(source.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let status = state.liveSourceValidationStatuses[source.id] {
                    liveSourceValidationStatus(status)
                }
            }
            Spacer()
            if source.sourceKind == .remote {
                Button {
                    Task { await state.refreshLiveSource(source.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.isLoading)
                .help("刷新直播源")
            }
            Button(role: .destructive) {
                pendingDelete = source
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除直播源")
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
                Text("正在后台检测频道 \(completed)/\(total)")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        case .completed(let removed, let total):
            Label(
                removed == 0
                    ? "已检测 \(total) 个频道，未发现明确失效项"
                    : "已检测 \(total) 个频道，清理 \(removed) 个（可恢复）",
                systemImage: removed == 0
                    ? "checkmark.circle"
                    : "trash.slash"
            )
            .font(.caption2)
            .foregroundColor(.secondary)
        case .failed(let message):
            Label("后台检测未完成：\(message)", systemImage: "exclamationmark.triangle")
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
                return "远程 URL"
            }
            return LogRedactor.url(url)
        case .localFile:
            return source.sourceValue ?? "本地文件"
        case .pasted:
            return "粘贴内容"
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
        SettingsControlRow(
            icon: "play.rectangle.on.rectangle.fill",
            color: .purple,
            title: "播放器窗口",
            subtitle: subtitle
        ) {
            HStack(spacing: 10) {
                Picker(
                    "播放器窗口模式",
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
                .frame(width: 250)

                Button("恢复默认", action: restoreDefault)
                    .help("清除播放器窗口的大小、位置和模式记录")
            }
        }
    }

    private var subtitle: String {
        switch preferences.preference.mode {
        case .automaticAspect:
            return "记住窗口位置和观看尺度；高度会随视频比例调整"
        case .fixedFrame:
            return "精确恢复上次的宽度和高度；不同比例可能出现黑边"
        }
    }
}

private extension SettingsPane {
    var title: String {
        switch self {
        case .general: return "通用"
        case .configurations: return "点播配置"
        case .search: return "搜索"
        case .liveSources: return "直播源"
        case .playback: return "视频"
        case .cache: return "缓存"
        case .backup: return "备份与恢复"
        case .advanced: return "高级"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "外观与基础设置"
        case .configurations: return "导入与切换片源"
        case .search: return "选择默认搜索站点"
        case .liveSources: return "导入与管理直播源"
        case .playback: return "播放器与播放设置"
        case .cache: return "缓存与历史管理"
        case .backup: return "配置与历史备份"
        case .advanced: return "诊断和运行信息"
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
            return "1 年"
        case 3_650:
            return "10 年"
        default:
            return "\(days) 天"
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
            VStack(alignment: .leading, spacing: 14) {
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
        VStack(spacing: 0) {
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
