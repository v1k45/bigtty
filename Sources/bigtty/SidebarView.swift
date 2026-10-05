import AppKit
import HerdrKit

/// What the sidebar shows, built by the window controller.
struct SidebarModel: Equatable {
    struct Tab: Equatable {
        let id: String
        let label: String
        let detail: String
        let selected: Bool
        let alert: Bool
        var audible = false
        /// Its shortcut, shown while ⌘ is held.
        var hint: String? = nil
        /// Its agent is working.
        var working = false
    }

    struct Space: Equatable {
        let id: String
        let name: String
        let shortcut: String
        let meta: String
        let ports: [Int]
        let line: String?
        let alert: Bool
        let finished: Bool
        let selected: Bool
        let tabs: [Tab]
        /// ⌘ held: the shortcut stands out.
        var hinting = false
        var audible = false
        /// "3 tabs · first · second +1" for a space that isn't selected.
        var tabSummary: String? = nil
        /// An agent in it is working (a quieter dot than "needs you").
        var working = false
        /// Nothing's happened in it for a long while: drawn faded.
        var stale = false
    }

    /// A machine's session switcher.
    struct SessionChip: Equatable {
        let name: String
        /// Panes in the machine's other sessions that need you.
        let othersNeedingYou: Int
    }

    struct Machine: Equatable {
        let id: String
        let name: String
        let status: String
        let statusIsProblem: Bool
        var statusTip: String? = nil
        /// Set when the machine has sessions to switch between.
        var session: SessionChip? = nil
        let spaces: [Space]
    }

    /// One thing on the Needs You list.
    struct NeedsYou: Equatable {
        let id: String
        let kind: NeedsYouItem.Kind
        let title: String
        let line: String
        let place: String
        let age: String?
        let symbol: String
        let urgent: Bool
        /// A login can't be dismissed, only dealt with.
        let dismissable: Bool
    }

    /// Everything waiting on you, most urgent first, on every machine.
    var needsYou: [NeedsYou] = []
    var machines: [Machine] = []
    var message: String?
}

/// The native sidebar: machines, their spaces as cards, and the selected
/// space's tabs. Plain AppKit views laid out top to bottom.
@MainActor
final class SidebarView: NSView {
    var onSelectSpace: ((String) -> Void)?
    var onSelectTab: ((String, String) -> Void)?
    var onSpaceMenu: ((String) -> NSMenu?)?
    var onCloseSpace: ((String) -> Void)?
    var onCloseTab: ((String, String) -> Void)?
    /// A pane dropped on a space card (key), one of its tabs (key, tab) or
    /// the empty list below the cards (nil, nil: a new space).
    var onDropPane: ((String?, String?, PaneDragPayload) -> Void)?
    /// A dragged pane held over a space (key) or one of its tabs: open it,
    /// to place the pane there precisely.
    var onSpringLoad: ((String, String?) -> Void)?
    var onMachineClick: ((String) -> Void)?
    /// The session switcher for a machine (by id).
    var onSessionMenu: ((String) -> NSMenu?)?
    var onHideSidebar: (() -> Void)?
    /// A space card dropped at a position among its machine's spaces.
    var onMoveSpace: ((String, Int) -> Void)?
    private let dropLine = NSView()
    var onToggleFiles: (() -> Void)?
    /// A Needs You row clicked or dismissed (by id), or "more" clicked.
    var onOpenNeedsYou: ((String) -> Void)?
    var onDismissNeedsYou: ((String) -> Void)?
    var onShowAllNeedsYou: (() -> Void)?
    /// Title-strip buttons, right of the traffic lights.
    private let hideButton = StripButton(symbol: "sidebar.left", tip: "Hide Sidebar (⌃⌘S)")
    private let filesButton = StripButton(symbol: "folder", tip: "Toggle File Viewer (⇧⌘E)")

    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let brand = BrandMark()
    private var model = SidebarModel()
    private var selectedID: String?

    static let titlebarHeight: CGFloat = 40

    /// No traffic lights in full screen: the brand takes their corner.
    var fullScreen = false { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
        addSubview(brand)
        hideButton.target = self
        hideButton.action = #selector(hideClicked)
        filesButton.target = self
        filesButton.action = #selector(filesClicked)
        addSubview(hideButton)
        addSubview(filesButton)
        list.registerForDraggedTypes([.bigttySpace, .bigttyPane])
        list.onDrag = { [weak self] key, point, done in self?.dragSpace(key, at: point, drop: done) ?? false }
        list.onPaneDrag = { [weak self] payload, point, done in self?.dragPane(payload, at: point, drop: done) ?? false }
        list.onDragEnd = { [weak self] in
            self?.dropLine.isHidden = true
            self?.markPaneDrop(nil, tab: nil)
            self?.springTarget = nil
        }
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropLine.layer?.cornerRadius = 1
        dropLine.isHidden = true
        list.addSubview(dropLine)
    }

