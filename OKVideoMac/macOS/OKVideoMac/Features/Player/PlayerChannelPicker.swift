import AppKit
import OKVideoCore
import SwiftUI

enum PlayerChannelGroupID: Hashable {
    case favorites, recent, all, source(String)
}

struct PlayerChannelGroup: Identifiable {
    let id: PlayerChannelGroupID
    let title: String
    let symbol: String
    let channels: [LiveChannel]
}

/// Keep source order and identity. Group names/numbers come from the accepted
/// catalogue; neither inferred TV categories nor invented numbers are stored.
struct PlayerChannelDirectory {
    let channels: [LiveChannel]
    let groups: [PlayerChannelGroup]

    init(channels: [LiveChannel], favoriteIDs: Set<String> = [], recentIDs: [String] = []) {
        var seen = Set<String>()
        self.channels = channels.filter { seen.insert($0.id).inserted }
        let byID = Dictionary(uniqueKeysWithValues: self.channels.map { ($0.id, $0) })
        var seenRecent = Set<String>()
        let recent = recentIDs.compactMap { id in seenRecent.insert(id).inserted ? byID[id] : nil }
        var result = [
            PlayerChannelGroup(id: .favorites, title: L10n.string("player.channel.favorites", fallback: "Favorites"), symbol: "star", channels: self.channels.filter { favoriteIDs.contains($0.id) }),
            PlayerChannelGroup(id: .recent, title: L10n.string("player.channel.recent", fallback: "Recent"), symbol: "clock", channels: recent),
            PlayerChannelGroup(id: .all, title: L10n.string("player.channel.all", fallback: "All"), symbol: "square.stack", channels: self.channels)
        ]
        var names: [String] = [], grouped: [String: [LiveChannel]] = [:]
        for channel in self.channels {
            if grouped[channel.groupName] == nil { names.append(channel.groupName) }
            grouped[channel.groupName, default: []].append(channel)
        }
        result += names.map { name in
            PlayerChannelGroup(id: .source(name), title: name.isEmpty ? L10n.string("player.channel.ungrouped", fallback: "Ungrouped") : name,
                symbol: "tv", channels: grouped[name] ?? [])
        }
        groups = result
    }

    func group(_ id: PlayerChannelGroupID) -> PlayerChannelGroup {
        groups.first { $0.id == id } ?? groups[2]
    }

    func initialGroup(navigationIDs: [String], currentID: String?) -> PlayerChannelGroupID {
        let ids = Set(navigationIDs)
        if !ids.isEmpty, ids == Set(group(.favorites).channels.map(\.id)) { return .favorites }
        if let matching = groups.dropFirst(3).first(where: { Set($0.channels.map(\.id)) == ids }) { return matching.id }
        return .all
    }
}

/// Owned by PlayerView, not the transient popup. Only view state is retained;
/// recent playback is separately scoped to the source in AppState.
@MainActor final class PlayerChannelPickerMemory: ObservableObject {
    @Published var group: PlayerChannelGroupID = .all
    @Published var query = ""
    @Published var highlightedID: String?
    private(set) var source: LiveSourceID?
    var offsets: [PlayerChannelGroupID: CGFloat] = [:]

    func prepare(source: LiveSourceID?, initialGroup: PlayerChannelGroupID) {
        guard self.source != source else { return }
        self.source = source
        group = initialGroup
        query = ""
        highlightedID = nil
        offsets = [:]
    }
}

struct PlayerChannelPicker: View {
    let directory: PlayerChannelDirectory
    let currentID: String?
    let initialGroup: PlayerChannelGroupID
    let title: String
    @ObservedObject var memory: PlayerChannelPickerMemory
    let epg: LiveEPGState?
    let source: LiveSourceID?
    let select: (String, PlayerChannelGroupID) -> Void
    let close: () -> Void
    @State private var keyboardInGroups = false
    @State private var locateRevision = 0

