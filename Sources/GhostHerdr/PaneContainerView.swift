import AppKit
import GhosttyTerminal
import HerdrKit

/// One leaf of the split tree: a thin header, the pane's content, and the
/// attention ring drawn around it.
@MainActor
final class PaneContainerView: NSView {
    let paneID: String
    let content: NSView
    private let header = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let overlay = NSButton()
    private let ring = CALayer()

    var terminal: HerdrTerminalView? { content as? HerdrTerminalView }
    var browser: BrowserPaneView? { content as? BrowserPaneView }
    /// What this view was built for; a pane re-tagged as another kind is rebuilt.
    var hostKind: HostPaneKind? { browser != nil ? .browser : nil }
    var isFocusedPane = false { didSet { updateChrome() } }
    private var status: AgentStatus = .unknown
    private var attention: Attention.Reason?

    static let headerHeight: CGFloat = 22

    init(paneID: String, content: NSView) {
        self.paneID = paneID
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true

        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4

        overlay.bezelStyle = .rounded
        overlay.title = "Take Control"
        overlay.target = self
        overlay.action = #selector(takeControl)
        overlay.isHidden = true

        for view in [header, statusDot, content, overlay] as [NSView] { addSubview(view) }

        ring.borderWidth = 2
        ring.cornerRadius = 4
        ring.borderColor = NSColor.clear.cgColor
        layer?.addSublayer(ring)

        terminal?.onDetached = { [weak self] reason in self?.showDetached(reason) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func apply(_ theme: Theme) {
        layer?.backgroundColor = theme.chrome.cgColor
    }

    func update(pane: Pane?, attention: Attention.Reason?) {
        guard let pane else { return }
        self.attention = attention
        var title = pane.displayName
        if let cwd = (pane.foregroundCwd ?? pane.cwd).map({ ($0 as NSString).abbreviatingWithTildeInPath }),
           !title.contains(cwd), title != (cwd as NSString).lastPathComponent
        {
            title += "  ·  " + cwd
        }
        header.stringValue = title
        status = pane.agentStatus
        updateChrome()
    }

    private func updateChrome() {
        statusDot.layer?.backgroundColor = status.color?.cgColor ?? NSColor.clear.cgColor
        // cmux-style ring: blocked panes want input, finished ones want a look.
        ring.borderColor = switch attention {
        case .blocked: NSColor.systemOrange.cgColor
        case .done: NSColor.systemBlue.cgColor
        case nil: NSColor.clear.cgColor
        }
        header.textColor = isFocusedPane ? .labelColor : .secondaryLabelColor
    }

    private func showDetached(_ reason: String) {
        overlay.title = "Detached (\(reason)) — Take Control"
        overlay.sizeToFit()
        overlay.isHidden = false
        needsLayout = true
    }

    @objc private func takeControl() {
        overlay.isHidden = true
        terminal?.takeControl()
        window?.makeFirstResponder(content)
    }

    override func layout() {
        super.layout()
        // Browser views are shared (BrowserRegistry). If another container
        // borrowed ours and let go, take it back.
        if content.superview !== self, content.window == nil {
            addSubview(content, positioned: .below, relativeTo: overlay)
        }
        let h = Self.headerHeight
        let b = bounds
        statusDot.frame = NSRect(x: 8, y: b.height - h / 2 - 4, width: 8, height: 8)
        header.frame = NSRect(x: 22, y: b.height - h + 3, width: b.width - 30, height: h - 6)
        content.frame = NSRect(x: 2, y: 2, width: b.width - 4, height: max(0, b.height - h - 2))
        overlay.sizeToFit()
        overlay.frame.origin = NSPoint(x: (b.width - overlay.frame.width) / 2, y: (b.height - overlay.frame.height) / 2)
        ring.frame = b.insetBy(dx: 1, dy: 1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    /// Hands a borrowed browser back rather than taking it down with us.
    isolated deinit {
        if content.superview === self, browser != nil { content.removeFromSuperview() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(content)
        super.mouseDown(with: event)
    }
}

extension AgentStatus {
    var color: NSColor? {
        switch self {
        case .blocked: .systemOrange
        case .working: .systemGreen
        case .done: .systemBlue
        case .idle: .tertiaryLabelColor
        case .unknown: nil
        }
    }
}
