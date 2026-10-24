import Foundation
@testable import HerdrKit
import Testing

@Suite struct PinnedSelectionTests {
    /// 100 lines of output, `rows` of them on screen, the last on screen
    /// being `bottom`.
    static func screen(bottom: Int, rows: Int = 10) -> [String] {
        (bottom - rows + 1...bottom).map { $0 >= 0 ? "output line \($0)" : "" }
    }

    @Test func fromGhosttyOffsets() {
        // Row 2 column 5 to row 3 column 1, 80 columns.
        let selection = PinnedSelection(offset: 2 * 80 + 5, length: 80 - 4, columns: 80, text: "x")
        #expect(selection == PinnedSelection(startRow: 2, startColumn: 5, endRow: 3, endColumn: 1, text: "x"))
        #expect(PinnedSelection(offset: 0, length: 0, columns: 0, text: "") == nil)
    }

    @Test func runsClipToTheScreen() {
        let selection = PinnedSelection(startRow: 1, startColumn: 4, endRow: 3, endColumn: 2, text: "")
        #expect(selection.runs(rows: 10, columns: 20).map { [$0.line, $0.column, $0.count] } == [[1, 4, 16], [2, 0, 20], [3, 0, 3]])
        // Its top scrolled off: the rest still shows from column 0.
        #expect(selection.movedUp(2).runs(rows: 10, columns: 20).map { [$0.line, $0.column, $0.count] } == [[0, 0, 20], [1, 0, 3]])
        #expect(selection.movedUp(5).runs(rows: 10, columns: 20).isEmpty)
        #expect(selection.movedUp(-8).runs(rows: 10, columns: 20).map { [$0.line, $0.column, $0.count] } == [[9, 4, 16]])
    }

    @Test func scrollingBackMovesTheTextDown() {
        #expect(ScreenShift.rows(from: Self.screen(bottom: 99), to: Self.screen(bottom: 96)) == -3)
        #expect(ScreenShift.rows(from: Self.screen(bottom: 96), to: Self.screen(bottom: 99)) == 3)
        #expect(ScreenShift.rows(from: Self.screen(bottom: 50), to: Self.screen(bottom: 50)) == 0)
    }

    @Test func newOutputMovesTheTextUp() {
        var old = Self.screen(bottom: 40)
        old[9] = "$ "
        var new = Self.screen(bottom: 42)
        new[9] = "$ "
        #expect(ScreenShift.rows(from: old, to: new) == 2)
    }

    @Test func outputBelowAShortScreenDoesNotMoveIt() {
        let old = ["$ ls", "a", "b", "$ ", "", "", "", "", "", ""]
        let new = ["$ ls", "a", "b", "$ echo hi", "hi", "$ ", "", "", "", ""]
        #expect(ScreenShift.rows(from: old, to: new) == 0)
    }

    @Test func aFixedFooterStillLinesUp() {
        // An app scrolls the text between a header and a footer it keeps.
        func app(_ bottom: Int) -> [String] { ["header"] + Self.screen(bottom: bottom, rows: 12) + ["footer", "status"] }
        #expect(ScreenShift.rows(from: app(60), to: app(55)) == -5)
    }

    @Test func aReplacedScreenDoesNotLineUp() {
        let other = (0..<10).map { "something else \($0)" }
        #expect(ScreenShift.rows(from: Self.screen(bottom: 30), to: other) == nil)
        // A jump of a screen or more: nothing lines up, so the scrolling says.
        #expect(ScreenShift.rows(from: Self.screen(bottom: 90), to: Self.screen(bottom: 60), expected: -30) == -30)
    }

    @Test func equalFitsGoTheWayTheScrollingAsked() {
        // Alternating lines fit one row up as well as one row down.
        let old = (0..<10).map { $0 % 2 == 0 ? "a" : "b" }
        let new = (0..<10).map { $0 % 2 == 0 ? "b" : "a" }
        #expect(ScreenShift.rows(from: old, to: new, expected: 1) == 1)
        #expect(ScreenShift.rows(from: old, to: new, expected: -1) == -1)
    }

    /// Selected on screen, scrolled out of view and back a few lines at a
    /// time: it lands on the same text, as the screens would show it.
    @Test func followsTheTextOutOfViewAndBack() {
        var bottom = 99
        var screen = Self.screen(bottom: bottom)
        // "output line 95" sits on line 5.
        var selection = PinnedSelection(startRow: 5, startColumn: 0, endRow: 6, endColumn: 13, text: "output line 95")
        for step in [-3, -4, -5, -3, 5, 4, 6] {
            bottom += step
            let next = Self.screen(bottom: bottom)
            let shift = try! #require(ScreenShift.rows(from: screen, to: next, expected: step))
            selection = selection.movedUp(shift)
            screen = next
        }
        #expect(bottom == 99)
        #expect(selection.startRow == 5)
        #expect(screen[selection.startRow] == "output line 95")
    }
}
