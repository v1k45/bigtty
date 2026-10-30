import AppKit
import WebKit

/// A browser pane: toolbar and tab strip around its pages. Its pages' URLs
/// and titles are kept in `HostPaneStore`, so they come back after a
/// restart, and the active page's is mirrored to herdr so other clients see
/// what the pane shows. One herdr pane can hold many pages: herdr has no
/// stacked panes, and a bigtty tab is already a herdr tab.
@MainActor
final class BrowserPaneView: NSView, NSTextFieldDelegate {
    let hostID: String
    private(set) var pages: [BrowserPage]
    private(set) var activePage: BrowserPage
    private let dataStore: WKWebsiteDataStore?
    /// Set for a remote machine's panes: its `localhost` goes through SSH.
    let localhostMapper: LocalhostMapper?
    /// Whose history this is: a remote `localhost` isn't this Mac's.
    let machineKey: String
    /// What ⇧⌘T brings back, last closed at the end.
    private(set) var closed: [ClosedBrowserTab] = []
    /// The page each calling terminal last used. Refs like @e5 belong to one
    /// page, so an agent stays on its page even if you switch tabs under it.
    private var callers: [String: String] = [:]

    private let back = HistoryButton()
    private let forward = HistoryButton()
    private let reload = NSButton()
    private let options = NSButton()
    private let closeButton = NSButton()
    private let tabCount = NSButton()
    private let strip = BrowserTabStrip()
    private var extensionObserver: NSObjectProtocol?
    /// Where an extension's popup points: the address bar. Extensions have
    /// no toolbar buttons (they'd crowd it); they're in the ⋯ menu.
    var extensionAnchor: NSView? { addressBox }
    /// The pane's × button, and closing its last tab.
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

    /// The pane's title or URL changed.
    var onStateChange: ((HostPaneState) -> Void)?
    /// The user clicked into the pane.
    var onFocus: (() -> Void)?
    /// The open tabs and dev servers the address bar can offer.
    var suggestionSources: (() -> BrowserSuggestionSources)?
    /// The space this pane is in, which ranks its history higher.
    var spaceName: (() -> String?)?
    /// Jumps to a tab anywhere on this machine.
    var onShowTab: ((String, String) -> Void)?

    static let toolbarHeight: CGFloat = 28
    static let stripHeight: CGFloat = 24
    /// Below this the toolbar drops › and ↻.
    static let tightWidth: CGFloat = 200

    /// The page showing.
    var webView: WKWebView { activePage.webView }

    private var finderStorage: BrowserFinder?
    /// ⌘F in the page.
    var finder: BrowserFinder {
        if let finderStorage { return finderStorage }
        let finder = BrowserFinder(browser: self)
        finderStorage = finder
        return finder
    }

    private var securityState = BrowserAddress.Security.quiet
    private lazy var completer = BrowserAddressCompleter(pane: self)
    private var keyObserver: NSObjectProtocol?

    /// Some page is playing sound; shown on the herdr tab.
    var isAudible: Bool { pages.contains(where: \.isAudible) }