    /// Where a dragged space would land among its machine's cards: shows
    /// the insertion line, or on drop moves it. Other machines' lists
    /// don't take it.
    private func dragSpace(_ key: String, at point: NSPoint, drop: Bool) -> Bool {
        let machine = key.split(separator: "|").first.map(String.init) ?? ""
        let cards = list.subviews.compactMap { $0 as? SpaceCard }.filter { $0.space.id.hasPrefix(machine + "|") }
        guard cards.contains(where: { $0.space.id == key }) else { dropLine.isHidden = true; return false }
        let others = cards.filter { $0.space.id != key }
        let index = others.filter { $0.frame.midY < point.y }.count
        if drop {
            dropLine.isHidden = true
            if cards.firstIndex(where: { $0.space.id == key }) != index { onMoveSpace?(key, index) }
            return true
        }
        let y = index < others.count ? others[index].frame.minY - 2 : (others.last?.frame.maxY ?? 0) + 1
        dropLine.frame = NSRect(x: 12, y: y - 1, width: list.bounds.width - 24, height: 2)
        dropLine.isHidden = false
        list.addSubview(dropLine) // on top
        return true
    }

    /// A pane dragged over the list: onto one of its machine's space cards
    /// (that space's tab under the pointer, else its current one), or below
    /// the cards for a new space. Highlights the target; on drop, moves.
    private func dragPane(_ payload: PaneDragPayload, at point: NSPoint, drop: Bool) -> Bool {
        let cards = list.subviews.compactMap { $0 as? SpaceCard }.filter { $0.space.id.hasPrefix(payload.machineID + "|") }
        guard !cards.isEmpty else { return false }
        if let card = cards.first(where: { $0.frame.contains(point) }) {
            let tab = card.tab(at: card.convert(point, from: list))
            if drop {
                springTarget = nil
                markPaneDrop(nil, tab: nil)
                onDropPane?(card.space.id, tab, payload)
            } else {
                markPaneDrop(card, tab: tab)
                springTarget = SpringTarget(space: card.space.id, tab: tab)
            }
            return true
        }
        springTarget = nil
        // Below this machine's last card: a space of its own.
        guard let last = cards.last, point.y > last.frame.maxY else {
            markPaneDrop(nil, tab: nil)
            return false
        }
        markPaneDrop(nil, tab: nil)
        if drop {
            dropLine.isHidden = true
            onDropPane?(nil, nil, payload)
            return true
        }
        dropLine.frame = NSRect(x: 12, y: last.frame.maxY + 3, width: list.bounds.width - 24, height: 2)
        dropLine.isHidden = false
        list.addSubview(dropLine)
        return true
    }

    // MARK: Spring-loading (as Finder opens a folder you hold a file over)

    private struct SpringTarget: Equatable {
        let space: String
        let tab: String?
    }

