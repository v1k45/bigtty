import AppKit
import WebKit

/// A browser pane: toolbar plus WKWebView. Its URL and title are kept in
/// `HostPaneStore` so the page comes back after a restart, and the title is
/// mirrored to herdr so other clients see what the pane shows.
@MainActor
final class BrowserPaneView: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, WKScriptMessageHandler {
    let hostID: String
    let webView: WKWebView
    private let back = HistoryButton()
    private let forward = HistoryButton()
    private let reload = NSButton()
    private let options = NSButton()
    private let closeButton = NSButton()
    private var extensionObserver: NSObjectProtocol?
    /// Where an extension's popup points: the address bar. Extensions have
    /// no toolbar buttons (they'd crowd it); they're in the ⋯ menu.
    var extensionAnchor: NSView? { addressBox }
    /// The pane's × button.
    var onClose: (() -> Void)?
    let address = AddressField()
    private let addressBox = AddressBox()
    let security = NSButton()
    private let securityWords = NSTextField(labelWithString: "Not secure")
    let machineName = NSTextField(labelWithString: "")
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

    static let toolbarHeight: CGFloat = 28
    /// Below this the toolbar drops › and ↻.
    static let tightWidth: CGFloat = 200

    private var finderStorage: BrowserFinder?
    /// ⌘F in the page.
    var finder: BrowserFinder {
        if let finderStorage { return finderStorage }
        let finder = BrowserFinder(browser: self)
        finderStorage = finder
        return finder
    }

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

    /// The page fills the pane (full screen in the pane): no toolbar.
    private var pageFullscreen = false {
        didSet { if pageFullscreen != oldValue { needsLayout = true } }
    }

    private var audibleFrames: [String: Bool] = [:]
    /// Some frame is playing sound; shown on the tab.
    private(set) var isAudible = false {
        didSet {
            guard isAudible != oldValue else { return }
            pageChanged()
            NotificationCenter.default.post(name: .bigttyAudioChanged, object: self)
        }
    }
    /// Automation runs here, out of the page's reach.
    static let automationWorld = WKContentWorld.world(name: "bigtty")

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

    /// What the page is at, as the address bar shows it: forwarded remote
    /// pages as their localhost, a failed load as the address that failed.
    private var pageAddress: URL?
    /// A navigation hasn't committed, so the page on screen isn't `pageAddress`
    /// yet and there's nothing true to say about its security.
    private var navigationPending = false
    private var securityState = BrowserAddress.Security.quiet

