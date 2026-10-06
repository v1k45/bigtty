import AppKit
@testable import bigtty
import Testing

/// Menu search (Help ▸ Search, Spotlight's menu actions) reads every menu,
/// including what delegates fill in. A space's name must lead only to a
/// jump (Window), never to an action on the focused pane.
@MainActor @Suite struct MainMenuTests {
    let main: NSMenu = {
        _ = NSApplication.shared
        return MainMenu.build()
    }()

    func menu(_ title: String) -> NSMenu? {
        main.items.first { $0.title == title }?.submenu
    }

    func submenus(of menu: NSMenu) -> [NSMenu] {
        menu.items.compactMap(\.submenu).flatMap { [$0] + submenus(of: $0) }
    }

    @Test func onlyWindowListsSpacesByName() {
        let window = menu("Window")
        #expect(window != nil)
        for top in main.items.compactMap(\.submenu) where top !== window {
            // Services is AppKit's own.
            for menu in [top] + submenus(of: top) where menu !== NSApp.servicesMenu {
                #expect(menu.delegate == nil, "\(top.title) ▸ \(menu.title) is filled from live state")
            }
        }
    }

    /// ⌘F, ⌘G, ⇧⌘G, ⌘E go to the focused pane's find bar; ⌘R reloads.
    @Test func findAndReloadShortcuts() {
        let find = menu("Edit")?.items.first { $0.title == "Find" }?.submenu
        func item(_ menu: NSMenu?, _ title: String) -> NSMenuItem? { menu?.items.first { $0.title == title } }
        #expect(item(find, "Find…")?.action == #selector(PaneActions.showFind(_:)))
        #expect(item(find, "Find…")?.keyEquivalent == "f")
        #expect(item(find, "Find Next")?.action == #selector(PaneActions.findNext(_:)))
        #expect(item(find, "Find Previous")?.keyEquivalentModifierMask == [.command, .shift])
        #expect(item(find, "Use Selection for Find")?.action == #selector(PaneActions.useSelectionForFind(_:)))
        let reload = item(menu("View"), "Reload")
        #expect(reload?.action == #selector(PaneActions.reloadPane(_:)))
        #expect(reload?.keyEquivalent == "r")
        #expect(reload?.keyEquivalentModifierMask == [.command])
        // ⌘R is taken once.
        let all = main.items.compactMap(\.submenu).flatMap { [$0] + submenus(of: $0) }.flatMap(\.items)
        #expect(all.filter { $0.keyEquivalent == "r" && $0.keyEquivalentModifierMask == [.command] }.count == 1)
    }

    @Test func movePaneToOpensThePicker() {
        let item = menu("Pane")?.items.first { $0.title.hasPrefix("Move Pane To") }
        #expect(item?.submenu == nil)
        #expect(item?.action == #selector(PaneActions.movePaneTo(_:)))
    }
}

/// Window ▸ spaces: the session on screen flat, the rest in submenus, tabs
/// as "space › tab", and every item only a jump.
@MainActor @Suite struct SpaceMenuTests {
    let jump = #selector(AppDelegate.showSpaceFromMenu(_:))
    let target = NSObject()

    func space(_ name: String, machine: String = "local", id: String? = nil, waiting: Int = 0, tabs: [String] = ["1"]) -> SpaceMenu.Space {
        let workspace = id ?? name
        return SpaceMenu.Space(
            ref: SpaceRef(machine: machine, workspace: workspace), name: name, waiting: waiting,
            tabs: tabs.enumerated().map { SpaceMenu.Tab(id: "\(workspace):t\($0.offset + 1)", title: $0.element, waiting: $0.element == "logs" ? 1 : 0) }
        )
    }

    func build() -> [NSMenuItem] {
        let shown = SpaceMenu.Group(title: "This Mac · work", spaces: [
            space("api", waiting: 2, tabs: ["server", "logs"]),
            space("web"),
        ])
        let others = [
            SpaceMenu.Group(title: "This Mac · default", spaces: [space("notes", machine: "session:default")]),
            SpaceMenu.Group(title: "devbox · main", spaces: [space("api", machine: "devbox", waiting: 1)]),
            SpaceMenu.Group(title: "devbox · idle", spaces: []),
        ]
        return SpaceMenu.items(shown: shown, others: others, target: target, action: jump)
    }

    func all(_ items: [NSMenuItem]) -> [NSMenuItem] {
        items.flatMap { [$0] + all($0.submenu?.items ?? []) }
    }

    @Test func shownSessionFlatOthersInSubmenus() {
        let items = build()
        #expect(items.first?.isSectionHeader == true)
        #expect(items.first?.title == "This Mac · work")
        #expect(items.prefix(5).map(\.title) == ["This Mac · work", "api", "api › server", "api › logs", "web"])
        #expect(items[5].isSeparatorItem)
        // A session with no spaces isn't listed.
        #expect(items.dropFirst(6).map(\.title) == ["This Mac · default", "devbox · main"])
        #expect(items.dropFirst(6).allSatisfy { $0.submenu != nil && $0.representedObject == nil })
        #expect(items[7].submenu?.items.map(\.title) == ["api"])
        #expect(SpaceMenu.groupTitle(machine: "devbox", session: "main") == "devbox · main")
    }

    @Test func tabRowsOnlyForSpacesWithSeveral() {
        let titles = all(build()).map(\.title)
        #expect(titles.contains("api › logs"))
        #expect(!titles.contains { $0.hasPrefix("web ›") || $0.hasPrefix("notes ›") })
    }

    @Test func badgesNotCountsInTitles() {
        let items = all(build())
        #expect(!items.contains { $0.title.contains("(") })
        #expect(items.first { $0.title == "api" }?.badge?.itemCount == 2)
        #expect(items.first { $0.title == "api › logs" }?.badge?.itemCount == 1)
        #expect(items.first { $0.title == "web" }?.badge == nil)
        // A submenu adds up what waits inside it.
        #expect(items.first { $0.title == "devbox · main" }?.badge?.itemCount == 1)
    }

    @Test func tabsCappedPerSpace() {
        let many = space("big", tabs: (1...12).map { "tab \($0)" })
        let items = SpaceMenu.items(shown: .init(title: "This Mac · work", spaces: [many]), others: [], target: target, action: jump)
        let tabs = items.filter { $0.title.hasPrefix("big › ") }
        #expect(tabs.count == SpaceMenu.maxTabs)
        #expect(tabs.first?.title == "big › tab 1")
    }

    @Test func everyItemOnlyJumps() {
        // Submenu holders only open their submenu.
        let actionable = all(build()).filter { $0.action != nil && $0.submenu == nil }
        #expect(!actionable.isEmpty)
        for item in actionable {
            #expect(item.action == jump)
            #expect(item.target === target)
            #expect(item.representedObject is SpaceMenu.Target)
        }
        let logs = all(build()).first { $0.title == "api › logs" }?.representedObject as? SpaceMenu.Target
        #expect(logs?.space == SpaceRef(machine: "local", workspace: "api"))
        #expect(logs?.tab == "api:t2")
        let space = all(build()).first { $0.title == "web" }?.representedObject as? SpaceMenu.Target
        #expect(space?.tab == nil)
    }
}