    private var springTimer: DispatchWorkItem?
    /// What a dragged pane is held over; after a moment it blinks and opens.
    private var springTarget: SpringTarget? {
        didSet {
            guard springTarget != oldValue else { return }
            springTimer?.cancel()
            springTimer = nil
            guard let target = springTarget else { return }
            let work = DispatchWorkItem { [weak self] in self?.spring(target) }
            springTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    private func spring(_ target: SpringTarget) {
        guard springTarget == target else { return }
        let card = list.subviews.compactMap { $0 as? SpaceCard }.first { $0.space.id == target.space }
        // Two quick blinks, then open.
        for (i, on) in [false, true, false, true].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) { [weak card] in
                card?.paneDropTab = on ? .some(target.tab) : nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.springTarget == target else { return }
            self.onSpringLoad?(target.space, target.tab)
        }
    }

    private weak var paneDropCard: SpaceCard?

    private func markPaneDrop(_ card: SpaceCard?, tab: String?) {
        if paneDropCard !== card { paneDropCard?.paneDropTab = nil }
        paneDropCard = card
        card?.paneDropTab = .some(tab)
        if card != nil { dropLine.isHidden = true }
    }

    @objc private func hideClicked() { onHideSidebar?() }
    @objc private func filesClicked() { onToggleFiles?() }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        scroll.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - Self.titlebarHeight))
        // Right of the traffic lights, in the title strip.
        let mark = brand.fittingSize
        brand.frame = NSRect(x: fullScreen ? 18 : b.width - mark.width - 14,
                             y: b.height - Self.titlebarHeight + (Self.titlebarHeight - mark.height) / 2 + 2,
                             width: mark.width, height: mark.height)
        brand.isHidden = b.width < 170 && !fullScreen
        // Right of the traffic lights; in full screen (none), at the right.
        let buttonY = b.height - Self.titlebarHeight + (Self.titlebarHeight - 24) / 2 + 2
        let buttonX: CGFloat = fullScreen ? b.width - 64 : 76
        hideButton.frame = NSRect(x: buttonX, y: buttonY, width: 26, height: 24)
        filesButton.frame = NSRect(x: buttonX + 26, y: buttonY, width: 26, height: 24)
        // The brand keeps clear of the buttons in narrow sidebars.
        if !fullScreen, brand.frame.minX < filesButton.frame.maxX + 6 { brand.isHidden = true }
        layoutList()
    }

    func update(_ model: SidebarModel) {
        guard model != self.model else { return }
        self.model = model
        rebuild()
        // A newly selected space (⌘N, ⌘K, a notification…) scrolls into view.
        let selected = model.machines.flatMap(\.spaces).first { $0.selected }?.id
        if selected != selectedID {
            selectedID = selected
            revealSelected()
        }
    }

    private func revealSelected() {
        guard let card = list.subviews.compactMap({ $0 as? SpaceCard }).first(where: { $0.space.selected }) else { return }
        layoutSubtreeIfNeeded()
        let frame = card.frame.insetBy(dx: 0, dy: -12)
        let visible = scroll.contentView.documentVisibleRect
        guard !visible.contains(frame) else { return }
        // Just enough to show it, with a little context around.
        let y = frame.minY < visible.minY ? frame.minY : frame.maxY - visible.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: max(0, y)))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Re-applies theme colors (appearance changes).
    func refreshTheme() {
        rebuild(force: true)
        needsLayout = true
    }

    /// Rows are kept while their content is unchanged, so a small update
    /// (a ping time, one agent's status) rebuilds one row, not the list.
    private func rebuild(force: Bool = false) {
        var oldHeaders: [String: MachineHeader] = [:]
        var oldCards: [String: SpaceCard] = [:]
        if !force {
            for view in list.subviews {
                if let header = view as? MachineHeader { oldHeaders[header.machine.id] = header }
                if let card = view as? SpaceCard { oldCards[card.space.id] = card }
            }
        }
        var rows: [NSView] = needsYouRows()
        for machine in model.machines {
            if let kept = oldHeaders[machine.id], kept.machine == machine {
                rows.append(kept)
                if let message = model.message, machine == model.machines.first { rows.append(MessageRow(text: message)) }
                for space in machine.spaces {
                    rows.append(oldCards[space.id].flatMap { $0.space == space ? $0 : nil } ?? makeCard(space))
                }
                continue
            }
            let header = MachineHeader(machine: machine)
            header.onClick = { [weak self] in self?.onMachineClick?(machine.id) }
            header.onChipClick = { [weak self, weak header] in
                guard let self, let header else { return }
                self.popUpSessionMenu(under: header)
            }
            rows.append(header)
            if let message = model.message, machine == model.machines.first {
                rows.append(MessageRow(text: message))
            }
            for space in machine.spaces {
                rows.append(oldCards[space.id].flatMap { $0.space == space ? $0 : nil } ?? makeCard(space))
            }
        }
        // Swap in the new order; views that stay keep their layers.
        for view in list.subviews where !rows.contains(where: { $0 === view }) { view.removeFromSuperview() }
        for view in rows where view.superview !== list { list.addSubview(view) }
        list.subviews = rows
        layoutList()
    }

    /// Rows the sidebar shows of Needs You; the rest are a click (⇧⌘K) away.
    private static let needsYouShown = 4

    /// The Needs You section, at the top; nothing when nothing waits.
    private func needsYouRows() -> [NSView] {
        let all = model.needsYou
        guard !all.isEmpty else { return [] }
        let header = NeedsYouHeader(count: all.count, urgent: all.contains(where: \.urgent))
        header.onClick = { [weak self] in self?.onShowAllNeedsYou?() }
        var rows: [NSView] = [header]
        for entry in all.prefix(Self.needsYouShown) {
            let row = NeedsYouRow(entry: entry)
            row.onClick = { [weak self] in self?.onOpenNeedsYou?(entry.id) }
            row.onDismiss = { [weak self] in self?.onDismissNeedsYou?(entry.id) }
            rows.append(row)
        }
        if all.count > Self.needsYouShown {
            let more = NeedsYouMore(count: all.count - Self.needsYouShown)
            more.onClick = { [weak self] in self?.onShowAllNeedsYou?() }
            rows.append(more)
        }
        return rows
    }

    private func makeCard(_ space: SidebarModel.Space) -> SpaceCard {
        let card = SpaceCard(space: space)
        card.onClick = { [weak self] in self?.onSelectSpace?(space.id) }
        card.onTab = { [weak self] tab in self?.onSelectTab?(space.id, tab) }
        card.onClose = { [weak self] in self?.onCloseSpace?(space.id) }
        card.onCloseTab = { [weak self] tab in self?.onCloseTab?(space.id, tab) }
        card.menuProvider = { [weak self] in self?.onSpaceMenu?(space.id) }
        return card
    }

    private func layoutList() {
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        for view in list.subviews where view is SidebarRow {
            let height = (view as? SidebarRow)?.height(forWidth: width - 16) ?? 24
            view.frame = NSRect(x: 8, y: y, width: width - 16, height: height)
            y += height + 3
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentSize.height))
    }

    /// Opens the session switcher under this Mac's header; false if the
    /// header isn't there.
    @discardableResult
    func popUpSessionMenu() -> Bool {
        guard let header = list.subviews.compactMap({ $0 as? MachineHeader }).first(where: \.isSessionSwitcher) else { return false }
        header.scrollToVisible(header.bounds)
        popUpSessionMenu(under: header)
        return true
    }

    private func popUpSessionMenu(under header: MachineHeader) {
        guard let menu = onSessionMenu?(header.machine.id) else { return }
        header.pressed = true
        menu.popUp(positioning: nil, at: NSPoint(x: 6, y: header.bounds.maxY + 2), in: header)
        header.pressed = false
    }

}

