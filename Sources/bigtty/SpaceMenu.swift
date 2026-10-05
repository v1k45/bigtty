import AppKit

/// Window ▸ every space, open or not: the session on screen flat under its
/// header, every other session and machine in a submenu. A space with more
/// than one tab also lists its tabs as "space › tab", so menu search (Help ▸
/// Search, Spotlight's menu actions) finds a tab by name. Every item only
/// jumps: nothing here moves a pane or changes herdr's focus.
@MainActor
enum SpaceMenu {
    struct Tab {
        let id: String
        let title: String
        let waiting: Int
    }

    struct Space {
        let ref: SpaceRef
        let name: String
        let waiting: Int
        let tabs: [Tab]
    }

    /// One session: "This Mac · hq", "orb · main".
    struct Group {
        let title: String
        let spaces: [Space]
    }

    /// What a picked item shows; no tab means the space as it was.
    final class Target: NSObject {
        let space: SpaceRef
        let tab: String?

        init(space: SpaceRef, tab: String?) {
            self.space = space
            self.tab = tab
        }
    }

    /// Tab rows per space: more go to ⌘K.
    static let maxTabs = 8

    static func groupTitle(machine: String, session: String) -> String { "\(machine) · \(session)" }

    static func tabTitle(space: String, tab: String) -> String { "\(space) › \(tab)" }

    /// The items to append to the Window menu: `shown` flat, `others` as submenus.
    static func items(shown: Group?, others: [Group], target: AnyObject, action: Selector) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let shown, !shown.spaces.isEmpty {
            items.append(.sectionHeader(title: shown.title))
            items += rows(shown.spaces, target: target, action: action)
        }
        let others = others.filter { !$0.spaces.isEmpty }
        if !others.isEmpty {
            if !items.isEmpty { items.append(.separator()) }
            for group in others {
                let submenu = NSMenu(title: group.title)
                for row in rows(group.spaces, target: target, action: action) { submenu.addItem(row) }
                let holder = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                holder.submenu = submenu
                let waiting = group.spaces.reduce(0) { $0 + $1.waiting }
                if waiting > 0 { holder.badge = NSMenuItemBadge(count: waiting) }
                items.append(holder)
            }
        }
        return items
    }

    private static func rows(_ spaces: [Space], target: AnyObject, action: Selector) -> [NSMenuItem] {
        var rows: [NSMenuItem] = []
        for space in spaces {
            rows.append(row(space.name, waiting: space.waiting, to: Target(space: space.ref, tab: nil), target: target, action: action))
            guard space.tabs.count > 1 else { continue }
            for tab in space.tabs.prefix(maxTabs) {
                let item = row(tabTitle(space: space.name, tab: tab.title), waiting: tab.waiting,
                               to: Target(space: space.ref, tab: tab.id), target: target, action: action)
                item.indentationLevel = 1
                rows.append(item)
            }
        }
        return rows
    }

    private static func row(_ title: String, waiting: Int, to destination: Target, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = destination
        // A badge, not "(2)" in the title: search matches the name alone.
        if waiting > 0 { item.badge = NSMenuItemBadge(count: waiting) }
        return item
    }
}