    init(hostID: String, state: HostPaneState, dataStore: WKWebsiteDataStore? = nil, localhostMapper: LocalhostMapper? = nil, machineName: String? = nil) {
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
        // Video full screen (YouTube's button, the page's requestFullscreen):
        // inside the pane by default, or the whole display.
        config.preferences.isElementFullscreenEnabled = true
        if Settings.browserFullscreen == .pane {
            content.addUserScript(WKUserScript(source: Self.paneFullscreen, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // Identify as the installed Safari: WebKit's default string lacks
        // Safari's version, and sites then call the browser outdated.
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        WebExtensions.configure(config)
        // Which frames are playing sound, for the tab's speaker.
        content.addUserScript(WKUserScript(source: Self.mediaHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "bttyConsole")
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "bttyMedia")
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "bttyFullscreen")
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")

        configure(back, "chevron.left", "Back", #selector(goBackClicked))
        configure(forward, "chevron.right", "Forward", #selector(goForwardClicked))
        configure(reload, "arrow.clockwise", "Reload", #selector(reloadPage))
        configure(options, "ellipsis", "Options", #selector(showOptions))
        configure(closeButton, "xmark", "Close Pane", #selector(closePane))
        back.historyMenu = { [weak self] in self?.historyMenu(forward: false) }
        forward.historyMenu = { [weak self] in self?.historyMenu(forward: true) }
        address.placeholderString = "Search or enter address"
        address.font = .systemFont(ofSize: 11.5)
        address.isBezeled = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.alignment = .left
        // Shortened to fit by `renderAddress`, and scrolled while typing.
        address.lineBreakMode = .byClipping
        address.cell?.usesSingleLineMode = true
        address.cell?.isScrollable = true
        address.delegate = self
        address.target = self
        address.action = #selector(addressEntered)
        address.onBeginFocus = { [weak self] in self?.addressGainedFocus() }
        address.onEndFocus = { [weak self] in self?.addressLostFocus() }
        addressBox.wantsLayer = true
        addressBox.layer?.cornerRadius = 6
        addressBox.onClick = { [weak self] in self?.focusAddressBar() }
        security.isBordered = false
        security.imagePosition = .imageOnly
        security.isHidden = true
        securityWords.font = .systemFont(ofSize: 11.5)
        securityWords.textColor = .systemOrange
        securityWords.isHidden = true
        self.machineName.font = .systemFont(ofSize: 10.5, weight: .medium)
        self.machineName.textColor = .secondaryLabelColor
        self.machineName.lineBreakMode = .byTruncatingTail
        self.machineName.stringValue = machineName ?? ""
        self.machineName.toolTip = machineName.map { "This page is on \($0)" }
        self.machineName.isHidden = machineName == nil
        for view in [address, security, securityWords, self.machineName] as [NSView] { addressBox.addSubview(view) }
        toolbarLine.wantsLayer = true
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progress.isHidden = true
        automationStrip.isHidden = true
        automationStrip.onTakeOver = { [weak self] in self?.hideAutomation() }
        errorPage.isHidden = true
        errorPage.onReload = { [weak self] in self?.reloadPage() }
        for view in [back, forward, addressBox, reload, options, closeButton, webView, errorPage, toolbarLine, progress, automationStrip] as [NSView] {
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
            webView.observe(\.hasOnlySecureContent, options: .new) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateSecurity() }
            },
        ]

        if let url = state.url.flatMap(BrowserAddress.normalize) {
            navigate(to: url)
        }
        updateButtons()
        extensionObserver = NotificationCenter.default.addObserver(forName: .bigttyExtensionsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExtensionButtons() }
        }
        WebExtensions.tabOpened(self)
        refreshExtensionButtons()
    }

    isolated deinit {
        if let extensionObserver { NotificationCenter.default.removeObserver(extensionObserver) }
    }

    /// Extensions changed: the toolbar menu is rebuilt when it opens, so
    /// there's nothing to lay out.
    func refreshExtensionButtons() {}

    /// ⋯, or a right-click on the toolbar: the page's actions and each
    /// extension (uBlock Origin Lite's popup opens under the address).
    func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            item.keyEquivalentModifierMask = modifiers
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let hasPage = pageAddress != nil
        // ↻ is out of the way in the tightest panes, so it comes in here.
        if bounds.width < Self.tightWidth {
            add("Reload Page", enabled: hasPage) { [weak self] in self?.reloadPage() }
        }
        add("Open in Default Browser", "o", [.command, .shift], enabled: hasPage) { [weak self] in self?.openInDefaultBrowser() }
        add("Copy Address", "c", [.command, .shift], enabled: hasPage) { [weak self] in self?.copyAddress() }
        add("Reload Without Cache", "r", [.command, .shift], enabled: hasPage) { [weak self] in self?.reloadWithoutCache() }
        add("Find in Page…", "f", enabled: hasPage) {
            NSApp.sendAction(#selector(PaneActions.showFind(_:)), to: nil, from: nil)
        }
        let zoom = NSMenuItem()
        zoom.view = ZoomMenuRow(percent: zoomPercent) { [weak self] step in
            self?.zoom(by: step)
            return self?.zoomPercent ?? 100
        }
        menu.addItem(zoom)
        let actions = WebExtensions.actions(for: self)
        if !actions.isEmpty {
            menu.addItem(.separator())
            for action in actions {
                let title = action.badge.isEmpty ? action.name : "\(action.name) (\(action.badge))"
                let item = ClosureMenuItem(title: title, keyEquivalent: "") { action.perform() }
                item.image = action.icon.map { icon in
                    let small = icon.copy() as? NSImage ?? icon
                    small.size = NSSize(width: 16, height: 16)
                    return small
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        add("Browser Settings…") {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        }
        return menu
    }

    @objc private func showOptions() {
        optionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: options.bounds.height + 4), in: options)
    }

    /// Where ‹ or › leads, nearest first.
    private func historyMenu(forward: Bool) -> NSMenu? {
        let list = webView.backForwardList
        let entries = forward ? list.forwardList : list.backList.reversed()
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries.prefix(20) {
            let shown = localhostMapper?.display(entry.url) ?? entry.url
            let title = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? shown.absoluteString
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.webView.go(to: entry) })
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        // The page has its own menu; the toolbar gets ours.
        guard point.y >= bounds.height - Self.toolbarHeight else { return super.menu(for: event) }
        return optionsMenu()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .regular))
        button.contentTintColor = .tertiaryLabelColor
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
        let h = pageFullscreen ? 0 : Self.toolbarHeight
        for view in [back, forward, closeButton, options, addressBox, toolbarLine] as [NSView] { view.isHidden = pageFullscreen }
        // Light and compact: ‹ › on the left, the address (with ↻ inside)
        // in the middle, ⋯ and × on the right.
        let y = b.height - h + (h - 20) / 2
        back.frame = NSRect(x: 6, y: y, width: 20, height: 20)
        forward.frame = NSRect(x: 26, y: y, width: 20, height: 20)
        closeButton.frame = NSRect(x: b.width - 26, y: y, width: 20, height: 20)
        options.frame = NSRect(x: b.width - 46, y: y, width: 20, height: 20)
        // The tightest panes keep ‹, the address, ⋯ and ×; › and ↻ are in
        // the right-click menus.
        let tight = b.width < Self.tightWidth
        forward.isHidden = pageFullscreen || tight
        reload.isHidden = pageFullscreen || tight
        let fieldX: CGFloat = tight ? 30 : 52
        let fieldWidth = max(40, b.width - fieldX - 52 - 4)
        addressBox.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: 20)
        reload.frame = NSRect(x: addressBox.frame.maxX - 22, y: y, width: 20, height: 20)
        layoutAddress(tight: tight)
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

    /// The box's contents, left to right: the machine (remote panes), the
    /// security slot, its words when there's room, then the field.
    private func layoutAddress(tight: Bool) {
        let box = addressBox.bounds
        let editing = isEditingAddress
        var x: CGFloat = 8
        // Telling a remote localhost from this Mac's matters more than the lock.
        if !machineName.stringValue.isEmpty {
            let room = box.width >= 170
            machineName.isHidden = !room
            if room {
                let width = min(machineName.intrinsicContentSize.width + 2, box.width / 3)
                machineName.frame = NSRect(x: x, y: 3, width: width, height: 14)
                x += width + 5
            }
        }
        let state = editing ? BrowserAddress.Security.quiet : securityState
        // A warning always stays; the quiet lock goes first.
        let slot = state.isWarning || (state == .secure && !tight)
        security.isHidden = !slot
        if slot {
            security.frame = NSRect(x: x - 2, y: 3, width: 14, height: 14)
            x += 15
        }
        let words = state == .insecure && box.width >= 280
        securityWords.isHidden = !words
        if words {
            let width = securityWords.intrinsicContentSize.width + 2
            securityWords.frame = NSRect(x: x, y: 2, width: width, height: 16)
            x += width + 3
        }
        let right: CGFloat = tight ? 6 : 26
        address.frame = NSRect(x: x, y: 2, width: max(10, box.width - x - right), height: 16)
        addressBox.layer?.backgroundColor = Theme.current?.field.withAlphaComponent(editing ? 0.9 : 0.55).cgColor
        addressBox.layer?.borderWidth = editing ? 1 : 0
        addressBox.layer?.borderColor = Theme.current?.accentLine.cgColor
        if !editing { renderAddress() }
    }

    private func updateLoading() {
        let loading = webView.isLoading
        progress.isHidden = !loading
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
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

    func load(_ input: String) {
        guard let url = BrowserAddress.normalize(input) else { return }
        navigate(to: url)
    }

    /// Loads a URL; on a remote machine, localhost first gets an SSH forward.
    func navigate(to url: URL) {
        showAddress(url)
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

    // MARK: - Address bar

    var isEditingAddress: Bool { address.currentEditor() != nil }

    func focusAddressBar() {
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    /// The page moved on. What someone is typing is never touched: it's
    /// only put back when they leave the field.
    private func showAddress(_ url: URL?) {
        pageAddress = url
        if !isEditingAddress { renderAddress() }
        updateSecurity()
    }

    /// At rest: the host bright, the rest dim, shortened to fit. A local
    /// page's port is part of the bright part, since it names the site.
    private func renderAddress() {
        guard let pageAddress else {
            address.stringValue = ""
            return
        }
        let font = address.font ?? .systemFont(ofSize: 11.5)
        let shown = BrowserAddress.fit(BrowserAddress.shown(pageAddress), width: address.bounds.width - 5) {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        let text = NSMutableAttributedString(string: shown.site, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: shown.rest, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        address.attributedStringValue = text
    }

    /// The exact URL goes in for editing (the field editor picks up what's
    /// here as it starts).
    private func addressGainedFocus() {
        address.textColor = .labelColor
        address.stringValue = pageAddress?.absoluteString ?? ""
        needsLayout = true
    }

    /// Left without Return: back to the page's address. With no page yet,
    /// what was typed stays, in case the click away was to go copy something.
    private func addressLostFocus() {
        if pageAddress != nil { renderAddress() }
        needsLayout = true
    }

    /// Esc: the first press puts the page's address back and keeps the
    /// field; the next returns to the page. Nothing to undo goes straight there.
    func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) else { return false }
        let original = pageAddress?.absoluteString ?? ""
        if textView.string != original {
            textView.string = original
            textView.selectAll(nil)
        } else {
            window?.makeFirstResponder(webView)
        }
        return true
    }

    @objc private func addressEntered() {
        load(address.stringValue)
        window?.makeFirstResponder(webView)
    }

    private func updateSecurity() {
        let state = navigationPending || !errorPage.isHidden
            ? BrowserAddress.Security.quiet
            : BrowserAddress.security(of: pageAddress, onlySecureContent: webView.hasOnlySecureContent)
        guard state != securityState else { return }
        securityState = state
        let (symbol, tip, tint): (String, String, NSColor) = switch state {
        case .secure: ("lock.fill", "This connection is secure", .tertiaryLabelColor)
        case .mixed: ("lock.open.fill", "Some of this page was loaded insecurely", .systemOrange)
        case .insecure: ("lock.open.fill", "This connection isn’t secure", .systemOrange)
        case .quiet: ("", "", .clear)
        }
        security.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .regular))
        security.contentTintColor = tint
        security.toolTip = tip
        needsLayout = true
    }

    @objc private func goBackClicked() { webView.goBack() }
    @objc private func goForwardClicked() { webView.goForward() }
    /// The ↻ in the address bar: stops a load in progress, else reloads.
    @objc private func reloadPage() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            reloadAgain()
        }
    }

    /// ⌘R: loads the page again, even mid-load. After a failed load, the
    /// address that failed.
    func reloadAgain() {
        if webView.url == nil || !errorPage.isHidden, let pageAddress {
            navigate(to: pageAddress)
        } else {
            webView.reload()
        }
    }

    /// ⇧⌘R: everything fetched again, for checking a dev server's assets.
    func reloadWithoutCache() {
        if webView.url == nil || !errorPage.isHidden { return reloadAgain() }
        webView.reloadFromOrigin()
    }

    func stopLoading() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    var isLoading: Bool { webView.isLoading }

    @objc private func closePane() { onClose?() }

    /// The real URL: a remote page's forwarded port reaches it from any
    /// browser on this Mac, where its localhost wouldn't.
    func openInDefaultBrowser() {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }

    func copyAddress() {
        guard let pageAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pageAddress.absoluteString, forType: .string)
    }

