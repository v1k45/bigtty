@testable import bigtty
import HerdrKit
import Testing

@Suite struct SelectionTrackerTests {
    static func screen(bottom: Int) -> [String] { (bottom - 9...bottom).map { "line \($0)" } }

    @Test func stillTextLeavesGhosttysSelectionAlone() {
        let tracker = SelectionTracker()
        tracker.start(PinnedSelection(startRow: 3, startColumn: 0, endRow: 3, endColumn: 6, text: "line 33"), screen: Self.screen(bottom: 39))
        var changed = Self.screen(bottom: 39)
        changed[9] = "line 39 and more"
        #expect(tracker.screenChanged(changed) == nil)
        #expect(tracker.movedSelection == nil)
    }

    @Test func scrolledTextTakesTheSelectionAlong() throws {
        let tracker = SelectionTracker()
        tracker.start(PinnedSelection(startRow: 3, startColumn: 0, endRow: 3, endColumn: 6, text: "line 33"), screen: Self.screen(bottom: 39))
        tracker.scrolled(movingTextUp: -4)
        guard case let .moved(selection, first) = try #require(tracker.screenChanged(Self.screen(bottom: 35))) else {
            Issue.record("expected a move")
            return
        }
        #expect(first)
        #expect(selection.startRow == 7)
        // Off the bottom, then back where it started.
        _ = tracker.screenChanged(Self.screen(bottom: 31))
        #expect(tracker.movedSelection?.startRow == 11)
        guard case let .moved(back, again) = try #require(tracker.screenChanged(Self.screen(bottom: 39))) else {
            Issue.record("expected a move")
            return
        }
        #expect(!again)
        #expect(back.startRow == 3)
        // Copy still gives what was selected.
        #expect(tracker.movedSelection?.text == "line 33")
    }

    @Test func aReplacedScreenDropsIt() throws {
        let tracker = SelectionTracker()
        tracker.start(PinnedSelection(startRow: 3, startColumn: 0, endRow: 3, endColumn: 6, text: "line 33"), screen: Self.screen(bottom: 39))
        guard case .lost = try #require(tracker.screenChanged(Array(repeating: "", count: 10))) else {
            Issue.record("expected lost")
            return
        }
        #expect(!tracker.isTracking)
    }
}