/// App icon and name, quiet, in the sidebar's title strip.
private final class BrandMark: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "bigtty")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .secondaryLabelColor
        addSubview(icon)
        addSubview(name)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // Title-strip behavior (drag, double-click to zoom) stays the window's.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override var fittingSize: NSSize {
        NSSize(width: 18 + 5 + ceil(name.intrinsicContentSize.width) + 4, height: 18)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 0, width: 18, height: 18)
        let text = name.intrinsicContentSize
        name.frame = NSRect(x: 23, y: (bounds.height - text.height) / 2, width: ceil(text.width) + 4, height: text.height)
    }
}

// MARK: - Rows

@MainActor
private protocol SidebarRow: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    /// Space cards dragged over the list (the sidebar decides).
    var onDrag: ((String, NSPoint, Bool) -> Bool)?
    /// Panes dragged over the list.
    var onPaneDrag: ((PaneDragPayload, NSPoint, Bool) -> Bool)?
    var onDragEnd: (() -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let pane = PaneDragPayload(sender.draggingPasteboard) {
            return onPaneDrag?(pane, convert(sender.draggingLocation, from: nil), false) == true ? .move : []
        }
        guard let key = sender.draggingPasteboard.string(forType: .bigttySpace) else { return [] }
        return onDrag?(key, convert(sender.draggingLocation, from: nil), false) == true ? .move : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let pane = PaneDragPayload(sender.draggingPasteboard) {
            return onPaneDrag?(pane, convert(sender.draggingLocation, from: nil), true) ?? false
        }
        guard let key = sender.draggingPasteboard.string(forType: .bigttySpace) else { return false }
        return onDrag?(key, convert(sender.draggingLocation, from: nil), true) ?? false
    }

    override func draggingExited(_: NSDraggingInfo?) { onDragEnd?() }
    override func draggingEnded(_: NSDraggingInfo) { onDragEnd?() }
}

private final class MessageRow: NSView, SidebarRow {
    private let label = NSTextField(wrappingLabelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.isSelectable = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func height(forWidth width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width - 20
        return label.fittingSize.height + 12
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 6)
    }
}

private final class MachineHeader: NSView, SidebarRow {
    // The window drags by its background; rows and cards must take the
    // click instead, over their whole area, even in an inactive window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var onClick: (() -> Void)?
    private let isProblem: Bool
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    /// The machine's session: name, chevron, and a badge for the others.
    private let chip = NSView()
    private let chipLabel = NSTextField(labelWithString: "")
    private let chipChevron = NSImageView()
    private let chipBadge = NSTextField(labelWithString: "")
    let isSessionSwitcher: Bool
    private var hovering = false { didSet { updateChip() } }
    var pressed = false { didSet { updateChip() } }

    let machine: SidebarModel.Machine

