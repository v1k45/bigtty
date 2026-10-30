import AppKit
import WebKit

/// One page of a browser pane: its web view, what it's doing, and all the
/// WebKit delegates. `BrowserPaneView` is the chrome around whichever page
/// is showing. A page restored from disk stays plain data until something
/// needs its web view, so a pane of ten tabs costs one web view at launch.
@MainActor
final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    weak var pane: BrowserPaneView?
    let localhostMapper: LocalhostMapper?
    private let dataStore: WKWebsiteDataStore?
    /// WebKit's own configuration for a popup, which keeps `window.opener`.
    private var popupConfiguration: WKWebViewConfiguration?
    /// Back/forward list to restore instead of loading the URL.
    private var restoring: Data?
    /// An agent opened this tab.
    var openedByAgent: Bool

    private var storage: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    /// What the page is at, as the address bar shows it: forwarded remote
    /// pages as their localhost, a failed load as the address that failed.
    private(set) var address: URL? {
        didSet { if address != oldValue { pane?.pageAddressChanged(self) } }
    }
    private(set) var title: String
    /// A load that never reached a server: the pane shows its error page.
    private(set) var failure: (error: NSError, url: URL?)?
    /// A navigation hasn't committed, so the page on screen isn't `address`
    /// yet and there's nothing true to say about its security.
    private var navigationPending = false
    /// A remote localhost's forward is starting.
    private(set) var isForwarding = false
    /// The page fills the pane (full screen in the pane): no toolbar.
    private(set) var isFullscreen = false
    /// A form was posted here: going back after a restart could post it again.
    private var postedForm = false

    private var audibleFrames: [String: Bool] = [:]
    /// Some frame is playing sound; shown on the tab.
    private(set) var isAudible = false {
        didSet {
            guard isAudible != oldValue else { return }
            pane?.pageChanged(self)
            NotificationCenter.default.post(name: .bigttyAudioChanged, object: pane)
        }
    }

    struct ConsoleEntry {
        let level: String
        let text: String
        let date: Date
    }

    private(set) var console: [ConsoleEntry] = []
    /// Resolved when the current navigation finishes (or fails).
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lastNavigationError: String?

    /// "claude is controlling this page · click @e3", for a few seconds
    /// after each command: the strip when showing, a dot on its tab if not.
    private(set) var automationText: String?
    private var automationHide: DispatchWorkItem?
    private var wakeEnd: DispatchWorkItem?

    /// Automation runs here, out of the page's reach.
    static let automationWorld = WKContentWorld.world(name: "bigtty")

    /// One cookie/storage store for every browser pane, persisted on disk.
    private static let sharedDataStore = WKWebsiteDataStore.default()

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
        try { window.webkit.messageHandlers.bttyMedia.postMessage(playing); } catch (_) {}
      };
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'])
        document.addEventListener(type, report, true);
    })();
    """

    /// "Full screen in the pane": a page's full screen request makes the
    /// element fill the web view instead of taking over the display. The
    /// Fullscreen API is answered in-page (fullscreenElement, change events,
    /// Esc to leave), and a frame asks its parent to fill with the frame.
    static let paneFullscreen = """
    (() => {
      if (window.__bttyPaneFullscreen) return;
      window.__bttyPaneFullscreen = true;
      let current = null;
      const cls = '__btty_fs';
      const style = document.createElement('style');
      style.textContent = `.${cls}{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;border:0!important;transform:none!important;z-index:2147483647!important;background-color:#000!important;object-fit:contain}`;
      const fire = (el) => {
        for (const type of ['fullscreenchange', 'webkitfullscreenchange'])
          (el || document).dispatchEvent(new Event(type, { bubbles: true }));
      };
      const tellApp = (on) => {
        if (window !== window.top) { window.parent.postMessage({ __bttyFullscreen: on }, '*'); return; }
        try { window.webkit.messageHandlers.bttyFullscreen.postMessage(on); } catch (_) {}
      };
      function enter() {
        const el = this;
        if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
        if (current && current !== el) current.classList.remove(cls);
        current = el;
        el.classList.add(cls);
        document.documentElement.style.setProperty('overflow', 'hidden', 'important');
        fire(el); tellApp(true);
        return Promise.resolve();
      }
      function exit() {
        const el = current;
        if (!el) return Promise.resolve();
        el.classList.remove(cls);
        current = null;
        document.documentElement.style.removeProperty('overflow');
        fire(el); tellApp(false);
        return Promise.resolve();
      }
      for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'])
        Element.prototype[name] = enter;
      HTMLVideoElement.prototype.webkitEnterFullscreen = enter;
      HTMLVideoElement.prototype.webkitEnterFullScreen = enter;
      for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'])
        Document.prototype[name] = exit;
      const get = (value) => ({ get: value, configurable: true });
      for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'])
        Object.defineProperty(Document.prototype, name, get(() => current));
      for (const name of ['fullscreen', 'webkitIsFullScreen'])
        Object.defineProperty(Document.prototype, name, get(() => !!current));
      for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled'])
        Object.defineProperty(Document.prototype, name, get(() => true));
      document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && current) exit(); }, true);
      // A frame going full screen: fill with the frame itself.
      window.addEventListener('message', (e) => {
        if (!e.data || typeof e.data.__bttyFullscreen !== 'boolean') return;
        const frame = Array.from(document.querySelectorAll('iframe')).find(f => f.contentWindow === e.source);
        if (!frame) return;
        if (e.data.__bttyFullscreen) enter.call(frame); else if (current === frame) exit();
      });
    })();
    """

    init(tab: BrowserTabState, history: Data? = nil, dataStore: WKWebsiteDataStore?, localhostMapper: LocalhostMapper?,
         popup: WKWebViewConfiguration? = nil) {
        id = tab.id
        self.dataStore = dataStore
        self.localhostMapper = localhostMapper
        popupConfiguration = popup
        restoring = history
        openedByAgent = tab.agent == true
        title = tab.title ?? ""
        address = tab.url.flatMap(BrowserAddress.normalize)
        super.init()
    }

    var tabState: BrowserTabState {
        BrowserTabState(id: id, url: address?.absoluteString, title: title.isEmpty ? nil : title, agent: openedByAgent ? true : nil)
    }

    /// Nothing loaded and nothing to load: a tab waiting for an address.
    var isBlank: Bool { address == nil }
    var isLoading: Bool { isForwarding || storage?.isLoading == true }
    var hasWebView: Bool { storage != nil }
    var progress: Double { storage?.estimatedProgress ?? 0 }
    var canGoBack: Bool { storage?.canGoBack == true }
    var canGoForward: Bool { storage?.canGoForward == true }

    var security: BrowserAddress.Security {
        guard !navigationPending, failure == nil, let storage else { return .quiet }
        return BrowserAddress.security(of: address, onlySecureContent: storage.hasOnlySecureContent)
    }

    // MARK: - The web view

    /// Built on first use: a restored tab's page loads when it's first shown
    /// or targeted by an agent.
    var webView: WKWebView {
        if let storage { return storage }
        let web = WKWebView(frame: pane?.pageFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
                            configuration: popupConfiguration ?? Self.configuration(dataStore: dataStore))
        popupConfiguration = nil
        storage = web
        Self.pages.setObject(self, forKey: web)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.setValue(false, forKey: "drawsBackground")
        web.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        observations = [
            web.observe(\.url, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageChanged() }
            },
            web.observe(\.title, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageChanged() }
            },
        ] + [
            web.observe(\.canGoBack, options: .new) { [weak self] _, _ in self?.chromeChanged() },
            web.observe(\.canGoForward, options: .new) { [weak self] _, _ in self?.chromeChanged() },
            web.observe(\.isLoading, options: .new) { [weak self] _, _ in self?.chromeChanged() },
            web.observe(\.estimatedProgress, options: .new) { [weak self] _, _ in self?.chromeChanged() },
            web.observe(\.hasOnlySecureContent, options: .new) { [weak self] _, _ in self?.chromeChanged() },
        ]
        WebExtensions.tabOpened(self)
        if let restoring {
            self.restoring = nil
            web.interactionState = restoring
        } else if let address {
            navigate(to: address)
        }
        return web
    }

    private nonisolated func chromeChanged() {
        MainActor.assumeIsolated { pane?.pageChromeChanged(self) }
    }

    /// Which page a script message or popup came from: a popup shares its
    /// opener's user content controller, so handlers can't belong to a page.
    private static let pages = NSMapTable<WKWebView, BrowserPage>.weakToWeakObjects()

    static func page(for webView: WKWebView?) -> BrowserPage? {
        webView.flatMap { pages.object(forKey: $0) }
    }

    private static func configuration(dataStore: WKWebsiteDataStore?) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore ?? sharedDataStore
        let content = config.userContentController
        content.addUserScript(WKUserScript(
            source: AutomationScript.source, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: automationWorld
        ))
        content.addUserScript(WKUserScript(
            source: AutomationScript.consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        // Video full screen (YouTube's button, the page's requestFullscreen):
        // inside the pane by default, or the whole display.
        config.preferences.isElementFullscreenEnabled = true
        // A window needs a click: a page can't open tabs on its own.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if Settings.browserFullscreen == .pane {
            content.addUserScript(WKUserScript(source: paneFullscreen, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // A hidden tab keeps running, slowly: the default all but freezes it,
        // down to a timer tick every 15 seconds. See `keepAwake`.
        config.preferences.inactiveSchedulingPolicy = .throttle
        // Identify as the installed Safari: WebKit's default string lacks
        // Safari's version, and sites then call the browser outdated.
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        WebExtensions.configure(config)
        // Which frames are playing sound, for the tab's speaker.
        content.addUserScript(WKUserScript(source: mediaHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for name in ["bttyConsole", "bttyMedia", "bttyFullscreen"] { content.add(PageMessages.shared, name: name) }
        return config
    }

    /// The tab is going away for good.
    func close() {
        automationHide?.cancel()
        wakeEnd?.cancel()
        finishLoad()
        guard let storage else { return }
        storage.stopLoading()
        storage.removeFromSuperview()
        WebExtensions.tabClosed(self)
    }

    // MARK: - Keeping hidden tabs usable

    /// A hidden page's timers run about once a second, which is too slow for
    /// a page an agent is working in. For a while after each command they run
    /// at full speed. (`_hiddenPageDOMTimerThrottlingEnabled` and friends are
    /// WebKit SPI, so each is checked: without them, hidden tabs stay slow and
    /// `btty browser wait`, which polls from here, still works.)
    private static let wakeTime: TimeInterval = 30
    private static let throttleSetters = ["_setHiddenPageDOMTimerThrottlingEnabled:", "_setPageVisibilityBasedProcessSuppressionEnabled:"]

    func keepAwake() {
        setThrottled(false)
        wakeEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setThrottled(true) }
        wakeEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeTime, execute: work)
    }

    private func setThrottled(_ on: Bool) {
        guard let preferences = storage?.configuration.preferences else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        for name in Self.throttleSetters {
            let selector = NSSelectorFromString(name)
            guard preferences.responds(to: selector) else { continue }
            unsafeBitCast(preferences.method(for: selector), to: Set.self)(preferences, selector, on)
        }
    }

    func noteAutomation(_ text: String) {
        automationText = text
        keepAwake()
        pane?.pageChromeChanged(self)
        automationHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endAutomationNote() }
        automationHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func endAutomationNote() {
        automationText = nil
        pane?.pageChromeChanged(self)
    }

    // MARK: - Navigation

    func load(_ input: String) {
        guard let url = BrowserAddress.normalize(input) else { return }
        navigate(to: url)
    }

    /// Loads a URL; on a remote machine, localhost first gets an SSH forward.
    func navigate(to url: URL) {
        address = url
        failure = nil
        pane?.pageChanged(self)
        guard let mapper = localhostMapper, LocalhostMapper.isLocalhost(url) else {
            webView.load(URLRequest(url: url))
            return
        }
        isForwarding = true
        pane?.pageChromeChanged(self)
        Task.detached {
            let target = mapper.rewrite(url)
            await MainActor.run {
                self.isForwarding = false
                if let target {
                    self.webView.load(URLRequest(url: target))
                } else {
                    self.failure = (NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), url)
                }
                self.pane?.pageChromeChanged(self)
            }
        }
    }

    /// ⌘R: loads the page again, even mid-load. After a failed load, the
    /// address that failed.
    func reload() {
        if storage?.url == nil || failure != nil, let address {
            navigate(to: address)
        } else {
            webView.reload()
        }
    }

    /// ⇧⌘R: everything fetched again, for checking a dev server's assets.
    func reloadWithoutCache() {
        if storage?.url == nil || failure != nil { return reload() }
        webView.reloadFromOrigin()
    }

    private func pageChanged() {
        let before = address
        // Forwarded remote pages show (and save) their localhost address.
        if let url = storage?.url, failure == nil { address = localhostMapper?.display(url) ?? url }
        // A restored page keeps its saved title until it publishes one.
        if let shown = storage?.title, !shown.isEmpty || address != before { title = shown }
        pane?.pageChanged(self)
        WebExtensions.tabChanged(self)
    }

    /// The URL to open elsewhere: a remote page's forwarded port reaches it
    /// from any browser on this Mac, where its localhost wouldn't.
    var realURL: URL? { storage?.url ?? address }

    /// A title for lists and tabs, never empty.
    var shownTitle: String {
        if !title.isEmpty { return title }
        return address.map { let shown = BrowserAddress.shown($0); return shown.site + shown.rest } ?? "New Tab"
    }

    // MARK: - WKNavigationDelegate

    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = action.targetFrame?.isMainFrame != false
        if mainFrame, let url = action.request.url, let pane, Self.opensInNewTab(action) {
            decisionHandler(.cancel)
            pane.openLink(localhostMapper?.display(url) ?? url, from: self, background: !action.modifierFlags.contains(.shift))
            return
        }
        // Links to the machine's localhost inside a page get the same forwarding.
        if let mapper = localhostMapper, let url = action.request.url, mainFrame,
           LocalhostMapper.isLocalhost(url), !mapper.isForwarded(url)
        {
            decisionHandler(.cancel)
            navigate(to: url)
            return
        }
        if action.request.httpMethod == "POST" { postedForm = true }
        decisionHandler(.allow)
    }

    /// ⌘-click and middle-click on a link.
    private static func opensInNewTab(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated && (action.modifierFlags.contains(.command) || action.buttonNumber == 4)
    }

    func webView(_: WKWebView, didCommit _: WKNavigation!) {
        navigationPending = false
        isFullscreen = false
        // A new page: its old media is gone.
        audibleFrames.removeAll()
        isAudible = false
        pane?.pageChromeChanged(self)
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        lastNavigationError = nil
        navigationPending = true
        failure = nil
        pane?.pageChromeChanged(self)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        finishLoad()
        pane?.pageLoaded(self)
        saveHistory()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        navigationPending = false
        finishLoad()
        pane?.pageChromeChanged(self)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        navigationPending = false
        finishLoad()
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else {
            // Stopped, or superseded: the page on screen is still this one.
            pageChanged()
            pane?.pageChromeChanged(self)
            return
        }
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? address
        failure = (nsError, failing)
        // Keep the address that failed, not the page underneath.
        if let failing { address = localhostMapper?.display(failing) ?? failing }
        pane?.pageChromeChanged(self)
    }

    // MARK: - WKUIDelegate

    /// `target=_blank` and `window.open`: a tab of their own, on a web view
    /// made from WebKit's configuration, so `window.opener` works for OAuth.
    func webView(
        _: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        pane?.openPopup(configuration, from: self, background: action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift))?.webView
    }

    /// `window.close()`, the end of most OAuth popups.
    func webViewDidClose(_: WKWebView) {
        pane?.close(self)
    }

    // MARK: - Console and load state

    func received(_ message: WKScriptMessage) {
        if message.name == "bttyFullscreen" {
            let on = (message.body as? Bool) == true
            if on != isFullscreen {
                isFullscreen = on
                pane?.pageChromeChanged(self)
            }
            return
        }
        if message.name == "bttyMedia" {
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
        let web = webView
        while !isLoading, web.title?.isEmpty ?? true, Date().timeIntervalSince(start) < 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await waitForLoad(timeout: max(0, timeout - Date().timeIntervalSince(start)))
        // WebKit publishes the title a moment after the load finishes.
        let titleDeadline = Date().addingTimeInterval(0.5)
        while web.title?.isEmpty ?? true, Date() < titleDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits for the page to finish loading, up to `timeout` seconds.
    func waitForLoad(timeout: TimeInterval) async {
        guard isLoading else { return }
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

    // MARK: - Back/forward across restarts

    /// Whether this tab's history may be written down: remote forwards
    /// change between launches.
    private var keepsHistory: Bool { localhostMapper == nil && !postedForm }

    /// What goes on ⇧⌘T's list, or `saveHistory`'s file.
    var historyData: Data? {
        guard keepsHistory else { return nil }
        return storage?.interactionState as? Data
    }

    func saveHistory() {
        if hasWebView { BrowserPageState.save(historyData, for: id) }
    }
}

/// Script messages, routed by web view: `WKUserContentController` retains
/// its handlers, and a popup shares its opener's controller.
private final class PageMessages: NSObject, WKScriptMessageHandler {
    @MainActor static let shared = PageMessages()

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { BrowserPage.page(for: message.webView)?.received(message) }
    }
}
