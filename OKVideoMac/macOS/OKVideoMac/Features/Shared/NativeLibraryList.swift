import AppKit
import SwiftUI

/// Passive progress with semantic grayscale colors; never suggests a draggable seek control.
final class NativeNeutralProgressView: NSView {
    var doubleValue: Double = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 2) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshContrast),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func refreshContrast() { needsDisplay = true }
    static func increasedContrast(in appearance: NSAppearance) -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ||
            [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua].contains(appearance.bestMatch(from:
                [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]))
    }
    override func accessibilityValue() -> Any? { min(max(doubleValue.isFinite ? doubleValue : 0, 0), 1) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let contrast = NativeNeutralProgressView.increasedContrast(in: effectiveAppearance)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1)
        NSColor.labelColor.withAlphaComponent(contrast ? 0.24 : 0.10).setFill()
        path.fill()
        let fraction = min(max(doubleValue.isFinite ? doubleValue : 0, 0), 1)
        guard fraction > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (contrast ? NSColor.labelColor : NSColor.secondaryLabelColor).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * fraction, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct NativeLibraryRow: Equatable {
    let id: String
    let title: String
    let subtitle: String
    var summary: String = ""
    let posterURL: URL?
    let date: Date
    var progress: Double? = nil
    var progressText: String = ""
    var isLoading = false
}

/// The table owns selection, scrolling, focus, and accessibility. Only the
/// application's open/delete commands cross back to SwiftUI.
struct NativeLibraryList: NSViewRepresentable {
    @Environment(\.browserNavigationSelection) private var navigationSelection
    let rows: [NativeLibraryRow]
    @Binding var selection: Set<String>
    let repository: ImageRepository?
    let openTitle: String
    var openSymbol = "play.fill"
    let onOpen: (String) -> Void
    let onDelete: (Set<String>, NSWindow?) -> Void
    var onRepairSource: ((String, NSWindow?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NativeLibraryScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let table = NativeLibraryTableView()
        table.headerView = nil
        table.focusRingType = .none
        table.style = .fullWidth
        table.rowHeight = 100
        table.intercellSpacing = NSSize(width: 0, height: 1)
        // Rows paint their own separator. Table grid lines also extend into
        // the empty viewport, and the full-width row background can hide them.
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("content"))
        column.minWidth = 260
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelection)
        table.onOpen = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        table.onDelete = { [weak coordinator = context.coordinator] in coordinator?.deleteSelection() }
        table.onMouseInteractionEnded = { [weak coordinator = context.coordinator] in coordinator?.finishMouseInteraction() }
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self, navigationSelection: navigationSelection)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: NativeLibraryList
        weak var table: NativeLibraryTableView?
        var updating = false
        private var lastRequestedSelection: Set<String>?
        private var pendingUpdate: (parent: NativeLibraryList, navigation: NavigationSelection?, selection: Set<String>?)?
        init(_ parent: NativeLibraryList) { self.parent = parent }

        func update(_ value: NativeLibraryList, navigationSelection: NavigationSelection?) {
            guard let table else { return }
            // Only an actual binding change (for example Select All) is a
            // selection command. Progress updates must not replay an old value
            // over AppKit's selection before its mouse-up notification.
            let requestedSelection = lastRequestedSelection != value.selection ? value.selection : nil
            lastRequestedSelection = value.selection
            if table.isTrackingMouse {
                // Keep the displayed row identities and action targets stable
                // through native tracking, including a double-click or drag.
                pendingUpdate = (value, navigationSelection, requestedSelection ?? pendingUpdate?.selection)
                return
            }
            apply(value, navigation: navigationSelection, selection: requestedSelection)
        }

        func finishMouseInteraction() {
            guard let pending = pendingUpdate else { return }
            pendingUpdate = nil
            apply(pending.parent, navigation: pending.navigation, selection: pending.selection)
        }

        private func apply(_ value: NativeLibraryList, navigation: NavigationSelection?, selection: Set<String>?) {
            guard let table else { return }
            let previousIDs = parent.rows.map(\.id)
            let selectedIDs = selection ?? Set(table.selectedRowIndexes.compactMap {
                parent.rows.indices.contains($0) ? parent.rows[$0].id : nil
            })
            parent = value
            table.navigationSelection = navigation
            updating = true
            defer { updating = false }
            let rows = value.rows
            if previousIDs != rows.map(\.id) || table.numberOfRows != rows.count {
                table.reloadData()
            } else {
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound {
                    for index in visible.location..<min(NSMaxRange(visible), rows.count) {
                        (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NativeLibraryCell)?.update(
                            rows[index], repository: value.repository, openTitle: value.openTitle, openSymbol: value.openSymbol,
                            onOpen: value.onOpen, onDelete: value.onDelete)
                    }
                }
            }
            let indexes = IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) })
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            if !value.selection.isSubset(of: Set(rows.map(\.id))) {
                // A row can disappear during the gesture. Reconcile on the
                // next turn, outside SwiftUI's representable update transaction.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.table?.isTrackingMouse == false else { return }
                    let valid = self.parent.selection.intersection(self.parent.rows.map(\.id))
                    if valid != self.parent.selection { self.parent.selection = valid }
                }
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("library-cell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NativeLibraryCell ?? NativeLibraryCell()
            cell.identifier = id
            cell.update(parent.rows[row], repository: parent.repository, openTitle: parent.openTitle, openSymbol: parent.openSymbol,
                        onOpen: parent.onOpen, onDelete: parent.onDelete)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            NativeLibrarySelectionRowView()
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap {
                parent.rows.indices.contains($0) ? parent.rows[$0].id : nil
            })
        }
        @objc func openSelection() {
            guard let table, table.selectedRowIndexes.count == 1,
                  parent.rows.indices.contains(table.selectedRow) else { return }
            parent.onOpen(parent.rows[table.selectedRow].id)
        }
        @objc func deleteSelection() {
            guard let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap {
                parent.rows.indices.contains($0) ? parent.rows[$0].id : nil
            })
            if !ids.isEmpty { parent.onDelete(ids, table.window) }
        }
        @objc func repairSelection() {
            guard let table, table.selectedRowIndexes.count == 1, parent.rows.indices.contains(table.selectedRow) else { return }
            parent.onRepairSource?(parent.rows[table.selectedRow].id, table.window)
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table else { return }
            if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            menu.removeAllItems()
            if parent.onRepairSource != nil {
                let repair = menu.addItem(withTitle: L10n.string("favorites.source.choose", fallback: "Confirm Favorite Source"), action: #selector(repairSelection), keyEquivalent: "")
                repair.target = self; repair.isEnabled = table.selectedRowIndexes.count == 1
            }
            let open = menu.addItem(withTitle: parent.openTitle, action: #selector(openSelection), keyEquivalent: "")
            open.target = self
            open.isEnabled = table.selectedRowIndexes.count == 1
            let delete = menu.addItem(withTitle: L10n.string("common.delete", fallback: "Delete"), action: #selector(deleteSelection), keyEquivalent: "")
            delete.target = self
            delete.isEnabled = !table.selectedRowIndexes.isEmpty
        }
    }
}

final class NativeLibraryScrollView: BrowserHoverScrollView {
    override func layout() {
        super.layout()
        guard let table = documentView as? NSTableView else { return }
        let width = contentSize.width
        if width > 0, abs((table.tableColumns.first?.width ?? 0) - width) > 0.5 {
            table.frame.size.width = width
            table.tableColumns.first?.width = width
        }
    }
}

final class NativeLibraryTableView: NSTableView, BrowserContentKeyTarget {
    var navigationSelection: NavigationSelection?
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    private(set) var showsKeyboardFocus = false
    private(set) var isTrackingMouse = false
    var onMouseInteractionEnded: (() -> Void)?
    private func refreshSelectionAppearance() {
        enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        defer {
            isTrackingMouse = false
            onMouseInteractionEnded?()
        }
        showsKeyboardFocus = false
        refreshSelectionAppearance()
        super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown
            refreshSelectionAppearance()
        }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { showsKeyboardFocus = false; refreshSelectionAppearance() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        showsKeyboardFocus = true
        refreshSelectionAppearance()
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 36, 76: onOpen?()
        case 51, 117: onDelete?()
        case 53: deselectAll(nil)
        default: super.keyDown(with: event)
        }
    }
}

