import AppKit
import HerdrKit

/// Owns every browser pane's web view, independent of windows, so agents
/// can drive a browser whose space isn't on screen. Windows borrow the view
/// for the pane they show.
@MainActor
final class BrowserRegistry {
    static let shared = BrowserRegistry()

    private var views: [String: BrowserPaneView] = [:]
    /// Most recently focused browser, the default target for commands.
    private(set) var lastFocused: String?

    func view(for hostID: String) -> BrowserPaneView {
        if let view = views[hostID] { return view }
        let state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser)
        let view = BrowserPaneView(hostID: hostID, state: state)
        // Until a window shows it, lay the page out at a desktop size.
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        view.layoutSubtreeIfNeeded()
        views[hostID] = view
        return view
    }

    func existing(_ hostID: String) -> BrowserPaneView? { views[hostID] }

    func noteFocus(_ hostID: String) { lastFocused = hostID }

    /// Drops views whose herdr pane is gone.
    func prune(keeping live: Set<String>) {
        for (id, view) in views where !live.contains(id) && HostPaneStore.shared[id] == nil {
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
        if let lastFocused, views[lastFocused] == nil { self.lastFocused = nil }
    }

    var all: [(id: String, view: BrowserPaneView)] {
        views.map { ($0.key, $0.value) }.sorted { $0.id < $1.id }
    }
}
