import AppKit
import GhosttyTerminal
import HerdrKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: SessionStore!
    private(set) var terminalController: TerminalController!
    private var windows: [MainWindowController] = []

    func applicationDidFinishLaunching(_: Notification) {
        let env = ProcessInfo.processInfo.environment
        let endpoint = HerdrEndpoint(session: env["GHOSTHERDR_SESSION"].flatMap { $0.isEmpty ? nil : $0 })
        store = SessionStore(endpoint: endpoint)
        terminalController = Self.makeTerminalController()
        NSApp.mainMenu = MainMenu.build()
        store.start()
        DebugDump.install { [weak self] in self?.debugDescription ?? "" }
        DebugDump.installTyping { NSApp.keyWindow?.firstResponder as? HerdrTerminalView
            ?? NSApp.windows.lazy.compactMap { $0.firstResponder as? HerdrTerminalView }.first }
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Uses the user's own Ghostty config, so fonts, theme and keybinds match.
    private static func makeTerminalController() -> TerminalController {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.config/ghostty/config.ghostty",
            home + "/.config/ghostty/config",
            home + "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            home + "/Library/Application Support/com.mitchellh.ghostty/config",
        ]
        let path = candidates.first { FileManager.default.fileExists(atPath: $0) }
        return TerminalController(configFilePath: path)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) {
        // Terminal channels release control on deinit; herdr keeps the panes.
        windows.removeAll()
        store.stop()
    }

    override var debugDescription: String {
        var out = "state: \(store.state)\nworkspaces: \(store.snapshot.workspaces.map(\.workspaceID))\n"
        for (i, window) in windows.enumerated() {
            out += "--- window \(i) visible=\(window.window?.isVisible ?? false)\n" + window.debugDescription
        }
        return out
    }

    @objc func newWindow(_: Any?) {
        let controller = MainWindowController(store: store, terminalController: terminalController)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        controller.showWindow(nil)
        if windows.count > 1, let previous = windows.dropLast().last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 28, y: previous.frame.maxY - 28))
        }
    }
}
