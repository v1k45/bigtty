import Foundation

/// What the address bar does with text and URLs, kept apart from the web
/// view so it can be tested without one.
enum BrowserAddress {
    /// Schemes taken as they are. (`localhost:3000` also parses as a URL,
    /// with the scheme "localhost", so this can't be "anything with a scheme".)
    private static let schemes: Set<String> = ["http", "https", "file", "about", "webkit-extension", "safari-web-extension"]

    /// Turns what someone typed into a URL: full URLs as-is, bare hosts
    /// (`localhost:3000`, `example.com`) get a scheme, `:3000` means
    /// localhost, anything else searches.
    static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) {
            return url
        }
        if text.hasPrefix(":"), let port = text.dropFirst().split(separator: "/", maxSplits: 1).first, port.allSatisfy(\.isNumber) {
            return URL(string: "http://localhost" + text)
        }
        if !text.contains(" "), let host = host(in: text),
           let url = URL(string: (isLocal(host: host) ? "http://" : "https://") + text)
        {
            return url
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    /// The host of text that reads as an address: it has a dot, a port, or
    /// is localhost. Nil for a search.
    private static func host(in text: String) -> String? {
        let authority = text.prefix { !"/?#".contains($0) }
        let bare = authority.split(separator: "@").last.map(String.init) ?? ""
        if bare.hasPrefix("[") { return bare.contains("]") ? String(bare.prefix { $0 != "]" }) + "]" : nil }
        let parts = bare.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty else { return nil }
        let hasPort = parts.count == 2 && !parts[1].isEmpty && parts[1].allSatisfy(\.isNumber)
        guard parts.count == 1 || hasPort else { return nil }
        return host.contains(".") || hasPort || host == "localhost" ? String(host) : nil
    }

    /// This machine: no warning for plain http, which is how dev servers run.
    static func isLocal(host: String) -> Bool {
        let host = host.lowercased()
        if ["localhost", "0.0.0.0", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { Int($0) != nil }
    }

    // MARK: - Showing it

    /// An address split the way the bar draws it: the part that says which
    /// site this is, then the rest, dimmer.
    struct Shown: Equatable {
        var site: String
        var rest: String
    }

    /// `https://` and any user name go; the host and port stay, then the
    /// path and query, which developers need. Other schemes show whole.
    static func shown(_ url: URL) -> Shown {
        let text = url.absoluteString
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let start = text.range(of: "://")?.upperBound else {
            return Shown(site: "", rest: text)
        }
        let tail = text[start...]
        let end = tail.firstIndex { "/?#".contains($0) } ?? tail.endIndex
        let authority = tail[..<end]
        let site = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
        let rest = String(tail[end...])
        return Shown(site: String(site), rest: rest == "/" ? "" : rest)
    }

    /// Shortens an address to fit `width`, cutting the end of the path and
    /// then the start of the host: `accounts.bank.com.evil.example` must end
    /// up as `…evil.example`, never as something that reads like the bank.
    static func fit(_ shown: Shown, width: CGFloat, measure: (String) -> CGFloat) -> Shown {
        let dots = "…"
        if measure(shown.site + shown.rest) <= width { return shown }
        if !shown.rest.isEmpty, measure(shown.site + dots) <= width {
            let path = Array(shown.rest)
            let keep = longest(path.count) { measure(shown.site + String(path.prefix($0)) + dots) <= width }
            return Shown(site: shown.site, rest: String(path.prefix(keep)) + dots)
        }
        if measure(shown.site) <= width { return Shown(site: shown.site, rest: "") }
        let host = Array(shown.site)
        let keep = longest(host.count) { measure(dots + String(host.suffix($0))) <= width }
        var tail = String(host.suffix(keep))
        // Start on a label when that leaves more than the last one.
        if let dot = tail.firstIndex(of: "."), tail[tail.index(after: dot)...].contains(".") {
            tail = String(tail[tail.index(after: dot)...])
        }
        return Shown(site: dots + tail, rest: "")
    }

    /// The largest n in 0...limit for which `fits` holds (and holds below it).
    private static func longest(_ limit: Int, fits: (Int) -> Bool) -> Int {
        var low = 0, high = limit
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return low
    }

    // MARK: - Security

    /// What the slot at the start of the field says.
    enum Security: Equatable {
        /// Nothing worth saying: local http, `file:`, no page.
        case quiet
        /// https, everything on the page secure.
        case secure
        /// https, but the page loaded something insecure.
        case mixed
        /// Plain http to somewhere else.
        case insecure

        var isWarning: Bool { self == .mixed || self == .insecure }
    }

    /// `url` is the address shown, so a remote pane's forwarded page counts
    /// as the localhost it is.
    static func security(of url: URL?, onlySecureContent: Bool) -> Security {
        switch url?.scheme?.lowercased() {
        case "https": onlySecureContent ? .secure : .mixed
        case "http": isLocal(host: url?.host ?? "") ? .quiet : .insecure
        default: .quiet
        }
    }
}
