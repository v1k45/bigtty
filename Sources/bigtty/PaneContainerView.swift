import AppKit
import GhosttyTerminal
import HerdrKit

/// One leaf of the split tree: a rounded card holding the pane's content.
/// No header: focus shows as full brightness (others dim), and an agent that
/// needs you gets a thin accent ring.
@MainActor
final class PaneContainerView: NSView {
    /// Changes when the pane moves to another space (herdr gives it a new
    /// id; the view and its terminal connection stay).
    var paneID: String
    let content: NSView
    private let ring = CALayer()
    /// Unfocused panes fade toward their own background (not see-through:
    /// the window behind follows macOS, which may be light under a dark
    /// theme and wash the pane out).
    private let dim = CALayer()
    private let detached = DetachedOverlay()
    private let zoomPill = ZoomPill()
    private let grip = PaneGrip()
    private var badge: KeyCap?
    /// Pinned: it follows you between spaces.
    private let pinMark = NSImageView()

    /// ⌘ held: this pane's shortcut, large, in its middle.
    var hintBadge: String? {
        didSet {
            guard hintBadge != oldValue else { return }
            badge?.removeFromSuperview()
            badge = hintBadge.map { KeyCap($0, size: 18, prominent: true) }
            if let badge { addSubview(badge) }
            needsLayout = true
        }
    }
    private var hoverArea: NSTrackingArea?

    /// What a drag of this pane carries; nil turns dragging off.
    var dragPayload: (() -> PaneDragPayload?)?
    /// The pane's name on the drag card.
    var dragTitle: (() -> String)?
    /// Being dragged: dimmed so it's clear what moves.
    private var isDragSource = false { didSet { updateDimming() } }

    var terminal: HerdrTerminalView? { content as? HerdrTerminalView }
    var browser: BrowserPaneView? { content as? BrowserPaneView }
    var files: FilesPaneView? { content as? FilesPaneView }
    /// The pane's side of ⌘F.
    var finder: FindDriver? {
        if let terminal { return terminal.finder }
        if let browser { return browser.finder }
        return files?.code.finder
    }

    /// What this view was built for; a pane re-tagged as another kind is rebuilt.
    var hostKind: HostPaneKind? { browser != nil ? .browser : files?.kind }

    /// Unfocused panes dim, unless this is the only pane or dimming is off.
    var isFocusedPane = false {
        didSet {
            updateDimming()
            if !isFocusedPane { terminal?.syncSurfaceFocus() }
        }
    }
    var dimsWhenUnfocused = true { didSet { updateDimming() } }
    var isZoomed = false { didSet { zoomPill.isHidden = !isZoomed } }
    private var attention: Attention.Reason?

