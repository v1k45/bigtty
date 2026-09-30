import AppKit
import WebKit

/// A browser pane: toolbar plus WKWebView. Its URL and title are kept in
/// `HostPaneStore` so the page comes back after a restart, and the title is
/// mirrored to herdr so other clients see what the pane shows.
@MainActor
final class BrowserPaneView: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, WKScriptMessageHandler {
    let hostID: String
    let webView: WKWebView
    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    private let external = NSButton()
    private let closeButton = NSButton()
    /// The pane's × button.
    var onClose: (() -> Void)?
    private let address = NSTextField()
    private let addressBox = NSView()
    private let toolbarLine = NSView()
    private let progress = NSView()
    private let automationStrip = AutomationStrip()
    private let errorPage = BrowserErrorPage()
    private var automationHide: DispatchWorkItem?
    private var observations: [NSKeyValueObservation] = []

    /// The page's title or URL changed.
    var onStateChange: ((HostPaneState) -> Void)?
    /// The user clicked into the pane.
    var onFocus: (() -> Void)?

    static let toolbarHeight: CGFloat = 34

    /// One cookie/storage store for every browser pane, persisted on disk.
    private static let dataStore = WKWebsiteDataStore.default()

    /// The installed Safari's version, for the user agent.
    static let safariVersion: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        return info?["CFBundleShortVersionString"] as? String ?? "26.0"
    }()

    /// Reports whether any audible media plays in the frame.
    static let mediaHook = """
    (() => {
      const report = () => {
        const playing = Array.from(document.querySelectorAll('video, audio')).some(m =>
          !m.paused && !m.ended && !m.muted && m.volume > 0);
        try { window.webkit.messageHandlers.ghrMedia.postMessage(playing); } catch (_) {}
      };
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'])
        document.addEventListener(type, report, true);
    })();
    """

    private var audibleFrames: [String: Bool] = [:]
    /// Some frame is playing sound; shown on the tab.
    private(set) var isAudible = false {
        didSet {
            guard isAudible != oldValue else { return }
            pageChanged()
            NotificationCenter.default.post(name: .ghostherdrAudioChanged, object: self)
        }
    }
    /// Automation runs here, out of the page's reach.
    static let automationWorld = WKContentWorld.world(name: "ghostherdr")

    struct ConsoleEntry {
        let level: String
        let text: String
        let date: Date
    }

    private(set) var console: [ConsoleEntry] = []
    /// Resolved when the current navigation finishes (or fails).
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lastNavigationError: String?

    /// Set for a remote machine's panes: its `localhost` goes through SSH.
    let localhostMapper: LocalhostMapper?

    init(hostID: String, state: HostPaneState, dataStore: WKWebsiteDataStore? = nil, localhostMapper: LocalhostMapper? = nil) {
        self.hostID = hostID
        self.localhostMapper = localhostMapper
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore ?? Self.dataStore
        let content = config.userContentController
        content.addUserScript(WKUserScript(
            source: AutomationScript.source, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: Self.automationWorld
        ))
        content.addUserScript(WKUserScript(
            source: AutomationScript.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Video full screen (YouTube's button, the page's requestFullscreen).
        config.preferences.isElementFullscreenEnabled = true
        // Identify as the installed Safari: WebKit's default string lacks
        // Safari's version, and sites then call the browser outdated.
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        // Which frames are playing sound, for the tab's speaker.
        content.addUserScript(WKUserScript(source: Self.mediaHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "ghrConsole")
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "ghrMedia")
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")

        configure(back, "chevron.left", "Back", #selector(goBack))
        configure(forward, "chevron.right", "Forward", #selector(goForward))
        configure(reload, "arrow.clockwise", "Reload", #selector(reloadPage))
        configure(external, "safari", "Open in Default Browser", #selector(openExternally))
        configure(closeButton, "xmark", "Close Pane", #selector(closePane))
        address.placeholderString = "Search or enter address"
        address.font = .systemFont(ofSize: 12)
        address.isBezeled = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.alignment = .center
        address.lineBreakMode = .byTruncatingTail
        address.cell?.usesSingleLineMode = true
        address.delegate = self
        address.target = self
        address.action = #selector(addressEntered)
        addressBox.wantsLayer = true
        addressBox.layer?.cornerRadius = 7
        addressBox.addSubview(address)
        toolbarLine.wantsLayer = true
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progress.isHidden = true
        automationStrip.isHidden = true
        automationStrip.onTakeOver = { [weak self] in self?.hideAutomation() }
        errorPage.isHidden = true
        errorPage.onReload = { [weak self] in self?.reloadPage() }
        for view in [back, forward, reload, addressBox, external, closeButton, webView, errorPage, toolbarLine, progress, automationStrip] as [NSView] {
            addSubview(view)
        }
        wantsLayer = true

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
            webView.observe(\.isLoading, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateLoading() }
            },
            webView.observe(\.estimatedProgress, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            },
        ]

        if let url = state.url.flatMap(Self.normalize) {
            navigate(to: url)
        }
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.contentTintColor = .secondaryLabelColor
        button.isBordered = false
        button.toolTip = label
        button.target = self
        button.action = action
    }

    override func layout() {
        super.layout()
        let b = bounds
        let theme = Theme.current
        layer?.backgroundColor = theme?.pane.cgColor
        let h = Self.toolbarHeight
        let y = b.height - h + (h - 24) / 2
        back.frame = NSRect(x: 8, y: y, width: 26, height: 24)
        forward.frame = NSRect(x: 34, y: y, width: 26, height: 24)
        closeButton.frame = NSRect(x: b.width - 34, y: y, width: 26, height: 24)
        reload.frame = NSRect(x: b.width - 60, y: y, width: 26, height: 24)
        external.frame = NSRect(x: b.width - 86, y: y, width: 26, height: 24)
        // A centered, Safari-like address field.
        let available = b.width - 94 - 94
        let fieldWidth = max(120, min(available, max(available * 0.8, 260)))
        addressBox.frame = NSRect(x: (b.width - fieldWidth) / 2, y: y, width: fieldWidth, height: 24)
        addressBox.layer?.backgroundColor = theme?.field.cgColor
        address.frame = NSRect(x: 8, y: 4, width: fieldWidth - 16, height: 16)
        toolbarLine.frame = NSRect(x: 0, y: b.height - h, width: b.width, height: 0.5)
        toolbarLine.layer?.backgroundColor = theme?.separator.cgColor
        progress.frame = NSRect(x: 0, y: b.height - h - 1, width: b.width * max(0.05, webView.estimatedProgress), height: 2)
        var top = b.height - h
        if !automationStrip.isHidden {
            automationStrip.frame = NSRect(x: 0, y: top - 26, width: b.width, height: 26)
            top -= 26
        }
        webView.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, top))
        errorPage.frame = webView.frame
    }

    private func updateLoading() {
        let loading = webView.isLoading
        progress.isHidden = !loading
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        reload.toolTip = loading ? "Stop" : "Reload"
        if loading { errorPage.isHidden = true }
        needsLayout = true
    }

    /// Shows "claude is controlling this page · click @e3" for a few seconds
    /// after each automation command, so it's clear who's driving.
    func noteAutomation(_ text: String) {
        automationStrip.text = text
        if automationStrip.isHidden {
            automationStrip.isHidden = false
            needsLayout = true
        }
        automationHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideAutomation() }
        automationHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hideAutomation() {
        automationStrip.isHidden = true
        needsLayout = true
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
        navigate(to: url)
    }

    /// Loads a URL; on a remote machine, localhost first gets an SSH forward.
    func navigate(to url: URL) {
        address.stringValue = url.absoluteString
        guard let mapper = localhostMapper, LocalhostMapper.isLocalhost(url) else {
            webView.load(URLRequest(url: url))
            return
        }
        errorPage.isHidden = true
        progress.isHidden = false
        Task.detached {
            let target = mapper.rewrite(url)
            await MainActor.run {
                if let target {
                    self.webView.load(URLRequest(url: target))
                } else {
                    self.errorPage.show(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), url: url)
                    self.progress.isHidden = true
                    self.needsLayout = true
                }
            }
        }
    }

    /// Links to the machine's localhost inside a page get the same forwarding.
    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let mapper = localhostMapper, let url = action.request.url, action.targetFrame?.isMainFrame != false,
           LocalhostMapper.isLocalhost(url), !mapper.isForwarded(url)
        {
            decisionHandler(.cancel)
            navigate(to: url)
            return
        }
        decisionHandler(.allow)
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
    @objc private func reloadPage() {
        if webView.isLoading {
            webView.stopLoading()
        } else if webView.url == nil || !errorPage.isHidden, let url = Self.normalize(address.stringValue) {
            navigate(to: url)
        } else {
            webView.reload()
        }
    }

    @objc private func closePane() { onClose?() }

    @objc private func openExternally() {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }

    private func updateButtons() {
        back.isEnabled = webView.canGoBack
        forward.isEnabled = webView.canGoForward
    }

    private func pageChanged() {
        // Forwarded remote pages show (and save) their localhost address.
        let shown = webView.url.map { localhostMapper?.display($0) ?? $0 }
        if let shown, errorPage.isHidden, window?.firstResponder !== address.currentEditor() {
            address.stringValue = shown.absoluteString
        }
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser)
        state.url = shown?.absoluteString ?? state.url
        state.title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        state.audible = isAudible
        HostPaneStore.shared[hostID] = state
        onStateChange?(state)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if ProcessInfo.processInfo.environment["GHOSTHERDR_TRACE_BROWSER"] != nil {
            NSLog("ghostherdr-trace: browser \(hostID) superview=\(String(describing: superview)) \(Thread.callStackSymbols.prefix(8).joined(separator: " | "))")
        }
    }

    // MARK: - Console and load state

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "ghrMedia" {
            let frame = message.frameInfo.isMainFrame ? "main" : message.frameInfo.request.url?.absoluteString ?? "frame"
            audibleFrames[frame] = (message.body as? Bool) == true ? true : nil
            isAudible = !audibleFrames.isEmpty
            return
        }
        guard let body = message.body as? [String: Any] else { return }
        console.append(ConsoleEntry(
            level: body["level"] as? String ?? "log", text: body["text"] as? String ?? "", date: Date()
        ))
        if console.count > 500 { console.removeFirst(console.count - 500) }
    }

    func clearConsole() { console.removeAll() }

    /// After starting a load: waits for it to begin, then to finish, so the
    /// caller sees the new page's URL and title.
    func waitForNavigation(timeout: TimeInterval) async {
        let start = Date()
        while !webView.isLoading, webView.title?.isEmpty ?? true, Date().timeIntervalSince(start) < 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await waitForLoad(timeout: max(0, timeout - Date().timeIntervalSince(start)))
        // WebKit publishes the title a moment after the load finishes.
        let titleDeadline = Date().addingTimeInterval(0.5)
        while webView.title?.isEmpty ?? true, Date() < titleDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits for the page to finish loading, up to `timeout` seconds.
    func waitForLoad(timeout: TimeInterval) async {
        guard webView.isLoading else { return }
        await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finishLoad() }
        }
    }

    private func finishLoad() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func webView(_: WKWebView, didCommit _: WKNavigation!) {
        // A new page: its old media is gone.
        audibleFrames.removeAll()
        isAudible = false
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        lastNavigationError = nil
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) { finishLoad() }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        finishLoad()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        finishLoad()
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? Self.normalize(address.stringValue)
        errorPage.show(error: nsError, url: failing)
        // Keep the address that failed, not the page underneath.
        if let failing { address.stringValue = failing.absoluteString }
        needsLayout = true
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

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// "claude is controlling this page · fill @e3", under the toolbar.
private final class AutomationStrip: NSView {
    var onTakeOver: (() -> Void)?
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Click to take over")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = NSColor.controlAccentColor.blended(withFraction: 0.35, of: .labelColor)
        label.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        for view in [dot, label, hint] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Theme.current?.accentWash.cgColor
        let y = (bounds.height - 15) / 2
        dot.frame = NSRect(x: 12, y: bounds.midY - 3, width: 6, height: 6)
        hint.frame = NSRect(x: bounds.width - 132, y: y, width: 120, height: 15)
        label.frame = NSRect(x: 26, y: y, width: bounds.width - 170, height: 15)
    }

    override func mouseDown(with _: NSEvent) { onTakeOver?() }
}

