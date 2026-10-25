import Combine
import SwiftUI

enum SettingsDataTab: String, CaseIterable, Identifiable {
    case privacy, storage, backup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .privacy: return SettingsL10n.string("settings.organized.data.privacy", "History & Privacy")
        case .storage: return SettingsL10n.string("settings.organized.data.storage", "Storage")
        case .backup: return SettingsL10n.string("settings.organized.data.backup", "Backup & Restore")
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, playback, details, configurations, liveSources, data, advanced, about
    // Preserve older navigation destinations without duplicating sidebar items.
    case search, cache, backup
    static let allCases: [Self] = [.general, .playback, .details, .configurations, .liveSources, .data, .advanced, .about]
    var id: String { rawValue }
    var canonical: Self {
        switch self {
        case .search: return .configurations
        case .cache, .backup: return .data
        default: return self
        }
    }
    var title: String {
        switch canonical {
        case .general: return SettingsL10n.string("settings.pane.general.title", "General")
        case .playback: return SettingsL10n.string("settings.organized.pane.playback", "Playback")
        case .details: return SettingsL10n.string("settings.organized.pane.details", "Movie Details")
        case .configurations: return SettingsL10n.string("settings.organized.pane.sources", "Providers & Search")
        case .liveSources: return SettingsL10n.string("settings.organized.pane.live", "Live TV & Guide")
        case .data: return SettingsL10n.string("settings.organized.pane.data", "Data & Privacy")
        case .advanced: return SettingsL10n.string("settings.organized.pane.compatibility", "Compatibility & Diagnostics")
        case .about: return SettingsL10n.string("settings.organized.pane.about", "About & Updates")
        default: return canonical.title
        }
    }
    var iconColor: Color {
        switch canonical {
        case .general: return .gray
        case .playback: return .blue
        case .details: return .orange
        case .configurations: return .indigo
        case .liveSources: return .pink
        case .data: return .green
        case .advanced: return .gray
        case .about: return .blue
        default: return .gray
        }
    }
    var systemImage: String {
        switch canonical {
        case .general: return "gearshape"
        case .playback: return "play.rectangle"
        case .details: return "film"
        case .configurations: return "square.stack"
        case .liveSources: return "dot.radiowaves.left.and.right"
        case .data: return "externaldrive"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        default: return canonical.systemImage
        }
    }
}

enum SettingsGroup: String, CaseIterable, Identifiable {
    case preferences, sources, application
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preferences: return SettingsL10n.string("settings.organized.group.preferences", "Preferences")
        case .sources: return SettingsL10n.string("settings.organized.group.sources", "Content Sources")
        case .application: return SettingsL10n.string("settings.organized.group.application", "Application")
        }
    }
    var panes: [SettingsPane] {
        switch self {
        case .preferences: return [.general, .playback, .details]
        case .sources: return [.configurations, .liveSources]
        case .application: return [.data, .advanced, .about]
        }
    }
}

struct SettingsFocus: Equatable {
    let id = UUID()
    let sectionID: String
}

/// Settings category changes remain isolated from the main browser publisher.
@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published private(set) var selectedPane: SettingsPane = .general
    @Published var dataTab: SettingsDataTab = .privacy
    @Published private(set) var focus: SettingsFocus?

    func select(_ pane: SettingsPane) {
        switch pane {
        case .search: select(.configurations, sectionID: "search-scope")
        case .cache: select(.data, sectionID: "image-cache", tab: .storage)
        case .backup: select(.data, sectionID: "backup", tab: .backup)
        default:
            if selectedPane != pane { selectedPane = pane }
            if focus != nil { focus = nil }
        }
    }
    func select(_ pane: SettingsPane, sectionID: String, tab: SettingsDataTab? = nil) {
        if selectedPane != pane.canonical { selectedPane = pane.canonical }
        if let tab, dataTab != tab { dataTab = tab }
        focus = SettingsFocus(sectionID: sectionID)
    }
    func finishFocus(_ id: UUID) { if focus?.id == id { focus = nil } }
}

