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

    @Test func movePaneToOpensThePicker() {
        let item = menu("Pane")?.items.first { $0.title.hasPrefix("Move Pane To") }
        #expect(item?.submenu == nil)
        #expect(item?.action == #selector(PaneActions.movePaneTo(_:)))
    }
}