    init(hostID: String, state: HostPaneState, dataStore: WKWebsiteDataStore? = nil, localhostMapper: LocalhostMapper? = nil, machineName: String? = nil, machineKey: String = "local") {
        self.hostID = hostID
        self.machineKey = machineKey
        self.dataStore = dataStore
        self.localhostMapper = localhostMapper
        // Panes saved before tabs have one page, in `url`.
        let tabs = state.tabs.flatMap { $0.isEmpty ? nil : $0 }
            ?? [BrowserTabState(id: BrowserTabRules.newID(), url: state.url, title: state.title)]
        let pages = tabs.map {
            BrowserPage(tab: $0, history: localhostMapper == nil ? BrowserPageState.load($0.id) : nil,
                        dataStore: dataStore, localhostMapper: localhostMapper)
        }
        self.pages = pages
        activePage = pages.first { $0.id == state.activeTab } ?? pages[0]
        super.init(frame: .zero)
        for page in pages { page.pane = self }

        configure(back, "chevron.left", "Back", #selector(goBackClicked))
        configure(forward, "chevron.right", "Forward", #selector(goForwardClicked))
        configure(reload, "arrow.clockwise", "Reload", #selector(reloadClicked))
        configure(options, "ellipsis", "Options", #selector(showOptions))
        configure(closeButton, "xmark", "Close Pane", #selector(closeClicked))
        back.historyMenu = { [weak self] in self?.historyMenu(forward: false) }
        forward.historyMenu = { [weak self] in self?.historyMenu(forward: true) }
        tabCount.isBordered = false
        tabCount.wantsLayer = true
        tabCount.layer?.cornerRadius = 4
        tabCount.layer?.borderWidth = 1
        tabCount.font = .systemFont(ofSize: 10, weight: .semibold)
        tabCount.contentTintColor = .secondaryLabelColor
        tabCount.target = self
        tabCount.action = #selector(showTabs)
        tabCount.isHidden = true
        strip.isHidden = true
        strip.onSelect = { [weak self] id in self?.page(id: id).map { self?.select($0) } }
        strip.onClose = { [weak self] id in self?.page(id: id).map { self?.close($0) } }
        strip.onNew = { [weak self] in self?.newTab() }
        strip.tabMenu = { [weak self] id in self?.page(id: id).flatMap { self?.tabMenu($0) } }
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
        automationStrip.onTakeOver = { [weak self] in self?.activePage.endAutomationNote() }
        errorPage.isHidden = true
        errorPage.onReload = { [weak self] in self?.reloadAgain() }
        for view in [back, forward, addressBox, reload, tabCount, options, closeButton, errorPage, strip, toolbarLine, progress, automationStrip] as [NSView] {
            addSubview(view)
        }
        wantsLayer = true
        addSubview(activePage.webView, positioned: .below, relativeTo: errorPage)
        refreshChrome()
        extensionObserver = NotificationCenter.default.addObserver(forName: .bigttyExtensionsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshExtensionButtons() }
        }
        refreshExtensionButtons()
    }

    isolated deinit {
        if let extensionObserver { NotificationCenter.default.removeObserver(extensionObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    /// The list closes with the field, and when the window stops being key
    /// (the field keeps its focus then, so nothing else would close it).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.completer.hide() }
            }
        }
    }

    /// Extensions changed: the toolbar menu is rebuilt when it opens, so
    /// there's nothing to lay out.
    func refreshExtensionButtons() {}

    // MARK: - Menus

    /// ⋯, or a right-click on the toolbar: the page's actions, tabs and
    /// each extension (uBlock Origin Lite's popup opens under the address).
    func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        addOptions(to: menu)
        return menu
    }

    private func addOptions(to menu: NSMenu) {
        menu.autoenablesItems = false
        func add(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            item.keyEquivalentModifierMask = modifiers
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let page = activePage
        let hasPage = !page.isBlank
        // ↻ is out of the way in the tightest panes, so it comes in here.
        if bounds.width < Self.tightWidth {
            add("Reload Page", enabled: hasPage) { [weak self] in self?.reloadClicked() }
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
        menu.addItem(.separator())
        add("New Tab", "t") { [weak self] in self?.newTab() }
        add("Reopen Closed Tab", "t", [.command, .shift], enabled: !closed.isEmpty) { [weak self] in self?.reopenClosed() }
        menu.addItem(.separator())
        let history = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        history.submenu = historyPagesMenu()
        menu.addItem(history)
        let actions = WebExtensions.actions(for: page)
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
        if BrowserInspector.isAvailable {
            add("Web Inspector", "i", [.command, .option], enabled: hasPage) { [weak self] in self?.showInspector() }
        }
        add("Browser Settings…") {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        }
    }

    /// ⋯ ▸ History: recent pages, then Clear History….
    private func historyPagesMenu() -> NSMenu {
        let menu = NSMenu()
        let recent = Settings.browserHistory ? BrowserHistory.shared.recent(machine: machineKey, limit: 15) : []
        for visit in recent {
            guard let url = URL(string: visit.url) else { continue }
            menu.addItem(ClosureMenuItem(title: visit.title.isEmpty ? BrowserSuggestions.displayed(url) : visit.title) { [weak self] in
                self?.openTyped(url, newTab: false)
            })
        }
        if recent.isEmpty {
            let none = NSMenuItem(title: Settings.browserHistory ? "No Pages Yet" : "History Is Off", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Clear History…") { [weak self] in BrowserData.confirmClearHistory(in: self?.window) })
        return menu
    }

    /// The count button: every tab, then New Tab. At the tightest width it
    /// stands in for ⋯, so the options come along.
    func tabsMenu() -> NSMenu {
        let menu = NSMenu()
        for page in pages {
            let item = ClosureMenuItem(title: page.shownTitle) { [weak self] in self?.select(page) }
            item.state = page === activePage ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if bounds.width < Self.tightWidth {
            addOptions(to: menu)
        } else {
            let new = ClosureMenuItem(title: "New Tab", keyEquivalent: "t") { [weak self] in self?.newTab() }
            menu.addItem(new)
        }
        return menu
    }

    /// A right-click on a tab.
    private func tabMenu(_ page: BrowserPage) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Close Tab") { [weak self] in self?.close(page) })
        let others = ClosureMenuItem(title: "Close Other Tabs") { [weak self] in self?.closeOthers(page) }
        others.isEnabled = pages.count > 1
        menu.addItem(others)
        return menu
    }

    @objc private func showOptions() {
        optionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: options.bounds.height + 4), in: options)
    }

    @objc private func showTabs() {
        tabsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: tabCount.bounds.height + 4), in: tabCount)
    }

    /// Where ‹ or › leads, nearest first.
    private func historyMenu(forward: Bool) -> NSMenu? {
        let web = webView
        let list = web.backForwardList
        let entries = forward ? list.forwardList : list.backList.reversed()
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries.prefix(20) {
            let shown = localhostMapper?.display(entry.url) ?? entry.url
            let title = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? shown.absoluteString
            menu.addItem(ClosureMenuItem(title: title) { web.go(to: entry) })
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        // The page has its own menu; the toolbar gets ours.
        guard point.y >= bounds.height - chromeHeight else { return super.menu(for: event) }
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

    // MARK: - Layout

    private var showsStrip: Bool {
        pages.count >= 2 && bounds.width >= BrowserTabRules.stripMinimumPaneWidth && !activePage.isFullscreen
    }

    /// Toolbar and tab strip together. The find bar sits under this, and a
    /// right-click inside it opens the options.
    var chromeHeight: CGFloat {
        activePage.isFullscreen ? 0 : Self.toolbarHeight + (showsStrip ? Self.stripHeight : 0)
    }

    /// Where the page goes: everything under the chrome and the automation strip.
    var pageFrame: NSRect {
        let automation: CGFloat = activePage.automationText == nil || activePage.isFullscreen ? 0 : 26
        return NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - chromeHeight - automation))
    }

    override func layout() {
        super.layout()
        let b = bounds
        let theme = Theme.current
        layer?.backgroundColor = theme?.pane.cgColor
        let full = activePage.isFullscreen
        for view in [back, forward, closeButton, options, addressBox, toolbarLine] as [NSView] { view.isHidden = full }
        // Light and compact: ‹ › on the left, the address (with ↻ inside)
        // in the middle, ⋯ and × on the right. The toolbar is always on top
        // and the same height: the strip below it stays out of the band that
        // drags the pane.
        let y = b.height - (full ? 0 : Self.toolbarHeight) + 4
        back.frame = NSRect(x: 6, y: y, width: 20, height: 20)
        forward.frame = NSRect(x: 26, y: y, width: 20, height: 20)
        closeButton.frame = NSRect(x: b.width - 26, y: y, width: 20, height: 20)
        options.frame = NSRect(x: b.width - 46, y: y, width: 20, height: 20)
        // The tightest panes keep ‹, the address, the count or ⋯, and ×;
        // › and ↻ are in the right-click menus.
        let tight = b.width < Self.tightWidth
        forward.isHidden = full || tight
        reload.isHidden = full || tight
        // With no room for the strip, a button counts the tabs. At the
        // tightest it takes ⋯'s place, and its menu holds the options too.
        let counted = pages.count >= 2 && b.width < BrowserTabRules.stripMinimumPaneWidth && !full
        tabCount.isHidden = !counted
        tabCount.title = "\(pages.count)"
        tabCount.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        if tight, counted { options.isHidden = true }
        tabCount.frame = NSRect(x: tight ? b.width - 44 : b.width - 66, y: y + 2, width: 16, height: 16)
        let right: CGFloat = counted && !tight ? 74 : 52
        let fieldX: CGFloat = tight ? 30 : 52
        let fieldWidth = max(40, b.width - fieldX - right - 4)
        addressBox.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: 20)
        reload.frame = NSRect(x: addressBox.frame.maxX - 22, y: y, width: 20, height: 20)
        layoutAddress(tight: tight)
        completer.reposition()
        let chrome = chromeHeight
        strip.isHidden = !showsStrip
        strip.frame = NSRect(x: 0, y: b.height - Self.toolbarHeight - Self.stripHeight, width: b.width, height: Self.stripHeight)
        toolbarLine.frame = NSRect(x: 0, y: b.height - chrome, width: b.width, height: 0.5)
        toolbarLine.layer?.backgroundColor = theme?.separator.cgColor
        progress.frame = NSRect(x: 0, y: b.height - chrome - 1, width: b.width * max(0.05, activePage.progress), height: 2)
        let page = pageFrame
        automationStrip.isHidden = page.height == b.height - chrome
        automationStrip.frame = NSRect(x: 0, y: page.maxY, width: b.width, height: 26)
        // Hidden pages keep the pane's size: an agent's screenshot of one
        // should look like the page would.
        for each in pages where each.hasWebView { each.webView.frame = page }
        BrowserInspector.keepDetached(webView, in: self)
        errorPage.frame = page
        if chrome != laidOutChrome {
            laidOutChrome = chrome
            superview?.needsLayout = true
        }
    }

    /// The find bar lines up under the chrome: its pane must hear of changes.
    private var laidOutChrome: CGFloat = 0

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

    // MARK: - Keeping the chrome current

    /// The page's URL, title or sound changed: what's saved, and the tab.
    func pageChanged(_ page: BrowserPage) {
        if page === activePage, !isEditingAddress { renderAddress() }
        refreshStrip()
        saveState()
    }

    func pageAddressChanged(_ page: BrowserPage) {
        guard page === activePage else { return }
        if !isEditingAddress { renderAddress() }
        updateSecurity()
    }

    /// Loading, progress, back/forward, a failure, an agent's strip.
    func pageChromeChanged(_ page: BrowserPage) {
        refreshStrip()
        guard page === activePage else { return }
        updateButtons()
        updateLoading()
        updateSecurity()
        updateErrorPage()
        automationStrip.text = page.automationText ?? ""
        needsLayout = true
    }

    /// A load finished: an open find bar searches the new page too.
    func pageLoaded(_ page: BrowserPage) {
        if page === activePage { finderStorage?.pageLoaded() }
        pageChromeChanged(page)
    }

    private func refreshChrome() {
        renderAddress()
        pageChromeChanged(activePage)
    }

    private func refreshStrip() {
        strip.show(pages.map { page in
            BrowserTabStrip.Tab(
                id: page.id, title: page.shownTitle, tile: BrowserTabRules.tile(title: page.title, url: page.address),
                loading: page.isLoading, audible: page.isAudible, driven: page.automationText != nil, active: page === activePage
            )
        })
    }

    private func updateLoading() {
        let loading = activePage.isLoading
        progress.isHidden = !loading
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        reload.toolTip = loading ? "Stop" : "Reload"
    }

    private func updateButtons() {
        back.isEnabled = activePage.canGoBack
        forward.isEnabled = activePage.canGoForward
    }

    private func updateErrorPage() {
        if let failure = activePage.failure {
            errorPage.show(error: failure.error, url: failure.url)
        } else {
            errorPage.isHidden = true
        }
    }

    /// Mirrors the tabs to the store, with `url` and `title` following the
    /// active one, so herdr tags and everything else that reads them still work.
    private func saveState() {
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser)
        state.url = activePage.address?.absoluteString
        state.title = activePage.title.isEmpty ? nil : activePage.title
        state.audible = isAudible
        state.tabs = pages.map(\.tabState)
        state.activeTab = activePage.id
        HostPaneStore.shared[hostID] = state
        onStateChange?(state)
    }

    // MARK: - Tabs

    func page(id: String) -> BrowserPage? { pages.first { $0.id == id } }

    /// `--tab`: its number in the strip, or its id.
    func page(matching wanted: String) -> BrowserPage? {
        BrowserTabRules.index(matching: wanted, ids: pages.map(\.id)).map { pages[$0] }
    }

    /// Someone is using this pane, so an agent mustn't take the screen.
    var isInUse: Bool {
        guard let window, window.isKeyWindow, let responder = window.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// The page a calling terminal last used here, if it's still open.
    func page(forCaller caller: String) -> BrowserPage? { callers[caller].flatMap(page(id:)) }

    func noteCaller(_ caller: String, on page: BrowserPage) { callers[caller] = page.id }

    /// A page next to `after`, or at the end of the row, selected or not.
    /// Unselected, it loads at once: it's a link someone wants to read.
    @discardableResult
    func newPage(url: URL? = nil, select selecting: Bool = true, after: BrowserPage? = nil, agent: Bool = false,
                 popup: WKWebViewConfiguration? = nil) -> BrowserPage {
        let tab = BrowserTabState(id: BrowserTabRules.newID(), url: url?.absoluteString, agent: agent ? true : nil)
        let page = BrowserPage(tab: tab, dataStore: dataStore, localhostMapper: localhostMapper, popup: popup)
        page.pane = self
        pages.insert(page, at: after.flatMap { opener in pages.firstIndex { $0 === opener } }.map { $0 + 1 } ?? pages.count)
        if selecting {
            select(page)
        } else {
            _ = page.webView
            refreshStrip()
            saveState()
            needsLayout = true
        }
        return page
    }

    /// ⌘T: a blank tab, with the address ready.
    func newTab() {
        newPage()
        focusAddressBar()
    }

    func select(_ page: BrowserPage) {
        guard page !== activePage, pages.contains(where: { $0 === page }) else { return }
        let hadKeyboard = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        if isEditingAddress { window?.makeFirstResponder(nil) }
        completer.hide()
        finderStorage?.pageHidden()
        activePage.saveHistory()
        // A hidden page leaves the view tree; its pane keeps it, and
        // `BrowserPage.keepAwake` covers one an agent is working in.
        if activePage.hasWebView { activePage.webView.removeFromSuperview() }
        activePage = page
        let web = page.webView
        web.frame = pageFrame
        addSubview(web, positioned: .below, relativeTo: errorPage)
        if hadKeyboard { window?.makeFirstResponder(web) }
        if BrowserRegistry.shared.lastFocused == hostID { WebExtensions.tabActivated(page) }
        finderStorage?.pageLoaded()
        refreshChrome()
        saveState()
    }

    /// ⌃⌥1–9.
    func selectNumber(_ n: Int) -> Bool {
        guard let index = BrowserTabRules.index(forNumber: n, count: pages.count) else { return false }
        select(pages[index])
        return true
    }

    /// ⇧⌘] and ⇧⌘[.
    func cycleTabs(by offset: Int) {
        guard let index = pages.firstIndex(where: { $0 === activePage }) else { return }
        select(pages[(index + offset + pages.count) % pages.count])
    }

    /// Closes a tab; the last one closes the pane.
    func close(_ page: BrowserPage) {
        guard let index = pages.firstIndex(where: { $0 === page }) else { return }
        guard pages.count > 1 else {
            onClose?()
            return
        }
        if !page.isBlank {
            closed.append(ClosedBrowserTab(tab: page.tabState, index: index, history: page.historyData))
            if closed.count > BrowserTabRules.closedLimit { closed.removeFirst() }
        }
        if page === activePage {
            let rest = pages.filter { $0 !== page }
            select(rest[BrowserTabRules.indexAfterClosing(index, count: pages.count)])
        }
        pages.removeAll { $0 === page }
        forget(page)
        refreshStrip()
        saveState()
        needsLayout = true
    }

    private func forget(_ page: BrowserPage) {
        page.close()
        BrowserPageState.remove(page.id)
        callers = callers.filter { $0.value != page.id }
    }

    func closeOthers(_ keep: BrowserPage) {
        for page in pages where page !== keep { close(page) }
    }

    /// The pane is gone.
    func closeAllPages() {
        pages.forEach(forget)
        closed.removeAll()
    }

    /// ⇧⌘T: the last closed tab, where it was, with its back/forward list.
    func reopenClosed() {
        guard let last = closed.popLast() else { return }
        let page = BrowserPage(tab: last.tab, history: last.history, dataStore: dataStore, localhostMapper: localhostMapper)
        page.pane = self
        pages.insert(page, at: min(last.index, pages.count))
        select(page)
    }

    /// ⌘-click and middle-click in a page.
    func openLink(_ url: URL, from page: BrowserPage, background: Bool) {
        newPage(url: url, select: !background, after: page, agent: page.openedByAgent)
    }

    /// A page asked for a window: WebKit loads it into the view we hand back.
    /// A hidden page is an agent's, which mustn't take the screen.
    func openPopup(_ configuration: WKWebViewConfiguration, from page: BrowserPage, background: Bool) -> BrowserPage? {
        newPage(select: !background && page === activePage, after: page, agent: page.openedByAgent, popup: configuration)
    }

    /// A link from a terminal: the tab already on that page, else a new one.
    func showLink(_ url: URL) {
        if let existing = pages.first(where: { BrowserTabRules.samePage($0.address, url) }) {
            select(existing)
        } else if activePage.isBlank {
            activePage.navigate(to: url)
        } else {
            newPage(url: url)
        }
    }

    /// ⌘ held: each tab's shortcut on its tile.
    func showTabHints(_ showing: Bool) { strip.showsHints = showing }

    // MARK: - Address bar

    var isEditingAddress: Bool { address.currentEditor() != nil }

    func focusAddressBar() {
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    /// At rest: the host bright, the rest dim, shortened to fit. A local
    /// page's port is part of the bright part, since it names the site.
    private func renderAddress() {
        guard let pageAddress = activePage.address else {
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
        address.stringValue = activePage.address?.absoluteString ?? ""
        needsLayout = true
        completer.began()
    }

    func controlTextDidChange(_ note: Notification) {
        if let editor = note.userInfo?["NSFieldEditor"] as? NSTextView { completer.textChanged(editor) }
    }

    var addressAnchor: NSView { addressBox }
    var suggestions: [BrowserSuggestion] { completer.rows }

    /// Left without Return: back to the page's address. With no page yet,
    /// what was typed stays, in case the click away was to go copy something.
    private func addressLostFocus() {
        completer.hide()
        if !activePage.isBlank { renderAddress() }
        needsLayout = true
    }

    /// Esc: the first press puts the page's address back and keeps the
    /// field; the next returns to the page. Nothing to undo goes straight there.
    func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        switch selector {
        case #selector(moveDown(_:)), #selector(moveUp(_:)):
            guard completer.isShowing else { return false }
            completer.move(by: selector == #selector(moveDown(_:)) ? 1 : -1)
            return true
        case #selector(insertNewline(_:)):
            return completer.enter(newTab: command)
        case Selector(("noop:")):
            // ⌘⏎ has no binding of its own.
            guard command, NSApp.currentEvent?.keyCode == 36 else { return false }
            return completer.enter(newTab: true)
        case #selector(deleteToBeginningOfLine(_:)):
            return completer.removeSelected()
        case #selector(cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            break
        default:
            return false
        }
        completer.hide()
        let original = activePage.address?.absoluteString ?? ""
        if textView.string != original {
            textView.string = original
            textView.selectAll(nil)
        } else {
            window?.makeFirstResponder(webView)
        }
        return true
    }

    @objc private func addressEntered() {
        let text = address.stringValue
        completer.hide()
        if let url = BrowserAddress.normalize(text) { openTyped(url, newTab: false) }
    }

    /// Return in the address bar, or a row or menu item the user chose.
    func openTyped(_ url: URL, newTab: Bool) {
        let page = newTab ? newPage() : activePage
        page.noteTyped()
        page.navigate(to: url)
        leaveAddressBar()
    }

    /// The keyboard goes back to the page.
    func leaveAddressBar() { window?.makeFirstResponder(webView) }

    /// Forgets saved back/forward lists and the reopen list, which hold URLs.
    func forgetSavedHistory() {
        closed.removeAll()
        for page in pages { page.forgetSavedHistory() }
    }

    func showInspector() { BrowserInspector.show(webView) }

    private func updateSecurity() {
        let state = activePage.security
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

    // MARK: - The active page

    func load(_ input: String) { activePage.load(input) }
    func navigate(to url: URL) { activePage.navigate(to: url) }
    func reloadAgain() { activePage.reload() }
    func reloadWithoutCache() { activePage.reloadWithoutCache() }
    func stopLoading() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    var isLoading: Bool { activePage.isLoading }

    @objc private func goBackClicked() { goBack() }
    @objc private func goForwardClicked() { goForward() }

    /// The ↻ in the address bar: stops a load in progress, else reloads.
    @objc private func reloadClicked() {
        if isLoading { stopLoading() } else { reloadAgain() }
    }

    /// The pane's ×. ⇧⌘T only brings back single tabs, so a pane of several
    /// asks first.
    @objc private func closeClicked() {
        guard pages.count > 1, let window else {
            onClose?()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane and its \(pages.count) tabs?"
        alert.informativeText = "Closed tabs can be reopened with ⇧⌘T, but a closed pane can’t."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onClose?() }
        }
    }

    func openInDefaultBrowser() {
        if let url = activePage.realURL { NSWorkspace.shared.open(url) }
    }

    func copyAddress() {
        guard let url = activePage.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// ⌘+ ⌘− (±1) and ⌘0 (0).
    func zoom(by step: Int) {
        webView.pageZoom = step == 0 ? 1 : min(3, max(0.5, webView.pageZoom + CGFloat(step) * 0.1))
    }

    private var zoomPercent: Int { Int((webView.pageZoom * 100).rounded()) }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if ProcessInfo.processInfo.environment["BIGTTY_TRACE_BROWSER"] != nil {
            NSLog("bigtty-trace: browser \(hostID) superview=\(String(describing: superview)) \(Thread.callStackSymbols.prefix(8).joined(separator: " | "))")
        }
    }

    // MARK: - Focus

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, [.leftMouseDown, .rightMouseDown].contains(NSApp.currentEvent?.type) { onFocus?() }
        return hit
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
