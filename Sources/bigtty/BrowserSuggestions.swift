import Foundation

/// One row under the address bar.
struct BrowserSuggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Goes to `url` in this tab.
        case go
        /// Jumps to a page that's already open, and loads nothing.
        case openTab(pane: String, tab: String)
        case devServer
        case history
        case search
    }

    var kind: Kind
    var title: String
    var detail: String
    var url: URL

    /// ⌘⌫ can remove it.
    var isHistory: Bool { kind == .history }
}

/// What the list is built from, gathered on the main thread.
struct BrowserSuggestionSources: Sendable {
    struct OpenTab: Equatable, Sendable {
        var pane: String
        var tab: String
        var url: String
        var title: String
        /// Where it is, for the row: the space's name.
        var place: String
        var inThisSpace: Bool
    }

    var tabs: [OpenTab] = []
    /// Ports listening in this space, on this pane's machine.
    var ports: [Int] = []
    var history: [BrowserVisit] = []
}

/// Builds the list, with no views or storage, so it can run off the main
/// thread and in tests. Nothing here reaches the network.
enum BrowserSuggestions {
    static let maximumRows = 8
    static let engine = "DuckDuckGo"

    /// The address as completion compares it: no scheme, no `www.`.
    static func bare(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://", "www."] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    /// What to add to `typed` for the top match to read in full, if the top
    /// match starts with it. Only a full-host-or-more address is offered,
    /// never a search, so Return always goes to something you've seen.
    static func completion(for typed: String, in rows: [BrowserSuggestion]) -> String? {
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        let wanted = typed.lowercased()
        for row in rows where [.devServer, .history].contains(row.kind) {
            let text = bare(displayed(row.url))
            if text.lowercased().hasPrefix(wanted), text.count > typed.count { return String(text.dropFirst(typed.count)) }
        }
        return nil
    }

    /// A URL as a row shows it.
    static func displayed(_ url: URL) -> String {
        var text = url.absoluteString
        if url.path == "/", url.query == nil, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func detail(_ url: URL) -> String {
        let shown = BrowserAddress.shown(url)
        return shown.site + shown.rest
    }

    private static func devServer(_ port: Int) -> BrowserSuggestion? {
        URL(string: "http://localhost:\(port)").map {
            BrowserSuggestion(kind: .devServer, title: "localhost:\(port)", detail: "dev server", url: $0)
        }
    }

    private static func tabRow(_ tab: BrowserSuggestionSources.OpenTab) -> BrowserSuggestion? {
        URL(string: tab.url).map {
            BrowserSuggestion(kind: .openTab(pane: tab.pane, tab: tab.tab), title: tab.title.isEmpty ? detail($0) : tab.title,
                              detail: "Switch to tab · \(tab.place)", url: $0)
        }
    }

    private static func historyRow(_ visit: BrowserVisit) -> BrowserSuggestion? {
        URL(string: visit.url).map {
            BrowserSuggestion(kind: .history, title: visit.title.isEmpty ? detail($0) : visit.title, detail: detail($0), url: $0)
        }
    }

    /// A blank field: this space's dev servers, its open tabs, recent pages.
    static func blank(_ sources: BrowserSuggestionSources) -> [BrowserSuggestion] {
        let servers = sources.ports.compactMap(devServer)
        let tabs = sources.tabs.filter(\.inThisSpace).compactMap(tabRow)
        let open = Set(tabs.map(\.url))
        let recent = sources.history.compactMap(historyRow).filter { !open.contains($0.url) }
        return Array((servers + tabs + recent).prefix(maximumRows))
    }

    private static func matches(_ query: [String], _ text: String) -> Bool {
        let lower = text.lowercased()
        return query.allSatisfy(lower.contains)
    }

    /// Typing. Row 1 is what Return does: the text as an address or, if it
    /// doesn't read as one, a search, unless a match will complete it. Then
    /// open tabs, dev servers, history and a search.
    static func typing(_ input: String, sources: BrowserSuggestionSources) -> [BrowserSuggestion] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return blank(sources) }
        let query = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let target = BrowserAddress.normalize(text) else { return [] }
        let searches = target.host == "duckduckgo.com" && !text.lowercased().contains("duckduckgo.com")
        let search = BrowserSuggestion(kind: .search, title: "Search \(engine) for “\(text)”", detail: "", url: searchURL(target, text))

        let servers = sources.ports.compactMap(devServer).filter { matches(query, $0.title) }
        let tabs = sources.tabs.filter { matches(query, "\($0.url) \($0.title)") }.compactMap(tabRow)
        var seen = Set(tabs.map(\.url.absoluteString) + servers.map(\.url.absoluteString))
        let history = sources.history.compactMap(historyRow).filter { seen.insert($0.url.absoluteString).inserted }

        let matched = servers + history
        var first: BrowserSuggestion
        if let completed = completion(for: text, in: matched), let url = BrowserAddress.normalize(text + completed) {
            first = BrowserSuggestion(kind: .go, title: bare(displayed(url)), detail: "", url: url)
        } else if searches {
            first = search
        } else {
            first = BrowserSuggestion(kind: .go, title: bare(displayed(target)), detail: "", url: target)
        }
        if first.kind == .go, let same = matched.first(where: { $0.url == first.url }), same.title != first.title { first.detail = same.title }
        var rows = [first] + tabs + (servers + history).filter { $0.url != first.url }
        if rows.count >= maximumRows { rows = Array(rows.prefix(maximumRows - 1)) }
        if first.kind != .search { rows.append(search) }
        return rows
    }

    /// The search for `text`, whichever way it would have gone.
    private static func searchURL(_ normalized: URL, _ text: String) -> URL {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url ?? normalized
    }
}
