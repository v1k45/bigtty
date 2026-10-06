import Foundation
@testable import HerdrKit
import Testing

@Suite struct ScrollbackSearchTests {
    /// 5002 rows, 40 on screen, scrolled 100 up: rows 4862–4901 show.
    let scrolled = ScrollInfo(offsetFromBottom: 100, maxOffsetFromBottom: 4962, viewportRows: 40)

    @Test func viewportPosition() {
        #expect(scrolled.totalRows == 5002)
        #expect(scrolled.topRow == 4862)
        #expect(scrolled.viewportLine(of: 4862) == 0)
        #expect(scrolled.viewportLine(of: 4901) == 39)
        #expect(scrolled.viewportLine(of: 4902) == nil)
        #expect(scrolled.viewportLine(of: 4861) == nil)
    }

    @Test func revealScrollsOnlyWhenOffScreen() {
        #expect(scrolled.offset(revealing: 4870) == nil)
        // Centred: row 1000 lands on the viewport's middle line.
        let offset = try! #require(scrolled.offset(revealing: 1000))
        var moved = scrolled
        moved.offsetFromBottom = offset
        #expect(moved.viewportLine(of: 1000) == 20)
        // Clamped at both ends.
        #expect(scrolled.offset(revealing: 0) == 4962)
        let bottom = ScrollInfo(offsetFromBottom: 4962, maxOffsetFromBottom: 4962, viewportRows: 40)
        #expect(bottom.offset(revealing: 5001) == 0)
    }

    @Test func decodesSearchAnswer() throws {
        let json = #"""
        {"type":"pane_copy_search","pane_id":"w1:p1","content_revision":5358,
         "matches":[{"start":{"row":3,"col":7},"end":{"row":3,"col":13}},
                    {"start":{"row":10,"col":8},"end":{"row":11,"col":2}}],
         "total":714,"current":1,"current_global":713}
        """#
        let found = try JSONDecoder().decode(ScrollbackMatches.self, from: Data(json.utf8))
        #expect(found.total == 714)
        #expect(found.currentGlobal == 713)
        #expect(found.currentMatch == ScrollbackRange(start: .init(row: 10, col: 8), end: .init(row: 11, col: 2)))

        let none = try JSONDecoder().decode(ScrollbackMatches.self, from: Data(#"{"matches":[],"total":0}"#.utf8))
        #expect(none.currentMatch == nil)
    }

    @Test func cursorJustBeforeAMatch() {
        #expect(ScrollbackMatches.cursor(before: .init(row: 4, col: 3)) == .init(row: 4, col: 2))
        #expect(ScrollbackMatches.cursor(before: .init(row: 4, col: 0)) == .init(row: 3, col: Int(UInt16.max)))
        #expect(ScrollbackMatches.cursor(before: .init(row: 0, col: 0)) == .init(row: 0, col: 0))
    }
}