    /// ⌘+ ⌘− (±1) and ⌘0 (0).
    func zoom(by step: Int) {
        webView.pageZoom = step == 0 ? 1 : min(3, max(0.5, webView.pageZoom + CGFloat(step) * 0.1))
    }

    private var zoomPercent: Int { Int((webView.pageZoom * 100).rounded()) }

    private func updateButtons() {
        back.isEnabled = webView.canGoBack
        forward.isEnabled = webView.canGoForward
    }

    private func pageChanged() {
        // Forwarded remote pages show (and save) their localhost address.
        let shown = webView.url.map { localhostMapper?.display($0) ?? $0 }
        if let shown, errorPage.isHidden { showAddress(shown) }
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser)
        state.url = shown?.absoluteString ?? state.url
        state.title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        state.audible = isAudible
        HostPaneStore.shared[hostID] = state
        onStateChange?(state)
        WebExtensions.tabChanged(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if ProcessInfo.processInfo.environment["BIGTTY_TRACE_BROWSER"] != nil {
            NSLog("bigtty-trace: browser \(hostID) superview=\(String(describing: superview)) \(Thread.callStackSymbols.prefix(8).joined(separator: " | "))")
        }
    }

    // MARK: - Console and load state

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "bttyFullscreen" {
            pageFullscreen = (message.body as? Bool) == true
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
        navigationPending = false
        updateSecurity()
        pageFullscreen = false
        // A new page: its old media is gone.
        audibleFrames.removeAll()
        isAudible = false
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        lastNavigationError = nil
        navigationPending = true
        updateSecurity()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        finishLoad()
        finderStorage?.pageLoaded()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        navigationPending = false
        updateSecurity()
        finishLoad()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        navigationPending = false
        finishLoad()
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else {
            // Stopped, or superseded: the page on screen is still this one.
            pageChanged()
            return updateSecurity()
        }
        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? pageAddress
        errorPage.show(error: nsError, url: failing)
        // Keep the address that failed, not the page underneath.
        if let failing { showAddress(localhostMapper?.display(failing) ?? failing) }
        updateSecurity()
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
        if hit != nil, [.leftMouseDown, .rightMouseDown].contains(NSApp.currentEvent?.type) { onFocus?() }
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
    static let bigttyAudioChanged = Notification.Name("BigttyAudioChanged")
}