    init(machine: SidebarModel.Machine) {
        self.machine = machine
        isProblem = machine.statusIsProblem || machine.status.contains("not running")
        isSessionSwitcher = machine.session != nil
        super.init(frame: .zero)
        toolTip = isProblem ? "Click for details" : nil
        icon.image = NSImage(systemSymbolName: machine.name == "This Mac" ? "laptopcomputer" : "server.rack", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        name.stringValue = machine.name
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = .secondaryLabelColor
        status.stringValue = machine.status
        toolTip = machine.statusTip
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = machine.statusIsProblem ? .systemOrange : .secondaryLabelColor
        status.alignment = .right
        for view in [icon, name, status] { addSubview(view) }
        if let session = machine.session {
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 6
            chipLabel.stringValue = session.name
            chipLabel.font = .systemFont(ofSize: 11, weight: .medium)
            chipLabel.textColor = .labelColor
            chipLabel.lineBreakMode = .byTruncatingTail
            chipChevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Switch session")
            chipChevron.symbolConfiguration = .init(pointSize: 8.5, weight: .semibold)
            chipChevron.contentTintColor = .secondaryLabelColor
            chipBadge.stringValue = "\(session.othersNeedingYou)"
            chipBadge.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
            chipBadge.textColor = .white
            chipBadge.alignment = .center
            chipBadge.wantsLayer = true
            chipBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            chipBadge.layer?.cornerRadius = 7
            chipBadge.isHidden = session.othersNeedingYou == 0
            for view in [chipLabel, chipChevron, chipBadge] as [NSView] { chip.addSubview(view) }
            addSubview(chip)
            let shortcut = machine.name == "This Mac" ? " · ⇧⌘S" : ""
            toolTip = session.othersNeedingYou > 0
                ? "Session “\(session.name)” · \(session.othersNeedingYou) waiting in other sessions · click to switch\(shortcut)"
                : "Session “\(session.name)” · click to switch sessions\(shortcut)"
            updateChip()
        }
    }

    private func updateChip() {
        guard isSessionSwitcher else { return }
        let alpha: CGFloat = pressed ? 0.16 : hovering ? 0.11 : 0.06
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard isSessionSwitcher else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func height(forWidth _: CGFloat) -> CGFloat { 30 }

    /// The session chip (or, on this Mac, the whole header).
    var onChipClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A remote's header elsewhere explains a connection problem.
        if isSessionSwitcher, machine.name == "This Mac" || chip.frame.contains(point) || !isProblem {
            onChipClick?()
        } else {
            onClick?()
        }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 10, width: 14, height: 14)
        let nameWidth = min(ceil(name.intrinsicContentSize.width) + 2, bounds.width * 0.5)
        name.frame = NSRect(x: 29, y: 10, width: nameWidth, height: 15)
        let statusX = 29 + nameWidth + 8
        var right = bounds.width - 4
        if isSessionSwitcher {
            let badge = chipBadge.isHidden ? 0 : max(14, ceil(chipBadge.intrinsicContentSize.width) + 8)
            let text = min(ceil(chipLabel.intrinsicContentSize.width) + 6, max(30, bounds.width * 0.45))
            let width = 8 + text + 4 + 9 + (badge > 0 ? 5 + badge : 0) + 7
            chip.frame = NSRect(x: bounds.width - 4 - width, y: 6, width: width, height: 22)
            chipLabel.frame = NSRect(x: 8, y: 3.5, width: text, height: 15)
            chipChevron.frame = NSRect(x: 8 + text + 4, y: 6, width: 9, height: 10)
            chipBadge.frame = NSRect(x: 8 + text + 4 + 9 + 5, y: 4, width: badge, height: 14)
            right = chip.frame.minX - 6
        } else {
            right = bounds.width - 10
        }
        status.frame = NSRect(x: statusX, y: 10, width: max(0, right - statusX), height: 15)
        status.lineBreakMode = .byTruncatingHead
    }
}

/// One space: name, shortcut, branch and folder, ports and the agent line;
/// the selected space also lists its tabs.
extension NSPasteboard.PasteboardType {
    /// A space card being dragged to a new place: its "machine|workspace" key.
    static let bigttySpace = NSPasteboard.PasteboardType("dev.bigtty.space")
}

