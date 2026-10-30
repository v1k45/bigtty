import AppKit

/// The row of page tabs, under the toolbar: it appears at two tabs, and the
/// active tab has the same quiet fill as a sidebar selection.
@MainActor
final class BrowserTabStrip: NSView {
    struct Tab: Equatable {
        var id: String
        var title: String
        var tile: String
        var loading: Bool
        var audible: Bool
        var driven: Bool
        var active: Bool
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNew: (() -> Void)?
    var tabMenu: ((String) -> NSMenu?)?
    /// ⌘ held: keycaps on the tabs.
    var showsHints = false { didSet { if showsHints != oldValue { update() } } }

    private var tabs: [Tab] = []
    private var views: [String: BrowserTabView] = [:]
    private let scroll = NSScrollView()
    private let row = NSView()
    private let new = NSButton()
    private let overflow = NSButton()

    private static let buttonWidth: CGFloat = 24

    /// Under the title bar a click here is for a tab, not the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = row
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        for (button, symbol, label, action) in [
            (new, "plus", "New Tab (⌘T)", #selector(newClicked)), (overflow, "chevron.down", "All Tabs", #selector(overflowClicked)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            button.contentTintColor = .tertiaryLabelColor
            button.isBordered = false
            button.toolTip = label
            button.target = self
            button.action = action
        }
        overflow.isHidden = true
        for view in [scroll, new, overflow] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(_ tabs: [Tab]) {
        guard tabs != self.tabs else { return }
        let scrollToActive = tabs.first(where: \.active)?.id != self.tabs.first(where: \.active)?.id || tabs.count != self.tabs.count
        self.tabs = tabs
        update()
        needsLayout = true
        if scrollToActive { layoutSubtreeIfNeeded(); revealActive() }
    }

    private func update() {
        for (id, view) in views where !tabs.contains(where: { $0.id == id }) {
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
        for (index, tab) in tabs.enumerated() {
            let view = views[tab.id] ?? {
                let made = BrowserTabView()
                made.onSelect = { [weak self] in self?.onSelect?(tab.id) }
                made.onClose = { [weak self] in self?.onClose?(tab.id) }
                made.contextMenu = { [weak self] in self?.tabMenu?(tab.id) }
                views[tab.id] = made
                row.addSubview(made)
                return made
            }()
            let key = index < 8 ? index + 1 : index == tabs.count - 1 ? 9 : nil
            view.show(tab, hint: showsHints ? key.map { "⌃⌥\($0)" } : nil)
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let (width, overflows) = BrowserTabRules.tabWidth(count: tabs.count, available: b.width - 8 - Self.buttonWidth)
        // The overflow menu takes room of its own once the row scrolls.
        let trailing = Self.buttonWidth * (overflows ? 2 : 1)
        let visible = b.width - 4 - trailing
        overflow.isHidden = !overflows
        overflow.frame = NSRect(x: b.width - Self.buttonWidth - 2, y: 2, width: Self.buttonWidth - 4, height: 20)
        scroll.frame = NSRect(x: 4, y: 0, width: visible, height: b.height)
        row.frame = NSRect(x: 0, y: 0, width: max(visible, width * CGFloat(tabs.count)), height: b.height)
        for (index, tab) in tabs.enumerated() {
            views[tab.id]?.frame = NSRect(x: CGFloat(index) * width, y: 2, width: width - 2, height: b.height - 4)
        }
        // + follows the last tab until the row fills up.
        let end = min(visible, width * CGFloat(tabs.count)) + 4
        new.frame = NSRect(x: overflows ? b.width - trailing : end + 2, y: 2, width: Self.buttonWidth - 4, height: 20)
    }

    private func revealActive() {
        guard let id = tabs.first(where: \.active)?.id, let view = views[id] else { return }
        row.scrollToVisible(view.frame)
    }

    @objc private func newClicked() { onNew?() }

    @objc private func overflowClicked() {
        let menu = NSMenu()
        for tab in tabs {
            let item = ClosureMenuItem(title: tab.title) { [weak self] in self?.onSelect?(tab.id) }
            item.state = tab.active ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 4), in: overflow)
    }
}

/// One tab: its tile (or a spinner while it loads), title, a speaker, a dot
/// while an agent drives it, and × on hover.
@MainActor
private final class BrowserTabView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    private let tile = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let speaker = NSImageView()
    private let dot = NSView()
    private let close = NSButton()
    private var keyCap: KeyCap?
    private var hint: String?
    private var tab: BrowserTabStrip.Tab?
    private var hovering = false { didSet { refresh() } }
    private var hoverArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        tile.font = .systemFont(ofSize: 9, weight: .semibold)
        tile.alignment = .center
        tile.textColor = .secondaryLabelColor
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 3
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        title.font = .systemFont(ofSize: 11)
        title.lineBreakMode = .byTruncatingTail
        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing sound")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        speaker.contentTintColor = .secondaryLabelColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.toolTip = "An agent is working here"
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold))
        close.contentTintColor = .secondaryLabelColor
        close.isBordered = false
        close.target = self
        close.action = #selector(closeClicked)
        close.isHidden = true
        for view in [tile, spinner, title, speaker, dot, close] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(_ tab: BrowserTabStrip.Tab, hint: String?) {
        self.tab = tab
        title.stringValue = tab.title
        tile.stringValue = tab.tile
        toolTip = tab.title
        if tab.loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if hint != self.hint {
            self.hint = hint
            keyCap?.removeFromSuperview()
            keyCap = hint.map { KeyCap($0, size: 9.5, prominent: true) }
            if let keyCap { addSubview(keyCap) }
        }
        refresh()
    }

    private func refresh() {
        guard let tab else { return }
        tile.isHidden = tab.loading
        title.textColor = tab.active ? .labelColor : .secondaryLabelColor
        speaker.isHidden = !tab.audible
        dot.isHidden = !tab.driven
        close.isHidden = !hovering
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = tab.active ? Theme.sidebarSelection : hovering ? Theme.sidebarHover : NSColor.clear
            layer?.backgroundColor = fill.cgColor
            tile.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        let y = (b.height - 14) / 2
        tile.frame = NSRect(x: 5, y: y, width: 14, height: 14)
        spinner.frame = NSRect(x: 5, y: y, width: 14, height: 14)
        var right = b.width - 5
        close.frame = NSRect(x: b.width - 19, y: y, width: 14, height: 14)
        if !close.isHidden { right -= 15 }
        if !speaker.isHidden {
            right -= 13
            speaker.frame = NSRect(x: right, y: y, width: 12, height: 14)
        }
        if !dot.isHidden {
            right -= 9
            dot.frame = NSRect(x: right, y: b.midY - 3, width: 6, height: 6)
        }
        title.frame = NSRect(x: 23, y: (b.height - 15) / 2, width: max(0, right - 25), height: 15)
        if let keyCap {
            let size = keyCap.intrinsicContentSize
            keyCap.frame = NSRect(x: 3, y: (b.height - size.height) / 2, width: size.width, height: size.height)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === close ? close : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }
    override func mouseDown(with _: NSEvent) { onSelect?() }
    override func menu(for _: NSEvent) -> NSMenu? { contextMenu?() }

    /// A middle click closes, as on a browser's tabs.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked() { onClose?() }
}
