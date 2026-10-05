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
    func nextPane(_ sender: Any?)
    func previousPane(_ sender: Any?)
    func selectPaneByNumber(_ sender: Any?)
    func toggleShortcutSheet(_ sender: Any?)
    func resizeLeft(_ sender: Any?)
    func resizeRight(_ sender: Any?)
    func resizeUp(_ sender: Any?)
    func resizeDown(_ sender: Any?)
    func newTab(_ sender: Any?)
    func closeTab(_ sender: Any?)
    func nextTab(_ sender: Any?)
    func previousTab(_ sender: Any?)
    func newWorkspace(_ sender: Any?)
    func newSpaceHere(_ sender: Any?)
    func newSession(_ sender: Any?)
    func showSessionSwitcher(_ sender: Any?)
    func renameSpace(_ sender: Any?)
    func closeSpace(_ sender: Any?)
    func makeTextBigger(_ sender: Any?)
    func makeTextSmaller(_ sender: Any?)
    func makeTextActualSize(_ sender: Any?)
    func selectSpaceByNumber(_ sender: Any?)
    func selectTabByNumber(_ sender: Any?)
    func nextSpace(_ sender: Any?)
    func recentSpace(_ sender: Any?)
    func recentSpaceBack(_ sender: Any?)
    func previousSpace(_ sender: Any?)
    func toggleSidebar(_ sender: Any?)
    func newBrowserPane(_ sender: Any?)
    func newBrowserTab(_ sender: Any?)
    func openBrowserHere(_ sender: Any?)
    func openFilesHere(_ sender: Any?)
    func openLocation(_ sender: Any?)
    func newFilesPane(_ sender: Any?)
    func toggleFileViewer(_ sender: Any?)
    func showChanges(_ sender: Any?)
    func movePaneToSpaceByNumber(_ sender: Any?)
    func movePaneTo(_ sender: Any?)
    func togglePin(_ sender: Any?)
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = submenu(main, "bigtty")
        appMenu.addItem(withTitle: "About bigtty", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        item(appMenu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        appMenu.addItem(withTitle: "Install btty and Agent Skill…", action: #selector(AppDelegate.installAgentSkill(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        item(appMenu, "Hide bigtty", #selector(NSApplication.hide(_:)), "h")
        item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        appMenu.addItem(.separator())
        item(appMenu, "Quit bigtty", #selector(AppDelegate.holdToQuit(_:)), "q")

        let file = submenu(main, "File")
        item(file, "New Space", #selector(PaneActions.newSpaceHere(_:)), "n")
        item(file, "New Space in Folder…", #selector(PaneActions.newWorkspace(_:)), "n", [.command, .option])
        item(file, "New Tab", #selector(PaneActions.newTab(_:)), "t")
        item(file, "New Browser Tab", #selector(PaneActions.newBrowserTab(_:)), "t", [.command, .option])
        item(file, "New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift])
        item(file, "New Session…", #selector(PaneActions.newSession(_:)), "n", [.command, .control])
        file.addItem(.separator())
        item(file, "Connect Machine…", #selector(AppDelegate.connectMachine(_:)), "k", [.command, .option])
        item(file, "Open Location…", #selector(PaneActions.openLocation(_:)), "l")
        file.addItem(.separator())
        item(file, "Rename Space…", #selector(PaneActions.renameSpace(_:)), "")
        file.addItem(.separator())
        item(file, "Close Pane", #selector(PaneActions.closePane(_:)), "w")
        item(file, "Close Tab", #selector(PaneActions.closeTab(_:)), "w", [.command, .option])
        item(file, "Close Space…", #selector(PaneActions.closeSpace(_:)), "")
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])

        let edit = submenu(main, "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(AppDelegate.pasteSmart(_:)), "v")
        item(edit, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        for (title, key, flags, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", [.command], .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", [.command], .setSearchString),
        ] {
            item(find, title, #selector(NSResponder.performTextFinderAction(_:)), key, flags).tag = action.rawValue
        }

        let view = submenu(main, "View")
        item(view, "Toggle Sidebar", #selector(PaneActions.toggleSidebar(_:)), "s", [.command, .control])
        item(view, "Toggle File Viewer", #selector(PaneActions.toggleFileViewer(_:)), "e", [.command, .shift])
        view.addItem(.separator())
        item(view, "Bigger", #selector(PaneActions.makeTextBigger(_:)), "=")
        alternate(item(view, "Bigger", #selector(PaneActions.makeTextBigger(_:)), "+"))
        item(view, "Smaller", #selector(PaneActions.makeTextSmaller(_:)), "-")
        item(view, "Actual Size", #selector(PaneActions.makeTextActualSize(_:)), "0")
        view.addItem(.separator())
        item(view, "Dim Unfocused Panes", #selector(AppDelegate.toggleDimming(_:)), "")
        item(view, "Translucent Window", #selector(AppDelegate.toggleTranslucency(_:)), "")
        item(view, "One Window per Space", #selector(AppDelegate.toggleWindowPerSpace(_:)), "")
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let pane = submenu(main, "Pane")
        item(pane, "Split Right", #selector(PaneActions.splitRight(_:)), "d")
        item(pane, "Split Down", #selector(PaneActions.splitDown(_:)), "d", [.command, .shift])
        item(pane, "Zoom Pane", #selector(PaneActions.zoomPane(_:)), "\r", [.command, .shift])
        pane.addItem(.separator())
        item(pane, "Split with Browser", #selector(PaneActions.newBrowserPane(_:)), "b", [.command, .option])
        item(pane, "Open Browser Here", #selector(PaneActions.openBrowserHere(_:)), "b", [.command, .option, .shift])
        item(pane, "Open Location…", #selector(PaneActions.openLocation(_:)), "l")
        item(pane, "Split with Files", #selector(PaneActions.newFilesPane(_:)), "f", [.command, .option])
        item(pane, "Open Files Here", #selector(PaneActions.openFilesHere(_:)), "f", [.command, .option, .shift])
        item(pane, "Show Changes", #selector(PaneActions.showChanges(_:)), "g", [.command, .option])
        pane.addItem(.separator())
        item(pane, "Focus Left", #selector(PaneActions.focusLeft(_:)), arrow(.leftArrow), [.command, .option])
        item(pane, "Focus Right", #selector(PaneActions.focusRight(_:)), arrow(.rightArrow), [.command, .option])
        item(pane, "Focus Up", #selector(PaneActions.focusUp(_:)), arrow(.upArrow), [.command, .option])
        item(pane, "Focus Down", #selector(PaneActions.focusDown(_:)), arrow(.downArrow), [.command, .option])
        item(pane, "Next Pane", #selector(PaneActions.nextPane(_:)), "]")
        item(pane, "Previous Pane", #selector(PaneActions.previousPane(_:)), "[")
        let paneNumbers = NSMenu(title: "Pane")
        let paneNumbersItem = NSMenuItem(title: "Go to Pane", action: nil, keyEquivalent: "")
        paneNumbersItem.submenu = paneNumbers
        pane.addItem(paneNumbersItem)
        for n in 1...9 {
            item(paneNumbers, "Pane \(n)", #selector(PaneActions.selectPaneByNumber(_:)), "\(n)", Settings.paneKeys.modifiers).tag = n
        }
        paneNumbersMenu = paneNumbers
        pane.addItem(.separator())
        // The palette, not a submenu of space names: menu search (Help ▸
        // Search, Spotlight's menu actions) reads those too, and a space's
        // name would offer "move this pane there" ahead of Window's jump.
        item(pane, "Move Pane To…", #selector(PaneActions.movePaneTo(_:)), "")
        item(pane, "Pin Pane", #selector(PaneActions.togglePin(_:)), "p", [.command, .option])
        let moveNumbers = NSMenu(title: "Move Pane to Space")
        let moveNumbersItem = NSMenuItem(title: "Move Pane to Space", action: nil, keyEquivalent: "")
        moveNumbersItem.submenu = moveNumbers
        pane.addItem(moveNumbersItem)
        for n in 1...9 {
            item(moveNumbers, "Space \(n)", #selector(PaneActions.movePaneToSpaceByNumber(_:)), "\(n)", [.command, .control, .option]).tag = n
        }
        pane.addItem(.separator())
        item(pane, "Resize Left", #selector(PaneActions.resizeLeft(_:)), arrow(.leftArrow), [.command, .control])
        item(pane, "Resize Right", #selector(PaneActions.resizeRight(_:)), arrow(.rightArrow), [.command, .control])
        item(pane, "Resize Up", #selector(PaneActions.resizeUp(_:)), arrow(.upArrow), [.command, .control])
        item(pane, "Resize Down", #selector(PaneActions.resizeDown(_:)), arrow(.downArrow), [.command, .control])

        let tabs = submenu(main, "Go")
        item(tabs, "Jump To…", #selector(AppDelegate.showJump(_:)), "k")
        item(tabs, "Switch Session…", #selector(PaneActions.showSessionSwitcher(_:)), "s", [.command, .shift])
        item(tabs, "Next Pane That Needs You", #selector(AppDelegate.jumpToNextUnread(_:)), "u", [.command, .shift])
        item(tabs, "Needs You…", #selector(AppDelegate.showNeedsYou(_:)), "k", [.command, .shift])
        tabs.addItem(.separator())
        // Tabs inside the space: ⌃Tab / ⌃⇧Tab and ⌃1–9, like cmux and
        // browsers; ⌘⇧] / ⌘⇧[ kept as alternates.
        item(tabs, "Next Tab", #selector(PaneActions.nextTab(_:)), "\t", [.control])
        item(tabs, "Previous Tab", #selector(PaneActions.previousTab(_:)), "\t", [.control, .shift])
        alternate(item(tabs, "Next Tab", #selector(PaneActions.nextTab(_:)), "]", [.command, .shift]))
        alternate(item(tabs, "Previous Tab", #selector(PaneActions.previousTab(_:)), "[", [.command, .shift]))
        let tabNumbers = NSMenu(title: "Tab")
        let tabNumbersItem = NSMenuItem(title: "Tab", action: nil, keyEquivalent: "")
        tabNumbersItem.submenu = tabNumbers
        tabs.addItem(tabNumbersItem)
        for n in 1...9 {
            item(tabNumbers, n == 9 ? "Last Tab" : "Tab \(n)", #selector(PaneActions.selectTabByNumber(_:)), "\(n)", [.control]).tag = n
        }
        tabs.addItem(.separator())
        item(tabs, "Next Space", #selector(PaneActions.nextSpace(_:)), "]", [.command, .control])
        item(tabs, "Previous Space", #selector(PaneActions.previousSpace(_:)), "[", [.command, .control])
        item(tabs, "Recent Space", #selector(PaneActions.recentSpace(_:)), "\t", [.command, .control])
        item(tabs, "Recent Space, Back", #selector(PaneActions.recentSpaceBack(_:)), "\t", [.command, .control, .shift])
        for n in 1...9 {
            item(tabs, "Space \(n)", #selector(PaneActions.selectSpaceByNumber(_:)), "\(n)").tag = n
        }

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        item(help, "Keyboard Shortcuts", #selector(PaneActions.toggleShortcutSheet(_:)), "/")
        help.addItem(.separator())
        for (title, url) in [
            ("bigtty on GitHub", "https://github.com/v1k45/bigtty"),
            ("Report an Issue…", "https://github.com/v1k45/bigtty/issues/new"),
            ("herdr Documentation", "https://herdr.dev"),
        ] {
            help.addItem(ClosureMenuItem(title: title, keyEquivalent: "") { NSWorkspace.shared.open(URL(string: url)!) })
        }
        NSApp.helpMenu = help

        return main
    }

    /// Hidden duplicate shortcut: works, but not listed twice in the menu.
    private static func alternate(_ item: NSMenuItem) {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }

    /// "Go to Pane" (its shortcuts follow Settings ▸ Go to pane).
    private static weak var paneNumbersMenu: NSMenu?

    static func applyPaneKeys() {
        for item in paneNumbersMenu?.items ?? [] { item.keyEquivalentModifierMask = Settings.paneKeys.modifiers }
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
