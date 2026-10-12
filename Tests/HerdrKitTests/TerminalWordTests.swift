import HerdrKit
import Testing

struct TerminalWordTests {
    /// A bulleted list printed as one long line, each item padded so the
    /// next one starts after a gap: the terminal wraps it wherever the
    /// width falls, so a URL may end a row, run into the next one, or have
    /// the next item's "-" waiting at the start of the next row.
    static let urls = [
        "https://github.com/org/repo/issues/111",
        "https://github.com/org/repo/issues/222",
        "https://github.com/org/repo/issues/333",
    ]
    static let list = "  - #111 Foo thing: \(urls[0])     - #222 Bar props: \(urls[1])     - #333 Baz: \(urls[2])"

    /// Rows of a terminal `width` wide holding `text`, soft-wrapped.
    static func rows(_ text: String, width: Int, trimTrailing: Bool) -> [String] {
        let chars = Array(text)
        return stride(from: 0, to: chars.count, by: width).map { start in
            var row = String(chars[start ..< min(start + width, chars.count)])
            while trimTrailing, row.last == " " { row.removeLast() }
            return row
        }
    }

    @Test(arguments: 30 ... 140)
    func eachWrappedURLOpensExactlyItself(width: Int) throws {
        for trimTrailing in [false, true] {
            let lines = Self.rows(Self.list, width: width, trimTrailing: trimTrailing)
            for url in Self.urls {
                let offset = try #require(Self.list.range(of: url)).lowerBound.utf16Offset(in: Self.list)
                for i in 0 ..< url.count {
                    let at = offset + i
                    let word = TerminalWord.at(column: at % width, row: at / width, lines: lines, width: width)
                    #expect(word == url, "width \(width), clicked \(url) at \(i), trimmed rows: \(trimTrailing)")
                }
            }
        }
    }

    @Test func doesNotGlueTheNextItemsDash() {
        // The URL ends near the edge; the padding wraps and the next row
        // starts with the next item.
        let lines = [
            "  - #222 Bar props: https://github.com/org/repo/issues/222   ",
            "  - #333 Baz: https://github.com/org/repo/issues/333",
        ]
        #expect(TerminalWord.at(column: 30, row: 0, lines: lines, width: 60) == "https://github.com/org/repo/issues/222")
        #expect(TerminalWord.at(column: 20, row: 1, lines: lines, width: 60) == "https://github.com/org/repo/issues/333")
    }

    @Test func nothingGoesBeforeAURLsScheme() {
        let lines = [
            "  - #222 Bar props:",
            "https://github.com/org/repo/issues/222",
        ]
        #expect(TerminalWord.at(column: 3, row: 1, lines: lines, width: 19) == "https://github.com/org/repo/issues/222")
    }

    @Test func joinsAURLHardSplitByTheWrap() {
        let lines = [
            "see https://github.com/org/re",
            "po/issues/222 for details",
        ]
        let whole = "https://github.com/org/repo/issues/222"
        #expect(TerminalWord.at(column: 10, row: 0, lines: lines, width: 29) == whole)
        #expect(TerminalWord.at(column: 3, row: 1, lines: lines, width: 29) == whole)
        // Split right after the scheme.
        let atScheme = ["the issue is at https:", "//github.com/org/repo/issues/222"]
        #expect(TerminalWord.at(column: 18, row: 0, lines: atScheme, width: 32) == whole)
        #expect(TerminalWord.at(column: 5, row: 1, lines: atScheme, width: 32) == whole)
        // Split inside the scheme, after another word ending in a colon.
        let inScheme = ["  - #222 Bar thing props: htt", "ps://github.com/org/repo/issues/222"]
        #expect(TerminalWord.at(column: 27, row: 0, lines: inScheme, width: 35) == whole)
        #expect(TerminalWord.at(column: 5, row: 1, lines: inScheme, width: 35) == whole)
    }

    @Test func joinsAPathAnAppWrappedShortAndIndented() {
        let lines = [
            "⏺ Saved the screenshot to /Users/me/projects/some-long-project/scree",
            "  nshots/workspace.png",
        ]
        let whole = "/Users/me/projects/some-long-project/screenshots/workspace.png"
        #expect(TerminalWord.at(column: 30, row: 0, lines: lines, width: 72) == whole)
        #expect(TerminalWord.at(column: 4, row: 1, lines: lines, width: 72) == whole)
    }

    @Test func prefersTheWholeWrappedLinkOverGhosttysRow() {
        let whole = "https://github.com/org/repo/issues/222"
        #expect(TerminalWord.link(ghostty: "https://github.com/org/re", whole: whole) == whole)
        #expect(TerminalWord.link(ghostty: whole, whole: whole) == whole)
        #expect(TerminalWord.link(ghostty: whole + ").", whole: nil) == whole)
        #expect(TerminalWord.link(ghostty: "https://example.com/other", whole: whole) == "https://example.com/other")
    }

    @Test func dropsTrailingPunctuation() {
        let url = "https://github.com/org/repo/issues/222"
        for end in [".", ",", ";", ":", ")", "]", "'", "\"", ").", "\");", "]:", "!", "?"] {
            #expect(TerminalWord.trimmed(url + end) == url, "\(end)")
        }
        #expect(TerminalWord.trimmed("https://en.wikipedia.org/wiki/Foo_(bar)") == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(TerminalWord.trimmed("https://en.wikipedia.org/wiki/Foo_(bar)).") == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(TerminalWord.trimmed("https://example.com/a?b=1&c=2") == "https://example.com/a?b=1&c=2")
    }
}
