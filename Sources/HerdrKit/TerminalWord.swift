import Foundation

/// The link or path under a ⌘-click in a terminal, read from the viewport's
/// rows. Ghostty finds links within one row; a URL or path wrapped onto more
/// rows (by the terminal, or by an app like Claude Code that breaks long
/// lines a little short of the edge and indents the rest) is read whole here.
public enum TerminalWord {
    /// The path-like word (has a dot or a slash) at a cell, joined across
    /// wrapped rows where it carries on.
    public static func at(column: Int, row: Int, lines: [String], width: Int) -> String? {
        let lines = lines.map { Array($0) }
        guard row >= 0, row < lines.count, column >= 0, column < lines[row].count else { return nil }
        let chars = lines[row]
        guard ok(chars[column]) else { return nil }
        var start = column, end = column
        while start > 0, ok(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, ok(chars[end + 1]) { end += 1 }
        var word = String(chars[start...end])

        // A row wrapped if its text runs to within a few columns of the edge.
        let width = max(width, lines.map(\.count).max() ?? 0)
        let nearEdge = max(0, width - 12)
        func lastText(_ line: [Character]) -> Int? { line.lastIndex { !$0.isWhitespace } }
        func firstText(_ line: [Character]) -> Int? { line.firstIndex { !$0.isWhitespace } }
        // Onward: the word ends its row, the row reaches the edge, and the
        // next row (after its indent) starts with more of it. Not a lone
        // "-" or "." (the next list item, or the sentence's end) and not
        // another URL.
        var r = row, e = end
        while r + 1 < lines.count, lastText(lines[r]) == e, e >= nearEdge,
              let first = firstText(lines[r + 1]), ok(lines[r + 1][first]) {
            let next = lines[r + 1]
            var ne = first
            while ne + 1 < next.count, ok(next[ne + 1]) { ne += 1 }
            let more = String(next[first...ne])
            guard continues(more, after: word) else { break }
            word += more
            r += 1
            e = ne
        }
        // Back: the word starts its row, and the row above ends at the edge
        // in the middle of it. A URL starts at its scheme, so nothing goes
        // before one ("props:" ending the row above).
        r = row
        var s = start
        while scheme(of: word) == nil, r > 0, firstText(lines[r]) == s,
              let last = lastText(lines[r - 1]), last >= nearEdge, ok(lines[r - 1][last]) {
            let previous = lines[r - 1]
            var ps = last
            while ps > 0, ok(previous[ps - 1]) { ps -= 1 }
            let before = String(previous[ps...last])
            guard before.contains(where: { $0.isLetter || $0.isNumber }) else { break }
            word = before + word
            r -= 1
            s = ps
        }
        word = trimmed(word.trimmingCharacters(in: CharacterSet(charactersIn: ".:,")))
        guard word.count > 1, word.contains(".") || word.contains("/") else { return nil }
        return word
    }

    /// What a ⌘-click opens: the whole wrapped word when Ghostty's one-row
    /// link is part of it, otherwise Ghostty's link; either way without
    /// the sentence's punctuation after it.
    public static func link(ghostty url: String, whole: String?) -> String {
        let url = trimmed(url)
        if let whole, whole.count > url.count, whole.contains(url) { return whole }
        return url
    }

    /// Drops punctuation that ends the sentence or wraps the link, not the
    /// link: `https://x.y/a).` → `https://x.y/a`. A closing bracket stays
    /// when the link opened it (`https://en.wikipedia.org/wiki/Foo_(bar)`).
    public static func trimmed(_ text: String) -> String {
        var text = text
        while let last = text.last {
            if ".,;:!?'\"".contains(last) {
                text.removeLast()
            } else if let open = ["(": ")", "[": "]"].first(where: { $0.value == String(last) })?.key,
                      text.filter({ String($0) == open }).count < text.filter({ $0 == last }).count {
                text.removeLast()
            } else {
                break
            }
        }
        return text
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/~+@:#?=&%"))
    private static func ok(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { allowed.contains($0) } }

    /// Whether a fragment from the neighbouring row can be more of the
    /// word: it has a letter or digit, and isn't a URL of its own.
    private static func continues(_ fragment: String, after word: String) -> Bool {
        fragment.contains { $0.isLetter || $0.isNumber }
            && scheme(of: fragment) == nil
            && !(word.contains("://") && fragment.contains("://"))
    }

    /// The schemes Ghostty makes links of.
    private static let schemes = ["https://", "http://", "mailto:", "ftp://", "file:", "ssh:", "git://", "tel:",
                                  "magnet:", "ipfs://", "ipns://", "gemini://", "gopher://", "news:"]

    private static func scheme(of word: String) -> String? {
        let lower = word.lowercased()
        return schemes.first { lower.hasPrefix($0) }
    }
}
