import Foundation

/// A text selection in a terminal screen that something else redraws (herdr
/// paints its scrollback into the surface, so the surface itself never
/// scrolls). Rows count from the screen's first line and may fall off
/// either edge, so the selection can follow its text out of view and back.
public struct PinnedSelection: Sendable, Equatable {
    /// First and last selected cells (inclusive).
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int
    /// The text as it was when selected, for copying while it's off screen.
    public var text: String

    public init(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int, text: String) {
        self.startRow = startRow
        self.startColumn = startColumn
        self.endRow = endRow
        self.endColumn = endColumn
        self.text = text
    }

    /// From Ghostty's viewport cell offsets (`row * columns + column`) of
    /// the first and last selected cells.
    public init?(offset: Int, length: Int, columns: Int, text: String) {
        guard columns > 0, offset >= 0, length >= 0 else { return nil }
        let end = offset + length
        self.init(startRow: offset / columns, startColumn: offset % columns,
                  endRow: end / columns, endColumn: end % columns, text: text)
    }

    /// The same text after the screen's content moved up `rows` (down when
    /// negative).
    public func movedUp(_ rows: Int) -> PinnedSelection {
        var moved = self
        moved.startRow -= rows
        moved.endRow -= rows
        return moved
    }

    /// The on-screen runs of selected cells, one per visible line.
    public func runs(rows: Int, columns: Int) -> [(line: Int, column: Int, count: Int)] {
        let top = max(startRow, 0), bottom = min(endRow, rows - 1)
        guard columns > 0, top <= bottom else { return [] }
        var runs: [(line: Int, column: Int, count: Int)] = []
        for line in top...bottom {
            let first = line == startRow ? startColumn : 0
            let last = line == endRow ? min(endColumn, columns - 1) : columns - 1
            if last >= first { runs.append((line: line, column: first, count: last - first + 1)) }
        }
        return runs
    }
}

/// How far a screen's content moved between two snapshots of it.
public enum ScreenShift {
    /// The rows the content moved up from `old` to `new` (new output, or
    /// scrolling toward the bottom), negative when it moved down (scrolling
    /// back), or nil when the two screens don't line up. `expected` (what
    /// the scrolling asked for) breaks ties between equally good fits, and
    /// stands in when nothing lines up, as after a jump of a screen or more.
    ///
    /// A fit compares the lines both screens still show: it needs more of
    /// them to agree than to differ, and blank lines don't count as agreeing.
    /// A fixed header or footer (an app's status bar) only costs a few
    /// disagreements, so the text scrolling between them still lines up.
    public static func rows(from old: [String], to new: [String], expected: Int = 0) -> Int? {
        let count = old.count
        guard count == new.count, count > 0 else { return nil }
        if old == new { return 0 }
        let a = old.map { $0.trimmingCharacters(in: .whitespaces) }
        let b = new.map { $0.trimmingCharacters(in: .whitespaces) }
        var best: (shift: Int, score: Int)?
        for shift in -(count - 1)...(count - 1) {
            var agree = 0, differ = 0
            for line in max(0, -shift)..<min(count, count - shift) {
                let then = a[line + shift], now = b[line]
                if then == now {
                    if !now.isEmpty { agree += 1 }
                } else if !then.isEmpty {
                    // (Output landing on blank lines isn't a disagreement.)
                    differ += 1
                }
            }
            guard agree > 0, agree > differ else { continue }
            let score = agree - differ
            if let current = best {
                let closer = abs(shift - expected) < abs(current.shift - expected)
                guard score > current.score || score == current.score && closer else { continue }
            }
            best = (shift, score)
        }
        if let best { return best.shift }
        return expected != 0 ? expected : nil
    }
}
