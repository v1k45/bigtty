import AppKit
import GhosttyTerminal
import HerdrKit

/// A Ghostty surface showing one herdr pane. The surface runs no process of
/// its own: herdr's frames are written into it, and its input goes back to
/// herdr through a `TerminalChannel`.
@MainActor
final class HerdrTerminalView: AppTerminalView {
    let paneID: String
    private let endpoint: HerdrEndpoint
    private let terminalID: String
    private var session: InMemoryTerminalSession!
    private var channel: TerminalChannel?
    private var viewport: InMemoryTerminalViewport?
    private var scrollAccumulator: CGFloat = 0

    var onFocus: (() -> Void)?
    /// herdr ended the stream, e.g. another client took control.
    var onDetached: ((String) -> Void)?

    init(pane: Pane, endpoint: HerdrEndpoint, controller: TerminalController) {
        paneID = pane.paneID
        terminalID = pane.terminalID
        self.endpoint = endpoint
        super.init(frame: .zero)

        let box = WeakBox<HerdrTerminalView>()
        session = InMemoryTerminalSession(
            write: { data in
                DispatchQueue.main.async { box.value?.channel?.sendInput(data) }
            },
            resize: { viewport in
                DispatchQueue.main.async { box.value?.viewportChanged(viewport) }
            },
            suppressesPixelOnlyResizes: true
        )
        box.value = self
        self.controller = controller
        configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    }

    isolated deinit {
        channel?.close()
    }

    // MARK: - Channel

    private func viewportChanged(_ viewport: InMemoryTerminalViewport) {
        self.viewport = viewport
        if let channel, channel.isRunning {
            channel.resize(
                columns: Int(viewport.columns), rows: Int(viewport.rows),
                cellWidth: Int(viewport.cellWidthPixels), cellHeight: Int(viewport.cellHeightPixels)
            )
        } else if window != nil {
            attach()
        }
    }

    /// Starts (or restarts) the stream, taking control from any other client.
    func attach() {
        guard let viewport, viewport.columns > 0, viewport.rows > 0 else { return }
        channel?.close()
        let channel = TerminalChannel(endpoint: endpoint, terminalID: terminalID)
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
        return "viewport=\(grid) channel=\(channel?.isRunning == true ? "running" : "none")\n\(text)"
    }

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
        if ok { onFocus?() }
        return ok
    }

    /// herdr owns scrollback. Unless the program in the pane captured the
    /// mouse, turn wheel movement into `terminal.scroll`.
    override func scrollWheel(with event: NSEvent) {
        if isMouseCaptured {
            super.scrollWheel(with: event)
            return
        }
        let lineHeight: CGFloat = event.hasPreciseScrollingDeltas ? 16 : 1
        scrollAccumulator += event.scrollingDeltaY / lineHeight
        let lines = Int(scrollAccumulator.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)
        channel?.scroll(up: lines > 0, lines: abs(lines))
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}
