import AppKit

/// Actions sent down the responder chain; `MainWindowController` implements them.
@MainActor @objc protocol PaneActions {
    func splitRight(_ sender: Any?)
    func splitDown(_ sender: Any?)
    func closePane(_ sender: Any?)
    func zoomPane(_ sender: Any?)
    func focusLeft(_ sender: Any?)
    func focusRight(_ sender: Any?)
    func focusUp(_ sender: Any?)
    func focusDown(_ sender: Any?)
    func resizeLeft(_ sender: Any?)
    func resizeRight(_ sender: Any?)
    func resizeUp(_ sender: Any?)
    func resizeDown(_ sender: Any?)
    func newTab(_ sender: Any?)
    func closeTab(_ sender: Any?)
    func nextTab(_ sender: Any?)
    func previousTab(_ sender: Any?)
    func newWorkspace(_ sender: Any?)
    func selectTabByNumber(_ sender: Any?)
    func toggleSidebar(_ sender: Any?)
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = submenu(main, "GhostHerdr")
        appMenu.addItem(withTitle: "About GhostHerdr", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide GhostHerdr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit GhostHerdr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New Window", #selector(AppDelegate.newWindow(_:)), "n")
        item(file, "New Tab", #selector(PaneActions.newTab(_:)), "t")
        item(file, "New Workspace", #selector(PaneActions.newWorkspace(_:)), "n", [.command, .shift])
        file.addItem(.separator())
        item(file, "Close Pane", #selector(PaneActions.closePane(_:)), "w")
        item(file, "Close Tab", #selector(PaneActions.closeTab(_:)), "w", [.command, .option])
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])

        let edit = submenu(main, "Edit")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let pane = submenu(main, "Pane")
        item(pane, "Split Right", #selector(PaneActions.splitRight(_:)), "d")
        item(pane, "Split Down", #selector(PaneActions.splitDown(_:)), "d", [.command, .shift])
        item(pane, "Zoom Pane", #selector(PaneActions.zoomPane(_:)), "\r", [.command, .shift])
        pane.addItem(.separator())
        item(pane, "Focus Left", #selector(PaneActions.focusLeft(_:)), arrow(.leftArrow), [.command, .option])
        item(pane, "Focus Right", #selector(PaneActions.focusRight(_:)), arrow(.rightArrow), [.command, .option])
        item(pane, "Focus Up", #selector(PaneActions.focusUp(_:)), arrow(.upArrow), [.command, .option])
        item(pane, "Focus Down", #selector(PaneActions.focusDown(_:)), arrow(.downArrow), [.command, .option])
        pane.addItem(.separator())
        item(pane, "Resize Left", #selector(PaneActions.resizeLeft(_:)), arrow(.leftArrow), [.command, .control])
        item(pane, "Resize Right", #selector(PaneActions.resizeRight(_:)), arrow(.rightArrow), [.command, .control])
        item(pane, "Resize Up", #selector(PaneActions.resizeUp(_:)), arrow(.upArrow), [.command, .control])
        item(pane, "Resize Down", #selector(PaneActions.resizeDown(_:)), arrow(.downArrow), [.command, .control])

        let tabs = submenu(main, "Tab")
        item(tabs, "Next Tab", #selector(PaneActions.nextTab(_:)), "]", [.command, .shift])
        item(tabs, "Previous Tab", #selector(PaneActions.previousTab(_:)), "[", [.command, .shift])
        tabs.addItem(.separator())
        for n in 1...9 {
            let i = item(tabs, "Tab \(n)", #selector(PaneActions.selectTabByNumber(_:)), "\(n)")
            i.tag = n
        }

        let view = submenu(main, "View")
        item(view, "Show Sidebar", #selector(PaneActions.toggleSidebar(_:)), "s", [.command, .control])
        item(view, "One Window per Space", #selector(AppDelegate.toggleWindowPerSpace(_:)), "")

        let window = submenu(main, "Window")
        item(window, "Jump to Next Unread", #selector(AppDelegate.jumpToNextUnread(_:)), "u", [.command, .shift])
        window.addItem(.separator())
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    @discardableResult
    private static func item(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }

}

private extension Int {
    static let leftArrow = NSLeftArrowFunctionKey
    static let rightArrow = NSRightArrowFunctionKey
    static let upArrow = NSUpArrowFunctionKey
    static let downArrow = NSDownArrowFunctionKey
}
