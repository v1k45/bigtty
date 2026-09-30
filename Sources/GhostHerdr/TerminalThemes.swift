import AppKit
import GhosttyTerminal

/// Terminal color themes, each a light and dark pair that follows the
/// system appearance. Colors are the published palettes of each theme.
/// "Ghostty config" applies no theme, so the user's own config decides.
struct TerminalThemeChoice: Sendable {
    let id: String
    let name: String
    /// background, foreground, cursor, selection, then palette 0–15.
    let dark: [String]?
    let light: [String]?

    static let ghosttyConfig = "ghostty-config"
    static let defaultID = "ghostherdr"

    static let all: [TerminalThemeChoice] = [
        .init(
            id: "ghostherdr", name: "GhostHerdr",
            // Neutral macOS grays, palette tuned so every color reads on the background.
            dark: ["1c1c1f", "e8e8ed", "e8e8ed", "3a4a66",
                   "48484e", "ff6b63", "4fd66a", "ffd43b", "5aa9ff", "d68bff", "5ad4e6", "d1d1d6",
                   "8e8e96", "ff8a82", "7ee68f", "ffe16b", "85c0ff", "e3a8ff", "8ae3f0", "f5f5f7"],
            light: ["ffffff", "1d1d1f", "1d1d1f", "b4d5fe",
                    "1d1d1f", "c41a16", "1d7a2e", "8f5b00", "0b5cd5", "8a36b8", "0a7285", "6e6e73",
                    "6e6e73", "e0301e", "248a3d", "a0690a", "1a73e8", "a24ccf", "0b8aa0", "3a3a3c"]
        ),
        .init(
            id: "catppuccin", name: "Catppuccin (Mocha / Latte)",
            dark: ["1e1e2e", "cdd6f4", "f5e0dc", "585b70",
                   "45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "bac2de",
                   "585b70", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8"],
            light: ["eff1f5", "4c4f69", "dc8a78", "acb0be",
                    "5c5f77", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "acb0be",
                    "6c6f85", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "bcc0cc"]
        ),
        .init(
            id: "tokyonight", name: "Tokyo Night (Night / Day)",
            dark: ["1a1b26", "c0caf5", "c0caf5", "33467c",
                   "15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
                   "414868", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "c0caf5"],
            light: ["e1e2e7", "3760bf", "3760bf", "99a7df",
                    "e9e9ed", "f52a65", "587539", "8c6c3e", "2e7de9", "9854f1", "007197", "6172b0",
                    "a1a6c5", "f52a65", "587539", "8c6c3e", "2e7de9", "9854f1", "007197", "3760bf"]
        ),
        .init(
            id: "github", name: "GitHub (Dark / Light)",
            dark: ["0d1117", "e6edf3", "e6edf3", "264f78",
                   "484f58", "ff7b72", "3fb950", "d29922", "58a6ff", "bc8cff", "39c5cf", "b1bac4",
                   "6e7681", "ffa198", "56d364", "e3b341", "79c0ff", "d2a8ff", "56d4dd", "ffffff"],
            light: ["ffffff", "1f2328", "1f2328", "add6ff",
                    "24292f", "cf222e", "116329", "4d2d00", "0969da", "8250df", "1b7c83", "6e7781",
                    "57606a", "a40e26", "1a7f37", "633c01", "218bff", "a475f9", "3192aa", "8c959f"]
        ),
        .init(
            id: "gruvbox", name: "Gruvbox (Dark / Light)",
            dark: ["282828", "ebdbb2", "ebdbb2", "504945",
                   "282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
                   "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"],
            light: ["fbf1c7", "3c3836", "3c3836", "d5c4a1",
                    "fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64",
                    "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836"]
        ),
        .init(
            id: "rosepine", name: "Rosé Pine (Main / Dawn)",
            dark: ["191724", "e0def4", "e0def4", "403d52",
                   "26233a", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
                   "6e6a86", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4"],
            light: ["faf4ed", "575279", "575279", "dfdad9",
                    "f2e9e1", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "575279",
                    "9893a5", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "575279"]
        ),
        .init(id: ghosttyConfig, name: "From my Ghostty config", dark: nil, light: nil),
    ]

    /// A theme from Ghostty's collection, applied for both appearances.
    static let ghosttyPrefix = "ghostty:"

    static func find(_ id: String) -> TerminalThemeChoice {
        if id.hasPrefix(ghosttyPrefix) {
            let name = String(id.dropFirst(ghosttyPrefix.count))
            return .init(id: id, name: name, dark: nil, light: nil)
        }
        return all.first { $0.id == id } ?? all[0]
    }

    var theme: TerminalTheme {
        if id.hasPrefix(Self.ghosttyPrefix) {
            let config = GhosttyThemes.configuration(named: name)
            return TerminalTheme(light: config, dark: config)
        }
        return TerminalTheme(light: Self.configuration(light), dark: Self.configuration(dark))
    }

    private static func configuration(_ colors: [String]?) -> TerminalConfiguration {
        guard let colors, colors.count == 20 else { return .init() }
        return TerminalConfiguration { builder in
            builder.withBackground(colors[0])
            builder.withForeground(colors[1])
            builder.withCursorColor(colors[2])
            builder.withSelectionBackground(colors[3])
            for index in 0..<16 { builder.withPalette(index, color: "#" + colors[4 + index]) }
        }
    }
}

/// Minimum contrast Ghostty enforces between text and its background, so
/// dim or same-colored text stays readable.
enum ContrastBoost: String, CaseIterable {
    case off, standard, high

    var title: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .high: "High"
        }
    }

