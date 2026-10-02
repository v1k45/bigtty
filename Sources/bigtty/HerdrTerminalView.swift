import AppKit
import GhosttyTerminal
import HerdrKit

/// A Ghostty surface showing one herdr pane. The surface runs no process of
/// its own: herdr's frames are written into it, and its input goes back to
/// herdr through a `TerminalChannel`.
@MainActor
final class HerdrTerminalView: AppTerminalView, TerminalSurfaceOpenURLDelegate, TerminalSurfaceTitleDelegate, TerminalSurfaceGridResizeDelegate {
    typealias Mode = TerminalChannel.Mode

    let paneID: String
    private let endpoint: HerdrEndpoint
    let terminalID: String
    /// Its channel ended for good (herdr stopped, the terminal went away).
    private(set) var hasDetached = false
    private var session: InMemoryTerminalSession!
    /// Frames pass through here, held while the app redraws for a new size.
    private var gate: FrameGate!
    /// The grid this view asked herdr for, readable off the main thread.
    private let expectedSize = LockedSize()
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
        let surfaceSession = session!
        gate = FrameGate { surfaceSession.receive($0) }
        self.controller = controller
        configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        delegate = self
    }

    isolated deinit {
        channel?.close()
        activationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Channel

    private func viewportChanged(_ viewport: InMemoryTerminalViewport) {
        let first = self.viewport == nil
        self.viewport = viewport
        // Ghostty creates surfaces focused; only the first responder should
        // draw a focused (blinking) cursor.
        if first {
            syncSurfaceFocus()
            syncColorScheme()
        }
        if let channel, channel.isRunning, mode == .control {
            // A new size makes the app redraw; show the result, not the
            // frames in between (except while dragging the window edge).
            if window?.inLiveResize != true { gate.hold() }
            expectedSize.set(Int(viewport.columns), Int(viewport.rows))
            channel.resize(
                columns: Int(viewport.columns), rows: Int(viewport.rows),
                cellWidth: Int(viewport.cellWidthPixels), cellHeight: Int(viewport.cellHeightPixels)
            )
        } else if window != nil {
            // Not attached yet, or an observer (whose size is fixed at
            // start): (re)start at the size the view settles on. The first
            // viewport is often a provisional one from before layout.
            scheduleStart()
        }
    }

    private var startScheduled = false

    /// Coalesces starts within a layout pass, so the pane is attached (and
    /// herdr sized) once, at the final size.
    private func scheduleStart() {
        guard !startScheduled else { return }
        startScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.startScheduled = false
            if self.window != nil { self.startChannel() }
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

    /// The pane's size as herdr reports it. While this view controls the
    /// pane it should match; if something else resized it (herdr's own
    /// interface, another client showing it), size it back.
    private var lastSizeFix = Date.distantPast

    private func frameSize(columns: Int, rows: Int, from source: TerminalChannel) {
        guard source === channel, mode == .control, !displaced, window != nil,
              let viewport, viewport.columns > 0, viewport.rows > 0,
              columns != Int(viewport.columns) || rows != Int(viewport.rows),
              window?.inLiveResize != true,
              Date().timeIntervalSince(lastSizeFix) > 0.5 else { return }
        lastSizeFix = Date()
        gate.hold()
        expectedSize.set(Int(viewport.columns), Int(viewport.rows))
        source.resize(columns: Int(viewport.columns), rows: Int(viewport.rows),
                      cellWidth: Int(viewport.cellWidthPixels), cellHeight: Int(viewport.cellHeightPixels))
    }

    /// Called by the arbiter.
    func setMode(_ mode: Mode) {
        guard mode != self.mode || channel == nil || displaced else { return }
        self.mode = mode
        displaced = false
        onModeChange?(mode)
        if window != nil { startChannel() }
    }

    /// Another herdr client (another app, the TUI) took this pane. We show
    /// a read-only mirror and quietly take it back once it's let go.
    private(set) var displaced = false
    var onDisplacedChange: ((Bool) -> Void)?
    private var reclaimTimer: Timer?
    private var reclaimProbe: TerminalChannel?

    private func startChannel() {
        guard let viewport, viewport.columns > 0, viewport.rows > 0 else { return }
        channel?.close()
        let channel = TerminalChannel(endpoint: endpoint, terminalID: terminalID, mode: displaced ? .observe : mode)
        // Attaching resizes the pane to this view: wait for the redraw.
        gate.hold()
        wire(channel)
        do {
            // An observer mirrors another client's size: nothing to expect.
            if displaced || mode == .observe { expectedSize.clear() } else { expectedSize.set(Int(viewport.columns), Int(viewport.rows)) }
            try channel.start(columns: Int(viewport.columns), rows: Int(viewport.rows))
            self.channel = channel
        } catch {
            hasDetached = true
            onDetached?("could not start herdr: \(error)")
        }
    }

    /// Frames go to the surface; a close only matters for the current channel.
    private func wire(_ channel: TerminalChannel) {
        let session = session!
        // Frames never carry the app's paste mode; herdr (0.9.2+, which the
        // app requires) re-brackets a bracketed paste for the app's own mode.
        session.receive(Data("\u{1b}[?2004h".utf8))
        let gate = gate!
        channel.onFrame = { gate.feed($0) }
        let box = WeakBox<HerdrTerminalView>()
        box.value = self
        // Compared on the reader thread against the size last sent; the
        // main thread only hears about a mismatch.
        let expected = expectedSize
        channel.onFrameSize = { columns, rows in
            guard let want = expected.value, want.columns != columns || want.rows != rows else { return }
            DispatchQueue.main.async { box.value?.frameSize(columns: columns, rows: rows, from: channel) }
        }
        let id = ObjectIdentifier(channel)
        channel.onClosed = { reason in
            DispatchQueue.main.async {
                guard let self = box.value, let current = self.channel,
                      ObjectIdentifier(current) == id else { return }
                self.channel = nil
                if reason.contains("taken over"), self.mode == .control, self.window != nil {
                    self.setDisplaced(true)
                    self.startChannel()
                } else {
                    self.hasDetached = true
                    self.onDetached?(reason)
                }
            }
        }
    }

    private func setDisplaced(_ value: Bool) {
        guard value != displaced else { return }
        displaced = value
        onDisplacedChange?(value)
        reclaimTimer?.invalidate()
        reclaimTimer = nil
        reclaimProbe?.close()
        reclaimProbe = nil
        guard value else { return }
        let box = WeakBox<HerdrTerminalView>()
        box.value = self
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { box.value?.tryReclaim() }
        }
    }

    /// Attaches without --takeover: herdr refuses while the other client
    /// holds the pane, and lets us in once it has gone.
    private func tryReclaim() {
        guard displaced, mode == .control, window != nil, reclaimProbe == nil,
              let viewport, viewport.columns > 0 else { return }
        let probe = TerminalChannel(endpoint: endpoint, terminalID: terminalID, mode: .control, takeover: false)
        let session = session!
        let box = WeakBox<HerdrTerminalView>()
        box.value = self
        let gate = gate!
        let first = OnceFlag()
        probe.onFrame = { data in
            // Taking the pane back resizes it: hold for the redraw.
            if first.take() { gate.hold() }
            gate.feed(data)
            DispatchQueue.main.async { box.value?.adopt(probe) }
        }
        probe.onClosed = { _ in
            DispatchQueue.main.async {
                guard let self = box.value, self.reclaimProbe === probe else { return }
                self.reclaimProbe = nil
            }
        }
        do {
            try probe.start(columns: Int(viewport.columns), rows: Int(viewport.rows))
            reclaimProbe = probe
        } catch {}
    }

    /// The probe got in: it becomes the control channel.
    private func adopt(_ probe: TerminalChannel) {
        guard displaced, reclaimProbe === probe else { return }
        reclaimProbe = nil
        channel?.close()
        if let viewport { expectedSize.set(Int(viewport.columns), Int(viewport.rows)) }
        wire(probe)
        channel = probe
        setDisplaced(false)
        onModeChange?(.control)
    }

    func detach() {
        setDisplaced(false)
        channel?.close()
        channel = nil
        ControlArbiter.shared.release(self)
    }

    /// Typing into an observing view takes control first, then delivers.
    private func userInput(_ data: Data) {
        if mode == .observe || displaced { takeControl() }
        channel?.sendInput(data)
    }

    /// The app you're using owns what it shows: when another client (the
    /// same session open on another Mac) took this pane, coming back to this
    /// window takes it back at this window's size, instead of mirroring the
    /// other client's size until you type.
    private var activationObservers: [NSObjectProtocol] = []

    private func watchActivation() {
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers = []
        guard let window else { return }
        let box = WeakBox<HerdrTerminalView>()
        box.value = self
        let handler: @Sendable (Notification) -> Void = { _ in
            DispatchQueue.main.async { box.value?.reclaimIfLooking() }
        }
        activationObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: handler),
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: handler),
        ]
    }

    private func reclaimIfLooking() {
        guard displaced, mode == .control, let window, window.isKeyWindow, NSApp.isActive, !isHiddenOrHasHiddenAncestor else { return }
        takeControl()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchActivation()
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
        let state = (channel?.isRunning == true ? "\(mode)" : "none") + (displaced ? " displaced" : "") + (hasDetached ? " detached" : "") + " term=\(terminalID)"
        return "viewport=\(grid) channel=\(state)\n\(text)"
    }

    /// Tells Ghostty whether this surface has focus. Unfocused surfaces draw
    /// a hollow, steady cursor instead of blinking with the focused one.
    /// Tells the surface whether it's light or dark, so a Ghostty
    /// `theme = light:…,dark:…` picks the right side. Surfaces created after
    /// the view joined its window otherwise never hear it.
    func syncColorScheme() {
        viewDidChangeEffectiveAppearance()
    }

    func syncSurfaceFocus() {
        guard window?.firstResponder !== self else { return }
        // The package's focus hook lives in resignFirstResponder; calling it
        // on a view that isn't first responder changes nothing else.
        _ = resignFirstResponder()
    }

    // MARK: - Surface callbacks

    /// ⌘-click on a link or a path. Web links go to the browser pane,
    /// paths (and file:// links) to the files pane; see `openURL(_:from:)`.
    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        openedLinkThisClick = true
        // Ghostty finds a link within one row; a path the app wrapped onto
        // the next rows is only part of it there, so look for the whole one.
        // After this callback returns: Ghostty holds the screen while it
        // reports the link, and reading it here would wait forever.
        let cell = commandClickCell
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var url = url
            if let cell, let whole = self.word(atColumn: cell.column, row: cell.row),
               whole.count > url.count, whole.contains(url.trimmingCharacters(in: CharacterSet(charactersIn: ".:,)"))) {
                url = whole
            }
            if let onOpenURL = self.onOpenURL {
                onOpenURL(url)
            } else if let link = URL(string: url), link.scheme != nil {
                NSWorkspace.shared.open(link)
            }
        }
    }

    /// herdr owns titles; the surface's own title changes are ignored.
    func terminalDidChangeTitle(_: String) {}

    // MARK: - Input routing

    /// Dragging in a terminal selects text; it never moves the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// A click on a background window reaches the app too, as in Ghostty.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

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
    // MARK: - Mouse clicks for the app

    // herdr's frames don't carry the app's mouse mode, so the surface never
    // reports clicks itself. A plain click (no drag) is forwarded as
    // terminal.mouse, and herdr passes it on only if the app (Claude Code,
    // vim, htop…) asked for mouse input. Drags stay local text selection.
    private var pressedCell: (column: Int, row: Int, button: String)?
    private var pressedPoint: NSPoint?
    private var draggedSincePress = false
    /// Movement a click may have before it counts as a drag (trackpad
    /// clicks wobble a point or two).
    private static let clickSlop: CGFloat = 5

    private func pressed(_ event: NSEvent, button: String) {
        // A click in a mirrored pane takes it back first.
        if displaced || mode == .observe { takeControl() }
        pressedCell = cellPosition(of: event).map { ($0.column, $0.row, button) }
        pressedPoint = convert(event.locationInWindow, from: nil)
        draggedSincePress = false
    }

    private func released(_ event: NSEvent) {
        defer { pressedCell = nil }
        // The click lands on the cell that was pressed, even if the pointer
        // wobbled into a neighbour.
        guard let press = pressedCell, !draggedSincePress, mode == .control, !displaced else { return }
        let cell = (column: press.column, row: press.row)
        let modifiers = (event.modifierFlags.contains(.shift) ? 1 : 0)
            | (event.modifierFlags.contains(.control) ? 2 : 0)
            | (event.modifierFlags.contains(.option) ? 4 : 0)
        channel?.mouse("down", button: press.button, column: cell.column, row: cell.row, modifiers: modifiers)
        channel?.mouse("up", button: press.button, column: cell.column, row: cell.row, modifiers: modifiers)
    }

    override func mouseDown(with event: NSEvent) {
        pressed(event, button: "left")
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = pressedPoint {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) > Self.clickSlop { draggedSincePress = true }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        openedLinkThisClick = false
        commandClickCell = event.modifierFlags.contains(.command) && !draggedSincePress ? cellPosition(of: event) : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.commandClickCell = nil }
        super.mouseUp(with: event)
        // ⌘-click opens links; that's Ghostty's, not the app's.
        guard event.modifierFlags.contains(.command) else { return released(event) }
        // Nothing Ghostty saw as a link: the word under the pointer may
        // still be a file name ("workspace.png" in an agent's table).
        guard !draggedSincePress, let cell = cellPosition(of: event) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.openedLinkThisClick, let word = self.word(atColumn: cell.column, row: cell.row) else { return }
            self.onOpenURL?(word)
        }
    }

    private var openedLinkThisClick = false
    /// Where the ⌘-click that may open a link landed, while it's handled.
    private var commandClickCell: (column: Int, row: Int)?

    /// The path-like word at a cell of the viewport, if it looks like a
    /// file name (has a dot or a slash). A path the app wrapped onto more
    /// rows (Claude Code breaks long lines a little short of the edge and
    /// indents the rest) is read whole, from whichever row was clicked.
    private func word(atColumn column: Int, row: Int) -> String? {
        guard let text = session.readViewportText() else { return nil }
        let lines = text.components(separatedBy: "\n").map { Array($0) }
        guard row < lines.count, column < lines[row].count else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/~+@:#"))
        func ok(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { allowed.contains($0) } }
        let chars = lines[row]
        guard ok(chars[column]) else { return nil }
        var start = column, end = column
        while start > 0, ok(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, ok(chars[end + 1]) { end += 1 }
        var word = String(chars[start...end])

        // A row wrapped if its text runs to within a few columns of the edge.
        let width = max(Int(grid?.columns ?? 0), lines.map(\.count).max() ?? 0)
        let nearEdge = max(0, width - 12)
        func lastText(_ line: [Character]) -> Int? { line.lastIndex { !$0.isWhitespace } }
        func firstText(_ line: [Character]) -> Int? { line.firstIndex { !$0.isWhitespace } }
        // Onward: the word ends its row, the row reaches the edge, and the
        // next row (after its indent) starts with more of it.
        var r = row, e = end
        while r + 1 < lines.count, lastText(lines[r]) == e, e >= nearEdge,
              let first = firstText(lines[r + 1]), ok(lines[r + 1][first]) {
            let next = lines[r + 1]
            var ne = first
            while ne + 1 < next.count, ok(next[ne + 1]) { ne += 1 }
            word += String(next[first...ne])
            r += 1
            e = ne
        }
        // Back: the word starts its row, and the row above ends at the edge
        // in the middle of it.
        r = row
        var s = start
        while r > 0, firstText(lines[r]) == s, let last = lastText(lines[r - 1]), last >= nearEdge, ok(lines[r - 1][last]) {
            let previous = lines[r - 1]
            var ps = last
            while ps > 0, ok(previous[ps - 1]) { ps -= 1 }
            word = String(previous[ps...last]) + word
            r -= 1
            s = ps
        }
        word = word.trimmingCharacters(in: CharacterSet(charactersIn: ".:,"))
        guard word.count > 1, word.contains(".") || word.contains("/") else { return nil }
        return word
    }

    /// Pointer motion, once per cell, for apps that track it (hover
    /// highlights in Claude Code). herdr ≥ 0.9.2 drops it for apps that don't.
    private var lastMotionCell: (column: Int, row: Int)?

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard mode == .control, !displaced, let cell = cellPosition(of: event) else { return }
        if let last = lastMotionCell, last.column == cell.column, last.row == cell.row { return }
        lastMotionCell = cell
        // herdr delivers it only to apps that track motion.
        channel?.mouse("move", column: cell.column, row: cell.row)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastMotionCell = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        pressed(event, button: "right")
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        released(event)
    }

    /// Lines per mouse-wheel notch, as herdr's own client scrolls
    /// (`ui.mouse_scroll_lines`, default 3).
    private static let linesPerNotch: CGFloat = 3

    override func scrollWheel(with event: NSEvent) {
        if displaced, event.phase == .began || event.phase == [] && event.momentumPhase == [] { takeControl() }
        if event.hasPreciseScrollingDeltas {
            // Trackpads: follow the fingers, one row per row height.
            let rowHeight = grid.map { CGFloat($0.cellHeightPixels) / (window?.backingScaleFactor ?? 2) } ?? 16
            scrollAccumulator += event.scrollingDeltaY / max(rowHeight, 1)
        } else {
            scrollAccumulator += event.scrollingDeltaY * Self.linesPerNotch
        }
        let lines = Int(scrollAccumulator.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)
        let cell = cellPosition(of: event)
        // One message per line: for apps with their own scrolling (less,
        // Claude Code) herdr sends one wheel event per message whatever
        // `lines` says; only its scrollback honours the count.
        for _ in 0..<min(abs(lines), 60) {
            channel?.scroll(up: lines > 0, lines: 1, column: cell?.column, row: cell?.row)
        }
    }

    /// Zero-based grid cell under the event, from the surface's cell size.
    /// The surface's exact grid (cell size in pixels), from Ghostty.
    private var grid: TerminalGridMetrics?

    func terminalDidResize(_ size: TerminalGridMetrics) { grid = size }

    /// The cell under the pointer. Uses Ghostty's own cell size and its
    /// top-left padding; an estimate from the view size drifts by a row
    /// toward the bottom of a tall pane, where Claude Code's expanders are.
    private func cellPosition(of event: NSEvent) -> (column: Int, row: Int)? {
        let point = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2
        let columns: Int, rows: Int, cellWidth: CGFloat, cellHeight: CGFloat
        if let grid, grid.columns > 0, grid.rows > 0, grid.cellWidthPixels > 0, grid.cellHeightPixels > 0 {
            columns = Int(grid.columns)
            rows = Int(grid.rows)
            cellWidth = CGFloat(grid.cellWidthPixels) / scale
            cellHeight = CGFloat(grid.cellHeightPixels) / scale
        } else if let viewport, viewport.columns > 0, viewport.rows > 0 {
            columns = Int(viewport.columns)
            rows = Int(viewport.rows)
            cellWidth = viewport.cellWidthPixels > 0 ? CGFloat(viewport.cellWidthPixels) / scale : bounds.width / CGFloat(columns)
            cellHeight = viewport.cellHeightPixels > 0 ? CGFloat(viewport.cellHeightPixels) / scale : bounds.height / CGFloat(rows)
        } else {
            return nil
        }
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        // Ghostty's window padding (2pt by default) sits top-left; any
        // partial-cell leftover goes right and bottom.
        let padX = min(2, max(0, bounds.width - CGFloat(columns) * cellWidth))
        let padY = min(2, max(0, bounds.height - CGFloat(rows) * cellHeight))
        let column = Int((point.x - padX) / cellWidth)
        let row = Int((bounds.height - point.y - padY) / cellHeight)
        return (min(max(column, 0), columns - 1), min(max(row, 0), rows - 1))
    }

    /// Debug hook: ⌘-clicks the middle of `word`'s first appearance on
    /// screen with real mouse events, as the user would.
    func debugCommandClick(_ word: String) {
        guard let window, let text = session.readViewportText(), let grid, grid.columns > 0 else { return }
        let lines = text.components(separatedBy: "\n")
        guard let row = lines.firstIndex(where: { $0.contains(word) }),
              let range = lines[row].range(of: word) else { return NSLog("bigtty: debugCommandClick: \(word) not on screen") }
        let column = lines[row].distance(from: lines[row].startIndex, to: range.lowerBound) + word.count / 2
        let scale = window.backingScaleFactor
        let cellWidth = CGFloat(grid.cellWidthPixels) / scale, cellHeight = CGFloat(grid.cellHeightPixels) / scale
        let local = NSPoint(x: 2 + (CGFloat(column) + 0.5) * cellWidth, y: bounds.height - 2 - (CGFloat(row) + 0.5) * cellHeight)
        let point = convert(local, to: nil)
        NSLog("bigtty: debugCommandClick \(word) at column \(column) row \(row)")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
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
