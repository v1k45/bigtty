import AppKit
import HerdrKit

/// User settings, in UserDefaults.
enum Settings {
    enum Notify: String, CaseIterable {
        case needsYouOrFinishes, needsYou, never

        var title: String {
            switch self {
            case .needsYouOrFinishes: "Needs you or finishes"
            case .needsYou: "Needs you"
            case .never: "Never"
            }
        }
    }

    enum Links: String, CaseIterable {
        case browserPane, defaultBrowser

        var title: String {
            switch self {
            case .browserPane: "In a browser pane"
            case .defaultBrowser: "In the default browser"
            }
        }
    }

    static var windowPerSpace: Bool {
        get { UserDefaults.standard.object(forKey: "windowPerSpace") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "windowPerSpace") }
    }

    static var sidebarVisible: Bool {
        get { UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarVisible") }
    }

    static var dimUnfocused: Bool {
        get { UserDefaults.standard.object(forKey: "dimUnfocused") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dimUnfocused") }
    }

    /// The window's translucent material behind the gaps between panes,
    /// not just the sidebar.
    static var translucentWindow: Bool {
        get { UserDefaults.standard.object(forKey: "translucentWindow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "translucentWindow") }
    }

    /// Terminal background opacity (1 = opaque); below 1 the window's
    /// material shows through terminals too.
    static var terminalOpacity: Double {
        get { UserDefaults.standard.object(forKey: "terminalOpacity") as? Double ?? 0.9 }
        set { UserDefaults.standard.set(newValue, forKey: "terminalOpacity") }
    }

    /// The modifier for "go to pane N".
    enum PaneKeys: String, CaseIterable {
        case option, optionCommand

        var title: String {
            switch self {
            case .option: "⌥1 – ⌥9"
            case .optionCommand: "⌥⌘1 – ⌥⌘9"
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .option: [.option]
            case .optionCommand: [.option, .command]
            }
        }

        var symbols: String {
            switch self {
            case .option: "⌥"
            case .optionCommand: "⌥⌘"
            }
        }
    }

    static var paneKeys: PaneKeys {
        get { UserDefaults.standard.string(forKey: "paneKeys").flatMap(PaneKeys.init) ?? .option }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "paneKeys") }
    }

    enum BrowserFullscreen: String, CaseIterable {
        case pane, screen

        var title: String {
            switch self {
            case .pane: "Fill the pane"
            case .screen: "Whole screen"
            }
        }
    }

    /// Where a page's full screen (a video's button) goes.
    /// Test copies (GHOSTHERDR_NO_REMOTES) don't save window frames or the
    /// sidebar width, so they can't overwrite the real app's layout.
    static let remembersLayout = ProcessInfo.processInfo.environment["GHOSTHERDR_NO_REMOTES"] != "1"

    static var sidebarWidth: CGFloat {
        get { let w = UserDefaults.standard.double(forKey: "sidebarWidth"); return w >= 200 ? min(w, 420) : 256 }
        set { if remembersLayout { UserDefaults.standard.set(Double(newValue), forKey: "sidebarWidth") } }
    }

    static var browserFullscreen: BrowserFullscreen {
        get { UserDefaults.standard.string(forKey: "browserFullscreen").flatMap(BrowserFullscreen.init) ?? .pane }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "browserFullscreen") }
    }

    /// Selecting text in a terminal copies it.
    static var copyOnSelect: Bool {
        get { UserDefaults.standard.object(forKey: "copyOnSelect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "copyOnSelect") }
    }

    /// Played when an agent needs you or finishes (a system sound's name;
    /// empty for none).
    static var sound: String {
        get { UserDefaults.standard.string(forKey: "sound") ?? "Glass" }
        set { UserDefaults.standard.set(newValue, forKey: "sound") }
    }

    static let sounds = ["Glass", "Ping", "Pop", "Purr", "Submarine", "Tink", "Hero", "Funk", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Basso"]

    static var notify: Notify {
        get { UserDefaults.standard.string(forKey: "notify").flatMap(Notify.init) ?? .needsYouOrFinishes }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "notify") }
    }

    static var links: Links {
        get { UserDefaults.standard.string(forKey: "links").flatMap(Links.init) ?? .browserPane }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "links") }
    }

    static func changed() {
        NotificationCenter.default.post(name: .ghostherdrSettingsChanged, object: nil)
    }
}

