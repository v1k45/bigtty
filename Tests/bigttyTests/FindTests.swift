import AppKit
@testable import bigtty
import HerdrKit
import Testing

@Suite struct TextSearchTests {
    @Test func findsEveryMatchIgnoringCase() {
        let text = "Foo bar foo FOO fóo" as NSString
        #expect(TextSearch.ranges(of: "foo", in: text).map(\.location) == [0, 8, 12, 16])
        #expect(TextSearch.ranges(of: "", in: text).isEmpty)
        #expect(TextSearch.ranges(of: "foo", in: text, limit: 2).count == 2)
        #expect(TextSearch.ranges(of: "aa", in: "aaaa").map(\.location) == [0, 2])
    }

    @Test func startsAtTheFirstMatchFromHere() {
        let ranges = [NSRange(location: 2, length: 1), NSRange(location: 9, length: 1)]
        #expect(TextSearch.index(after: 0, in: ranges) == 0)
        #expect(TextSearch.index(after: 5, in: ranges) == 1)
        #expect(TextSearch.index(after: 12, in: ranges) == 0)
        #expect(TextSearch.index(after: 0, in: []) == nil)
    }

    @Test func statusLabels() {
        #expect(FindStatus.matches(current: 2, total: 12).label == "3 of 12")
        #expect(FindStatus.matches(current: nil, total: 0).label == "No matches")
        #expect(FindStatus.matches(current: nil, total: 4).label == "4 matches")
        #expect(FindStatus.idle.label.isEmpty)
    }
}

@Suite struct TerminalHighlightTests {
    let scroll = ScrollInfo(offsetFromBottom: 0, maxOffsetFromBottom: 80, viewportRows: 20)

    @Test func matchOnScreenIsOneRun() {
        let match = ScrollbackRange(start: .init(row: 90, col: 4), end: .init(row: 90, col: 9))
        let runs = TerminalFinder.rects(for: match, scroll: scroll, columns: 40)
        #expect(runs.map(\.line) == [10])
        #expect(runs.map(\.column) == [4])
        #expect(runs.map(\.count) == [6])
    }

    @Test func wrappedMatchSpansRows() {
        let match = ScrollbackRange(start: .init(row: 85, col: 36), end: .init(row: 86, col: 2))
        let runs = TerminalFinder.rects(for: match, scroll: scroll, columns: 40)
        #expect(runs.map(\.line) == [5, 6])
        #expect(runs.map(\.column) == [36, 0])
        #expect(runs.map(\.count) == [4, 3])
    }

    @Test func offScreenMatchDrawsNothing() {
        let match = ScrollbackRange(start: .init(row: 10, col: 0), end: .init(row: 10, col: 3))
        #expect(TerminalFinder.rects(for: match, scroll: scroll, columns: 40).isEmpty)
    }
}

@MainActor @Suite struct CodeFinderTests {
    func code(_ text: String) -> CodeView {
        let view = CodeView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.showAttributed(NSAttributedString(string: text), identity: "test")
        return view
    }

    @Test func findsStepsAndWraps() {
        let view = code("alpha\nbeta alpha\ngamma ALPHA\n")
        var status: FindStatus = .idle
        view.finder.onFindStatus = { status = $0 }
        view.finder.find("alpha")
        #expect(status == .matches(current: 0, total: 3))
        view.finder.findNext(backwards: false)
        #expect(status == .matches(current: 1, total: 3))
        view.finder.findNext(backwards: false)
        view.finder.findNext(backwards: false)
        #expect(status == .matches(current: 0, total: 3))
        view.finder.findNext(backwards: true)
        #expect(status == .matches(current: 2, total: 3))
    }

    @Test func reloadedTextIsSearchedAgain() {
        let view = code("one two\n")
        var status: FindStatus = .idle
        view.finder.onFindStatus = { status = $0 }
        view.finder.find("two")
        #expect(status == .matches(current: 0, total: 1))
        // The current match (at 4) stays current.
        view.showAttributed(NSAttributedString(string: "two two three\n"), identity: "test")
        #expect(status == .matches(current: 1, total: 2))
        view.finder.endFind()
        #expect(status == .idle)
        #expect(view.finder.ranges.isEmpty)
    }
}
