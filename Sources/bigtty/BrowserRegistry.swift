import AppKit
import HerdrKit
import Network
import WebKit

/// Browser storage per machine. This Mac's panes share the default store; a
/// remote machine's panes get their own, proxied through its SSH tunnel's
/// SOCKS port, so `localhost` means that machine.
@MainActor
enum BrowserProxy {
    private static var stores: [String: WKWebsiteDataStore] = [:]
    private static var ports: [String: Int] = [:]

    static func store(for machine: Machine) -> WKWebsiteDataStore? {
        guard !machine.isLocal else { return nil }
        let store = stores[machine.id] ?? {
            // A stable identifier per machine keeps its cookies across launches.
            let uuid = UUID(uuidString: String(machine.id.prefix(36))) ?? UUID()
            let made = WKWebsiteDataStore(forIdentifier: uuid)
            stores[machine.id] = made
            return made
        }()
        if let port = machine.socksPort, ports[machine.id] != port {
            ports[machine.id] = port
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
            var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
            // Everything, localhost included, goes to the machine.
            proxy.excludedDomains = []
            store.proxyConfigurations = [proxy]
        }
        return store
    }
}

/// Owns every browser pane's web view, independent of windows, so agents
/// can drive a browser whose space isn't on screen. Windows borrow the view
/// for the pane they show.
@MainActor
final class BrowserRegistry {
    static let shared = BrowserRegistry()

    private var views: [String: BrowserPaneView] = [:]
    /// Most recently focused browser, the default target for commands.
    private(set) var lastFocused: String?

    func view(for hostID: String, machine: Machine? = nil) -> BrowserPaneView {
        if let view = views[hostID] { return view }
        let state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser)
        let view = BrowserPaneView(
            hostID: hostID, state: state,
            dataStore: machine.flatMap { BrowserProxy.store(for: $0) },
            localhostMapper: machine?.localhostMapper
        )
        // Until a window shows it, lay the page out at a desktop size.
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        view.layoutSubtreeIfNeeded()
        views[hostID] = view
        return view
    }

    func existing(_ hostID: String) -> BrowserPaneView? { views[hostID] }

    func noteFocus(_ hostID: String) {
        lastFocused = hostID
        if let view = views[hostID] { WebExtensions.tabActivated(view) }
    }

    /// Drops views whose herdr pane is gone.
    func prune(keeping live: Set<String>) {
        for (id, view) in views where !live.contains(id) && HostPaneStore.shared[id] == nil {
            view.removeFromSuperview()
            views.removeValue(forKey: id)
            WebExtensions.tabClosed(view)
        }
        if let lastFocused, views[lastFocused] == nil { self.lastFocused = nil }
    }

    var all: [(id: String, view: BrowserPaneView)] {
        views.map { ($0.key, $0.value) }.sorted { $0.id < $1.id }
    }
}

/// Files panes, owned here for the same reasons as browsers: `btty open`
/// reaches a pane that isn't on screen, and windows only borrow the view.
@MainActor
final class FilesRegistry {
    static let shared = FilesRegistry()
    private var views: [String: FilesPaneView] = [:]

    /// The pane's view; `machine` is where its files live (this Mac if nil).
    func view(for hostID: String, machine: Machine? = nil) -> FilesPaneView {
        if let view = views[hostID] { return view }
        let state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .files)
        let source = machine.map { $0.isLocal ? .local : FileSource(runner: $0.runner) } ?? .local
        let view = FilesPaneView(hostID: hostID, state: state, source: source)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        views[hostID] = view
        return view
    }

    func existing(_ hostID: String) -> FilesPaneView? { views[hostID] }

    func prune(keeping live: Set<String>) {
        for (id, view) in views where !live.contains(id) && HostPaneStore.shared[id] == nil {
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
    }
}