private final class SpaceCard: NSView, SidebarRow, NSDraggingSource {
    // The window drags by its background; rows and cards must take the
    // click instead, over their whole area, even in an inactive window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// The whole card is one button (labels must not take the click or
    /// show a text cursor); only its tab rows are separate.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is TabRow { return current }
            view = current.superview
        }
        return self
    }

    let space: SidebarModel.Space
    var onClick: (() -> Void)?
    var onTab: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onCloseTab: ((String) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// Shown on hover in place of the shortcut.
    private let closeIcon = CloseIcon()

    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let speaker = NSImageView()
    private let meta = NSTextField(labelWithString: "")
    private let line = NSTextField(wrappingLabelWithString: "")
    private let tabSummary = NSTextField(labelWithString: "")
    private var chips: [NSTextField] = []
    private var tabRows: [TabRow] = []

    /// A pane dragged over this card: nil when not, .some(tab) when it
    /// would land in that tab (or the space's current one).
    var paneDropTab: String?? {
        didSet {
            updateBackground()
            for row in tabRows { row.dropTarget = paneDropTab == .some(row.tabID) && !row.tabID.isEmpty }
        }
    }

    /// The tab whose row is under `point` (in this card), if any.
    func tab(at point: NSPoint) -> String? {
        tabRows.first { $0.frame.contains(point) && !$0.tabID.isEmpty }?.tabID
    }
    private var hovering = false {
        didSet {
            updateBackground()
            updateFade()
            closeIcon.isHidden = !hovering
            shortcut.isHidden = hovering
        }
    }

    /// Quiet spaces fade back until hovered or selected.
    private func updateFade() {
        let faded = space.stale && !space.selected && !hovering
        for view in subviews { view.alphaValue = faded ? 0.55 : 1 }
    }

    init(space: SidebarModel.Space) {
        self.space = space
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        // Needs you (accent) over finished (blue) over working (green,
        // breathing slowly).
        dot.layer?.backgroundColor = space.alert ? NSColor.controlAccentColor.cgColor
            : space.finished ? NSColor.systemBlue.withAlphaComponent(0.8).cgColor
            : NSColor.systemGreen.cgColor
        dot.isHidden = !(space.alert || space.finished || space.working)
        if space.working, !space.alert, !space.finished { Self.breathe(dot) }

        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing audio")
        speaker.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        speaker.contentTintColor = .controlAccentColor
        speaker.isHidden = !space.audible
        addSubview(speaker)
        name.stringValue = space.name
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        shortcut.stringValue = space.shortcut
        shortcut.font = .systemFont(ofSize: 11, weight: space.hinting ? .bold : .regular)
        shortcut.textColor = space.hinting ? .controlAccentColor : .tertiaryLabelColor
        shortcut.alignment = .right
        meta.stringValue = space.meta
        meta.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingMiddle
        line.stringValue = space.line ?? ""
        line.font = .systemFont(ofSize: 11.5)
        line.textColor = space.alert ? NSColor.controlAccentColor.blended(withFraction: 0.35, of: .labelColor) : .secondaryLabelColor
        line.maximumNumberOfLines = space.alert ? 2 : 1
        line.lineBreakMode = .byTruncatingTail
        line.isHidden = space.line == nil
        line.isSelectable = false
        tabSummary.stringValue = space.tabSummary ?? ""
        tabSummary.font = .systemFont(ofSize: 11)
        tabSummary.textColor = .tertiaryLabelColor
        tabSummary.lineBreakMode = .byTruncatingTail
        tabSummary.isHidden = space.tabSummary == nil
        for view in [dot, name, shortcut, meta, line, tabSummary] { addSubview(view) }
        closeIcon.isHidden = true
        closeIcon.toolTip = "Close Space"
        addSubview(closeIcon)

        for port in space.ports.prefix(3) {
            let chip = NSTextField(labelWithString: ":\(port)")
            chip.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            chip.textColor = .secondaryLabelColor
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 4
            effectiveAppearance.performAsCurrentDrawingAppearance {
                chip.layer?.backgroundColor = Theme.sidebarRow.cgColor
            }
            chip.alignment = .center
            chips.append(chip)
            addSubview(chip)
        }
        for tab in space.tabs {
            let row = TabRow(tab: tab)
            row.onClick = { [weak self] in self?.onTab?(tab.id) }
            row.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
            tabRows.append(row)
            addSubview(row)
        }
        updateBackground()
        updateFade()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(space.name), \(space.line ?? "")")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func updateBackground() {
        let theme = Theme.current
        if paneDropTab != nil {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.sidebarHover.cgColor }
            return
        }
        if space.alert {
            layer?.backgroundColor = theme?.accentWash.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = theme?.accentLine.cgColor
        } else {
            layer?.borderWidth = 0
            let fill = space.selected ? Theme.sidebarSelection : hovering ? Theme.sidebarHover : nil
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = fill?.cgColor
            }
        }
    }

    private var lineHeight: CGFloat {
        guard !line.isHidden else { return 0 }
        return space.alert ? 30 : 15
    }

    func height(forWidth _: CGFloat) -> CGFloat {
        var h: CGFloat = 8 + 17 + 16
        if !line.isHidden || !chips.isEmpty { h += 3 + max(lineHeight, chips.isEmpty ? 0 : 16) }
        if !tabRows.isEmpty { h += 6 + CGFloat(tabRows.count) * 23 }
        if !tabSummary.isHidden { h += 16 }
        return h + 9
    }

    override func layout() {
        super.layout()
        syncHover()
        let w = bounds.width
        var x: CGFloat = 10
        if !dot.isHidden {
            dot.frame = NSRect(x: 10, y: 13, width: 7, height: 7)
            x = 23
        }
        name.frame = NSRect(x: x, y: 8, width: w - x - (space.audible ? 58 : 40) - max(0, ceil(shortcut.intrinsicContentSize.width) - 30), height: 17)
        let shortcutWidth = max(32, ceil(shortcut.intrinsicContentSize.width) + 2)
        shortcut.frame = NSRect(x: w - 10 - shortcutWidth, y: 9, width: shortcutWidth, height: 15)
        speaker.frame = NSRect(x: w - 58, y: 10, width: 14, height: 13)
        closeIcon.frame = NSRect(x: w - 8 - 18, y: 7, width: 18, height: 18)
        meta.frame = NSRect(x: 10, y: 26, width: w - 20, height: 15)
        var y: CGFloat = 44
        var lx: CGFloat = 10
        for chip in chips {
            let cw = chip.intrinsicContentSize.width + 10
            chip.frame = NSRect(x: lx, y: y, width: cw, height: 16)
            lx += cw + 5
        }
        if !line.isHidden {
            line.frame = NSRect(x: lx, y: y, width: w - lx - 10, height: lineHeight)
        }
        if !line.isHidden || !chips.isEmpty { y += max(lineHeight, chips.isEmpty ? 0 : 16) + 3 }
        if !tabSummary.isHidden {
            tabSummary.frame = NSRect(x: 10, y: y, width: w - 20, height: 15)
            y += 16
        }
        y += 3
        for row in tabRows {
            row.frame = NSRect(x: 6, y: y, width: w - 12, height: 22)
            y += 23
        }
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    /// The sidebar rebuilds its rows as things change; a new one under the
    /// pointer gets no mouseEntered, so it looks for itself.
    private func syncHover() {
        guard let window else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside != hovering { hovering = inside }
    }

    private var pressEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if tabRows.contains(where: { $0.frame.contains(point) }) { return super.mouseDown(with: event) }
        if !closeIcon.isHidden, closeIcon.frame.insetBy(dx: -3, dy: -3).contains(point) { return onClose?() ?? () }
        pressEvent = event
        onClick?()
    }

    /// Dragged a few points: the card itself moves (drop between cards to
    /// reorder; the order sets ⌘1–9).
    override func mouseDragged(with event: NSEvent) {
        guard let press = pressEvent else { return }
        let start = convert(press.locationInWindow, from: nil), now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        pressEvent = nil
        let item = NSPasteboardItem()
        item.setString(space.id, forType: .bigttySpace)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: press, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressEvent = nil
        super.mouseUp(with: event)
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation { .move }

    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
}

