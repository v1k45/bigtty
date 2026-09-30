import AppKit

/// A small regex highlighter: comments, strings, numbers, keywords and
/// types for common languages. Not a parser, but fast and dependency-free.
enum SyntaxHighlighter {
    struct Palette {
        let text: NSColor
        let comment: NSColor
        let string: NSColor
        let number: NSColor
        let keyword: NSColor
        let type: NSColor

        static func make(dark: Bool) -> Palette {
            dark
                ? Palette(
                    text: NSColor(white: 0.86, alpha: 1), comment: NSColor(white: 0.5, alpha: 1),
                    string: NSColor(srgbRed: 0.65, green: 0.85, blue: 0.55, alpha: 1),
                    number: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.47, alpha: 1),
                    keyword: NSColor(srgbRed: 0.8, green: 0.6, blue: 0.95, alpha: 1),
                    type: NSColor(srgbRed: 0.55, green: 0.8, blue: 0.95, alpha: 1)
                )
                : Palette(
                    text: NSColor(white: 0.12, alpha: 1), comment: NSColor(white: 0.5, alpha: 1),
                    string: NSColor(srgbRed: 0.15, green: 0.5, blue: 0.15, alpha: 1),
                    number: NSColor(srgbRed: 0.7, green: 0.4, blue: 0.1, alpha: 1),
                    keyword: NSColor(srgbRed: 0.55, green: 0.2, blue: 0.7, alpha: 1),
                    type: NSColor(srgbRed: 0.1, green: 0.4, blue: 0.65, alpha: 1)
                )
        }
    }

    struct Language {
        let keywords: Set<String>
        let lineComment: [String]
        let blockComment: (String, String)?
    }

    private static let cLike: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
        "true", "false", "null", "nil", "new", "this", "self", "super", "class", "struct", "enum",
        "interface", "public", "private", "protected", "static", "const", "let", "var", "func", "function",
        "import", "export", "from", "as", "try", "catch", "throw", "throws", "async", "await", "in", "of",
        "extends", "implements", "typeof", "instanceof", "void", "yield", "package", "type",
    ]

    static func language(for path: String) -> Language? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift":
            return Language(keywords: cLike.union(["guard", "defer", "extension", "protocol", "init", "deinit",
                                                  "where", "some", "any", "inout", "override", "final", "mutating",
                                                  "fileprivate", "internal", "open", "weak", "lazy", "case", "repeat",
                                                  "Self", "is", "actor", "nonisolated", "isolated", "consuming"]),
                            lineComment: ["//"], blockComment: ("/*", "*/"))
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "dart", "scala":
            return Language(keywords: cLike.union(["undefined", "delete", "finally", "with", "debugger", "int",
                                                  "long", "char", "float", "double", "bool", "boolean", "unsigned",
                                                  "sizeof", "typedef", "namespace", "using", "template", "fun", "val",
                                                  "object", "when", "readonly", "declare", "keyof", "abstract"]),
                            lineComment: ["//"], blockComment: ("/*", "*/"))
        case "go":
            return Language(keywords: cLike.union(["go", "chan", "select", "defer", "range", "map", "fallthrough",
                                                  "goto", "struct", "iota"]), lineComment: ["//"], blockComment: ("/*", "*/"))
        case "rs":
            return Language(keywords: cLike.union(["fn", "mut", "impl", "trait", "pub", "crate", "mod", "use",
                                                  "match", "loop", "where", "move", "ref", "dyn", "unsafe", "Self",
                                                  "Some", "None", "Ok", "Err"]), lineComment: ["//"], blockComment: ("/*", "*/"))
        case "py":
            return Language(keywords: ["def", "class", "if", "elif", "else", "for", "while", "return", "import",
                                       "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield",
                                       "True", "False", "None", "and", "or", "not", "in", "is", "pass", "break",
                                       "continue", "global", "nonlocal", "async", "await", "self"],
                            lineComment: ["#"], blockComment: nil)
        case "rb":
            return Language(keywords: ["def", "class", "module", "if", "elsif", "else", "unless", "end", "do",
                                       "while", "return", "require", "true", "false", "nil", "self", "yield", "begin",
                                       "rescue", "ensure", "then", "case", "when"], lineComment: ["#"], blockComment: nil)
        case "sh", "bash", "zsh", "fish":
            return Language(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                                       "case", "esac", "function", "return", "export", "local", "set", "echo"],
                            lineComment: ["#"], blockComment: nil)
        case "yml", "yaml", "toml", "ini", "conf":
            return Language(keywords: ["true", "false", "null", "yes", "no"], lineComment: ["#"], blockComment: nil)
        case "json", "jsonc":
            return Language(keywords: ["true", "false", "null"], lineComment: ["//"], blockComment: nil)
        case "sql":
            return Language(keywords: ["select", "from", "where", "insert", "into", "update", "delete", "create",
                                       "table", "join", "left", "right", "inner", "on", "group", "by", "order",
                                       "limit", "and", "or", "not", "null", "as", "values", "set", "SELECT", "FROM",
                                       "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN", "ON",
                                       "GROUP", "BY", "ORDER", "LIMIT", "AND", "OR", "NOT", "NULL", "AS"],
                            lineComment: ["--"], blockComment: ("/*", "*/"))
        case "css", "scss", "less":
            return Language(keywords: ["important"], lineComment: [], blockComment: ("/*", "*/"))
        case "html", "htm", "xml", "svg", "vue", "svelte":
            return Language(keywords: [], lineComment: [], blockComment: ("<!--", "-->"))
        default:
            return nil
        }
    }

    /// Colors `storage` in place.
    static func highlight(_ storage: NSTextStorage, path: String, palette: Palette, font: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: palette.text, .font: font], range: full)
        guard let language = language(for: path), storage.length < 400_000 else {
            storage.endEditing()
            return
        }
        let text = storage.string as NSString

        func color(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }

        color(#"\b[0-9][0-9_]*(\.[0-9]+)?([eE][+-]?[0-9]+)?\b|\b0x[0-9a-fA-F]+\b"#, palette.number)
        color(#"\b[A-Z][A-Za-z0-9_]*\b"#, palette.type)
        if !language.keywords.isEmpty {
            let words = language.keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            color("\\b(\(words))\\b", palette.keyword)
        }
        // Strings and comments last, so they win over keywords inside them.
        color(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#, palette.string)
        for marker in language.lineComment {
            color(NSRegularExpression.escapedPattern(for: marker) + #".*$"#, palette.comment, options: .anchorsMatchLines)
        }
        if let (open, close) = language.blockComment {
            color(NSRegularExpression.escapedPattern(for: open) + #"[\s\S]*?"# + NSRegularExpression.escapedPattern(for: close), palette.comment)
        }
        _ = text
        storage.endEditing()
    }
}
