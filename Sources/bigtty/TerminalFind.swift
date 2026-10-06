import AppKit
import HerdrKit

/// ⌘F in a terminal. herdr keeps the scrollback (the surface only has the
/// screen), so herdr searches it: `pane.copy_search` finds every match,
/// `pane.scroll` brings one on screen, and an overlay marks those visible.
/// Starts at the newest match; Next walks back through older output.
@MainActor
final class TerminalFinder: FindDriver {
    private weak var view: HerdrTerminalView?
    private let overlay = FindHighlightView()
    var onFindStatus: ((FindStatus) -> Void)?
    var findBarInset: CGFloat { 0 }
    var findsUpward: Bool { true }
    var findFocusView: NSView { view ?? overlay }

    private var query = ""
    private var result: ScrollbackMatches?
    private var scroll: ScrollInfo?
    /// Answers to older requests are dropped.
    private var generation = 0
    private var debounce: DispatchWorkItem?
    /// Polls the screen while searching: scrolling and new output move the
    /// matches, so they're looked up again when it changes.
    private var watcher: Timer?
    private var lastScreen: String?
    private var inFlight = false
    private var refreshPending = false

    init(view: HerdrTerminalView) {
        self.view = view
    }

    private var paneID: String { view?.paneID ?? "" }

    func find(_ query: String) {
        self.query = query
        debounce?.cancel()
        guard !query.isEmpty else {
            generation += 1
            result = nil
            onFindStatus?(.idle)
            redraw()
            return
        }
        startWatching()
        // herdr searches the whole scrollback per keystroke; let typing settle.
        let work = DispatchWorkItem { [weak self] in
            self?.search(from: .end, backward: true, reveal: true)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func findNext(backwards: Bool) {
        guard !query.isEmpty else { return }
        guard let current = result?.currentMatch else {
            return search(from: .end, backward: true, reveal: true)
        }
        // Next is up (older): a backward search from the current match.
        search(from: current.start, backward: !backwards, reveal: true)
    }

    func endFind() {
        generation += 1
        debounce?.cancel()
        watcher?.invalidate()
        watcher = nil
        query = ""
        result = nil
        lastScreen = nil
        overlay.removeFromSuperview()
    }

    func selectionForFind(_ done: @escaping (String?) -> Void) { done(nil) }

    // MARK: - Searching

    private func search(from cursor: ScrollbackPoint, backward: Bool, reveal: Bool) {
        guard let view else { return }
        generation += 1
        let generation = generation
        let client = view.herdrClient
        let pane = paneID
        let query = query
        inFlight = true
        Task {
            do {
                let found = try await client.searchScrollback(paneID: pane, query: query, from: cursor, backward: backward)
                var scroll = try await client.scrollInfo(paneID: pane)
                if reveal, let match = found.currentMatch, let offset = scroll?.offset(revealing: match.start.row) {
                    scroll = try await client.scroll(paneID: pane, offsetFromBottom: offset) ?? scroll
                }
                self.apply(found, scroll: scroll, generation: generation)
            } catch {
                self.failed(error, generation: generation)
            }
        }
    }

    private func apply(_ found: ScrollbackMatches, scroll: ScrollInfo?, generation: Int) {
        inFlight = false
        guard generation == self.generation else { return refreshIfPending() }
        result = found
        self.scroll = scroll
        onFindStatus?(.matches(current: found.currentGlobal, total: found.total))
        redraw()
        refreshIfPending()
    }

    private func failed(_ error: Error, generation: Int) {
        inFlight = false
        guard generation == self.generation else { return }
        result = nil
        redraw()
        if case let HerdrError.server(code, _) = error, code == "unknown_method" || code == "invalid_request" {
            onFindStatus?(.unavailable("Needs a newer herdr"))
        } else {
            onFindStatus?(.unavailable("Search failed"))
            NSLog("bigtty: terminal search failed: \(error)")
        }
    }

    /// The screen changed: look the matches up again around the current one.
    private func refresh() {
        guard !query.isEmpty else { return }
        if inFlight {
            refreshPending = true
            return
        }
        let cursor = result?.currentMatch.map { ScrollbackMatches.cursor(before: $0.start) }
        // Forward from just before it lands on it again.
        search(from: cursor ?? .end, backward: cursor == nil, reveal: false)
    }

    private func refreshIfPending() {
        guard refreshPending else { return }
        refreshPending = false
        refresh()
    }

    private func startWatching() {
        guard watcher == nil else { return }
        lastScreen = view?.screenText
        watcher = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenMaybeChanged() }
        }
    }

    private func screenMaybeChanged() {
        guard let view, view.window != nil else { return }
        let screen = view.screenText
        guard screen != lastScreen else { return }
        lastScreen = screen
        refresh()
    }

    // MARK: - Highlights

    private func redraw() {
        guard let view else { return }
        if overlay.superview !== view {
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.width, .height]
            view.addSubview(overlay)
        }
        var all: [NSRect] = []
        var current: [NSRect] = []
        if let result, let scroll, let columns = view.gridColumns {
            for (index, match) in result.matches.enumerated() {
                let rects = Self.rects(for: match, scroll: scroll, columns: columns).compactMap {
                    view.cellsRect(column: $0.column, row: $0.line, count: $0.count)
                }
                if index == result.current { current += rects } else { all += rects }
            }
        }
        overlay.matches = all
        overlay.current = current
    }

    /// The on-screen runs of cells a match covers: one per viewport line
    /// (a match can wrap onto the next row).
    nonisolated static func rects(for match: ScrollbackRange, scroll: ScrollInfo, columns: Int) -> [(line: Int, column: Int, count: Int)] {
        guard match.start.row <= match.end.row else { return [] }
        var runs: [(line: Int, column: Int, count: Int)] = []
        for row in match.start.row...match.end.row {
            guard let line = scroll.viewportLine(of: row) else { continue }
            let first = row == match.start.row ? match.start.col : 0
            let last = row == match.end.row ? match.end.col : columns - 1
            if last >= first { runs.append((line: line, column: first, count: last - first + 1)) }
        }
        return runs
    }
}

/// Translucent marks over the terminal's matches; the current one stronger.
final class FindHighlightView: NSView {
    var matches: [NSRect] = [] { didSet { needsDisplay = true } }
    var current: [NSRect] = [] { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.3).setFill()
        for rect in matches { NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill() }
        for rect in current {
            NSColor.systemOrange.withAlphaComponent(0.45).setFill()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2)
            path.fill()
            NSColor.systemOrange.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}
