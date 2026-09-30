import AppKit
import WebKit

/// A browser pane: toolbar plus WKWebView. Its URL and title are kept in
/// `HostPaneStore` so the page comes back after a restart, and the title is
/// mirrored to herdr so other clients see what the pane shows.
@MainActor
final class BrowserPaneView: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let hostID: String
    let webView: WKWebView
    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    private let external = NSButton()
    private let address = NSTextField()
    private var observations: [NSKeyValueObservation] = []

    /// The page's title or URL changed.
    var onStateChange: ((HostPaneState) -> Void)?
    /// The user clicked into the pane.
    var onFocus: (() -> Void)?

    static let toolbarHeight: CGFloat = 30

    /// One cookie/storage store for every browser pane, persisted on disk.
    private static let dataStore = WKWebsiteDataStore.default()

    init(hostID: String, state: HostPaneState) {
        self.hostID = hostID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")

        configure(back, "chevron.left", "Back", #selector(goBack))
        configure(forward, "chevron.right", "Forward", #selector(goForward))
        configure(reload, "arrow.clockwise", "Reload", #selector(reloadPage))
        configure(external, "safari", "Open in Default Browser", #selector(openExternally))
        address.placeholderString = "Search or enter address"
        address.font = .systemFont(ofSize: 12)
        address.bezelStyle = .roundedBezel
        address.lineBreakMode = .byTruncatingTail
        address.delegate = self
        address.target = self
        address.action = #selector(addressEntered)
        for view in [back, forward, reload, address, external, webView] as [NSView] { addSubview(view) }

        observations = [
            webView.observe(\.url, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageChanged() }
            },
            webView.observe(\.title, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageChanged() }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
        ]

        if let url = state.url.flatMap(Self.normalize) {
            address.stringValue = url.absoluteString
            webView.load(URLRequest(url: url))
        }
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.toolTip = label
        button.target = self
        button.action = action
    }

    override func layout() {
        super.layout()
        let b = bounds
        let h = Self.toolbarHeight
        let y = b.height - h + (h - 22) / 2
        back.frame = NSRect(x: 6, y: y, width: 24, height: 22)
        forward.frame = NSRect(x: 30, y: y, width: 24, height: 22)
        reload.frame = NSRect(x: 54, y: y, width: 24, height: 22)
        external.frame = NSRect(x: b.width - 30, y: y, width: 24, height: 22)
        address.frame = NSRect(x: 84, y: y, width: max(0, b.width - 84 - 36), height: 22)
        webView.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - h))
    }

    // MARK: - Navigation

    /// Turns what someone typed into a URL: full URLs as-is, bare hosts
    /// (`localhost:3000`, `example.com`) get a scheme, anything else searches.
    static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost") || text.contains(":"))
        if looksLikeHost {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("0.0.0.0")
            return URL(string: (local ? "http://" : "https://") + text)
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    func load(_ input: String) {
        guard let url = Self.normalize(input) else { return }
        address.stringValue = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func focusAddressBar() {
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    @objc private func addressEntered() {
        load(address.stringValue)
        window?.makeFirstResponder(webView)
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reloadPage() { webView.reload() }

    @objc private func openExternally() {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }

    private func updateButtons() {
        back.isEnabled = webView.canGoBack
        forward.isEnabled = webView.canGoForward
    }

    private func pageChanged() {
        if let url = webView.url, window?.firstResponder !== address.currentEditor() {
            address.stringValue = url.absoluteString
        }
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser)
        state.url = webView.url?.absoluteString ?? state.url
        state.title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        HostPaneStore.shared[hostID] = state
        onStateChange?(state)
    }

    // MARK: - WKUIDelegate

    /// `target=_blank` and `window.open` load in this pane.
    func webView(
        _ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    // MARK: - Focus

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onFocus?() }
        return hit
    }
}
