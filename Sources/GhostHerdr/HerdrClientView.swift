import AppKit
import GhosttyTerminal
import HerdrKit

/// "herdr client" terminal mode: one Ghostty surface per window running
/// herdr's own client, exactly as in a plain Ghostty window, so every
/// terminal behavior (mouse, paste, keyboard protocols, images) is herdr's.
/// GhostHerdr's native UI (sidebar, palette, browser and files panes)
/// sits around and over it, driven by herdr's API.
@MainActor
final class HerdrClientView: AppTerminalView, TerminalSurfaceGridResizeDelegate, TerminalSurfaceCloseDelegate {
    let endpoint: HerdrEndpoint
    private(set) var grid: TerminalGridMetrics?

    /// The grid changed size (for placing overlays over panes).
    var onGridChange: (() -> Void)?
    /// herdr exited (detached, quit, or the server went away).
    var onExit: (() -> Void)?
    var onFocus: (() -> Void)?

    init(endpoint: HerdrEndpoint, controller: TerminalController) {
        self.endpoint = endpoint
        super.init(frame: .zero)
        self.controller = controller
        var env = endpoint.cliEnvironment
        env["HERDR_CONFIG_PATH"] = HerdrClientConfig.path()
        // Never "nested": drop the pane variables GhostHerdr may have
        // inherited from being launched inside a herdr pane. The socket
        // variable stays only when we set it (a remote machine's tunnel).
        var unset = ["HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID", "HERDR_ENV", "HERDR_BIN_PATH"]
        if env["HERDR_SOCKET_PATH"] == nil { unset.append("HERDR_SOCKET_PATH") }
        let command = (["/usr/bin/env"] + unset.flatMap { ["-u", $0] } + [endpoint.herdrBinary] + endpoint.sessionArguments)
            .map(Self.shellQuote).joined(separator: " ")
        configuration = TerminalSurfaceOptions(
            backend: .exec, workingDirectory: NSHomeDirectory(), envVars: env,
            command: command, waitAfterCommand: false
        )
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        grid = size
        onGridChange?()
    }

    func terminalDidClose(processAlive _: Bool) { onExit?() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    /// The app menu gets first pick at ⌘ shortcuts (GhostHerdr's own
    /// actions); everything else is herdr's.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The view rectangle of a cell rectangle of the grid (herdr's pane
    /// rects are in cells from the top-left of the terminal).
    func rect(column: Int, row: Int, columns: Int, rows: Int) -> NSRect? {
        guard let grid, grid.columns > 0, grid.rows > 0, grid.cellWidthPixels > 0, grid.cellHeightPixels > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let cellWidth = CGFloat(grid.cellWidthPixels) / scale
        let cellHeight = CGFloat(grid.cellHeightPixels) / scale
        // Ghostty pads the grid by window-padding (2pt by default) at the
        // top-left; the leftover of a partial cell goes right and bottom.
        let padX = min(2, max(0, bounds.width - CGFloat(grid.columns) * cellWidth))
        let padY = min(2, max(0, bounds.height - CGFloat(grid.rows) * cellHeight))
        let x = padX + CGFloat(column) * cellWidth
        let top = padY + CGFloat(row) * cellHeight
        return NSRect(x: x, y: bounds.height - top - CGFloat(rows) * cellHeight,
                      width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The config the embedded herdr client runs with: the user's own herdr
/// config plus what GhostHerdr's native UI replaces (herdr's sidebar, and
/// the tab row when there's one tab). The user's config file is untouched.
enum HerdrClientConfig {
    static let overrides: [(String, String)] = [
        ("sidebar_start_collapsed", "true"),
        ("sidebar_collapsed_mode", "\"hidden\""),
        ("hide_tab_bar_when_single_tab", "true"),
    ]

    static func userConfigPath() -> String {
        if let path = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"] { return path }
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        return base + "/herdr/config.toml"
    }

    /// Writes the merged config and returns its path.
    static func path() -> String {
        let dir = NSHomeDirectory() + "/Library/Application Support/GhostHerdr"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/herdr-client.toml"
        let user = (try? String(contentsOfFile: userConfigPath(), encoding: .utf8)) ?? ""
        try? merged(user).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// The user's TOML with the overrides in its `[ui]` table (added if
    /// missing); keys the user set there are replaced.
    static func merged(_ user: String) -> String {
        var lines = user.components(separatedBy: "\n")
        let keys = Set(overrides.map(\.0))
        guard let ui = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[ui]" }) else {
            return user + (user.hasSuffix("\n") || user.isEmpty ? "" : "\n") + "\n[ui]\n"
                + overrides.map { "\($0.0) = \($0.1)" }.joined(separator: "\n") + "\n"
        }
        // Drop the user's own values for our keys inside [ui].
        var index = ui + 1
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let key = lines[index].split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if keys.contains(key) { lines.remove(at: index) } else { index += 1 }
        }
        lines.insert(contentsOf: overrides.map { "\($0.0) = \($0.1)" }, at: ui + 1)
        return lines.joined(separator: "\n")
    }
}
