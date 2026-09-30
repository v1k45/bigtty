import Foundation

/// A path someone ⌘-clicked in a terminal, as Ghostty hands it over:
/// `/abs/file.png`, `src/app.py:12:5`, `~/notes.md`, `file:///x/y`, or text
/// with trailing punctuation from the sentence it sat in.
public struct ClickedPath: Equatable, Sendable {
    public let path: String
    public let line: Int?

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quotes or brackets around it, punctuation after it, in any order.
        var previous = ""
        while previous != text {
            previous = text
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>()[]{}"))
            while let last = text.last, ".,;!?".contains(last) { text.removeLast() }
        }
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { return nil }
            text = url.path
            if let fragment = url.fragment, fragment.hasPrefix("L"), let n = Int(fragment.dropFirst()) {
                self.init(path: text, line: n)
                return
            }
        } else if let colon = text.range(of: "://"), !text[..<colon.lowerBound].contains("/") {
            return nil // another scheme: not a path
        } else if text.contains(":"), !text.hasPrefix("/"), !text.hasPrefix("."), !text.hasPrefix("~"),
                  let first = text.split(separator: ":").first, !first.contains("/"), !first.contains(".") {
            return nil // mailto:x, tel:… — a scheme, not a file
        }

        // path:line or path:line:col
        var line: Int?
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2, let n = Int(parts[1]), parts.count == 2 || (parts.count == 3 && Int(parts[2]) != nil) {
            text = parts[0]
            line = n
        }
        guard !text.isEmpty else { return nil }
        self.init(path: text, line: line)
    }

    public init(path: String, line: Int?) {
        self.path = path
        self.line = line
    }

    /// Absolute, with `~` and relative paths resolved on the pane's machine.
    public func resolved(cwd: String, home: String?) -> String {
        var result = path
        if result == "~" || result.hasPrefix("~/"), let home {
            result = home + result.dropFirst()
        } else if !result.hasPrefix("/") {
            result = (cwd as NSString).appendingPathComponent(result)
        }
        return (result as NSString).standardizingPath
    }
}