private final class TabRow: NSView {
    // The window drags by its background; rows and cards must take the
    // click instead, over their whole area, even in an inactive window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// Shown on hover in place of the detail ("+N more" has none).
    private let closeIcon = CloseIcon()
    private let closable: Bool
    private var hovering = false {
        didSet {
            closeIcon.isHidden = !(hovering && closable)
            detail.isHidden = hovering && closable
            workingDotHidden(hovering && closable)
        }
    }
    private var dotWanted = false

    private func workingDotHidden(_ hide: Bool) { workingDot.isHidden = hide || !dotWanted }
    /// Its agent is working: a small breathing dot before the detail.
    private let workingDot = NSView()

    let tabID: String
    private var normalBackground: CGColor?

    /// A pane dragged over it would land in this tab.
    var dropTarget = false {
        didSet {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = dropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : normalBackground
            }
        }
    }

    init(tab: SidebarModel.Tab) {
        closable = !tab.id.isEmpty
        tabID = tab.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            normalBackground = tab.selected ? Theme.sidebarRow.cgColor : nil
            layer?.backgroundColor = normalBackground
        }
        // The "+N more" row (no tab id) opens the space.
        let symbol = tab.id.isEmpty ? "ellipsis" : tab.audible ? "speaker.wave.2.fill" : "terminal"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tab.audible ? "Playing audio" : nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.contentTintColor = tab.audible ? .controlAccentColor : tab.selected ? .labelColor : .secondaryLabelColor
        label.stringValue = tab.label
        label.font = .systemFont(ofSize: 12)
        label.textColor = tab.selected ? .labelColor : tab.id.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        detail.stringValue = tab.hint ?? tab.detail
        if tab.hint != nil {
            detail.font = .systemFont(ofSize: 11, weight: .bold)
            detail.textColor = .controlAccentColor
        }
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = tab.alert ? .controlAccentColor : .secondaryLabelColor
        detail.alignment = .right
        for view in [icon, label, detail] { addSubview(view) }
        workingDot.wantsLayer = true
        workingDot.layer?.cornerRadius = 3
        workingDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dotWanted = tab.working && !tab.alert
        workingDot.isHidden = !dotWanted
        addSubview(workingDot)
        closeIcon.isHidden = true
        closeIcon.toolTip = "Close Tab"
        addSubview(closeIcon)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        if !workingDot.isHidden { NSView.breathe(workingDot) }
        setAccessibilityRole(.button)
        setAccessibilityLabel("Tab \(tab.label)")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if let window {
            let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            if inside != hovering { hovering = inside }
        }
        let h = bounds.height
        icon.frame = NSRect(x: 6, y: (h - 12) / 2, width: 13, height: 12)
        // The name takes whatever the detail ("needs you", "2 panes") leaves.
        let detailWidth = detail.stringValue.isEmpty ? 0 : ceil(detail.intrinsicContentSize.width) + 4
        detail.frame = NSRect(x: bounds.width - detailWidth - 6, y: (h - 14) / 2, width: detailWidth, height: 14)
        let dotSpace: CGFloat = workingDot.isHidden ? 0 : 12
        workingDot.frame = NSRect(x: bounds.width - detailWidth - 6 - 10, y: (h - 6) / 2, width: 6, height: 6)
        label.frame = NSRect(x: 24, y: (h - 15) / 2, width: max(0, bounds.width - 24 - max(detailWidth + dotSpace, 22) - 12), height: 15)
        closeIcon.frame = NSRect(x: bounds.width - 4 - 18, y: (h - 18) / 2, width: 18, height: 18)
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !closeIcon.isHidden, closeIcon.frame.insetBy(dx: -3, dy: -3).contains(point) { return onClose?() ?? () }
        onClick?()
    }
}

/// The × on a hovered space card or tab row; the row handles the click.
private final class CloseIcon: NSView {
    private let image = NSImageView()
    private var hovering = false { didSet { updateBackground() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        image.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        image.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        image.contentTintColor = .secondaryLabelColor
        addSubview(image)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        image.frame = bounds.insetBy(dx: 3, dy: 3)
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
        }
        image.contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }
}