    var ratio: Double? {
        switch self {
        case .off: nil
        case .standard: 1.6
        case .high: 3
        }
    }
}

/// How panes are shown: GhostHerdr's own per-pane terminals, or herdr's
/// own client in one terminal per window.
enum TerminalMode: String, CaseIterable {
    case panes, herdrClient

    var title: String {
        switch self {
        case .panes: "GhostHerdr panes"
        case .herdrClient: "herdr client (native)"
        }
    }
}

extension Settings {
    /// `GHOSTHERDR_TERMINAL_MODE` (panes / herdrClient) overrides it for one
    /// launch, e.g. a test copy beside the one in use.
    static var terminalMode: TerminalMode {
        get {
            if let forced = ProcessInfo.processInfo.environment["GHOSTHERDR_TERMINAL_MODE"].flatMap(TerminalMode.init) { return forced }
            return UserDefaults.standard.string(forKey: "terminalMode").flatMap(TerminalMode.init) ?? .panes
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "terminalMode") }
    }

    static var terminalTheme: String {
        get {
            if let chosen = UserDefaults.standard.string(forKey: "terminalTheme") { return chosen }
            // Never picked: a Ghostty config that sets its own colors wins.
            return TerminalAppearance.configSetsColors() ? TerminalThemeChoice.ghosttyConfig : TerminalThemeChoice.defaultID
        }
        set { UserDefaults.standard.set(newValue, forKey: "terminalTheme") }
    }

    /// Empty: the Ghostty config's font.
    static var fontFamily: String {
        get { UserDefaults.standard.string(forKey: "fontFamily") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "fontFamily") }
    }

    /// 0: the Ghostty config's size.
    static var fontSize: Double {
        get { UserDefaults.standard.double(forKey: "fontSize") }
        set { UserDefaults.standard.set(newValue, forKey: "fontSize") }
    }

    static var contrast: ContrastBoost {
        get { UserDefaults.standard.string(forKey: "contrast").flatMap(ContrastBoost.init) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "contrast") }
    }
}

