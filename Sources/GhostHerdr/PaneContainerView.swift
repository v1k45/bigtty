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
    /// Space between the card edge and terminal text, so glyphs clear the corners.
    static let contentInset: CGFloat = 5

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

        terminal?.onDetached = { [weak self] _ in self?.detached.isHidden = false }
        terminal?.onModeChange = { [weak self] mode in
            // A mirror of a pane another window controls.
            self?.detached.isHidden = mode == .control
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
        detached.isHidden = true
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
        let inset = terminal != nil ? Self.contentInset : 0
        content.frame = b.insetBy(dx: inset, dy: inset)
        detached.frame = b
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

/// Covers a pane shown read-only because another window or client controls it.
private final class DetachedOverlay: NSView {
    var onTakeControl: (() -> Void)?
    private let title = NSTextField(labelWithString: "Open in another window")
    private let detail = NSTextField(labelWithString: "Showing it read-only. Type or click to take control.")
    private let button = NSButton(title: "Take Control", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(clicked)
        for view in [title, detail, button] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Theme.current?.pane.withAlphaComponent(0.78).cgColor
        let midY = bounds.midY
        title.frame = NSRect(x: 0, y: midY + 14, width: bounds.width, height: 18)
        detail.frame = NSRect(x: 0, y: midY - 6, width: bounds.width, height: 16)
        button.sizeToFit()
        button.frame.origin = NSPoint(x: (bounds.width - button.frame.width) / 2, y: midY - 40)
    }

    override func mouseDown(with _: NSEvent) { onTakeControl?() }
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
