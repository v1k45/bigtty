import AppKit
import GhosttyTerminal
import HerdrKit

/// One app window: a sidebar of machines and spaces (the selected space's
/// tabs nested under it), and the selected tab's panes as rounded cards.
/// Each window keeps its own space/tab selection.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, PaneActions {
    private let manager: MachineManager
    /// The machine whose space this window shows.
    private(set) var machine: Machine
    private let terminalController: TerminalController
    /// A store stand-in while a remote machine is still connecting.
    private static let offline = SessionStore(endpoint: HerdrEndpoint(forwardedSocket: "/nonexistent/herdr.sock"))
    private var store: SessionStore { machine.store ?? Self.offline }
    private var attention: AttentionCenter { machine.attention ?? Self.offlineAttention }
    private var spaceInfo: SpaceInfoCenter { machine.spaceInfo ?? Self.offlineInfo }
    private static let offlineAttention = AttentionCenter(store: offline)
    private static let offlineInfo = SpaceInfoCenter(store: offline, attention: offlineAttention)
    private let sidebar = SidebarView()
    private let splitTree = SplitTreeView()
    private let topBar = CollapsedTopBar()
    private let placeholder = PlaceholderView()
    private var observers: [(UUID, (UUID) -> Void)] = []
    private var settingsObserver: NSObjectProtocol?
    /// herdr's focused pane as of the last render, to notice when it moves.
    private var lastHerdrFocus: String?
    /// A pane to focus once its view exists (reveal, jump-to-unread).
    private var pendingFocus: String?

    private var workspaceID: String?
    private var tabID: String?
    /// Pane views for the visible tab, reused across layout changes.
    private var paneViews: [String: PaneContainerView] = [:]
    private var lastFocusedPane: String?
    private var theme: Theme
    private var root: RootView!

    var onClose: (() -> Void)?
    /// In window-per-space mode the window shows exactly this space, and
    /// picking another one in the sidebar opens that space's window instead.
    var pinnedSpace: SpaceRef? {
        didSet {
            guard pinnedSpace != oldValue else { return }
            if let space = pinnedSpace {
                if space.machine != machine.id, let target = manager.machine(space.machine) { switchMachine(to: target) }
                workspaceID = space.workspace
                tabID = nil
                lastFocusedPane = nil
            }
            render()
        }
    }
    var pinnedWorkspaceID: String? { pinnedSpace?.workspace }
    var onShowSpace: ((SpaceRef) -> Void)?
    var onConnectMachine: (() -> Void)?
    var onMachineProblem: ((Machine) -> Void)?
    /// The pinned workspace no longer exists in herdr.
    var onSpaceClosed: (() -> Void)?
    var onStartHerdr: (() -> Void)?
    var onJump: (() -> Void)?

    var sidebarVisible: Bool {
        get { root.sidebarVisible }
        set {
            root.sidebarVisible = newValue
            UserDefaults.standard.set(newValue, forKey: "sidebarVisible")
        }
    }

    init(manager: MachineManager, terminalController: TerminalController) {
        self.manager = manager
        machine = manager.local
        self.terminalController = terminalController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("GhostHerdrMain")
        window.tabbingMode = .disallowed
        theme = Theme(controller: terminalController)
        super.init(window: window)
        window.delegate = self
        buildLayout()
        wireActions()
        // Every machine's store, attention and sidebar info report through the manager.
        let a = manager.observe { [weak self] in self?.render() }
        observers = [(a, { manager.removeObserver($0) })]
        settingsObserver = NotificationCenter.default.addObserver(forName: .ghostherdrSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        guard let window else { return }
        let main = MainArea(content: splitTree, placeholder: placeholder, topBar: topBar)
        root = RootView(sidebar: sidebar, main: main)
        root.sidebarVisible = Settings.sidebarVisible
        root.onAppearanceChange = { [weak self] in self?.applyTheme() }
        window.contentView = root
        applyTheme()

        splitTree.paneView = { [weak self] id in self?.paneView(for: id) }
        splitTree.onRatioChange = { [weak self] path, ratio in
            guard let self, let tabID = self.tabID else { return }
            self.store.perform { try await $0.setSplitRatio(tabID: tabID, path: path, ratio: ratio) }
        }
    }

    /// Follows the system appearance: Ghostty picks the matching light or
    /// dark theme, and the chrome is derived from its background.
    private func applyTheme() {
        guard let window else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        terminalController.setColorScheme(dark ? .dark : .light)
        theme = Theme(controller: terminalController)
        Theme.current = theme
        window.backgroundColor = theme.window
        root.background = theme.window
        placeholder.background = theme.pane
        for view in paneViews.values { view.apply(theme) }
        sidebar.refreshTheme()
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.needsLayout = true
            view.subviews.forEach(redraw)
        }
        window.contentView.map(redraw)
    }

    private func wireActions() {
        sidebar.onSelectSpace = { [weak self] key in
            guard let self, let ref = SpaceRef(key: key) else { return }
            if let pinned = self.pinnedSpace, pinned != ref {
                self.onShowSpace?(ref)
            } else {
                self.select(ref)
            }
        }
        sidebar.onSelectTab = { [weak self] key, tab in
            guard let self, let ref = SpaceRef(key: key) else { return }
            if let pinned = self.pinnedSpace, pinned != ref {
                self.onShowSpace?(ref)
                return
            }
            self.select(ref)
            self.selectTab(tab)
        }
        sidebar.onSpaceMenu = { [weak self] key in
            guard let self, let ref = SpaceRef(key: key), ref.machine == self.machine.id else { return nil }
            return self.spaceMenu(ref.workspace)
        }
        sidebar.onMachineClick = { [weak self] id in
            guard let self, let machine = self.manager.machine(id) else { return }
            self.onMachineProblem?(machine)
        }
        sidebar.onNewSpace = { [weak self] in self?.newWorkspace(nil) }
        sidebar.onConnectMachine = { [weak self] in self?.onConnectMachine?() }
        topBar.onShowSidebar = { [weak self] in self?.sidebarVisible = true }
        placeholder.onStart = { [weak self] in self?.onStartHerdr?() }
        placeholder.onConnect = { [weak self] in self?.onConnectMachine?() }
        placeholder.onAction = { [weak self] in
            guard let self else { return }
            switch self.machine.status {
            case .notRunning: self.machine.startServer()
            default: self.machine.connect()
            }
        }
    }

    // MARK: - Rendering

    private func render() {
        let snapshot = store.snapshot
        if let pinned = pinnedWorkspaceID {
            if store.workspace(pinned) == nil {
                if case .connected = store.state, machine.status == .connected { onSpaceClosed?() }
                return
            }
            workspaceID = pinned
        }
        // Keep this window's selection while it exists; otherwise follow herdr.
        if store.workspace(workspaceID) == nil {
            workspaceID = snapshot.focusedWorkspaceID ?? snapshot.workspaces.first?.workspaceID
            tabID = nil
        }
        if let workspaceID, store.tab(tabID)?.workspaceID != workspaceID {
            tabID = store.workspace(workspaceID)?.activeTabID ?? store.tabs(in: workspaceID).first?.tabID
        }

        sidebar.update(sidebarModel())

        let layout = tabID.flatMap { store.layouts[$0] }
        let visible = Set(layout?.root.paneIDs ?? [])
        for (id, view) in paneViews where !visible.contains(id) {
            view.terminal?.detach()
            view.removeFromSuperview()
            paneViews.removeValue(forKey: id)
        }
        // Each window keeps its own focused pane. herdr's focus is followed
        // only by the key window, where it moved because of this window's
        // own actions (focus left/right, split, …).
        let herdrFocus = layout?.focusedPaneID
        if herdrFocus != lastHerdrFocus {
            lastHerdrFocus = herdrFocus
            if window?.isKeyWindow == true || lastFocusedPane == nil || !visible.contains(lastFocusedPane!) {
                pendingFocus = pendingFocus ?? herdrFocus
            }
        }
        if let current = lastFocusedPane, !visible.contains(current) { lastFocusedPane = nil }
        let focused = lastFocusedPane ?? herdrFocus
        // A pane tagged as a browser (or untagged) since its view was built
        // keeps the same layout, so the tree must be rebuilt explicitly.
        let retagged = paneViews.filter { id, view in store.pane(id).map { $0.hostKind != view.hostKind } ?? false }
        for (id, view) in retagged {
            view.terminal?.detach()
            view.removeFromSuperview()
            paneViews.removeValue(forKey: id)
            if id == lastFocusedPane || id == herdrFocus { pendingFocus = id }
        }
        let zoomed = layout?.zoomed == true ? herdrFocus : nil
        splitTree.show(layout?.root, zoomedPane: zoomed)
        if !retagged.isEmpty { splitTree.rebuild() }
        let dim = Settings.dimUnfocused
        for (id, view) in paneViews {
            view.update(pane: store.pane(id), attention: attention.reason(for: id))
            view.dimsWhenUnfocused = dim && visible.count > 1 && zoomed == nil
            view.isFocusedPane = id == focused
            view.isZoomed = id == zoomed
        }

        placeholder.state = placeholderState(hasLayout: layout != nil)
        topBar.update(space: store.workspace(workspaceID)?.label, tab: store.tab(tabID).map(tabLabel), alert: firstAlertElsewhere())

        if let target = pendingFocus ?? (lastFocusedPane == nil ? focused : nil), let view = paneViews[target] {
            pendingFocus = nil
            lastFocusedPane = target
            if let browser = view.browser {
                if pendingAddressFocus, browser.webView.url == nil {
                    pendingAddressFocus = false
                    browser.focusAddressBar()
                } else {
                    window?.makeFirstResponder(browser.webView)
                }
            } else {
                window?.makeFirstResponder(view.content)
            }
        }
        window?.title = store.workspace(workspaceID)?.label ?? "GhostHerdr"
    }

    /// What to show instead of panes, for this window's machine.
    private func placeholderState(hasLayout: Bool) -> PlaceholderView.State {
        if machine.isLocal {
            switch store.state {
            case .connecting: return .connecting("Connecting to herdr…")
            case .disconnected: return .notRunning(socket: store.client.endpoint.socketPath, binary: store.client.endpoint.herdrBinary)
            case .connected: return hasLayout ? .hidden : .empty
            }
        }
        let name = machine.name
        switch machine.status {
        case .connecting: return .connecting("Connecting to \(name)…")
        case let .reconnecting(seconds): return .connecting("Lost \(name) · reconnecting\(seconds > 0 ? " in \(seconds)s" : "")…")
        case .connected:
            if case .connected = store.state { return hasLayout ? .hidden : .empty }
            return .connecting("Connecting to \(name)…")
        case .notRunning: return .remote(title: "herdr isn’t running on \(name)", detail: "Start it there to see its spaces.", action: "Start herdr on \(name)")
        case .herdrMissing: return .remote(title: "herdr isn’t installed on \(name)", detail: "Install herdr on the machine (herdr.dev), or set it up from a terminal with herdr machine add.", action: nil)
        case let .signIn(message): return .remote(title: "Sign in to \(name)", detail: message, action: "Try Again")
        case let .failed(message): return .remote(title: "Can’t reach \(name)", detail: message, action: "Try Again")
        case .disabled: return .remote(title: "\(name) is off", detail: "", action: "Connect")
        }
    }

    /// Shows a space, switching this window to its machine if needed.
    func select(_ ref: SpaceRef) {
        if ref.machine != machine.id, let target = manager.machine(ref.machine) { switchMachine(to: target) }
        selectWorkspace(ref.workspace)
    }

    /// Points this window at another machine: its panes go, its spaces come.
    func switchMachine(to target: Machine) {
        guard target !== machine else { return }
        for view in paneViews.values {
            view.terminal?.detach()
            view.removeFromSuperview()
        }
        paneViews.removeAll()
        machine = target
        workspaceID = nil
        tabID = nil
        lastFocusedPane = nil
        lastHerdrFocus = nil
        pendingFocus = nil
        splitTree.show(nil, zoomedPane: nil)
        render()
    }

    private func tabLabel(_ tab: Tab) -> String {
        tab.label == String(tab.number) ? "tab \(tab.number)" : tab.label
    }

    /// The sidebar: every machine with its spaces; the selected one lists its tabs.
    private func sidebarModel() -> SidebarModel {
        var model = SidebarModel()
        var number = 0
        for machine in manager.all {
            guard let store = machine.store, let attention = machine.attention, let spaceInfo = machine.spaceInfo,
                  case .connected = store.state
            else {
                let status = machine.isLocal
                    ? (machine.store?.state == .connecting ? "connecting…" : "not running")
                    : machine.statusText
                model.machines.append(.init(id: machine.id, name: machine.name, status: status, statusIsProblem: machine.statusIsProblem, spaces: []))
                if machine.isLocal, case .disconnected = machine.store?.state { model.message = "No spaces yet." }
                continue
            }
            let spaces = store.snapshot.workspaces.map { workspace -> SidebarModel.Space in
                number += 1
                let ref = SpaceRef(machine: machine.id, workspace: workspace.workspaceID)
                let info = spaceInfo.info[workspace.workspaceID] ?? .init()
                let dir = info.directory.map { machine.isLocal ? ($0 as NSString).abbreviatingWithTildeInPath : $0 } ?? ""
                let meta = [info.branch, dir.isEmpty ? nil : dir].compactMap { $0 }.joined(separator: " · ")
                let selected = machine === self.machine && workspace.workspaceID == workspaceID
                let tabs = selected ? store.tabs(in: workspace.workspaceID).map { tab -> SidebarModel.Tab in
                    let panes = store.panes(in: tab.tabID).count
                    let alert = attention.count(inTab: tab.tabID) > 0
                    return .init(
                        id: tab.tabID, label: tabLabel(tab),
                        detail: alert ? "needs you" : (panes > 1 ? "\(panes) panes" : ""),
                        selected: tab.tabID == tabID, alert: alert
                    )
                } : []
                let finished = store.snapshot.panes.contains {
                    $0.workspaceID == workspace.workspaceID && attention.reason(for: $0.paneID) == .done
                }
                return .init(
                    id: ref.key, name: workspace.label,
                    shortcut: number <= 9 ? "⌘\(number)" : "",
                    meta: meta, ports: info.ports, line: info.line,
                    alert: info.lineIsAlert && !selected || (info.lineIsAlert && selected && tabs.count <= 1),
                    finished: finished, selected: selected, tabs: tabs.count > 1 ? tabs : []
                )
            }
            model.machines.append(.init(id: machine.id, name: machine.name, status: machine.statusText, statusIsProblem: machine.statusIsProblem, spaces: spaces))
        }
        return model
    }

    /// Spaces in sidebar order, for ⌘1…⌘9.
    private var orderedSpaces: [SpaceRef] {
        manager.all.flatMap { machine -> [SpaceRef] in
            guard let store = machine.store, case .connected = store.state else { return [] }
            return store.snapshot.workspaces.map { SpaceRef(machine: machine.id, workspace: $0.workspaceID) }
        }
    }

    /// A space other than this one with an agent waiting, for the top bar.
    private func firstAlertElsewhere() -> String? {
        for machine in manager.all {
            guard let store = machine.store, let info = machine.spaceInfo else { continue }
            if let space = store.snapshot.workspaces.first(where: {
                !(machine === self.machine && $0.workspaceID == workspaceID) && info.info[$0.workspaceID]?.lineIsAlert == true
            }) {
                return "\(space.label) needs you"
            }
        }
        return nil
    }

    private func spaceMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            menu.addItem(item)
        }
        add("Rename Space…") { [weak self] in self?.promptRename(workspaceID: id) }
        add("New Tab") { [weak self] in self?.store.perform { try await $0.createTab(workspaceID: id) } }
        menu.addItem(.separator())
        add("Show Changes") { [weak self] in
            guard let self else { return }
            if self.workspaceID != id { self.selectWorkspace(id) }
            self.showChanges(nil)
        }
        if let dir = spaceInfo.info[id]?.directory {
            add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)]) }
        }
        menu.addItem(.separator())
        add("Close Space…") { [weak self] in self?.confirmCloseSpace(id) }
        return menu
    }

    // MARK: - Panes

    private func paneView(for id: String) -> NSView? {
        guard let pane = store.pane(id) else { return paneViews[id] }
        if let view = paneViews[id] {
            if view.hostKind == pane.hostKind { return view }
            // The pane was tagged (or untagged) as a host pane since: rebuild.
            view.terminal?.detach()
            view.removeFromSuperview()
            paneViews.removeValue(forKey: id)
        }
        let content: NSView
        if pane.hostKind == .browser, let hostID = pane.hostID {
            content = makeBrowser(pane: pane, hostID: hostID)
        } else if pane.hostKind == .files || pane.hostKind == .diff, let hostID = pane.hostID {
            content = makeFiles(pane: pane, hostID: hostID)
        } else {
            let terminal = HerdrTerminalView(pane: pane, endpoint: store.client.endpoint, controller: terminalController)
            terminal.onFocus = { [weak self] in self?.paneGainedFocus(id) }
            terminal.onOpenURL = { [weak self] url in self?.openURL(url, from: id) }
            content = terminal
        }
        let view = PaneContainerView(paneID: id, content: content)
        view.apply(theme)
        view.update(pane: pane, attention: attention.reason(for: id))
        paneViews[id] = view
        return view
    }

    private func makeBrowser(pane: Pane, hostID: String) -> BrowserPaneView {
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser)
        state.paneID = pane.paneID
        HostPaneStore.shared[hostID] = state
        // The registry owns the web view so agents can drive it while no
        // window shows it; this window borrows it.
        if state.machine == nil, !machine.isLocal {
            state.machine = machine.id
            HostPaneStore.shared[hostID] = state
        }
        let browser = BrowserRegistry.shared.view(for: hostID, machine: machine)
        let id = pane.paneID
        browser.onFocus = { [weak self] in
            BrowserRegistry.shared.noteFocus(hostID)
            self?.paneGainedFocus(id)
        }
        browser.onStateChange = { [weak self] state in self?.hostTitleChanged(paneID: id, hostID: hostID, state: state) }
        return browser
    }

    private func makeFiles(pane: Pane, hostID: String) -> FilesPaneView {
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: pane.hostKind ?? .files, path: pane.cwd)
        state.paneID = pane.paneID
        if state.machine == nil, !machine.isLocal { state.machine = machine.id }
        HostPaneStore.shared[hostID] = state
        let files = FilesRegistry.shared.view(for: hostID, machine: machine)
        let id = pane.paneID
        files.onFocus = { [weak self] in self?.paneGainedFocus(id) }
        files.onStateChange = { [weak self] state in self?.hostTitleChanged(paneID: id, hostID: hostID, state: state) }
        files.onInsertPath = { [weak self] path in self?.insertPath(path, near: id) }
        return files
    }

    /// Types a shell-quoted path into the tab's most recent terminal pane.
    private func insertPath(_ path: String, near paneID: String) {
        guard let tabID = store.pane(paneID)?.tabID else { return }
        let terminals = store.panes(in: tabID).filter { $0.hostKind == nil }
        let target = terminals.first { $0.paneID == lastTerminalPane } ?? terminals.first
        guard let target else { return }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' "
        store.perform { try await $0.sendText(paneID: target.paneID, text: quoted) }
        pendingFocus = target.paneID
    }

    /// The terminal pane focused most recently in this window.
    private var lastTerminalPane: String?

    @objc func newFilesPane(_: Any?) { openFilesPane(mode: .files) }
    @objc func showChanges(_: Any?) { openFilesPane(mode: .changes) }

    private func openFilesPane(mode: FilesPaneView.Mode) {
        guard let target = focusedPaneID else { return }
        let pane = store.pane(target)
        let home = machine.isLocal ? NSHomeDirectory() : "/"
        // The pane finds the repository root itself for Changes.
        let cwd = pane?.foregroundCwd ?? pane?.cwd ?? home
        HostPaneStore.open(
            HostPaneState(kind: mode == .changes ? .diff : .files, path: cwd, mode: mode.rawValue,
                          machine: machine.isLocal ? nil : machine.id),
            beside: target, direction: .right, store: store, remote: !machine.isLocal
        )
    }

    /// Mirrors a browser pane's page title to herdr, at most once a second.
    private var titleUpdates: [String: DispatchWorkItem] = [:]

    private func hostTitleChanged(paneID: String, hostID: String, state: HostPaneState) {
        titleUpdates[paneID]?.cancel()
        let title = HostPaneStore.hostTitle(state)
        let work = DispatchWorkItem { [weak self] in
            self?.store.perform { client in
                try await client.reportMetadata(
                    paneID: paneID, title: title, tokens: ["ghr_kind": state.kind.rawValue, "ghr_id": hostID]
                )
            }
        }
        titleUpdates[paneID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// A link clicked in a terminal opens in the tab's browser pane, or in a
    /// new one split off to the right of that terminal.
    func openURL(_ url: String, from paneID: String) {
        if Settings.links == .defaultBrowser, let link = URL(string: url) {
            NSWorkspace.shared.open(link)
            return
        }
        guard let tabID = store.pane(paneID)?.tabID else { return }
        if let browserPane = store.panes(in: tabID).first(where: { $0.hostKind == .browser }),
           let browser = paneViews[browserPane.paneID]?.browser
        {
            browser.load(url)
            return
        }
        HostPaneStore.open(HostPaneState(kind: .browser, url: url, machine: machine.isLocal ? nil : machine.id), beside: paneID, direction: .right, store: store, remote: !machine.isLocal)
    }

    /// Debug hook: scrolls the focused terminal by N lines (negative: down).
    @objc func debugScroll(_ sender: Any?) {
        guard let lines = (sender as? String).flatMap(Int32.init), let id = focusedPaneID else { return }
        paneViews[id]?.terminal?.debugScroll(lines: lines)
    }

    /// Debug hook: behaves like ⌘-clicking a link in the focused terminal.
    @objc func debugOpenURL(_ sender: Any?) {
        if let url = sender as? String, let pane = focusedPaneID { openURL(url, from: pane) }
    }

    /// Debug hook: selects a path in the focused files pane; `changes`
    /// or `files` switches its mode instead.
    @objc func debugFilesSelect(_ sender: Any?) {
        guard let arg = sender as? String, let id = focusedPaneID, let files = paneViews[id]?.files else { return }
        if let mode = FilesPaneView.Mode(rawValue: arg) { files.setMode(mode) } else { files.select(path: arg) }
    }

    @objc func newBrowserPane(_: Any?) {
        guard let target = focusedPaneID else { return }
        pendingAddressFocus = true
        HostPaneStore.open(HostPaneState(kind: .browser, machine: machine.isLocal ? nil : machine.id), beside: target, direction: .right, store: store, remote: !machine.isLocal)
    }

    /// ⌘L: the focused browser pane's address bar, or a new browser pane.
    @objc func openLocation(_ sender: Any?) {
        if let id = focusedPaneID, let browser = paneViews[id]?.browser {
            browser.focusAddressBar()
        } else {
            newBrowserPane(sender)
        }
    }

    private var pendingAddressFocus = false

    private func paneGainedFocus(_ id: String) {
        lastFocusedPane = id
        if paneViews[id]?.terminal != nil { lastTerminalPane = id }
        for (paneID, view) in paneViews { view.isFocusedPane = paneID == id }
        attention.viewChanged()
        guard let tabID, store.layouts[tabID]?.focusedPaneID != id else { return }
        store.perform { try await $0.focusPane(id) }
    }

    /// The focused pane, for control commands issued outside herdr.
    var focusedPaneForControl: String? { focusedPaneID }

    /// The pane the user is looking at in this window, if it is key.
    var viewedPane: String? {
        guard window?.isKeyWindow == true, window?.isVisible == true,
              let id = lastFocusedPane, paneViews[id] != nil else { return nil }
        return id
    }

    /// The space this window shows.
    var shownWorkspaceID: String? { workspaceID }

    /// Selects the pane's workspace and tab and focuses it.
    func reveal(_ pane: Pane) {
        window?.makeKeyAndOrderFront(nil)
        if pinnedWorkspaceID == nil { workspaceID = pane.workspaceID }
        tabID = pane.tabID
        lastFocusedPane = nil
        pendingFocus = pane.paneID
        render()
        store.perform { client in
            try await client.focusTab(pane.tabID)
            try await client.focusPane(pane.paneID)
        }
    }

    // MARK: - Selection

    func selectWorkspace(_ id: String) {
        guard id != workspaceID else { return }
        workspaceID = id
        tabID = nil
        lastFocusedPane = nil
        render()
    }

    private func selectTab(_ id: String) {
        guard id != tabID else { return }
        tabID = id
        lastFocusedPane = nil
        render()
        store.perform { try await $0.focusTab(id) }
    }

    private var focusedPaneID: String? {
        guard let tabID else { return nil }
        return lastFocusedPane ?? store.layouts[tabID]?.focusedPaneID
    }

    // MARK: - PaneActions

    @objc func splitRight(_: Any?) { split(.right) }
    @objc func splitDown(_: Any?) { split(.down) }

    private func split(_ direction: SplitDirection) {
        guard let pane = focusedPaneID else { return }
        store.perform { try await $0.split(paneID: pane, direction: direction) }
    }

    /// Asks first when an agent is still working or waiting in the pane.
    @objc func closePane(_: Any?) {
        guard let id = focusedPaneID, let pane = store.pane(id) else { return }
        let busy = (pane.agent != nil || pane.displayAgent != nil) && (pane.agentStatus == .working || pane.agentStatus == .blocked)
        guard busy, let window else {
            store.perform { try await $0.closePane(id) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        let agent = pane.displayAgent ?? pane.agent ?? "An agent"
        alert.informativeText = "\(agent) is still \(pane.agentStatus == .blocked ? "waiting for you" : "working") in it. Closing the pane stops it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.perform { try await $0.closePane(id) }
        }
    }

    @objc func zoomPane(_: Any?) {
        let pane = focusedPaneID
        store.perform { try await $0.zoomPane(pane) }
    }

    @objc func focusLeft(_: Any?) { moveFocus("left") }
    @objc func focusRight(_: Any?) { moveFocus("right") }
    @objc func focusUp(_: Any?) { moveFocus("up") }
    @objc func focusDown(_: Any?) { moveFocus("down") }

    private func moveFocus(_ direction: String) {
        let pane = focusedPaneID
        lastFocusedPane = nil
        store.perform { try await $0.focusDirection(direction, from: pane) }
    }

    @objc func resizeLeft(_: Any?) { resize("left") }
    @objc func resizeRight(_: Any?) { resize("right") }
    @objc func resizeUp(_: Any?) { resize("up") }
    @objc func resizeDown(_: Any?) { resize("down") }

    private func resize(_ direction: String) {
        let pane = focusedPaneID
        store.perform { try await $0.resizePane(pane, direction: direction) }
    }

    @objc func newTab(_: Any?) {
        guard let workspaceID else { return }
        tabID = nil
        store.perform { try await $0.createTab(workspaceID: workspaceID) }
    }

    @objc func closeTab(_: Any?) {
        guard let tabID else { return }
        store.perform { try await $0.closeTab(tabID) }
    }

    @objc func nextTab(_: Any?) { cycleTab(by: 1) }
    @objc func previousTab(_: Any?) { cycleTab(by: -1) }

    private func cycleTab(by offset: Int) {
        guard let workspaceID else { return }
        let tabs = store.tabs(in: workspaceID)
        guard let index = tabs.firstIndex(where: { $0.tabID == tabID }), !tabs.isEmpty else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count].tabID)
    }

    /// ⌘1…⌘9: spaces, in sidebar order.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag ?? (sender as? String).flatMap(Int.init) else { return }
        let spaces = orderedSpaces
        guard n - 1 < spaces.count else { return }
        sidebar.onSelectSpace?(spaces[n - 1].key)
    }

    /// The folder new spaces start in: the focused pane's working directory.
    var currentDirectory: String? {
        let pane = store.pane(focusedPaneID)
        return pane?.foregroundCwd ?? pane?.cwd
    }

    @objc func toggleSidebar(_: Any?) {
        sidebarVisible.toggle()
    }

    @objc func newWorkspace(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "New Space"
        panel.message = "Choose the folder the new space starts in."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if self.pinnedWorkspaceID == nil { self.workspaceID = nil }
            self.store.perform { try await $0.createWorkspace(cwd: url.path, label: url.lastPathComponent) }
        }
    }

    private func promptRename(workspaceID: String) {
        guard let window, let workspace = store.workspace(workspaceID) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        let field = NSTextField(string: workspace.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let label = field.stringValue
            self?.store.perform { try await $0.renameWorkspace(workspaceID, label: label) }
        }
    }

    private func confirmCloseSpace(_ id: String) {
        guard let window, let workspace = store.workspace(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Close “\(workspace.label)”?"
        alert.informativeText = "Its \(workspace.paneCount) pane\(workspace.paneCount == 1 ? "" : "s") and anything running in them stop. Files on disk are not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Space")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.perform { try await $0.closeWorkspace(id) }
        }
    }

    override var debugDescription: String {
        var out = "machine=\(machine.id) (\(machine.statusText)) window=\(window?.frame ?? .zero) tree=\(splitTree.frame)\n"
        out += "workspace=\(workspaceID ?? "-") tab=\(tabID ?? "-") focused=\(focusedPaneID ?? "-")\n"
        for (id, view) in paneViews.sorted(by: { $0.key < $1.key }) {
            let browser = view.browser.map {
                "browser url=\($0.webView.url?.absoluteString ?? "-") title=\($0.webView.title ?? "-") frame=\($0.frame) attached=\($0.superview === view) web=\($0.webView.frame)"
            }
            out += "pane \(id) alpha=\(view.alphaValue) frame=\(view.frame) \(view.terminal?.debugDescription ?? browser ?? "")\n"
        }
        return out
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_: Notification) {
        // Coming back to a window takes control of the pane it shows.
        if let id = lastFocusedPane, let terminal = paneViews[id]?.terminal, terminal.mode == .observe {
            terminal.takeControl()
        }
    }

    func windowWillClose(_: Notification) {
        for view in paneViews.values { view.terminal?.detach() }
        paneViews.removeAll()
        for (id, remove) in observers { remove(id) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        observers.removeAll()
        onClose?()
    }
}

