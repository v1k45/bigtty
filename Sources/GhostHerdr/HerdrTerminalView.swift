import AppKit
import GhosttyTerminal
import HerdrKit

/// A Ghostty surface showing one herdr pane. The surface runs no process of
/// its own: herdr's frames are written into it, and its input goes back to
/// herdr through a `TerminalChannel`.
@MainActor
final class HerdrTerminalView: AppTerminalView, TerminalSurfaceOpenURLDelegate, TerminalSurfaceTitleDelegate {
    typealias Mode = TerminalChannel.Mode

    let paneID: String
    private let endpoint: HerdrEndpoint
    private let terminalID: String
    private var session: InMemoryTerminalSession!
    private var channel: TerminalChannel?
    private(set) var mode: Mode = .control
    private var viewport: InMemoryTerminalViewport?
    private var scrollAccumulator: CGFloat = 0

    var onFocus: (() -> Void)?
    /// herdr ended the stream, e.g. another client took control.
    var onDetached: ((String) -> Void)?
    /// Control moved to or from this view.
    var onModeChange: ((Mode) -> Void)?
    /// A link in the terminal was opened (⌘-click).
    var onOpenURL: ((String) -> Void)?

    init(pane: Pane, endpoint: HerdrEndpoint, controller: TerminalController) {
        paneID = pane.paneID
        terminalID = pane.terminalID
        self.endpoint = endpoint
        super.init(frame: .zero)

        let box = WeakBox<HerdrTerminalView>()
        session = InMemoryTerminalSession(
            write: { data in
                DispatchQueue.main.async { box.value?.userInput(data) }
            },
            resize: { viewport in
                DispatchQueue.main.async { box.value?.viewportChanged(viewport) }
            },
            suppressesPixelOnlyResizes: true
        )
        box.value = self
        self.controller = controller
        configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        delegate = self
    }

    isolated deinit {
        channel?.close()
    }

    // MARK: - Channel

    private func viewportChanged(_ viewport: InMemoryTerminalViewport) {
        let first = self.viewport == nil
        self.viewport = viewport
        // Ghostty creates surfaces focused; only the first responder should
        // draw a focused (blinking) cursor.
        if first { syncSurfaceFocus() }
        if let channel, channel.isRunning, mode == .control {
            channel.resize(
                columns: Int(viewport.columns), rows: Int(viewport.rows),
                cellWidth: Int(viewport.cellWidthPixels), cellHeight: Int(viewport.cellHeightPixels)
            )
        } else if window != nil {
            // An observer's size is fixed at start, so restart it to follow.
            startChannel()
        }
    }

    /// Joins the pane in whatever mode the arbiter assigns.
    func attach() {
        mode = ControlArbiter.shared.register(self)
        startChannel()
    }

    /// Takes control from other windows and from other herdr clients.
    func takeControl() {
        ControlArbiter.shared.claim(self)
    }

    /// Called by the arbiter.
    func setMode(_ mode: Mode) {
        guard mode != self.mode || channel == nil else { return }
        self.mode = mode
        onModeChange?(mode)
        if window != nil { startChannel() }
    }

    private func startChannel() {
        guard let viewport, viewport.columns > 0, viewport.rows > 0 else { return }
        channel?.close()
        let channel = TerminalChannel(endpoint: endpoint, terminalID: terminalID, mode: mode)
        let session = session!
        channel.onFrame = { session.receive($0) }
        let box = WeakBox<HerdrTerminalView>()
        box.value = self
        let id = ObjectIdentifier(channel)
        channel.onClosed = { reason in
            DispatchQueue.main.async {
                guard let self = box.value, let current = self.channel,
                      ObjectIdentifier(current) == id else { return }
                self.channel = nil
                self.onDetached?(reason)
            }
        }
        do {
            try channel.start(columns: Int(viewport.columns), rows: Int(viewport.rows))
            self.channel = channel
        } catch {
            onDetached?("could not start herdr: \(error)")
        }
    }

    func detach() {
        channel?.close()
        channel = nil
        ControlArbiter.shared.release(self)
    }

    /// Typing into an observing view takes control first, then delivers.
    private func userInput(_ data: Data) {
        if mode == .observe { takeControl() }
        channel?.sendInput(data)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layout rebuild briefly removes and re-adds the view, so only
        // release control if it is still out of a window a moment later.
        if window == nil {
            DispatchQueue.main.async { [weak self] in
                if let self, self.window == nil { self.detach() }
            }
        } else if channel == nil {
            attach()
        }
    }

    override var debugDescription: String {
        let grid = viewport.map { "\($0.columns)x\($0.rows)" } ?? "none"
        let text = session.readViewportText() ?? "<no surface>"
        let state = channel?.isRunning == true ? "\(mode)" : "none"
        return "viewport=\(grid) channel=\(state)\n\(text)"
    }

    /// Tells Ghostty whether this surface has focus. Unfocused surfaces draw
    /// a hollow, steady cursor instead of blinking with the focused one.
    func syncSurfaceFocus() {
        guard window?.firstResponder !== self else { return }
        // The package's focus hook lives in resignFirstResponder; calling it
        // on a view that isn't first responder changes nothing else.
        _ = resignFirstResponder()
    }

    // MARK: - Surface callbacks

    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        if let onOpenURL, url.hasPrefix("http://") || url.hasPrefix("https://") {
            onOpenURL(url)
        } else if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    /// herdr owns titles; the surface's own title changes are ignored.
    func terminalDidChangeTitle(_: String) {}

    // MARK: - Input routing

    /// The app menu gets first pick at ⌘ shortcuts, so ⌘D splits through
    /// herdr instead of hitting Ghostty's own split keybind.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            if mode == .observe { takeControl() }
            onFocus?()
        }
        return ok
    }

    /// The wheel goes to herdr as `terminal.scroll`: herdr scrolls its
    /// scrollback, or, for full-screen apps that asked for mouse input
    /// (Claude Code, vim, less), forwards one wheel event per message. So each
    /// line is its own message, at the cell under the pointer. herdr's frames
    /// don't carry the app's mouse modes, so Ghostty can't tell the difference
    /// itself.
    override func scrollWheel(with event: NSEvent) {
        let lineHeight: CGFloat = event.hasPreciseScrollingDeltas ? 16 : 1
        scrollAccumulator += event.scrollingDeltaY / lineHeight
        let lines = Int(scrollAccumulator.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)
        let cell = cellPosition(of: event)
        for _ in 0..<min(abs(lines), 40) {
            channel?.scroll(up: lines > 0, lines: 1, column: cell?.column, row: cell?.row)
        }
    }

    /// Zero-based grid cell under the event, from the surface's cell size.
    private func cellPosition(of event: NSEvent) -> (column: Int, row: Int)? {
        guard let viewport, viewport.cellWidthPixels > 0, viewport.cellHeightPixels > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x * scale) / Int(viewport.cellWidthPixels)
        let row = Int((bounds.height - point.y) * scale) / Int(viewport.cellHeightPixels)
        return (min(max(column, 0), Int(viewport.columns) - 1), min(max(row, 0), Int(viewport.rows) - 1))
    }

    /// Debug hook: a synthetic wheel event, `lines` positive for up.
    func debugScroll(lines: Int32) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return }
        scrollWheel(with: event)
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}
