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
    private let notify = NSPopUpButton()
    private let links = NSPopUpButton()
    private let herdr = NSTextField(labelWithString: "")

    private let theme = NSPopUpButton()
    private let font = NSPopUpButton()
    private let size = NSPopUpButton()
    private let contrast = NSSegmentedControl(labels: ContrastBoost.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let configPath = NSTextField(labelWithString: "")

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
        window.contentViewController = tabs
        window.toolbarStyle = .preference
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
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
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
        for item in Settings.Links.allCases { links.addItem(withTitle: item.title) }
        links.target = self
        links.action = #selector(linksChanged)
        sidebar.target = self
        sidebar.action = #selector(sidebarChanged)
        dim.target = self
        dim.action = #selector(dimChanged)
        herdr.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        herdr.textColor = .secondaryLabelColor
        return form([
            [label("Windows:"), stack(windows, "Spaces live in one window's sidebar, or each gets its own window.")],
            [label("Sidebar:"), stack(sidebar, "Show machines and spaces in new windows. ⌃⌘S toggles it per window.")],
            [label("Dim unfocused panes:"), dim],
            [label("Notify when an agent:"), stack(notify, "Only for panes you aren’t looking at.")],
            [label("Open terminal links:"), links],
            [label("herdr:"), herdr],
        ])
    }

    private func buildTerminal() -> NSView {
        for choice in TerminalThemeChoice.all {
            if choice.id == TerminalThemeChoice.ghosttyConfig { theme.menu?.addItem(.separator()) }
            theme.addItem(withTitle: choice.name)
            theme.lastItem?.representedObject = choice.id
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

        configPath.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        configPath.textColor = .secondaryLabelColor
        configPath.lineBreakMode = .byTruncatingMiddle
        configPath.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        let edit = NSButton(title: "Edit Config…", target: self, action: #selector(editConfig))
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadConfig))
        let buttons = NSStackView(views: [edit, reload])
        buttons.spacing = 8
        let config = NSStackView(views: [configPath, buttons, note("Everything else (cursor, padding, keybinds, any Ghostty option) lives in your Ghostty config, shared with Ghostty. Saved edits apply right away.")])
        config.orientation = .vertical
        config.alignment = .leading
        config.spacing = 6

        return form([
            [label("Theme:"), stack(theme, "Light and dark follow the system appearance.")],
            [label("Font:"), font],
            [label("Size:"), size],
            [label("Contrast boost:"), stack(contrast, "Lifts text too close to its background, like dim gray on dark.")],
            [label("Ghostty config:"), config],
        ])
    }

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
        notify.selectItem(at: Settings.Notify.allCases.firstIndex(of: Settings.notify) ?? 0)
        links.selectItem(at: Settings.Links.allCases.firstIndex(of: Settings.links) ?? 0)
        herdr.stringValue = herdrDescription()

        let themeIndex = theme.itemArray.firstIndex { $0.representedObject as? String == Settings.terminalTheme } ?? 0
        theme.selectItem(at: themeIndex)
        if Settings.fontFamily.isEmpty || font.item(withTitle: Settings.fontFamily) == nil {
            font.selectItem(at: 0)
        } else {
            font.selectItem(withTitle: Settings.fontFamily)
        }
        if !size.selectItem(withTag: Int(Settings.fontSize)) || Settings.fontSize == 0 { size.selectItem(at: 0) }
        contrast.selectedSegment = ContrastBoost.allCases.firstIndex(of: Settings.contrast) ?? 1
        configPath.stringValue = TerminalAppearance.configPath().map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? "None yet: Edit Config creates ~/.config/ghostty/config.ghostty"
    }

    @objc private func terminalChanged() {
        Settings.terminalTheme = theme.selectedItem?.representedObject as? String ?? TerminalThemeChoice.defaultID
        Settings.fontFamily = font.indexOfSelectedItem <= 0 ? "" : font.titleOfSelectedItem ?? ""
        Settings.fontSize = size.indexOfSelectedItem <= 0 ? 0 : Double(size.selectedItem?.tag ?? 0)
        Settings.contrast = ContrastBoost.allCases[max(0, contrast.selectedSegment)]
        onTerminalChange?()
    }

    @objc private func editConfig() {
        TerminalAppearance.editConfig()
        refresh()
    }

    @objc private func reloadConfig() { onTerminalChange?() }

    @objc private func windowsChanged() {
        let perSpace = windows.indexOfSelectedItem == 1
        guard perSpace != Settings.windowPerSpace else { return }
        onWindowModeChange?()
    }

    @objc private func sidebarChanged() {
        Settings.sidebarVisible = sidebar.state == .on
        Settings.changed()
    }

    @objc private func dimChanged() {
        Settings.dimUnfocused = dim.state == .on
        Settings.changed()
    }

    @objc private func notifyChanged() {
        Settings.notify = Settings.Notify.allCases[notify.indexOfSelectedItem]
    }

    @objc private func linksChanged() {
        Settings.links = Settings.Links.allCases[links.indexOfSelectedItem]
    }
}