/// Preserve native table selection and accessibility while drawing a quiet inset highlight.
final class NativeLibrarySelectionRowView: NSTableRowView, BrowserHoverTarget {
    private var isHovering = false
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool { didSet { needsDisplay = true } }
    override var isSelected: Bool { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance), name: name, object: window)
            }
        }
        needsDisplay = true
    }
    @objc private func refreshAppearance() { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    func setBrowserHovered(_ hovered: Bool) {
        guard isHovering != hovered else { return }
        isHovering = hovered
        needsDisplay = true
    }
    var selectionRect: NSRect {
        let visible = bounds.intersection(visibleRect)
        // Clip horizontally for the full-width table's extra column inset, but
        // keep vertical geometry stable as a row scrolls partly out of view.
        return NSRect(x: visible.minX, y: bounds.minY, width: visible.width, height: bounds.height).insetBy(dx: 10, dy: 4)
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovering && !isSelected && window?.isKeyWindow == true {
            BrowserHoverStyle.color.setFill()
            NSBezierPath(roundedRect: selectionRect, xRadius: BrowserHoverStyle.cornerRadius, yRadius: BrowserHoverStyle.cornerRadius).fill()
        }
        let pixel = 1 / max(window?.backingScaleFactor ?? 1, 1)
        let y = isFlipped ? bounds.maxY - pixel : bounds.minY
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: y, width: bounds.width, height: pixel).intersection(dirtyRect).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let active = window?.isKeyWindow == true
        let contrast = NativeNeutralProgressView.increasedContrast(in: effectiveAppearance)
        let background = NSColor.controlBackgroundColor
        let fill = background.blended(withFraction: active ? 0.09 : 0.06, of: active ? .systemBlue : .labelColor) ?? background
        let outline = NSColor.labelColor.withAlphaComponent(contrast ? 0.55 : 0.16)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
        fill.setFill(); path.fill()
        outline.setStroke(); path.lineWidth = contrast ? 1.5 : 0.75; path.stroke()
        if active, let table = superview as? NativeLibraryTableView,
           table.showsKeyboardFocus, window?.firstResponder === table {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            path.lineWidth = 2; path.stroke()
        }
    }
}

