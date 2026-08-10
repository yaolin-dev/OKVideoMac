import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var posterCacheSize = "正在计算…"

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
        .navigationTitle("设置")
        .task {
            await refreshCacheSize()
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
        case .liveSources:
            LiveSourceSettingsPane()
                .environmentObject(state)
        case .playback:
            playbackSettings
        case .cache:
            cacheSettings
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
            subtitle: "导入、切换和维护 FongMi 点播配置"
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
                    subtitle: "OK影视 Mac",
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
                    subtitle: "\(state.visibleSites.count) 个可见站点",
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
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Button("检查") {
                            Task { await state.refreshAndroidRuntimeStatus() }
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
                        "该模块仅用于 Java/Dex 点播站点，普通播放和 JS 站点不需要它。",
                        systemImage: "info.circle"
                    )
                    Text(
                        "应用会复用现有的 OKVideoDexBridge 模拟器数据；"
                            + "退出 OK影视时不会强制关闭，需要时可在此手动停止。"
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
            await state.refreshAndroidRuntimeStatus()
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
        do {
            try state.exportDiagnostics(to: url)
        } catch {
            state.presentedError = UserFacingError(
                title: "诊断导出失败",
                message: error.localizedDescription
            )
        }
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
                        Text("支持远程 URL、本地 M3U/TXT/JSON 文件和粘贴内容。")
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
                    subtitle: "远程来源可在更新后直接刷新"
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

private extension SettingsPane {
    var title: String {
        switch self {
        case .general: return "通用"
        case .configurations: return "点播配置"
        case .liveSources: return "直播源"
        case .playback: return "视频"
        case .cache: return "缓存"
        case .advanced: return "高级"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "外观与基础设置"
        case .configurations: return "导入与切换片源"
        case .liveSources: return "导入与管理直播源"
        case .playback: return "播放器与播放设置"
        case .cache: return "缓存与历史管理"
        case .advanced: return "诊断和运行信息"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .configurations: return "doc.badge.gearshape"
        case .liveSources: return "dot.radiowaves.left.and.right"
        case .playback: return "play.rectangle.fill"
        case .cache: return "externaldrive.fill"
        case .advanced: return "slider.horizontal.3"
        }
    }

    var color: Color {
        switch self {
        case .general: return .blue
        case .configurations: return .indigo
        case .liveSources: return .teal
        case .playback: return .pink
        case .cache: return .orange
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