struct SettingsSearchEntry: Identifiable {
    let id: String
    let title: String
    let pane: SettingsPane
    let sectionID: String
    var tab: SettingsDataTab? = nil
    let keywords: String
    var path: String { [pane.title, tab?.title].compactMap { $0 }.joined(separator: " › ") }
    static var all: [Self] { [
        .init(id: "language", title: L10n.string(.languageTitle), pane: .general, sectionID: "appearance", keywords: "语言 中文 英文 language english chinese"),
        .init(id: "theme", title: SettingsL10n.string("settings.appearance.theme.title", "Appearance"), pane: .general, sectionID: "appearance", keywords: "外观 主题 浅色 深色 系统 theme dark light appearance"),
        .init(id: "main-window", title: SettingsL10n.string("settings.window.main.title", "Main Window"), pane: .general, sectionID: "main-window", keywords: "窗口 布局 恢复 尺寸 位置 window layout reset"),
        .init(id: "hardware", title: SettingsL10n.string("settings.playback.hardware-decoding.title", "Hardware Decoding"), pane: .playback, sectionID: "playback", keywords: "硬解 硬件 解码 hardware decoding"),
        .init(id: "autoplay", title: SettingsL10n.string("settings.playback.autoplay.title", "Autoplay Next Episode"), pane: .playback, sectionID: "playback", keywords: "连播 自动 下一集 autoplay next episode"),
        .init(id: "player-window", title: SettingsL10n.string("settings.player-window.title", "Player Window"), pane: .playback, sectionID: "player-window", keywords: "播放 窗口 比例 固定 尺寸 player window aspect fixed"),
        .init(id: "playback-info", title: SettingsL10n.string("settings.organized.playback.information", "Playback Information"), pane: .playback, sectionID: "playback-info", keywords: "内核 libmpv 播放 状态 backend"),
        .init(id: "details", title: L10n.string("detail.presentation.title", fallback: "Detail Page Style"), pane: .details, sectionID: "detail-style", keywords: "详情 原版 tmdb 海报 卡片 style"),
        .init(id: "tmdb", title: SettingsL10n.string("settings.organized.tmdb.connection", "TMDB Connection"), pane: .details, sectionID: "tmdb-connection", keywords: "凭据 凭证 账号 直连 API token key 图片 检测 metadata credentials"),
        .init(id: "matching", title: SettingsL10n.string("settings.organized.tmdb.matching", "Matching Rules"), pane: .details, sectionID: "matching", keywords: "匹配 宽松 识别 relaxed matching"),
        .init(id: "providers", title: SettingsL10n.string("settings.organized.sources.configurations", "Video Configurations"), pane: .configurations, sectionID: "providers", keywords: "片源 配置 导入 添加 切换 更新 链接 文件 账号 xtream catpaw tvbox provider source"),
        .init(id: "search", title: SettingsL10n.string("settings.search.default-scope.section", "Default Search Scope"), pane: .configurations, sectionID: "search-scope", keywords: "搜索 范围 站点 全选 默认 search scope sites"),
        .init(id: "live", title: SettingsL10n.string("settings.live.manage.section", "Source Management"), pane: .liveSources, sectionID: "live-sources", keywords: "直播 源 导入 添加 更新 m3u m3u8 txt live"),
        .init(id: "epg", title: SettingsL10n.string("settings.organized.epg.defaults", "Programme Guide Defaults"), pane: .liveSources, sectionID: "epg", keywords: "节目单 节目表 默认 地址 自动 epg xmltv guide"),
        .init(id: "history", title: SettingsL10n.string("settings.organized.data.privacy", "History & Privacy"), pane: .data, sectionID: "history", tab: .privacy, keywords: "历史 无痕 隐私 保留 清除 删除 private incognito retention history"),
        .init(id: "crash", title: SettingsL10n.string("settings.organized.privacy.diagnostics", "Crash Reports"), pane: .data, sectionID: "crash-reports", tab: .privacy, keywords: "隐私 崩溃 报告 上传 发送 privacy crash reports consent"),
        .init(id: "cache", title: SettingsL10n.string("settings.organized.cache.images", "Image Cache"), pane: .data, sectionID: "image-cache", tab: .storage, keywords: "存储 缓存 海报 图标 清理 空间 cache storage poster logos"),
        .init(id: "backup", title: SettingsL10n.string("settings.organized.backup.current", "Back Up Current Configuration"), pane: .data, sectionID: "backup", tab: .backup, keywords: "备份 恢复 导入 导出 收藏 历史 backup restore import export favorites"),
        .init(id: "runtime", title: SettingsL10n.string("settings.android.section.title", "Android Compatibility"), pane: .advanced, sectionID: "runtime", keywords: "兼容 安卓 组件 安装 启动 停止 android dex runtime"),
        .init(id: "environment", title: SettingsL10n.string("settings.organized.runtime.environment", "Environment Configuration"), pane: .advanced, sectionID: "environment", keywords: "环境 外部 sdk 托管 路径 sdk managed external"),
        .init(id: "repair", title: SettingsL10n.string("settings.organized.runtime.maintenance", "Repair & Uninstall"), pane: .advanced, sectionID: "maintenance", keywords: "修复 桥接 重建 卸载 维护 repair bridge rebuild uninstall"),
        .init(id: "diagnostics", title: SettingsL10n.string("settings.diagnostics.title", "Export Diagnostics"), pane: .advanced, sectionID: "diagnostics", keywords: "诊断 导出 故障 日志 diagnostics export logs"),
        .init(id: "updates", title: L10n.string("updates.title", fallback: "Software Updates"), pane: .about, sectionID: "updates", keywords: "更新 版本 自动 检查 update version automatic"),
        .init(id: "credits", title: SettingsL10n.string("settings.organized.about.credits", "Acknowledgements & Scope"), pane: .about, sectionID: "credits", keywords: "关于 致谢 许可 版权 支持 about credits license")
    ] }
    static func matching(_ query: String) -> [Self] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return all.filter { entry in
            let value = "\(entry.title) \(entry.path) \(entry.keywords)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return words.allSatisfy { value.contains($0) }
        }
    }
}