/// A native page for loads that never reached a server.
private final class BrowserErrorPage: NSView {
    var onReload: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Reload", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12.5)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(reload)
        for view in [title, detail, button] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(error: NSError, url: URL?) {
        let host = url?.host ?? "the page"
        let local = ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host)
        switch error.code {
        case NSURLErrorCannotConnectToHost where local:
            title.stringValue = "Nothing is listening on :\(url?.port.map(String.init) ?? "80")"
            detail.stringValue = "Start the dev server in a terminal, then reload."
        case NSURLErrorCannotFindHost:
            title.stringValue = "Can’t find \(host)"
            detail.stringValue = "Check the address, or your network connection."
        case NSURLErrorNotConnectedToInternet:
            title.stringValue = "You’re offline"
            detail.stringValue = "Reconnect to the internet, then reload."
        default:
            title.stringValue = "Can’t open \(host)"
            detail.stringValue = error.localizedDescription
        }
        isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Theme.current?.pane.cgColor
        let midY = bounds.midY
        title.frame = NSRect(x: 16, y: midY + 16, width: bounds.width - 32, height: 20)
        detail.preferredMaxLayoutWidth = min(340, bounds.width - 32)
        let dh = detail.fittingSize.height
        detail.frame = NSRect(x: (bounds.width - detail.preferredMaxLayoutWidth) / 2, y: midY - dh + 6, width: detail.preferredMaxLayoutWidth, height: dh)
        button.sizeToFit()
        button.frame.origin = NSPoint(x: (bounds.width - button.frame.width) / 2, y: midY - dh - 30)
    }

    @objc private func reload() {
        isHidden = true
        onReload?()
    }
}

extension Notification.Name {
    /// A browser pane started or stopped playing sound.
    static let ghostherdrAudioChanged = Notification.Name("GhostHerdrAudioChanged")
}
