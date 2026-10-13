import AppKit
import GhosttyKit
import GhosttyTerminal
import HerdrKit

/// Keeps a terminal selection on its text while herdr scrolls the screen.
///
/// herdr owns the scrollback and repaints the visible screen into the
/// surface, so the surface never scrolls and Ghostty's own selection stays
/// on the same cells while different text moves under it. This follows the
/// text instead: each frame's screen is lined up with the one before
/// (`ScreenShift`), and once the text has moved the selection is drawn by
/// the view (`SelectionHighlightView`) and copied from what was selected.
///
/// Frames arrive on a reader thread; the view's main-thread calls and the
/// frame path share state under a lock.
final class SelectionTracker: @unchecked Sendable {
    enum Change {
        /// The text moved; `first` the first time it did.
        case moved(PinnedSelection, first: Bool)
        /// The screen no longer lines up with the selection's text.
        case lost
    }

    private let lock = NSLock()
    private var selection: PinnedSelection?
    private var screen: [String] = []
    private var moved = false
    /// Rows the scrolling sent since the last frame should move the text.
    private var expected = 0

    var isTracking: Bool { lock.withLock { selection != nil } }

    /// The selection once it has moved off the cells Ghostty highlights.
    var movedSelection: PinnedSelection? { lock.withLock { moved ? selection : nil } }

    func start(_ selection: PinnedSelection, screen: [String]) {
        lock.withLock {
            self.selection = selection
            self.screen = screen
            moved = false
            expected = 0
        }
    }

    func stop() {
        lock.withLock {
            selection = nil
            screen = []
            moved = false
        }
    }

    /// Scrolling asked herdr to move the text up `rows` (down if negative).
    func scrolled(movingTextUp rows: Int) {
        lock.withLock { if selection != nil { expected += rows } }
    }

    /// The screen after a frame. Returns what the view should redraw.
    func screenChanged(_ new: [String]) -> Change? {
        lock.withLock {
            guard let current = selection, new != screen else { return nil }
            defer { screen = new }
            guard let shift = ScreenShift.rows(from: screen, to: new, expected: expected) else {
                selection = nil
                return .lost
            }
            expected = 0
            guard shift != 0 else { return nil }
            let first = !moved
            moved = true
            selection = current.movedUp(shift)
            return .moved(selection!, first: first)
        }
    }
}

/// The selection, drawn by the view once herdr has scrolled it off the
/// cells Ghostty highlights.
final class SelectionHighlightView: NSView {
    var rects: [NSRect] = [] { didSet { needsDisplay = true } }
    var color: NSColor = .selectedTextBackgroundColor { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        color.setFill()
        for rect in rects { rect.fill() }
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

extension AppTerminalView {
    /// Ghostty's current selection, as cells of the screen and the text it
    /// copies (trailing blanks trimmed, as Ghostty's copy does by default).
    func ghosttySelection() -> PinnedSelection? {
        guard let surface = ghosttySurface else { return nil }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        // Negative when no part of it is on screen.
        guard out.tl_px_x >= 0 else { return nil }
        let text = out.text.map { pointer in
            String(decoding: UnsafeBufferPointer(start: pointer, count: Int(out.text_len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } ?? ""
        let trimmed = text.components(separatedBy: "\n")
            .map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
            .joined(separator: "\n")
        let columns = Int(ghostty_surface_size(surface).columns)
        return PinnedSelection(offset: Int(out.offset_start), length: Int(out.offset_len), columns: columns, text: trimmed)
    }

    /// The package keeps the Ghostty surface to itself; reading where the
    /// selection is takes the C API, so it's looked up by reflection.
    /// Nil if the package's layout changes, and selections then stay put.
    private var ghosttySurface: ghostty_surface_t? {
        var mirror: Mirror? = Mirror(reflecting: self)
        while let current = mirror, current.subjectType != AppTerminalView.self {
            mirror = current.superclassMirror
        }
        guard let core = mirror.flatMap({ Self.child($0, "core") }),
              let wrapper = Self.child(Mirror(reflecting: core), "surface") else { return nil }
        return Self.child(Mirror(reflecting: wrapper), "surface") as? ghostty_surface_t
    }

    private static func child(_ mirror: Mirror, _ label: String) -> Any? {
        mirror.children.first { $0.label == label }.flatMap { unwrap($0.value) }
    }

    private static func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.flatMap { unwrap($0.value) }
    }
}