/// Applies the terminal settings on top of the user's Ghostty config, and
/// finds (or creates) that config for editing.
@MainActor
enum TerminalAppearance {
    static func configPath() -> String? {
        // A separate config (testing, or keeping GhostHerdr apart from Ghostty).
        if let path = ProcessInfo.processInfo.environment["GHOSTHERDR_GHOSTTY_CONFIG"] { return path }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static var candidates: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/.config/ghostty/config.ghostty",
            home + "/.config/ghostty/config",
            home + "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            home + "/Library/Application Support/com.mitchellh.ghostty/config",
        ]
    }

    static func makeController() -> TerminalController {
        let controller = TerminalController(configSource: configSource(), theme: TerminalThemeChoice.find(Settings.terminalTheme).theme)
        lastIssue = controller.lastConfigurationIssue
        controller.setTerminalConfiguration(overrides())
        return controller
    }

    /// Whether the config picks a theme or background itself.
    nonisolated static func configSetsColors() -> Bool {
        let env = ProcessInfo.processInfo.environment["GHOSTHERDR_GHOSTTY_CONFIG"]
        let home = NSHomeDirectory()
        let paths = [env, home + "/.config/ghostty/config.ghostty", home + "/.config/ghostty/config",
                     home + "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
                     home + "/Library/Application Support/com.mitchellh.ghostty/config"].compactMap { $0 }
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.components(separatedBy: .newlines).contains { line in
            let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            return key == "theme" || key == "background"
        }
    }

    /// Why the Ghostty config didn't load, for Settings; nil when it did.
    private(set) static var lastIssue: String? {
        get { issue }
        set { issue = newValue.map(tidy) }
    }

    private static var issue: String?

    /// "ghostty config diagnostics: /long/path:2:font-size: invalid …" as
    /// "line 2: font-size: invalid …", one per line, deduplicated.
    private static func tidy(_ raw: String) -> String {
        var seen: [String] = []
        let body = raw.replacingOccurrences(of: "ghostty config diagnostics: ", with: "")
        for part in body.components(separatedBy: " | ") {
            var line = part.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: #"^/[^:]+:(\d+):"#, options: .regularExpression) {
                let number = line[range].split(separator: ":").dropFirst().first ?? ""
                line = "line \(number): " + line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            if let tried = line.range(of: ", tried path") { line = String(line[..<tried.lowerBound]) }
            if !seen.contains(line) { seen.append(line) }
        }
        return seen.joined(separator: "\n")
    }

    /// Re-reads the config file and re-applies the settings.
    static func apply(to controller: TerminalController) {
        lastIssue = controller.updateConfigSource(configSource()) ? nil : controller.lastConfigurationIssue
        controller.setTheme(TerminalThemeChoice.find(Settings.terminalTheme).theme)
        controller.setTerminalConfiguration(overrides())
        Settings.changed()
    }

    /// The config file, or its text with `theme = <name>` pointed at the
    /// bundled theme collection: embedded libghostty ships without Ghostty's
    /// themes, and Ghostty accepts a theme's absolute path.
    /// The appearance `theme = light:…,dark:…` was last resolved for.
    private static var resolvedDark: Bool?

    /// Follows the system appearance: a light/dark config theme is
    /// re-resolved when it flips.
    static func follow(dark: Bool, controller: TerminalController) {
        guard dark != resolvedDark else { return }
        let first = resolvedDark == nil
        resolvedDark = dark
        if !first || configNamesLightDark() { apply(to: controller) }
    }

    private static func configNamesLightDark() -> Bool {
        guard let path = configPath(), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.contains("light:") || text.contains("dark:")
    }

    static func configSource() -> TerminalController.ConfigSource {
        guard let path = configPath() else { return .none }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .file(path) }
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let dark = resolvedDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            guard let rewritten = GhosttyThemes.rewriteThemeLine(line, dark: dark) else { return line }
            changed = true
            return rewritten
        }
        return changed ? .generated(lines.joined(separator: "\n")) : .file(path)
    }

    private static func overrides() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            let family = Settings.fontFamily.trimmingCharacters(in: .whitespaces)
            if !family.isEmpty { builder.withFontFamily(family) }
            if Settings.fontSize > 0 { builder.withFontSize(Float(Settings.fontSize)) }
            if let ratio = Settings.contrast.ratio { builder.withMinimumContrast(ratio) }
            // Translucent terminals: Ghostty leaves default-background cells
            // clear and the pane card paints the color once, at the chosen
            // opacity (both painting it doubled the opacity toward black).
            if Settings.terminalOpacity < 1 { builder.withBackgroundOpacity(0) }
        }
    }

    /// Opens the Ghostty config in the default editor, creating it first.
    static func editConfig() {
        let path = configPath() ?? candidates[0]
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let starter = """
            # Ghostty config, shared by Ghostty and GhostHerdr.
            # Every option: https://ghostty.org/docs/config/reference
            # GhostHerdr's Settings ▸ Terminal (theme, font, contrast) apply on top.
            #
            # font-family = JetBrains Mono
            # font-size = 13
            # cursor-style = bar
            # adjust-cell-height = 10%

            """
            FileManager.default.createFile(atPath: path, contents: Data(starter.utf8))
        }
        let url = URL(fileURLWithPath: path)
        let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        if let editor {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Ghostty's theme collection, bundled with the app.
enum GhosttyThemes {
    static let directory: URL? = Bundle.module.url(forResource: "ghostty-themes", withExtension: nil)

    static let names: [String] = {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return files.filter { !$0.hasPrefix(".") && !$0.hasPrefix("LICENSE") && $0 != "SOURCE" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    /// A theme file's settings (`background = …`, `palette = 0=#…`) as
    /// configuration commands.
    static func configuration(named name: String) -> TerminalConfiguration {
        guard let url = directory?.appendingPathComponent(name),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return .init() }
        return TerminalConfiguration { builder in
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !value.isEmpty { builder.withCustom(key, value) }
            }
        }
    }

    /// `theme = Dracula` or `theme = light:A,dark:B`, resolved to one
    /// theme file: the side matching `dark`, from ~/.config/ghostty/themes
    /// or the bundled collection. The embedded runtime doesn't switch
    /// Ghostty's light/dark themes itself, so GhostHerdr picks the side.
    /// Nil when the line needs no change.
    static func rewriteThemeLine(_ line: String, dark: Bool) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("theme"), let eq = trimmed.firstIndex(of: "="),
              trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "theme" else { return nil }
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        var plain: String?
        var sides: [String: String] = [:]
        for part in value.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("light:") { sides["light"] = String(piece.dropFirst(6)) }
            else if piece.hasPrefix("dark:") { sides["dark"] = String(piece.dropFirst(5)) }
            else { plain = piece }
        }
        guard let name = sides[dark ? "dark" : "light"] ?? plain ?? sides.values.first else { return nil }
        guard let path = themePath(name) else { return nil }
        return path == value ? nil : "theme = " + path
    }

    /// A theme's file: absolute as given, the user's own, then bundled.
    static func themePath(_ name: String) -> String? {
        if name.hasPrefix("/") { return name }
        let user = NSHomeDirectory() + "/.config/ghostty/themes/" + name
        if FileManager.default.fileExists(atPath: user) { return user }
        guard let bundled = directory?.appendingPathComponent(name).path,
              FileManager.default.fileExists(atPath: bundled) else { return nil }
        return bundled
    }
}