    static let cornerRadius: CGFloat = 8
    /// Space between the card edge and terminal text, so glyphs clear the
    /// corners. The right edge also collects whatever is left of a partial
    /// cell column, so it gets less of its own.
    static let contentInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)

    init(paneID: String, content: NSView) {
        self.paneID = paneID
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        // macOS 14 stopped clipping subviews by default; keep pane content in its pane.
        clipsToBounds = true

        addSubview(content)
        detached.isHidden = true
        detached.onTakeControl = { [weak self] in self?.takeControl() }
        addSubview(detached)
        zoomPill.isHidden = true
        addSubview(zoomPill)
        grip.content = content
        grip.payload = { [weak self] in self?.dragPayload?() }
        grip.title = { [weak self] in self?.dragTitle?() ?? "Pane" }
        addSubview(grip)
        grip.onDragChange = { [weak self] dragging in self?.isDragSource = dragging }

        ring.borderWidth = 1.5
        ring.cornerRadius = Self.cornerRadius
        ring.borderColor = NSColor.clear.cgColor
        ring.zPosition = 10
        layer?.addSublayer(ring)
        dim.zPosition = 9
        dim.opacity = 0
        layer?.addSublayer(dim)

        terminal?.onDetached = { [weak self] reason in self?.detached.show(.disconnected(reason)) }
        terminal?.onModeChange = { [weak self] mode in
            // A mirror of a pane another of our windows controls.
            if mode == .control { self?.detached.hide() } else { self?.detached.show(.otherWindow) }
            self?.needsLayout = true
        }
        terminal?.onDisplacedChange = { [weak self] displaced in
            if displaced { self?.detached.show(.otherClient) } else { self?.detached.hide() }
            self?.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func apply(_ theme: Theme) {
        // Terminals honour the background opacity setting; the card behind
        // them must be as see-through, or the material can't show.
        let alpha = terminal != nil ? CGFloat(Settings.terminalOpacity) : 1
        layer?.backgroundColor = theme.pane.withAlphaComponent(alpha).cgColor
        // Text and controls inside (the files tree, the address bar) match
        // the terminal theme, which can be dark while macOS is light.
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        dim.backgroundColor = theme.pane.cgColor
        updateRing()
    }

    func update(pane: Pane?, attention: Attention.Reason?) {
        guard let pane else { return }
        self.attention = attention
        updateRing()
        if pinMark.superview == nil {
            pinMark.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            pinMark.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            pinMark.contentTintColor = .tertiaryLabelColor
            pinMark.toolTip = "Pinned: follows you between spaces (⌥⌘P to unpin)"
            addSubview(pinMark)
        }
        pinMark.isHidden = pane.tokens?["btty_pin"] == nil
    }

    private func updateRing() {
        ring.borderColor = attention == .blocked ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    private func updateDimming() {
        alphaValue = isDragSource ? 0.4 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.opacity = isDragSource || isFocusedPane || !dimsWhenUnfocused ? 0 : 0.3
        CATransaction.commit()
    }

    private func takeControl() {
        detached.hide()
        terminal?.takeControl()
        window?.makeFirstResponder(content)
    }

    override func layout() {
        super.layout()
        // Browser and files views are shared (registries). If another
        // container borrowed ours and let go, take it back.
        if content.superview !== self, content.window == nil {
            addSubview(content, positioned: .below, relativeTo: detached)
        }
        let b = bounds
        // Terminals get an inset so text clears the rounded corners; browser
        // and files panes run edge to edge.
        if terminal != nil {
            let i = Self.contentInsets
            content.frame = NSRect(x: i.left, y: i.bottom,
                                   width: max(0, b.width - i.left - i.right), height: max(0, b.height - i.top - i.bottom))
        } else {
            content.frame = b
        }
        // A bar over the live mirror; a full cover only when disconnected.
        detached.frame = detached.isBanner
            ? NSRect(x: (b.width - min(b.width - 16, detached.fittingSize.width)) / 2, y: 10,
                     width: min(b.width - 16, detached.fittingSize.width), height: 30)
            : b
        if let badge {
            let size = badge.intrinsicContentSize
            badge.frame = NSRect(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2, width: size.width, height: size.height)
        }
        // The whole top edge is the handle; the pill shows in its middle.
        grip.frame = NSRect(x: 0, y: b.height - PaneGrip.bandHeight, width: b.width, height: PaneGrip.bandHeight)
        pinMark.frame = NSRect(x: b.width - 22, y: 8, width: 14, height: 14) // bottom right: clear of browser toolbars
        if let findBar, let finder {
            let width = min(FindBar.width, b.width - 16)
            let top = content.frame.maxY - finder.findBarInset - 8
            findBar.frame = NSRect(x: content.frame.maxX - width - 8, y: top - FindBar.height, width: width, height: FindBar.height)
        }
        let pill = zoomPill.fittingSize
        zoomPill.frame = NSRect(x: b.width - pill.width - 12, y: b.height - pill.height - 10, width: pill.width, height: pill.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = b
        dim.frame = b
        CATransaction.commit()
    }

    // MARK: - Find

    private(set) var findBar: FindBar?

    /// ⌘F: opens the bar (or focuses it) with the field selected.
    func showFind() {
        guard let finder else { return }
        if findBar == nil {
            let bar = FindBar(driver: finder)
            bar.onClose = { [weak self] in self?.closeFind() }
            addSubview(bar, positioned: .below, relativeTo: detached)
            findBar = bar
            if bar.query.isEmpty, !FindBar.lastQuery.isEmpty {
                bar.query = FindBar.lastQuery
                bar.search()
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        findBar?.focus()
    }

    /// ⌘G / ⇧⌘G: the next match, opening the bar with the last search
    /// if it isn't open.
    func findNext(backwards: Bool) {
        if findBar == nil {
            guard !FindBar.lastQuery.isEmpty else { return showFind() }
            showFind()
            return
        }
        findBar?.findNext(backwards: backwards)
    }

    /// ⌘E: the selection becomes the search.
    func useSelectionForFind() {
        finder?.selectionForFind { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            FindBar.lastQuery = text
            if let findBar = self.findBar {
                findBar.query = text
                findBar.search()
            } else {
                self.showFind()
            }
        }
    }

    func closeFind() {
        guard let findBar else { return }
        let refocus = findBar.field.currentEditor() != nil
        finder?.endFind()
        findBar.removeFromSuperview()
        self.findBar = nil
        if refocus, let view = finder?.findFocusView { window?.makeFirstResponder(view) }
    }

    // MARK: - Drag and drop

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// The pill shows while the pointer is near the top edge.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        grip.showsPill = dragPayload != nil && point.y >= bounds.height - 28
    }

    override func mouseExited(with _: NSEvent) { grip.showsPill = false }

    /// Dragging inside a pane is for the pane (selection, the grip), never
    /// for moving the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true; return }
        // Layout rebuilds take panes out for a moment: only a pane that
        // stays out loses its find bar.
        DispatchQueue.main.async { [weak self] in
            if let self, self.window == nil { self.closeFind() }
        }
    }

    /// Hands a borrowed browser back rather than taking it down with us.
    isolated deinit {
        if content.superview === self, browser != nil || files != nil { content.removeFromSuperview() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(content)
        super.mouseDown(with: event)
    }
}

/// Says why a pane isn't taking input: a slim bar over the live mirror
/// when another window or herdr client has it, a full cover when the
/// stream is gone.
private final class DetachedOverlay: NSView {
    enum State: Equatable {
        case otherWindow, otherClient, disconnected(String)
    }

    var onTakeControl: (() -> Void)?
    private(set) var state: State?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Take Control", target: nil, action: nil)

    var isBanner: Bool {
        if case .disconnected = state { return false }
        return true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.lineBreakMode = .byTruncatingMiddle
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(clicked)
        for view in [title, detail, button] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(_ state: State) {
        self.state = state
        switch state {
        case .otherWindow:
            title.stringValue = "Open in another window"
            button.title = "Take Control"
        case .otherClient:
            title.stringValue = "In use by another herdr client"
            button.title = "Take Control"
        case let .disconnected(reason):
            title.stringValue = "Disconnected"
            detail.stringValue = reason
            button.title = "Reconnect"
        }
        button.controlSize = isBanner ? .small : .regular
        detail.isHidden = isBanner
        title.alignment = isBanner ? .left : .center
        isHidden = false
        needsLayout = true
    }

    func hide() {
        state = nil
        isHidden = true
    }

    override var fittingSize: NSSize {
        button.sizeToFit()
        return NSSize(width: 14 + title.intrinsicContentSize.width + 12 + button.frame.width + 6, height: 30)
    }

    override func layout() {
        super.layout()
        button.sizeToFit()
        if isBanner {
            layer?.cornerRadius = 15
            layer?.backgroundColor = (Theme.current?.cardStrong ?? .windowBackgroundColor).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.cgColor
            let buttonX = bounds.width - button.frame.width - 6
            button.frame.origin = NSPoint(x: buttonX, y: (bounds.height - button.frame.height) / 2)
            title.frame = NSRect(x: 14, y: (bounds.height - 16) / 2, width: max(0, buttonX - 20), height: 16)
        } else {
            layer?.cornerRadius = 0
            layer?.borderWidth = 0
            layer?.backgroundColor = Theme.current?.pane.withAlphaComponent(0.85).cgColor
            let midY = bounds.midY
            title.frame = NSRect(x: 0, y: midY + 14, width: bounds.width, height: 18)
            detail.frame = NSRect(x: 16, y: midY - 6, width: bounds.width - 32, height: 16)
            button.frame.origin = NSPoint(x: (bounds.width - button.frame.width) / 2, y: midY - 40)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // The bar only reacts to its button; the full cover to any click.
        if !isBanner { onTakeControl?() } else { super.mouseDown(with: event) }
    }

    @objc private func clicked() { onTakeControl?() }
}

/// "Zoomed · ⌘⇧↩ to restore", top right of a zoomed pane.
private final class ZoomPill: NSView {
    private let label = NSTextField(labelWithString: "Zoomed · ⌘⇧↩ to restore")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 20, height: 24)
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Theme.current?.card.cgColor
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 10, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

extension AgentStatus {
    var color: NSColor? {
        switch self {
        case .blocked: .controlAccentColor
        case .working: .systemGreen
        case .done: .systemBlue
        case .idle: .tertiaryLabelColor
        case .unknown: nil
        }
    }
}
