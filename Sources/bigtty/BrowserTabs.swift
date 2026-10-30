import Foundation

/// A page tab as saved in `panes.json`. The back/forward list lives in its
/// own file (`BrowserPageState`): this one is rewritten on every title change.
struct BrowserTabState: Codable, Equatable {
    var id: String
    var url: String?
    var title: String?
    /// An agent opened it.
    var agent: Bool?
}

/// The rules of a pane's page tabs, kept apart from the views.
enum BrowserTabRules {
    /// At two tabs the row appears; below this width it folds into a count.
    static let stripMinimumPaneWidth: CGFloat = 300
    static let tabMaximumWidth: CGFloat = 180
    static let tabMinimumWidth: CGFloat = 72
    /// Reopen list, per pane.
    static let closedLimit = 20

    static func newID() -> String { "t" + UUID().uuidString.prefix(8).lowercased() }

    /// Tabs share `available` equally up to a maximum. Below the minimum
    /// they stop shrinking and the row scrolls.
    static func tabWidth(count: Int, available: CGFloat) -> (width: CGFloat, overflows: Bool) {
        guard count > 0 else { return (tabMaximumWidth, false) }
        let share = (available / CGFloat(count)).rounded(.down)
        return (min(tabMaximumWidth, max(tabMinimumWidth, share)), share < tabMinimumWidth)
    }

    /// Which tab takes over when the active one at `index` closes: the
    /// one to its right, or the new last.
    static func indexAfterClosing(_ index: Int, count: Int) -> Int {
        max(0, min(index, count - 2))
    }

    /// ⌃⌥1–8, and ⌃⌥9 for the last, as in browsers.
    static func index(forNumber n: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(n) else { return nil }
        if n == 9 { return count - 1 }
        return n <= count ? n - 1 : nil
    }

    /// `--tab`: a number as `tab list` prints it, or a tab id. Ids are what
    /// agents should keep, since numbers shift when a tab closes.
    static func index(matching wanted: String, ids: [String]) -> Int? {
        if let position = ids.firstIndex(of: wanted) { return position }
        guard let n = Int(wanted), n >= 1, n <= ids.count else { return nil }
        return n - 1
    }

    /// Whether two addresses are the same page, for a terminal link that
    /// could reuse a tab: a trailing slash and a fragment don't count.
    static func samePage(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = key(a), let b = key(b) else { return false }
        return a == b
    }

    private static func key(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.url?.absoluteString.lowercased()
    }

    /// The letter on a tab's tile until favicons exist.
    static func tile(title: String, url: URL?) -> String {
        let host = url?.host?.replacingOccurrences(of: "www.", with: "")
        let source = title.isEmpty ? (host ?? "") : title
        return source.first(where: \.isLetter).map { String($0).uppercased() } ?? "•"
    }
}

/// A closed tab, for ⇧⌘T. It holds URLs, so clearing history clears these too.
struct ClosedBrowserTab {
    let tab: BrowserTabState
    let index: Int
    let history: Data?
}

/// Each tab's back/forward list and scroll position, one file per tab in
/// `browser-tabs/`. WebKit's `interactionState` is opaque and can be large.
enum BrowserPageState {
    /// Above this a page's state isn't worth restoring.
    static let sizeLimit = 256 * 1024

    static var folder: URL { HostPaneStore.directory.appendingPathComponent("browser-tabs", isDirectory: true) }

    private static func file(_ id: String) -> URL? {
        // Ids come from `panes.json`: nothing there may name a path elsewhere.
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return folder.appendingPathComponent(id)
    }

    static func load(_ id: String) -> Data? {
        file(id).flatMap { try? Data(contentsOf: $0) }
    }

    static func save(_ data: Data?, for id: String) {
        guard let file = file(id) else { return }
        guard let data, data.count <= sizeLimit else { return remove(id) }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func remove(_ id: String) {
        if let file = file(id) { try? FileManager.default.removeItem(at: file) }
    }
}