    init(directory: PlayerChannelDirectory, currentID: String?, title: String,
         memory: PlayerChannelPickerMemory, initialGroup: PlayerChannelGroupID = .all, epg: LiveEPGState? = nil, source: LiveSourceID? = nil,
         select: @escaping (String, PlayerChannelGroupID) -> Void, close: @escaping () -> Void) {
        self.directory = directory; self.currentID = currentID; self.title = title
        self.memory = memory; self.initialGroup = initialGroup; self.epg = epg; self.source = source
        self.select = select; self.close = close
    }

    private var selectedGroup: PlayerChannelGroup { directory.group(memory.group) }
    private var results: [LiveChannel] { PlayerChannelSearch.results(selectedGroup.channels, query: memory.query) }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 480
            let matches = results
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text("\(directory.channels.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(action: locateCurrent) {
                        Label(L10n.string("player.channel.locate", fallback: "Now Playing"), systemImage: "scope")
                            .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 28)
                    }
                    .buttonStyle(PlayerPanelButtonStyle(restingOpacity: 0.05))
                    .disabled(currentID == nil)
                    .accessibilityIdentifier("player.channel.locate")
                }
                PlayerChannelSearchField(text: $memory.query, move: { move($0) },
                    submit: submit, escape: escape, horizontal: { keyboardInGroups = $0 < 0 })
                    .frame(height: 30)
                if !wide {
                    Picker(L10n.string("player.channel.group", fallback: "Group"), selection: $memory.group) {
                        ForEach(directory.groups) { group in
                            Text("\(group.title) (\(group.channels.count))").tag(group.id)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .accessibilityIdentifier("player.channel.group-menu")
                }
                HStack(spacing: 12) {
                    if wide {
                        groupList.frame(width: 132)
                        Rectangle().fill(.white.opacity(0.09)).frame(width: 1)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(selectedGroup.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(L10n.string("player.channel.count", fallback: "%d channels", matches.count))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(height: 20)
                        channelList(matches)
                    }
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                Text(L10n.string("player.channel.keys", fallback: "↑↓ Select    ←→ Groups / Channels    Return Play    Esc Back"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(PlayerChannelKeyboardBridge(move: move, horizontal: { direction in
            keyboardInGroups = direction < 0
        }, submit: submit, escape: escape))
        .onAppear {
            memory.prepare(source: source, initialGroup: initialGroup)
            normalizeGroup()
            if !results.contains(where: { $0.id == memory.highlightedID }) { alignHighlight() }
        }
        .onChange(of: source) { _ in
            memory.prepare(source: source, initialGroup: initialGroup)
            normalizeGroup()
            keyboardInGroups = false
            alignHighlight()
        }
        .onChange(of: directory.groups.map(\.id)) { _ in normalizeGroup() }
        .onChange(of: memory.query) { _ in alignHighlight(); keyboardInGroups = false }
        .onChange(of: memory.group) { _ in alignHighlight() }
        .onChange(of: results.map(\.id)) { ids in
            if !ids.contains(memory.highlightedID ?? "") { alignHighlight() }
        }
        .accessibilityIdentifier("player.channel-picker")
    }

    private var groupList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(directory.groups) { group in
                        Button { memory.group = group.id; keyboardInGroups = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: group.symbol).frame(width: 16)
                                Text(group.title).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(group.channels.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 34)
                        }
                        .buttonStyle(PlayerPanelButtonStyle(selected: group.id == selectedGroup.id))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(keyboardInGroups && group.id == selectedGroup.id ? 0.6 : 0), lineWidth: 1).allowsHitTesting(false))
                        .accessibilityIdentifier("player.channel.group.\(group.title)")
                        .help(group.id == .recent ? L10n.string("player.channel.recent-help", fallback: "Channels played in this app session") : group.title)
                        .id(group.id)
                    }
                }
            }
            .onAppear { proxy.scrollTo(selectedGroup.id, anchor: .center) }
            .onChange(of: memory.group) { id in
                if keyboardInGroups { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func channelList(_ matches: [LiveChannel]) -> some View {
        let groupID = selectedGroup.id
        let searching = !memory.query.isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(matches) { channel in
                        Button { select(channel.id, selectedGroup.id) } label: {
                            channelRow(channel)
                        }
                        .buttonStyle(PlayerPanelButtonStyle(selected: channel.id == currentID))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                            .white.opacity(!keyboardInGroups && channel.id == memory.highlightedID ? 0.55 : 0), lineWidth: 1).allowsHitTesting(false))
                        .accessibilityIdentifier("player.channel.\(channel.id)")
                        .id(channel.id)
                    }
                }
                .background(PlayerChannelScrollMemory(
                    initialOffset: memory.query.isEmpty ? memory.offsets[selectedGroup.id] : 0,
                    initialIndex: matches.firstIndex { $0.id == currentID } ?? 0,
                    onScroll: { offset in
                        if !searching { memory.offsets[groupID] = offset }
                    }))
            }
            .overlay {
                if matches.isEmpty {
                    VStack(spacing: 10) {
                        Text(L10n.string("player.channel.no-results", fallback: "No matching channels"))
                            .foregroundStyle(.secondary)
                        if !memory.query.isEmpty {
                            Button(L10n.string("player.channel.clear", fallback: "Clear Search")) { memory.query = "" }
                                .buttonStyle(PlayerPanelButtonStyle())
                        }
                    }.font(.callout).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: memory.highlightedID) { id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: locateRevision) { _ in
                if let currentID { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
        .id(ChannelListIdentity(group: selectedGroup.id, query: memory.query))
    }

    private func channelRow(_ channel: LiveChannel) -> some View {
        HStack(spacing: 8) {
            if let number = channel.number, !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(number).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).frame(width: 32, alignment: .leading).help(number)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let epg, let source {
                    PlayerChannelProgrammeLine(epg: epg, channel: channel, source: source)
                } else {
                    Text(channel.groupName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if channel.id == currentID {
                Label(L10n.string("player.channel.playing", fallback: "Playing"), systemImage: "checkmark")
                    .font(.system(size: 10, weight: .medium)).fixedSize()
            }
        }
        .padding(.horizontal, 10).frame(height: 52)
        .help(channel.name + (channel.id == currentID ? " · " + L10n.string("player.channel.playing", fallback: "Playing") : ""))
    }

    private func normalizeGroup() {
        if !directory.groups.contains(where: { $0.id == memory.group }) { memory.group = .all }
    }

    private func alignHighlight() {
        let matches = results
        memory.highlightedID = memory.query.isEmpty
            ? matches.first(where: { $0.id == currentID })?.id ?? matches.first?.id : matches.first?.id
    }
    private func move(_ offset: Int) {
        if keyboardInGroups {
            let index = directory.groups.firstIndex { $0.id == selectedGroup.id } ?? 0
            memory.group = directory.groups[min(max(0, index + offset), directory.groups.count - 1)].id
        } else {
            let matches = results
            guard !matches.isEmpty else { return }
            let index = matches.firstIndex { $0.id == memory.highlightedID } ?? (offset > 0 ? -1 : matches.count)
            memory.highlightedID = matches[min(max(index + offset, 0), matches.count - 1)].id
        }
    }
    private func submit() {
        if keyboardInGroups { keyboardInGroups = false; return }
        if let id = memory.highlightedID, results.contains(where: { $0.id == id }) { select(id, selectedGroup.id) }
    }
    private func escape() {
        if !memory.query.isEmpty { memory.query = "" }
        else { close() }
    }
    private func locateCurrent() {
        guard let currentID, let channel = directory.channels.first(where: { $0.id == currentID }) else { return }
        memory.query = ""
        if !selectedGroup.channels.contains(where: { $0.id == currentID }) { memory.group = .source(channel.groupName) }
        keyboardInGroups = false
        memory.highlightedID = currentID
        locateRevision += 1
    }
}

private struct ChannelListIdentity: Hashable {
    let group: PlayerChannelGroupID
    let query: String
}

private struct PlayerChannelProgrammeLine: View {
    @ObservedObject var epg: LiveEPGState
    let channel: LiveChannel
    let source: LiveSourceID
    var body: some View {
        let initial = epg.nowNext(channel: channel, source: source, at: Date())
        let intervals = [initial.current, initial.next].compactMap { $0 }.filter { $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
        TimelineView(PlayerLiveInfoTimelineSchedule(intervals: intervals)) { context in
            Text(epg.nowNext(channel: channel, source: source, at: context.date).current?.title
                ?? L10n.string("player.live-info.empty", fallback: "No programme information"))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(height: 15, alignment: .leading)
        }
    }
}

/// Restore native scroll offsets exactly, rather than moving to the current
/// channel on every reopen. Each group owns its offset; search starts at top.
struct PlayerChannelScrollMemory: NSViewRepresentable {
    let initialOffset: CGFloat?
    let initialIndex: Int
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.initialOffset = initialOffset; view.initialIndex = initialIndex
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.onScroll = onScroll; view.bindLater() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        var initialOffset: CGFloat?
        var initialIndex = 0
        var onScroll: ((CGFloat) -> Void)?
        private weak var clip: NSClipView?
        private var observer: NSObjectProtocol?
        private var restored = false
        private var scheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindLater() }
        override func layout() { super.layout(); bindLater() }
        func bindLater() {
            guard !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard self.window != nil, let scroll = self.enclosingScrollView, let document = scroll.documentView,
                      scroll.contentView.bounds.height > 0, document.bounds.height > 0 else { return }
                if self.clip !== scroll.contentView {
                    self.stop(); self.clip = scroll.contentView
                    scroll.contentView.postsBoundsChangedNotifications = true
                    self.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                        object: scroll.contentView, queue: .main) { [weak self] _ in self?.bindLater() }
                }
                if !self.restored {
                    self.restored = true
                    let desired = self.initialOffset ?? max(0, CGFloat(self.initialIndex) * 56 - scroll.contentView.bounds.height / 2 + 26)
                    let offset = min(max(0, desired), max(0, document.bounds.height - scroll.contentView.bounds.height))
                    let y = document.isFlipped ? document.bounds.minY + offset : document.bounds.maxY - scroll.contentView.bounds.height - offset
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
                let offset = document.isFlipped ? scroll.contentView.bounds.minY - document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.maxY
                self.onScroll?(max(0, offset))
            }
        }
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil; clip = nil
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Scoped to the mounted popup and its own window. Editable text keeps normal
/// caret/IME handling; the native search delegate handles Up/Down/Return/Esc.
struct PlayerChannelKeyboardBridge: NSViewRepresentable {
    let move: (Int) -> Void
    let horizontal: (Int) -> Void
    let submit: () -> Void
    let escape: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {
        view.handler = { event in
            switch event.keyCode {
            case 125: move(1)
            case 126: move(-1)
            case 123: horizontal(-1)
            case 124: horizontal(1)
            case 36, 76: submit()
            case 53: escape()
            default: return false
            }
            return true
        }
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }
    final class KeyView: NSView {
        private static let owners = NSMapTable<NSWindow, KeyView>.weakToWeakObjects()
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?
        private weak var registeredWindow: NSWindow?

        static func route(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let owner = owners.object(forKey: window), owner.window === window,
                  event.window === window, window.isKeyWindow,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(window.firstResponder is NSTextField),
                  (window.firstResponder as? NSTextView)?.isEditable != true else { return false }
            return owner.handler?(event) == true
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            registeredWindow = window
            Self.owners.setObject(self, forKey: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let window = self?.window else { return event }
                return Self.route(event, in: window) ? nil : event
            }
        }
        func stop() {
            if let window = registeredWindow, Self.owners.object(forKey: window) === self { Self.owners.removeObject(forKey: window) }
            registeredWindow = nil
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