/// AppKit still draws and tracks the button. Explicit first-mouse acceptance
/// lets a click from the separate player window present the confirmation sheet.
final class NativeLibraryActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NativeLibraryCell: NSTableCellView {
    let poster = NSImageView()
    let title = NativeOverflowTooltipField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let summary = NSTextField(wrappingLabelWithString: "")
    let time = NSTextField(labelWithString: "")
    let date = NSTextField(labelWithString: "")
    let progress = NativeNeutralProgressView()
    let loading = NSProgressIndicator()
    let open = NativeLibraryActionButton()
    let remove = NativeLibraryActionButton()
    private var rowID = ""
    private var imageURL: URL?
    private var imageTask: Task<Void, Never>?
    private var openAction: ((String) -> Void)?
    private var deleteAction: ((Set<String>, NSWindow?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for label in [title, subtitle, summary, time, date] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = label === summary ? 2 : 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [subtitle, summary, time, date] { label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        let details = NSStackView(views: [title, subtitle, summary, progress, time])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        for button in [open, remove] {
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.contentTintColor = .secondaryLabelColor
            button.setButtonType(.momentaryPushIn)
            button.imagePosition = .imageOnly
            button.target = self
        }
        open.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        open.action = #selector(openItem)
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        remove.action = #selector(deleteItem)
        remove.toolTip = L10n.string("common.delete", fallback: "Delete")
        remove.setAccessibilityLabel(remove.toolTip)
        loading.style = .spinning; loading.controlSize = .small
        loading.isDisplayedWhenStopped = false
        let stack = NSStackView(views: [poster, details, date, loading, open, remove])
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let progressWidth = progress.widthAnchor.constraint(equalToConstant: 200)
        progressWidth.priority = .defaultHigh
        progressWidth.isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            loading.widthAnchor.constraint(equalToConstant: 16),
            loading.heightAnchor.constraint(equalToConstant: 16),
            summary.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            summary.widthAnchor.constraint(lessThanOrEqualTo: details.widthAnchor),
            poster.widthAnchor.constraint(equalToConstant: 48),
            poster.heightAnchor.constraint(equalToConstant: 72),
            progress.widthAnchor.constraint(lessThanOrEqualTo: details.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            open.heightAnchor.constraint(equalToConstant: 28),
            remove.heightAnchor.constraint(equalToConstant: 28),
            open.widthAnchor.constraint(equalToConstant: 36),
            remove.widthAnchor.constraint(equalToConstant: 36)
        ])
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { imageTask?.cancel() }
    func update(_ row: NativeLibraryRow, repository: ImageRepository?, openTitle: String, openSymbol: String = "play.fill",
                onOpen: @escaping (String) -> Void, onDelete: @escaping (Set<String>, NSWindow?) -> Void) {
        rowID = row.id; openAction = onOpen; deleteAction = onDelete
        title.stringValue = row.title; subtitle.stringValue = row.subtitle
        summary.stringValue = row.summary; summary.isHidden = row.summary.isEmpty
        time.stringValue = row.progressText; time.isHidden = row.progressText.isEmpty
        progress.isHidden = row.progress == nil; progress.doubleValue = row.progress ?? 0
        progress.setAccessibilityLabel(L10n.string("history.playback-progress", fallback: "Watch Progress"))
        date.stringValue = row.date.formatted(date: .abbreviated, time: .shortened)
        open.toolTip = openTitle; open.setAccessibilityLabel(openTitle)
        open.image = NSImage(systemSymbolName: openSymbol, accessibilityDescription: nil)
        open.isEnabled = !row.isLoading
        loading.isHidden = !row.isLoading
        if row.isLoading { loading.startAnimation(nil) } else { loading.stopAnimation(nil) }
        if imageURL != row.posterURL || poster.image == nil {
            imageTask?.cancel(); imageURL = row.posterURL
            poster.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            if let url = row.posterURL, let repository {
                imageTask = Task { @MainActor [weak self] in
                    let image = try? await repository.image(for: url)
                    guard !Task.isCancelled, let self, self.imageURL == url else { return }
                    if let image { self.poster.image = image }
                }
            }
        }
    }
    @objc private func openItem() { openAction?(rowID) }
    @objc private func deleteItem() { deleteAction?([rowID], window) }
}

@MainActor
enum NativeLibraryConfirmation {
    static func present(title: String, message: String, window: NSWindow?, confirm: @escaping () -> Void) {
        guard let window = window ?? NSApp.keyWindow, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title; alert.informativeText = message
        let cancel = alert.addButton(withTitle: L10n.string(.commonCancel))
        cancel.keyEquivalent = "\u{1b}"
        let delete = alert.addButton(withTitle: L10n.string("common.delete", fallback: "Delete"))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { confirm() }
        }
    }
}