/// ⌘, — native preferences: General and Terminal tabs.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    var herdrDescription: () -> String = { "" }
    var onWindowModeChange: (() -> Void)?
    /// Theme, font, contrast or the Ghostty config changed.
    var onTerminalChange: (() -> Void)?

    private let windows = NSPopUpButton()
    private let sidebar = NSSwitch()
    private let dim = NSSwitch()
    private let translucent = NSSwitch()
    private let opacity = NSPopUpButton()
    private let notify = NSPopUpButton()
    private let sound = NSPopUpButton()
    private let links = NSPopUpButton()
    private let fullscreen = NSPopUpButton()
    private let paneKeys = NSPopUpButton()
    private let herdr = NSTextField(labelWithString: "")
    private let getUBlock = NSButton(title: "Get uBlock Origin Lite", target: nil, action: nil)
    private let extensionsFolder = NSButton(title: "Open Folder", target: nil, action: nil)
    private let extensionsStatus = NSTextField(wrappingLabelWithString: "")

    private let copySelect = NSSwitch()
    private let theme = NSPopUpButton()
    private let font = NSPopUpButton()
    private let size = NSPopUpButton()
    private let contrast = NSSegmentedControl(labels: ContrastBoost.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let configPath = NSTextField(labelWithString: "")
    private let configIssue = NSTextField(wrappingLabelWithString: "")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Settings"
        super.init(window: window)
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(page("General", symbol: "gearshape", view: buildGeneral()))
        tabs.addTabViewItem(page("Terminal", symbol: "terminal", view: buildTerminal()))
        tabs.addTabViewItem(page("Browser", symbol: "globe", view: buildBrowser()))
        window.contentViewController = tabs
        window.toolbarStyle = .preference
        // Reflect reloads that happen while open (config edited elsewhere).
        NotificationCenter.default.addObserver(forName: .ghostherdrSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.refresh()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show() {
        refresh()
        window?.center()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func page(_ title: String, symbol: String, view: NSView) -> NSTabViewItem {
        let controller = NSViewController()
        controller.view = view
        controller.title = title
        // Each tab keeps its own height; the window resizes when switching,
        // instead of stretching the shorter form's rows apart.
        view.layoutSubtreeIfNeeded()
        controller.preferredContentSize = view.fittingSize
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 340
        return label
    }

    private func stack(_ control: NSView, _ text: String?) -> NSView {
        guard let text else { return control }
        let v = NSStackView(views: [control, note(text)])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 4
        return v
    }

    private func form(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 620),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        return content
    }

    private func buildGeneral() -> NSView {
        windows.addItems(withTitles: ["One window, spaces in the sidebar", "One window per space"])
        windows.target = self
        windows.action = #selector(windowsChanged)
        for item in Settings.Notify.allCases { notify.addItem(withTitle: item.title) }
        notify.target = self
        notify.action = #selector(notifyChanged)
        sound.addItem(withTitle: "None")
        sound.menu?.addItem(.separator())
        for name in Settings.sounds { sound.addItem(withTitle: name) }
        sound.target = self
        sound.action = #selector(soundChanged)
        for item in Settings.Links.allCases { links.addItem(withTitle: item.title) }
        links.target = self
        links.action = #selector(linksChanged)
        for item in Settings.PaneKeys.allCases { paneKeys.addItem(withTitle: item.title) }
        paneKeys.target = self
        paneKeys.action = #selector(paneKeysChanged)
        for item in Settings.BrowserFullscreen.allCases { fullscreen.addItem(withTitle: item.title) }
        fullscreen.target = self
        fullscreen.action = #selector(fullscreenChanged)
        sidebar.target = self
        sidebar.action = #selector(sidebarChanged)
        dim.target = self
        dim.action = #selector(dimChanged)
        translucent.target = self
        translucent.action = #selector(translucentChanged)
        herdr.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        herdr.textColor = .secondaryLabelColor
        return form([
            [label("Windows:"), stack(windows, "Spaces live in one window's sidebar, or each gets its own window.")],
            [label("Sidebar:"), stack(sidebar, "Show machines and spaces in new windows. ⌃⌘S toggles it per window.")],
            [label("Dim unfocused panes:"), dim],
            [label("Translucent window:"), stack(translucent, "The sidebar’s material also shows between panes.")],
            [label("Notify when an agent:"), stack(notify, "Only for panes you aren’t looking at.")],
            [label("Sound:"), stack(sound, "Plays with those notifications; the Dock icon also bounces when an agent needs you.")],
            [label("Go to pane:"), stack(paneKeys, "⌥ alone is quicker, but then ⌥1–9 no longer type ¡ ™ £ … or reach terminal apps.")],
            [label("herdr:"), herdr],
        ])
    }

    /// Browser panes: where terminal links open, video full screen, extensions.
    private func buildBrowser() -> NSView {
        form([
            [label("Open terminal links:"), stack(links, "⌘-click on a web link in a terminal.")],
            [label("Video full screen:"), stack(fullscreen, "Fill the pane keeps the rest of GhostHerdr on screen; Esc leaves. Applies to pages opened after a change.")],
            [label("Extensions:"), extensionsRow()],
        ])
    }

    /// Web extensions for browser panes: the uBlock installer, the folder
    /// for any other unpacked MV3 extension, and what's loaded.
    private func extensionsRow() -> NSView {
        getUBlock.bezelStyle = .rounded
        getUBlock.target = self
        getUBlock.action = #selector(installUBlock)
        extensionsFolder.bezelStyle = .rounded
        extensionsFolder.target = self
        extensionsFolder.action = #selector(openExtensionsFolder)
        extensionsStatus.font = .systemFont(ofSize: 11)
        extensionsStatus.textColor = .secondaryLabelColor
        extensionsStatus.preferredMaxLayoutWidth = 380
        let buttons = NSStackView(views: [getUBlock, extensionsFolder])
        buttons.spacing = 8
        let column = NSStackView(views: [buttons, extensionsStatus])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        NotificationCenter.default.addObserver(forName: .ghostherdrExtensionsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateExtensionsStatus() }
        }
        updateExtensionsStatus()
        return column
    }

    private func updateExtensionsStatus() {
        guard WebExtensions.isSupported else {
            getUBlock.isEnabled = false
            extensionsFolder.isEnabled = false
            extensionsStatus.stringValue = "Needs macOS 15.4 or later."
            return
        }
        let loaded = WebExtensions.status
        extensionsStatus.stringValue = (loaded.isEmpty ? "None loaded." : "Loaded: " + loaded.joined(separator: ", ") + ".")
            + " Unpacked Safari or Chrome MV3 extensions in the folder load at launch."
        getUBlock.title = loaded.contains(where: { $0.hasPrefix("uBlock") }) ? "Update uBlock Origin Lite" : "Get uBlock Origin Lite"
    }

    @objc private func installUBlock() {
        getUBlock.isEnabled = false
        extensionsStatus.stringValue = "Downloading uBlock Origin Lite…"
        WebExtensions.installUBlockLite { [weak self] result in
            guard let self else { return }
            self.getUBlock.isEnabled = true
            switch result {
            case let .success(version):
                self.extensionsStatus.stringValue = "Installed uBlock Origin Lite \(version)."
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.updateExtensionsStatus() }
            case let .failure(error):
                self.extensionsStatus.stringValue = "Couldn’t install: \(error.localizedDescription)"
            }
        }
    }

    @objc private func openExtensionsFolder() {
        try? FileManager.default.createDirectory(at: WebExtensions.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(WebExtensions.folder)
    }

    private func buildTerminal() -> NSView {
        for choice in TerminalThemeChoice.all {
            if choice.id == TerminalThemeChoice.ghosttyConfig { theme.menu?.addItem(.separator()) }
            theme.addItem(withTitle: choice.name)
            theme.lastItem?.representedObject = choice.id
        }
        // Ghostty's own collection, the names `theme =` takes. Type to jump.
        theme.menu?.addItem(.separator())
        theme.menu?.addItem(NSMenuItem.sectionHeader(title: "Ghostty Themes"))
        for name in GhosttyThemes.names {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.representedObject = TerminalThemeChoice.ghosttyPrefix + name
            theme.menu?.addItem(item)
        }
        theme.target = self
        theme.action = #selector(terminalChanged)

        font.addItem(withTitle: "From Ghostty config")
        font.menu?.addItem(.separator())
        for family in Self.monospacedFamilies() { font.addItem(withTitle: family) }
        font.target = self
        font.action = #selector(terminalChanged)

        size.addItem(withTitle: "From Ghostty config")
        size.menu?.addItem(.separator())
        for points in [10, 11, 12, 13, 14, 15, 16, 18, 20, 24] { size.addItem(withTitle: "\(points) pt") ; size.lastItem?.tag = points }
        size.target = self
        size.action = #selector(terminalChanged)

        contrast.target = self
        contrast.action = #selector(terminalChanged)
        copySelect.target = self
        copySelect.action = #selector(terminalChanged)
        for (title, value) in Self.opacities {
            opacity.addItem(withTitle: title)
            opacity.lastItem?.representedObject = value
        }
        opacity.target = self
        opacity.action = #selector(terminalChanged)

        configPath.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        configPath.textColor = .secondaryLabelColor
        configPath.lineBreakMode = .byTruncatingMiddle
        configPath.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        let edit = NSButton(title: "Edit Config…", target: self, action: #selector(editConfig))
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadConfig))
        let buttons = NSStackView(views: [edit, reload])
        buttons.spacing = 8
        configIssue.font = .systemFont(ofSize: 11)
        configIssue.textColor = .systemRed
        configIssue.preferredMaxLayoutWidth = 360
        configIssue.isHidden = true
        let config = NSStackView(views: [configPath, configIssue, buttons, note("Everything else (cursor, padding, keybinds, any Ghostty option) lives in your Ghostty config, shared with Ghostty. Saved edits apply right away.")])
        config.orientation = .vertical
        config.alignment = .leading
        config.spacing = 6

        return form([
            [label("Theme:"), stack(theme, "The paired themes follow the system’s light and dark appearance.")],
            [label("Font:"), font],
            [label("Size:"), size],
            [label("Background:"), stack(opacity, "Below opaque, the window’s material shows through terminals.")],
            [label("Copy on select:"), stack(copySelect, "Selected text goes straight to the clipboard.")],
            [label("Contrast boost:"), stack(contrast, "Lifts text too close to its background, like dim gray on dark.")],
            [label("Ghostty config:"), config],
        ])
    }

    private static let opacities: [(String, Double)] = [("Opaque", 1), ("Translucent (90%)", 0.9), ("Translucent (80%)", 0.8), ("Frosted (70%)", 0.7), ("Glass (50%)", 0.5)]

    /// Installed fixed-pitch families, the usual terminal fonts.
    private static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) ?? manager.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            return font.isFixedPitch && !family.hasPrefix(".")
        }
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func refresh() {
        windows.selectItem(at: Settings.windowPerSpace ? 1 : 0)
        sidebar.state = Settings.sidebarVisible ? .on : .off
        dim.state = Settings.dimUnfocused ? .on : .off
        translucent.state = Settings.translucentWindow ? .on : .off
        let opacityIndex = Self.opacities.firstIndex { abs($0.1 - Settings.terminalOpacity) < 0.001 } ?? 0
        opacity.selectItem(at: opacityIndex)
        notify.selectItem(at: Settings.Notify.allCases.firstIndex(of: Settings.notify) ?? 0)
        if Settings.sound.isEmpty { sound.selectItem(at: 0) } else { sound.selectItem(withTitle: Settings.sound) }
        links.selectItem(at: Settings.Links.allCases.firstIndex(of: Settings.links) ?? 0)
        fullscreen.selectItem(at: Settings.BrowserFullscreen.allCases.firstIndex(of: Settings.browserFullscreen) ?? 0)
        paneKeys.selectItem(at: Settings.PaneKeys.allCases.firstIndex(of: Settings.paneKeys) ?? 0)
        herdr.stringValue = herdrDescription()

        let themeIndex = theme.itemArray.firstIndex { $0.representedObject as? String == Settings.terminalTheme } ?? 0
        theme.selectItem(at: themeIndex)
        if Settings.fontFamily.isEmpty || font.item(withTitle: Settings.fontFamily) == nil {
            font.selectItem(at: 0)
        } else {
            font.selectItem(withTitle: Settings.fontFamily)
        }
        if !size.selectItem(withTag: Int(Settings.fontSize)) || Settings.fontSize == 0 { size.selectItem(at: 0) }
        copySelect.state = Settings.copyOnSelect ? .on : .off
        contrast.selectedSegment = ContrastBoost.allCases.firstIndex(of: Settings.contrast) ?? 1
        configPath.stringValue = TerminalAppearance.configPath().map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? "None yet: Edit Config creates ~/.config/ghostty/config.ghostty"
        configIssue.stringValue = TerminalAppearance.lastIssue.map { "Couldn’t load it, keeping the last good config:\n" + $0 } ?? ""
        let hadIssue = !configIssue.isHidden
        configIssue.isHidden = TerminalAppearance.lastIssue == nil
        if hadIssue == configIssue.isHidden { fitTerminalPage() }
    }

    /// The error line comes and goes; the Terminal page resizes with it.
    private func fitTerminalPage() {
        guard let tabs = window?.contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { $0.label == "Terminal" }),
              let page = tabs.tabViewItems[index].viewController else { return }
        page.view.layoutSubtreeIfNeeded()
        page.preferredContentSize = page.view.fittingSize
        if tabs.selectedTabViewItemIndex == index, let window {
            var frame = window.frame
            let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: page.view.fittingSize)).size
            frame.origin.y += frame.height - size.height
            frame.size = size
            window.setFrame(frame, display: true, animate: true)
        }
    }

    @objc private func terminalChanged() {
        Settings.terminalTheme = theme.selectedItem?.representedObject as? String ?? TerminalThemeChoice.defaultID
        Settings.fontFamily = font.indexOfSelectedItem <= 0 ? "" : font.titleOfSelectedItem ?? ""
        Settings.fontSize = size.indexOfSelectedItem <= 0 ? 0 : Double(size.selectedItem?.tag ?? 0)
        Settings.contrast = ContrastBoost.allCases[max(0, contrast.selectedSegment)]
        Settings.terminalOpacity = opacity.selectedItem?.representedObject as? Double ?? 1
        Settings.copyOnSelect = copySelect.state == .on
        onTerminalChange?()
        refresh()
    }

    @objc private func editConfig() {
        TerminalAppearance.editConfig()
        refresh()
    }

    @objc private func reloadConfig() {
        onTerminalChange?()
        refresh()
    }

    @objc private func windowsChanged() {
        let perSpace = windows.indexOfSelectedItem == 1
        guard perSpace != Settings.windowPerSpace else { return }
        onWindowModeChange?()
    }

    @objc private func sidebarChanged() {
        Settings.sidebarVisible = sidebar.state == .on
        Settings.changed()
    }

    @objc private func translucentChanged() {
        Settings.translucentWindow = translucent.state == .on
        Settings.changed()
    }

    @objc private func dimChanged() {
        Settings.dimUnfocused = dim.state == .on
        Settings.changed()
    }

    @objc private func soundChanged() {
        let name = sound.indexOfSelectedItem <= 0 ? "" : sound.titleOfSelectedItem ?? ""
        Settings.sound = name
        if !name.isEmpty { NSSound(named: name)?.play() }
    }

    @objc private func notifyChanged() {
        Settings.notify = Settings.Notify.allCases[notify.indexOfSelectedItem]
    }

    @objc private func paneKeysChanged() {
        Settings.paneKeys = Settings.PaneKeys.allCases[max(0, paneKeys.indexOfSelectedItem)]
        MainMenu.applyPaneKeys()
        Settings.changed()
    }

    @objc private func fullscreenChanged() {
        Settings.browserFullscreen = Settings.BrowserFullscreen.allCases[max(0, fullscreen.indexOfSelectedItem)]
    }

    @objc private func linksChanged() {
        Settings.links = Settings.Links.allCases[links.indexOfSelectedItem]
    }
}
