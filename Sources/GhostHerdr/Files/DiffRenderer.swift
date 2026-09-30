import AppKit

/// Turns `git diff` output into colored, full-width lines with old/new line
/// numbers in the gutter.
@MainActor
enum DiffRenderer {
    static func render(_ diff: String, dark: Bool) -> NSAttributedString {
        let font = CodeView.font
        let text = dark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        let dim = NSColor.secondaryLabelColor
        let added = NSColor.systemGreen.withAlphaComponent(dark ? 0.18 : 0.14)
        let removed = NSColor.systemRed.withAlphaComponent(dark ? 0.2 : 0.14)
        let hunk = NSColor.systemBlue.withAlphaComponent(dark ? 0.16 : 0.1)

        let out = NSMutableAttributedString()
        var oldLine = 0
        var newLine = 0
        let hunkPattern = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

        func append(_ line: String, color: NSColor, background: NSColor?, label: String) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .gutterLabel: label]
            if let background { attributes[.lineBackground] = background }
            out.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ") || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename ") || line.hasPrefix("old mode")
                || line.hasPrefix("new mode")
            {
                continue
            }
            if line.hasPrefix("@@") {
                if let match = hunkPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    oldLine = Int((line as NSString).substring(with: match.range(at: 1))) ?? 0
                    newLine = Int((line as NSString).substring(with: match.range(at: 2))) ?? 0
                }
                append(line, color: dim, background: hunk, label: "⋯")
            } else if line.hasPrefix("+") {
                append(line, color: text, background: added, label: "\(newLine)")
                newLine += 1
            } else if line.hasPrefix("-") {
                append(line, color: text, background: removed, label: "\(oldLine)")
                oldLine += 1
            } else if line.hasPrefix("\\") {
                append(line, color: dim, background: nil, label: "")
            } else if !line.isEmpty || oldLine > 0 {
                append(line, color: text, background: nil, label: "\(newLine)")
                oldLine += 1
                newLine += 1
            }
        }
        if out.length == 0 {
            out.append(NSAttributedString(string: "No changes\n", attributes: [.font: font, .foregroundColor: dim, .gutterLabel: ""]))
        }
        return out
    }
}