/// A borderless symbol button for the title strip; takes the click
/// instead of moving the window.
final class StripButton: NSButton {
    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = tip
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

extension NSView {
    /// A slow opacity pulse for "working" dots. Core Animation runs it on
    /// the render server: no timers or redraws in the app.
    static func breathe(_ view: NSView) {
        guard let layer = view.layer, layer.animation(forKey: "breathe") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "breathe")
    }
}

// MARK: - Needs You

/// "NEEDS YOU 3 · ⇧⌘K" above the list.
private final class NeedsYouHeader: NSView, SidebarRow {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var onClick: (() -> Void)?
    private let title = NSTextField(labelWithString: "NEEDS YOU")
    private let badge = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "⇧⌘K")

    init(count: Int, urgent: Bool) {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 10.5, weight: .semibold)
        title.textColor = .secondaryLabelColor
        badge.stringValue = "\(count)"
        badge.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        badge.textColor = urgent ? .white : .secondaryLabelColor
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.layer?.backgroundColor = urgent ? NSColor.controlAccentColor.cgColor : NSColor.labelColor.withAlphaComponent(0.1).cgColor
        shortcut.font = .systemFont(ofSize: 10.5)
        shortcut.textColor = .tertiaryLabelColor
        shortcut.alignment = .right
        for view in [title, badge, shortcut] { addSubview(view) }
        toolTip = "Everything waiting on you, most urgent first (⇧⌘K)"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func height(forWidth _: CGFloat) -> CGFloat { 22 }

    override func layout() {
        super.layout()
        let titleWidth = ceil(title.intrinsicContentSize.width) + 2
        title.frame = NSRect(x: 10, y: 5, width: titleWidth, height: 14)
        let badgeWidth = max(14, ceil(badge.intrinsicContentSize.width) + 8)
        badge.frame = NSRect(x: 10 + titleWidth + 5, y: 4, width: badgeWidth, height: 14)
        shortcut.frame = NSRect(x: bounds.width - 60, y: 5, width: 50, height: 14)
    }

    override func mouseDown(with _: NSEvent) { onClick?() }
}

/// One thing waiting on you: where, what it wants, and for how long.
private final class NeedsYouRow: NSView, SidebarRow {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    let entry: SidebarModel.NeedsYou
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    private let closeIcon = CloseIcon()
    private var hovering = false {
        didSet {
            updateBackground()
            closeIcon.isHidden = !(hovering && entry.dismissable)
            age.isHidden = !closeIcon.isHidden
        }
    }

    init(entry: SidebarModel.NeedsYou) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let tint: NSColor = entry.urgent ? .controlAccentColor : entry.kind == .finished ? .systemBlue : .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = tint
        title.stringValue = entry.title
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        age.stringValue = entry.age ?? ""
        age.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        age.textColor = .tertiaryLabelColor
        age.alignment = .right
        line.stringValue = [entry.line, entry.place].filter { !$0.isEmpty }.joined(separator: " · ")
        line.font = .systemFont(ofSize: 11)
        line.textColor = entry.urgent ? NSColor.controlAccentColor.blended(withFraction: 0.35, of: .labelColor) : .secondaryLabelColor
        line.lineBreakMode = .byTruncatingTail
        for view in [icon, title, age, line] { addSubview(view) }
        closeIcon.isHidden = true
        closeIcon.toolTip = "Dismiss until it changes"
        addSubview(closeIcon)
        toolTip = "\(entry.title)\n\(line.stringValue)"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(entry.title), \(line.stringValue)")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func height(forWidth _: CGFloat) -> CGFloat { 36 }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 8, y: 4, width: 16, height: 16)
        let ageWidth = max(26, ceil(age.intrinsicContentSize.width) + 2)
        age.frame = NSRect(x: w - 8 - ageWidth, y: 4, width: ageWidth, height: 15)
        closeIcon.frame = NSRect(x: w - 6 - 18, y: 3, width: 18, height: 18)
        title.frame = NSRect(x: 29, y: 3, width: max(0, w - 29 - ageWidth - 12), height: 16)
        line.frame = NSRect(x: 29, y: 18, width: max(0, w - 29 - 8), height: 15)
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? Theme.sidebarHover.cgColor : nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !closeIcon.isHidden, closeIcon.frame.insetBy(dx: -3, dy: -3).contains(point) { return onDismiss?() ?? () }
        onClick?()
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Go There", keyEquivalent: "") { [weak self] in self?.onClick?() })
        if entry.dismissable {
            menu.addItem(ClosureMenuItem(title: "Dismiss Until It Changes", keyEquivalent: "") { [weak self] in self?.onDismiss?() })
        }
        return menu
    }
}

/// "+3 more · ⇧⌘K" under the shown rows.
private final class NeedsYouMore: NSView, SidebarRow {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    init(count: Int) {
        super.init(frame: .zero)
        label.stringValue = "+\(count) more · ⇧⌘K"
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func height(forWidth _: CGFloat) -> CGFloat { 18 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 29, y: 1, width: bounds.width - 37, height: 15)
    }

    override func mouseDown(with _: NSEvent) { onClick?() }
}
