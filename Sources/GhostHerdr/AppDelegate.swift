import AppKit
import GhosttyTerminal
import HerdrKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var store: SessionStore!
    private(set) var terminalController: TerminalController!
    private(set) var attention: AttentionCenter!
    private var windows: [MainWindowController] = []

    /// Each herdr workspace ("space") gets its own window, cmux-style, and the
    /// sidebar is optional. Off: sidebar windows that switch between spaces.
    private var windowPerSpace: Bool {
        get { UserDefaults.standard.object(forKey: "windowPerSpace") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowPerSpace") }
    }

    /// Spaces whose window the user closed; they stay closed until asked for.
    private var dismissedSpaces: Set<String> = []
    /// Spaces this app just created; their windows open in front.
    private var spacesToActivate: Set<String> = []
    private var knownSpaces: Set<String> = []

    func applicationDidFinishLaunching(_: Notification) {
        let env = ProcessInfo.processInfo.environment
        let endpoint = HerdrEndpoint(session: env["GHOSTHERDR_SESSION"].flatMap { $0.isEmpty ? nil : $0 })
        store = SessionStore(endpoint: endpoint)
        terminalController = Self.makeTerminalController()
        attention = AttentionCenter(store: store)
        attention.viewedPanes = { [weak self] in Set(self?.windows.compactMap(\.viewedPane) ?? []) }
        attention.reveal = { [weak self] pane in self?.reveal(pane) }
        NSApp.mainMenu = MainMenu.build()
        NSApp.windowsMenu?.delegate = self
        store.observe { [weak self] in self?.reconcileSpaceWindows() }
        store.start()
        DebugDump.install { [weak self] in self?.debugDescription ?? "" }
        DebugDump.installTyping { NSApp.keyWindow?.firstResponder as? HerdrTerminalView
            ?? (ProcessInfo.processInfo.environment["GHOSTHERDR_DEBUG_TYPE_BACK"] == nil ? Array(NSApp.orderedWindows) : NSApp.orderedWindows.reversed()).lazy.compactMap { $0.firstResponder as? HerdrTerminalView }.first }
        // Until herdr answers, one unpinned window shows the connection state;
        // in space mode it is then adopted by the first space.
        openWindow(pinnedTo: nil)
        // Debug: extra sidebar windows at launch, to exercise control handoff.
        if !windowPerSpace, let extra = env["GHOSTHERDR_DEBUG_WINDOWS"].flatMap(Int.init), extra > 1 {
            for _ in 1..<extra { openWindow(pinnedTo: nil) }
        }
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

    /// In space mode closing every window just hides the spaces; the app
    /// stays running for notifications and the Dock badge.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { !windowPerSpace }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible {
            if windowPerSpace, let focused = store.snapshot.focusedWorkspaceID ?? store.snapshot.workspaces.first?.workspaceID {
                showSpace(focused)
            } else if windows.isEmpty {
                openWindow(pinnedTo: nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_: Notification) {
        // Terminal channels release control on deinit; herdr keeps the panes.
        windows.removeAll()
        store.stop()
    }

    // MARK: - Windows

    @discardableResult
    private func openWindow(pinnedTo spaceID: String?, activate: Bool = true) -> MainWindowController {
        let controller = MainWindowController(store: store, attention: attention, terminalController: terminalController)
        controller.sidebarVisible = !windowPerSpace
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if let id = controller.pinnedWorkspaceID { self.dismissedSpaces.insert(id) }
            self.windows.removeAll { $0 === controller }
        }
        controller.onShowSpace = { [weak self] id in self?.showSpace(id) }
        controller.onSpaceClosed = { [weak controller] in controller?.close() }
        pin(controller, to: spaceID)
        if let previous = windows.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 28, y: previous.frame.maxY - 28))
        }
        windows.append(controller)
        if activate || NSApp.keyWindow == nil {
            controller.showWindow(nil)
        } else {
            controller.window?.order(.below, relativeTo: NSApp.keyWindow?.windowNumber ?? 0)
        }
        return controller
    }

    private func pin(_ controller: MainWindowController, to spaceID: String?) {
        controller.pinnedWorkspaceID = spaceID
        if let spaceID, let label = store.workspace(spaceID)?.label {
            controller.window?.setFrameAutosaveName("GhostHerdr.space.\(label)")
        }
    }

    private func window(for spaceID: String) -> MainWindowController? {
        windows.first { $0.pinnedWorkspaceID == spaceID }
    }

    /// Brings a space's window forward, opening it if needed.
    func showSpace(_ id: String) {
        dismissedSpaces.remove(id)
        if windowPerSpace {
            (window(for: id) ?? openWindow(pinnedTo: id)).window?.makeKeyAndOrderFront(nil)
        } else if let pane = store.snapshot.panes.first(where: { $0.workspaceID == id && $0.focused })
            ?? store.snapshot.panes.first(where: { $0.workspaceID == id })
        {
            reveal(pane)
        }
    }

    /// In space mode, keeps one window per live space: spaces that appear
    /// get a window, spaces that close lose theirs.
    private func reconcileSpaceWindows() {
        guard windowPerSpace, case .connected = store.state else { return }
        let spaces = store.snapshot.workspaces
        let live = Set(spaces.map(\.workspaceID))
        let firstReconcile = knownSpaces.isEmpty
        let newSpaces = live.subtracting(knownSpaces)
        knownSpaces = live
        dismissedSpaces.formIntersection(live)

        // Launch: the space herdr has focused takes over the launch window.
        if firstReconcile, let lobby = windows.first(where: { $0.pinnedWorkspaceID == nil }),
           let first = store.snapshot.focusedWorkspaceID ?? spaces.first?.workspaceID
        {
            pin(lobby, to: first)
        }
        for space in spaces where window(for: space.workspaceID) == nil
            && !dismissedSpaces.contains(space.workspaceID)
            && (firstReconcile || newSpaces.contains(space.workspaceID))
        {
            let id = space.workspaceID
            if let lobby = windows.first(where: { $0.pinnedWorkspaceID == nil }) {
                pin(lobby, to: id)
                continue
            }
            // Spaces created elsewhere (an agent, the herdr TUI) open behind.
            openWindow(pinnedTo: id, activate: spacesToActivate.remove(id) != nil)
        }
    }

    @objc func toggleWindowPerSpace(_: Any?) {
        windowPerSpace.toggle()
        for controller in windows { controller.onClose = nil; controller.close() }
        windows.removeAll()
        dismissedSpaces.removeAll()
        knownSpaces.removeAll()
        openWindow(pinnedTo: nil)
        reconcileSpaceWindows()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleWindowPerSpace(_:)) { item.state = windowPerSpace ? .on : .off }
        return true
    }

    /// ⌘N: in space mode, a new space in the current folder, in its own
    /// window; otherwise another sidebar window.
    @objc func newWindow(_: Any?) {
        guard windowPerSpace else {
            openWindow(pinnedTo: nil)
            return
        }
        let key = windows.first { $0.window?.isKeyWindow == true }
        let cwd = key?.currentDirectory ?? NSHomeDirectory()
        let store = store!
        Task {
            do {
                let pane = try await store.client.createWorkspace(cwd: cwd)
                spacesToActivate.insert(pane.workspaceID)
                store.scheduleRefresh()
            } catch {
                NSLog("ghostherdr: could not create space: \(error)")
            }
        }
    }

    // MARK: - Attention

    /// Shows the pane in its space's window (space mode) or the key window.
    private func reveal(_ pane: Pane) {
        if windowPerSpace {
            dismissedSpaces.remove(pane.workspaceID)
            (window(for: pane.workspaceID) ?? openWindow(pinnedTo: pane.workspaceID)).reveal(pane)
            return
        }
        if windows.isEmpty { openWindow(pinnedTo: nil) }
        let target = windows.first { $0.window?.isKeyWindow == true } ?? windows.first
        target?.reveal(pane)
    }

    @objc func jumpToNextUnread(_: Any?) {
        let current = windows.first { $0.window?.isKeyWindow == true }?.viewedPane
        attention.jumpToNext(after: current)
    }

    // MARK: - Window menu lists every space, open or not

    private static let spaceItemTag = 7001

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.spaceItemTag { menu.removeItem(item) }
        let spaces = store.snapshot.workspaces
        guard !spaces.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = Self.spaceItemTag
        menu.addItem(separator)
        for (index, space) in spaces.enumerated() {
            let count = attention.count(inWorkspace: space.workspaceID)
            let title = count > 0 ? "\(space.label)  (\(count))" : space.label
            let item = NSMenuItem(
                title: title, action: #selector(showSpaceFromMenu(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : ""
            )
            item.keyEquivalentModifierMask = [.command, .control]
            item.target = self
            item.representedObject = space.workspaceID
            item.tag = Self.spaceItemTag
            let isKey = window(for: space.workspaceID)?.window?.isKeyWindow == true
            item.state = isKey ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func showSpaceFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { showSpace(id) }
    }

    override var debugDescription: String {
        var out = "state: \(store.state) windowPerSpace=\(windowPerSpace)\n"
        out += "workspaces: \(store.snapshot.workspaces.map(\.workspaceID)) dismissed=\(dismissedSpaces.sorted())\n"
        out += "attention: blocked=\(attention.attention.blocked.sorted()) unseenDone=\(attention.attention.unseenDone.sorted())\n"
        for (i, window) in windows.enumerated() {
            let pinned = window.pinnedWorkspaceID ?? "-"
            out += "--- window \(i) pinned=\(pinned) key=\(window.window?.isKeyWindow ?? false) visible=\(window.window?.isVisible ?? false)\n"
            out += window.debugDescription
        }
        return out
    }
}
