import AppKit
import GhosttyTerminal
import HerdrKit

/// One leaf of the split tree: a rounded card holding the pane's content.
/// No header: focus shows as full brightness (others dim), and an agent that
/// needs you gets a thin accent ring.
@MainActor
final class PaneContainerView: NSView {
    let paneID: String
    let content: NSView
    private let ring = CALayer()
    private let detached = DetachedOverlay()
    private let zoomPill = ZoomPill()

    var terminal: HerdrTerminalView? { content as? HerdrTerminalView }
    var browser: BrowserPaneView? { content as? BrowserPaneView }
    var files: FilesPaneView? { content as? FilesPaneView }
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

        ring.borderWidth = 1.5
        ring.cornerRadius = Self.cornerRadius
        ring.borderColor = NSColor.clear.cgColor
        ring.zPosition = 10
        layer?.addSublayer(ring)

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
        layer?.backgroundColor = theme.pane.cgColor
        updateRing()
    }

    func update(pane: Pane?, attention: Attention.Reason?) {
        guard pane != nil else { return }
        self.attention = attention
        updateRing()
    }

    private func updateRing() {
        ring.borderColor = attention == .blocked ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    private func updateDimming() {
        alphaValue = isFocusedPane || !dimsWhenUnfocused ? 1 : 0.72
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
        let pill = zoomPill.fittingSize
        zoomPill.frame = NSRect(x: b.width - pill.width - 12, y: b.height - pill.height - 10, width: pill.width, height: pill.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = b
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
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
