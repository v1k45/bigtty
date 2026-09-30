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

/// ⌘, — a plain native form.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    var herdrDescription: () -> String = { "" }
    var onWindowModeChange: (() -> Void)?

    private let windows = NSPopUpButton()
    private let sidebar = NSSwitch()
    private let dim = NSSwitch()
    private let notify = NSPopUpButton()
    private let links = NSPopUpButton()
    private let herdr = NSTextField(labelWithString: "")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "General"
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show() {
        refresh()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
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

        func note(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 340
            return label
        }
        func stack(_ control: NSView, _ text: String?) -> NSView {
            guard let text else { return control }
            let v = NSStackView(views: [control, note(text)])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 4
            return v
        }
        let grid = NSGridView(views: [
            [label("Windows:"), stack(windows, "Spaces live in one window's sidebar, or each gets its own window.")],
            [label("Sidebar:"), stack(sidebar, "Show machines and spaces in new windows. ⌃⌘S toggles it per window.")],
            [label("Dim unfocused panes:"), dim],
            [label("Notify when an agent:"), stack(notify, "Only for panes you aren’t looking at.")],
            [label("Open terminal links:"), links],
            [label("herdr:"), herdr],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        window?.contentView = content
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