extension Notification.Name {
    static let ghostherdrSettingsChanged = Notification.Name("GhostHerdrSettingsChanged")
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Sidebar on the left with a draggable edge; the main area on the right.
@MainActor
private final class RootView: NSView {
    private let sidebar: NSView
    private let main: MainArea
    private var sidebarWidth: CGFloat = 256
    private var dragging = false
    var background: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var sidebarVisible = true {
        didSet {
            sidebar.isHidden = !sidebarVisible
            main.showsTopBar = !sidebarVisible
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// The sidebar's translucent material, like Finder's or Mail's.
    private let material = NSVisualEffectView()

    init(sidebar: NSView, main: MainArea) {
        self.sidebar = sidebar
        self.main = main
        super.init(frame: .zero)
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        addSubview(material)
        addSubview(sidebar)
        addSubview(main)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: NSRect) {
        // Only the content side is opaque; the sidebar shows its material.
        background.setFill()
        NSRect(x: sidebarVisible ? sidebarWidth : 0, y: 0, width: bounds.width, height: bounds.height).fill()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        let b = bounds
        let w = sidebarVisible ? sidebarWidth : 0
        sidebar.frame = NSRect(x: 0, y: 0, width: w, height: b.height)
        material.frame = sidebar.frame
        material.isHidden = !sidebarVisible
        main.frame = NSRect(x: w, y: 0, width: b.width - w, height: b.height)
        main.leadingPadding = sidebarVisible ? 0 : 8
    }

    private var edge: NSRect { NSRect(x: sidebarWidth - 3, y: 0, width: 6, height: bounds.height) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        sidebarVisible && edge.contains(convert(point, from: superview)) ? self : super.hitTest(point)
    }

    override func resetCursorRects() {
        if sidebarVisible { addCursorRect(edge, cursor: .resizeLeftRight) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with _: NSEvent) { dragging = true }
    override func mouseUp(with _: NSEvent) { dragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        sidebarWidth = min(max(convert(event.locationInWindow, from: nil).x, 200), 420)
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }
}

/// Panes (or a placeholder) with 8pt margins; a slim top bar when the
/// sidebar is hidden, since the traffic lights then sit over the content.
@MainActor
private final class MainArea: NSView {
    let content: NSView
    let placeholder: PlaceholderView
    let topBar: CollapsedTopBar
    var showsTopBar = false { didSet { topBar.isHidden = !showsTopBar; needsLayout = true } }
    var leadingPadding: CGFloat = 0 { didSet { needsLayout = true } }

    init(content: NSView, placeholder: PlaceholderView, topBar: CollapsedTopBar) {
        self.content = content
        self.placeholder = placeholder
        self.topBar = topBar
        super.init(frame: .zero)
        topBar.isHidden = true
        addSubview(content)
        addSubview(placeholder)
        addSubview(topBar)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let top: CGFloat = showsTopBar ? 40 : 8
        topBar.frame = NSRect(x: 0, y: b.height - 40, width: b.width, height: 40)
        let area = NSRect(x: leadingPadding, y: 8, width: b.width - leadingPadding - 8, height: b.height - top - 8)
        content.frame = area
        placeholder.frame = area
    }
}

/// Shown instead of the sidebar's top when it is hidden.
@MainActor
private final class CollapsedTopBar: NSView {
    var onShowSidebar: (() -> Void)?
    private let button = NSButton()
    private let space = NSTextField(labelWithString: "")
    private let tab = NSTextField(labelWithString: "")
    private let alert = NSTextField(labelWithString: "")
    private let alertDot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show Sidebar")
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(show)
        space.font = .systemFont(ofSize: 13, weight: .semibold)
        tab.font = .systemFont(ofSize: 12)
        tab.textColor = .secondaryLabelColor
        alert.font = .systemFont(ofSize: 12)
        alert.textColor = .controlAccentColor
        alert.alignment = .right
        alertDot.wantsLayer = true
        alertDot.layer?.cornerRadius = 3.5
        alertDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        for view in [button, space, tab, alert, alertDot] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func update(space: String?, tab: String?, alert: String?) {
        self.space.stringValue = space ?? ""
        self.tab.stringValue = tab ?? ""
        self.alert.stringValue = alert ?? ""
        alertDot.isHidden = alert == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - 18) / 2
        button.frame = NSRect(x: 84, y: y - 3, width: 26, height: 24)
        let sw = ceil(space.intrinsicContentSize.width) + 4
        space.frame = NSRect(x: 116, y: y, width: sw, height: 18)
        tab.frame = NSRect(x: 116 + sw + 8, y: y + 1, width: 200, height: 16)
        let aw = alert.intrinsicContentSize.width
        alert.frame = NSRect(x: bounds.width - aw - 16, y: y + 1, width: aw, height: 16)
        alertDot.frame = NSRect(x: bounds.width - aw - 28, y: y + 5, width: 7, height: 7)
    }

    @objc private func show() { onShowSidebar?() }
}

/// What the main area shows with no panes: connecting, herdr not running,
/// or an empty space.
@MainActor
final class PlaceholderView: NSView {
    enum State: Equatable {
        case hidden, empty
        case connecting(String)
        case notRunning(socket: String, binary: String)
        /// A remote machine's problem, with an optional fix button.
        case remote(title: String, detail: String, action: String?)
    }

    var onStart: (() -> Void)?
    var onConnect: (() -> Void)?
    var onAction: (() -> Void)?
    private let action = NSButton(title: "", target: nil, action: nil)
    var background: NSColor = .textBackgroundColor { didSet { layer?.backgroundColor = background.cgColor } }
    var state: State = .hidden { didSet { if state != oldValue { apply() } } }

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let start = NSButton(title: "Start herdr", target: nil, action: nil)
    private let connect = NSButton(title: "Connect Machine…", target: nil, action: nil)
    private let footnote = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PaneContainerView.cornerRadius
        spinner.style = .spinning
        spinner.controlSize = .small
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.target = self
        start.action = #selector(startClicked)
        connect.bezelStyle = .rounded
        connect.target = self
        connect.action = #selector(connectClicked)
        footnote.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footnote.textColor = .tertiaryLabelColor
        footnote.alignment = .center
        action.bezelStyle = .rounded
        action.keyEquivalent = "\r"
        action.target = self
        action.action = #selector(actionClicked)
        for view in [spinner, icon, title, detail, start, connect, footnote, action] { addSubview(view) }
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func apply() {
        isHidden = state == .hidden
        let notRunning: Bool
        var remote = false
        switch state {
        case let .connecting(text):
            notRunning = false
            title.stringValue = ""
            detail.stringValue = text
            spinner.startAnimation(nil)
        case let .remote(titleText, detailText, actionTitle):
            notRunning = false
            remote = true
            title.stringValue = titleText
            detail.stringValue = detailText
            action.title = actionTitle ?? ""
            action.isHidden = actionTitle == nil
            spinner.stopAnimation(nil)
        case let .notRunning(socket, binary):
            notRunning = true
            title.stringValue = "herdr isn’t running"
            detail.stringValue = "GhostHerdr shows the spaces, agents and terminals of a herdr server. Start one here, or connect to a machine that already runs herdr."
            footnote.stringValue = "looked for \((socket as NSString).abbreviatingWithTildeInPath) · herdr at \((binary as NSString).abbreviatingWithTildeInPath)"
            spinner.stopAnimation(nil)
        case .empty:
            notRunning = false
            title.stringValue = ""
            detail.stringValue = "This space has no open tab. ⌘T opens one."
            spinner.stopAnimation(nil)
        case .hidden:
            notRunning = false
            spinner.stopAnimation(nil)
        }
        if case .connecting = state { spinner.isHidden = false } else { spinner.isHidden = true }
        for view in [start, connect, footnote] { view.isHidden = !notRunning }
        icon.isHidden = !(notRunning || remote)
        icon.image = NSImage(systemSymbolName: remote ? "server.rack" : "terminal", accessibilityDescription: nil)
        title.isHidden = !(notRunning || remote)
        if !remote { action.isHidden = true }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midX = bounds.midX
        var y = bounds.midY + 70
        icon.frame = NSRect(x: midX - 28, y: y, width: 56, height: 56)
        y -= 36
        title.frame = NSRect(x: 0, y: y, width: bounds.width, height: 26)
        detail.preferredMaxLayoutWidth = 420
        let dh = detail.fittingSize.height
        switch state {
        case .notRunning, .remote: y -= dh + 8
        default: y = bounds.midY - dh / 2
        }
        detail.frame = NSRect(x: midX - 210, y: y, width: 420, height: dh)
        spinner.frame = NSRect(x: midX - 110, y: y + (dh - 16) / 2, width: 16, height: 16)
        if case .connecting = state {
            detail.frame = NSRect(x: midX - 80, y: y, width: 200, height: dh)
            detail.alignment = .left
        } else {
            detail.alignment = .center
        }
        action.sizeToFit()
        action.frame.origin = NSPoint(x: midX - action.frame.width / 2, y: y - 44)
        start.sizeToFit()
        connect.sizeToFit()
        let total = start.frame.width + connect.frame.width + 10
        y -= 44
        start.frame.origin = NSPoint(x: midX - total / 2, y: y)
        connect.frame.origin = NSPoint(x: midX - total / 2 + start.frame.width + 10, y: y)
        footnote.frame = NSRect(x: 0, y: y - 34, width: bounds.width, height: 16)
    }

    @objc private func startClicked() { onStart?() }
    @objc private func actionClicked() { onAction?() }
    @objc private func connectClicked() { onConnect?() }
}
