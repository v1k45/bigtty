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
    private weak var mainArea: MainArea?
    private let topBar = CollapsedTopBar()
    private let placeholder = PlaceholderView()
    private var observers: [(UUID, (UUID) -> Void)] = []
    private var audioObserver: NSObjectProtocol?
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
    /// Autosave name of the main (sidebar) window's frame.
    static let frameName = "BigttyMain"
    private var fullScreenObservers: [NSObjectProtocol] = []
    /// Switch this Mac's session (the app delegate handles space windows).
    var onShowSession: ((Machine) -> Void)?
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
        machine = manager.activeLocal
        self.terminalController = terminalController
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 400)
        // The first window comes back where it was; the app delegate
        // cascades further windows from it.
        if Settings.remembersLayout {
            if !window.setFrameUsingName(Self.frameName) { window.center() }
            window.setFrameAutosaveName(Self.frameName)
        } else {
            window.center()
        }
        window.tabbingMode = .disallowed
        theme = Theme(controller: terminalController)
        super.init(window: window)
        window.delegate = self
        window.eventObserver = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if self.sheetConsumes(event) { return true }
                if self.paneKeyConsumes(event) { return true }
                // Letting go of ⌃ or ⌘ ends a ⌃⌘Tab walk through recent spaces.
                if event.type == .flagsChanged, Self.cycle != nil,
                   event.modifierFlags.intersection([.command, .control]) != [.command, .control] {
                    self.endRecentCycle()
                }
                self.hintTrigger.observe(event)
                return false
            }
        }

        buildLayout()
        wireActions()
        for (name, value) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)] {
            fullScreenObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setFullScreen(value) }
            })
        }
        // Every machine's store, attention and sidebar info report through the manager.
        let a = manager.observe { [weak self] in
            guard let self else { return }
            // This window's machine was removed (a session deleted elsewhere,
            // a machine removed): fall back rather than show a dead one.
            if !self.manager.all.contains(where: { $0 === self.machine }) {
                self.switchMachine(to: self.manager.activeLocal)
                return
            }
            self.render()
        }
        observers = [(a, { manager.removeObserver($0) })]
        audioObserver = NotificationCenter.default.addObserver(forName: .bigttyAudioChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: .bigttySettingsChanged, object: nil, queue: .main) { [weak self] _ in
            // The terminal theme may have changed; the chrome follows.
            MainActor.assumeIsolated {
                self?.applyTheme()
                self?.render()
            }
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        guard let window else { return }
        let main = MainArea(content: splitTree, placeholder: placeholder, topBar: topBar)
        mainArea = main
        main.dropSurface.hover = { [weak self] payload, point in self?.hoverDrop(payload, at: point) ?? false }
        main.dropSurface.commit = { [weak self] payload, point in self?.commitDrop(payload, at: point) ?? false }
        main.dropSurface.exit = { [weak main] in main?.dropHint.hide() }
        root = RootView(sidebar: sidebar, main: main)
        root.sidebarVisible = Settings.sidebarVisible
        root.onAppearanceChange = { [weak self] in self?.applyTheme() }
        window.contentView = root
        applyTheme()

        setUpHints()
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
        TerminalAppearance.follow(dark: dark, controller: terminalController)
        theme = Theme(controller: terminalController)
        Theme.current = theme
        window.backgroundColor = theme.window
        root.background = theme.window
        root.translucentContent = Settings.translucentWindow
        placeholder.background = theme.pane
        for view in paneViews.values {
            view.apply(theme)
            view.terminal?.syncColorScheme()
        }
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
            // "+N more" on a card just opens the space.
            if !tab.isEmpty { self.selectTab(tab) }
        }
        sidebar.onSpaceMenu = { [weak self] key in
            guard let self, let ref = SpaceRef(key: key), ref.machine == self.machine.id else { return nil }
            return self.spaceMenu(ref.workspace)
        }
        sidebar.onMachineClick = { [weak self] id in
            guard let self, let machine = self.manager.machine(id) else { return }
            self.onMachineProblem?(machine)
        }
        sidebar.onSessionMenu = { [weak self] in self?.sessionMenu() }
        sidebar.onMoveSpace = { [weak self] key, index in
            guard let self, let ref = SpaceRef(key: key), let machine = self.manager.machine(ref.machine) else { return }
            machine.store?.perform { try await $0.moveWorkspace(ref.workspace, to: index) }
        }
        topBar.onShowSidebar = { [weak self] in self?.sidebarVisible = true }
        topBar.onToggleFiles = { [weak self] in self?.toggleFileViewer(nil) }
        sidebar.onHideSidebar = { [weak self] in self?.sidebarVisible = false }
        sidebar.onToggleFiles = { [weak self] in self?.toggleFileViewer(nil) }
        placeholder.onStart = { [weak self] in self?.onStartHerdr?() }
        placeholder.onConnect = { [weak self] in self?.onConnectMachine?() }
        placeholder.onAction = { [weak self] in
            guard let self else { return }
            if self.herdrVersionProblem() != nil {
                // After an update: ask both versions again.
                LocalHerdr.forget()
                if self.machine.isLocal { self.store.stop(); self.store.start() } else { self.machine.connect() }
                self.render()
                return
            }
            switch self.machine.status {
            case let .approval(url): NSWorkspace.shared.open(url)
            case .notRunning: self.machine.startServer()
            default: self.machine.connect()
            }
        }
    }

    // MARK: - Rendering

    // MARK: - Shortcut hints (hold ⌘) and the ⌘/ sheet

    private let hintTrigger = ShortcutHintTrigger()
    private let sheet = ShortcutSheetView()
    private(set) var showsHints = false

    private func setUpHints() {
        hintTrigger.onChange = { [weak self] showing in self?.setHints(showing) }
        sheet.onDismiss = { [weak self] in self?.setSheet(false) }
    }

    /// Badges on what the keys reach: ⌃N on tabs, ⌥⌘N on panes (⌘N is
    /// always on the spaces).
    private func setHints(_ showing: Bool) {
        showsHints = showing
        let order = tabID.flatMap { store.layouts[$0]?.root.paneIDs } ?? []
        for (id, view) in paneViews {
            let index = order.firstIndex(of: id)
            view.hintBadge = showing ? index.flatMap { $0 < 9 ? "\(Settings.paneKeys.symbols)\($0 + 1)" : nil } : nil
        }
        sidebar.update(sidebarModel())
    }

    @objc func toggleShortcutSheet(_: Any?) { setSheet(sheet.isHidden) }

    /// Debug hook: the hold-⌘ badges on ("on") or off.
    @objc func debugHints(_ sender: Any?) { setHints((sender as? String) != "off") }

    private func setSheet(_ visible: Bool) {
        guard let root = window?.contentView else { return }
        if visible {
            hintTrigger.hide()
            let size = sheet.reload()
            if sheet.superview !== root { root.addSubview(sheet) }
            let width = min(size.width, root.bounds.width - 40), height = min(size.height, root.bounds.height - 40)
            sheet.frame = NSRect(x: (root.bounds.width - width) / 2, y: (root.bounds.height - height) / 2, width: width, height: height)
            sheet.alphaValue = 0
            sheet.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; sheet.animator().alphaValue = 1 }
        } else {
            sheet.isHidden = true
        }
    }

    /// Esc (or ⌘/ again) closes the sheet without reaching the terminal.
    /// Paste with an image on the clipboard (a screenshot, an image copied
    /// in Finder) into a terminal: the image is saved and its path pasted,
    /// which Claude Code and friends attach as an image. A pane on another
    /// machine gets the file uploaded there first, so the path works where
    /// the agent runs. False when it isn't an image paste into a terminal.
    func pasteImage(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let terminal = (window?.firstResponder as? HerdrTerminalView) ?? focusedPaneID.flatMap({ paneViews[$0]?.terminal }),
              window?.firstResponder is HerdrTerminalView || pasteboard != .general,
              let image = ImagePaste.clipboardImage(pasteboard) else { return false }
        let runner = machine.runner
        Task { @MainActor [weak terminal] in
            // Saving (or uploading) happens off the main thread.
            let path = await Task.detached { ImagePaste.stage(image, runner: runner) }.value
            if let path { _ = terminal?.paste(text: SSHTunnel.shellQuote(path)) } else { NSSound.beep() }
        }
        return true
    }

    private func sheetConsumes(_ event: NSEvent) -> Bool {
        guard !sheet.isHidden, event.type == .keyDown else { return false }
        if event.keyCode == 53 { setSheet(false); return true }
        return false
    }

    /// The pane shortcut, caught before the focused view: ⌥-only keys
    /// never reach the menu from a terminal, they'd be typed.
    private func paneKeyConsumes(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == Settings.paneKeys.modifiers,
              let key = event.charactersIgnoringModifiers, let n = Int(key), (1...9).contains(n) else { return false }
        selectPaneByNumber(String(n))
        return true
    }

    /// Debug hook: "chars mods" (mods from o/c/m/s) as a key press through
    /// the window's normal event path, e.g. "2 o" for ⌥2.
    @objc func debugKey(_ sender: Any?) {
        let parts = (sender as? String)?.split(separator: " ").map(String.init) ?? []
        guard let chars = parts.first, let window else { return }
        var flags: NSEvent.ModifierFlags = []
        for ch in parts.count > 1 ? parts[1] : "" {
            switch ch { case "o": flags.insert(.option); case "c": flags.insert(.control); case "m": flags.insert(.command); case "s": flags.insert(.shift); default: break }
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0) else { return }
        window.sendEvent(event)
    }

    /// ⌥1…⌥9 (or ⌥⌘1…⌥⌘9): panes of this tab in layout order.
    @objc func selectPaneByNumber(_ sender: Any?) {
        guard let n = Self.number(sender), let tabID, let panes = store.layouts[tabID]?.root.paneIDs, n - 1 < panes.count else { return }
        let target = panes[n - 1]
        if let view = paneViews[target] {
            window?.makeFirstResponder(view.browser?.webView ?? view.content)
            paneGainedFocus(target)
        } else {
            lastFocusedPane = nil
            store.perform { try await $0.focusPane(target) }
        }
    }

    /// A pane move is in flight; see `drop(_:on:)`.
    private var rearranging = false

    /// The oldest herdr bigtty works with: terminal.mouse (clicks and
    /// hover for pane apps) and paste re-bracketing arrived in 0.9.2.
    static let minimumHerdr = [0, 9, 2]

    /// Why this window's machine can't be used, when its herdr (the server,
    /// or this Mac's herdr CLI that carries the terminal streams) is too old.
    private func herdrVersionProblem() -> (title: String, detail: String)? {
        guard case let .connected(server) = store.state else { return nil }
        let cli = LocalHerdr.version(of: store.client.endpoint.herdrBinary) ?? "unknown"
        let need = Self.minimumHerdr.map(String.init).joined(separator: ".")
        let serverOld = !Self.version(server, atLeast: Self.minimumHerdr)
        let cliOld = !Self.version(cli, atLeast: Self.minimumHerdr)
        guard serverOld || cliOld else { return nil }
        let update = "Update with  herdr update --handoff  (run it outside herdr); --handoff keeps running panes."
        if machine.isLocal {
            return ("bigtty needs herdr \(need) or newer",
                    "This Mac has herdr \(cliOld ? cli : server)\(cliOld && serverOld && cli != server ? " (server \(server))" : "").\n\(update)")
        }
        if serverOld {
            return ("herdr on \(machine.name) is too old",
                    "\(machine.name) runs herdr \(server); bigtty needs \(need) or newer. \(update) Run it on \(machine.name).")
        }
        return ("This Mac’s herdr is too old for \(machine.name)",
                "This Mac has herdr \(cli); it carries the terminal streams, so it needs \(need) or newer too. \(update)")
    }

    private func render() {
        if rearranging { return }
        if let problem = herdrVersionProblem() {
            // Nothing half-works: no panes until herdr is new enough.
            for view in paneViews.values {
                view.terminal?.detach()
                view.removeFromSuperview()
            }
            paneViews.removeAll()
            splitTree.show(nil, zoomedPane: nil)
            sidebar.update(sidebarModel())
            placeholder.state = .remote(title: problem.title, detail: problem.detail, action: "Check Again")
            return
        }
        if case .connected = store.state { HostPaneStore.restoreTags(store: store, remote: !machine.isLocal) }
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
        // So must a terminal whose pane got a new terminal (herdr restarted
        // and restored the layout) or whose connection ended while herdr is up.
        var connected = false
        if case .connected = store.state { connected = true }
        let retagged = paneViews.filter { id, view in
            guard let pane = store.pane(id) else { return false }
            if pane.hostKind != view.hostKind { return true }
            guard let terminal = view.terminal else { return false }
            return terminal.terminalID != pane.terminalID || (terminal.hasDetached && connected)
        }
        for (id, view) in retagged {
            view.terminal?.detach()
            view.removeFromSuperview()
            paneViews.removeValue(forKey: id)
            if id == lastFocusedPane || id == herdrFocus { pendingFocus = id }
        }
        let zoomed = layout?.zoomed == true ? herdrFocus : nil
        noteShown(tab: tabID, zoomed: zoomed)
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
        window?.title = store.workspace(workspaceID).map {
            Self.spaceName($0, store: store, agentTitles: machine.spaceInfo?.agentTitles ?? [:])
        } ?? "bigtty"
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
        case .approval: return .remote(title: "Approve the login to \(name)",
                                       detail: "Tailscale SSH asks you to confirm this login in the browser. bigtty connects on its own once you do.",
                                       action: "Open Approval Page")
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
        if target.isLocal { manager.activeLocal = target }
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

    /// A tab's name: one it was given, else what its focused pane shows
    /// (Claude Code's conversation title, a shell's directory), else "tab N".
    private func tabLabel(_ tab: Tab) -> String {
        Self.tabTitle(tab, store: store, agentTitles: machine.spaceInfo?.agentTitles ?? [:])
    }

    /// A given label, else a title reported to herdr (agent integrations),
    /// else the agent conversation's name from its session (AgentTitles),
    /// else the title the terminal set, else the agent.
    static func tabTitle(_ tab: Tab, store: SessionStore, agentTitles: [String: String]) -> String {
        if tab.label != String(tab.number), !tab.label.isEmpty { return tab.label }
        let lead = leadPane(of: tab, store: store)
        if let title = paneTitle(lead, agentTitles: agentTitles) { return title }
        if let title = lead?.shownTitle { return title }
        if let agent = lead?.displayAgent ?? lead?.agent { return agent }
        return "tab \(tab.number)"
    }

    /// The pane a tab is named after: its terminal or agent; a browser or
    /// files pane beside it only names a tab that has nothing else.
    private static func leadPane(of tab: Tab, store: SessionStore) -> Pane? {
        let panes = store.panes(in: tab.tabID)
        let terminals = panes.filter { $0.hostKind == nil }
        return terminals.first { $0.focused } ?? terminals.first { $0.agent != nil } ?? terminals.first ?? panes.first
    }

    /// A name for the pane from what it says it's doing: a label, a title
    /// reported to herdr, the agent's conversation title.
    private static func paneTitle(_ pane: Pane?, agentTitles: [String: String]) -> String? {
        guard let pane else { return nil }
        if let label = pane.label, !label.isEmpty { return label }
        if let title = pane.title.map(Pane.cleanTitle), !title.isEmpty { return title }
        return agentTitles[pane.paneID]
    }

    /// A space is shown under its first tab's title (an agent's
    /// conversation, a title it reports, a terminal title that says what's
    /// going on), unless you named it yourself. herdr names a space after
    /// its folder, so a name that is a folder's counts as unnamed. herdr's
    /// own name is never changed.
    static func spaceName(_ workspace: Workspace, store: SessionStore, agentTitles: [String: String]) -> String {
        let panes = store.snapshot.panes.filter { $0.workspaceID == workspace.workspaceID }
        let folders = Set(panes.flatMap { [$0.cwd, $0.foregroundCwd] }.compactMap { $0 }.map { ($0 as NSString).lastPathComponent })
        guard workspace.label.isEmpty || folders.contains(workspace.label),
              let first = store.tabs(in: workspace.workspaceID).min(by: { $0.number < $1.number })
        else { return workspace.label }
        if first.label != String(first.number), !first.label.isEmpty { return first.label }
        let lead = leadPane(of: first, store: store)
        let candidates = [paneTitle(lead, agentTitles: agentTitles), lead?.shownTitle]
        let title = candidates.compactMap { $0 }.first { title in
            // Not a shell's own title ("me@host: ~/code/api", "~/api", "zsh")
            // or just the folder again.
            !(title.contains("@") && title.contains(":")) && !title.hasPrefix("~") && !title.hasPrefix("/")
                && !folders.contains(title) && !HostPaneStore.shells.contains(title)
                && title != lead?.agent && title != lead?.displayAgent
        }
        return title ?? (workspace.label.isEmpty ? "space \(workspace.number)" : workspace.label)
    }

    /// The sidebar: every machine with its spaces; the selected one lists its tabs.
    /// Debug hook: the full-screen look without entering full screen.
    @objc func debugFullScreenLook(_ sender: Any?) {
        setFullScreen((sender as? String) != "off")
    }

    /// Full screen: our own backdrop instead of the (empty) material, and
    /// the chrome without room for traffic lights.
    private func setFullScreen(_ value: Bool) {
        root.fullScreen = value
        sidebar.fullScreen = value
        topBar.fullScreen = value
    }

    /// The session on this Mac the sidebar lists: this window's, else the
    /// one last switched to.
    private var localSession: Machine { machine.isLocal ? machine : manager.activeLocal }

    /// Machines the sidebar shows: one session of this Mac, every remote.
    private var visibleMachines: [Machine] { [localSession] + manager.remotes }

    private func sidebarModel() -> SidebarModel {
        var model = SidebarModel()
        var number = 0
        for machine in visibleMachines {
            guard let store = machine.store, let attention = machine.attention, let spaceInfo = machine.spaceInfo,
                  case .connected = store.state
            else {
                let status = machine.isLocal
                    ? (machine.store?.state == .connecting ? "connecting…" : "not running")
                    : machine.statusText
                model.machines.append(.init(id: machine.id, name: machine.name, status: status, statusIsProblem: machine.statusIsProblem,
                                            session: sessionChip(machine), spaces: []))
                if machine.isLocal, case .disconnected = machine.store?.state { model.message = "No spaces yet." }
                continue
            }
            let spaces = store.snapshot.workspaces.map { workspace -> SidebarModel.Space in
                number += 1
                let ref = SpaceRef(machine: machine.id, workspace: workspace.workspaceID)
                let info = spaceInfo.info[workspace.workspaceID] ?? .init()
                let dir = info.directory.map { machine.displayPath($0) } ?? ""
                let meta = [info.branch, dir.isEmpty ? nil : dir].compactMap { $0 }.joined(separator: " · ")
                let selected = machine === self.machine && workspace.workspaceID == workspaceID
                let titles = spaceInfo.agentTitles
                let allTabs = store.tabs(in: workspace.workspaceID)
                // The selected space lists every tab; others their first two
                // and "+N more", so a glance shows what's in each space.
                let listed = selected ? Array(allTabs) : Array(allTabs.prefix(2))
                var tabs = allTabs.count > 1 ? listed.enumerated().map { index, tab -> SidebarModel.Tab in
                    let panes = store.panes(in: tab.tabID).count
                    let alert = attention.count(inTab: tab.tabID) > 0
                    return .init(
                        id: tab.tabID, label: Self.tabTitle(tab, store: store, agentTitles: titles),
                        detail: alert ? "needs you" : (panes > 1 ? "\(panes) panes" : ""),
                        selected: selected && tab.tabID == tabID, alert: alert,
                        audible: store.panes(in: tab.tabID).contains(where: Self.isAudible),
                        hint: selected && showsHints && index < 9 ? "⌃\(index + 1)" : nil,
                        working: store.panes(in: tab.tabID).contains { $0.agentStatus == .working }
                    )
                } : []
                if !selected, allTabs.count > 2 {
                    tabs.append(.init(id: "", label: "+\(allTabs.count - 2) more", detail: "", selected: false, alert: false))
                }
                let finished = store.snapshot.panes.contains {
                    $0.workspaceID == workspace.workspaceID && attention.reason(for: $0.paneID) == .done
                }
                return .init(
                    id: ref.key, name: Self.spaceName(workspace, store: store, agentTitles: spaceInfo.agentTitles),
                    shortcut: number <= 9 ? "⌘\(number)" : "",
                    meta: meta, ports: info.ports, line: info.line,
                    alert: info.lineIsAlert && !selected || (info.lineIsAlert && selected && tabs.count <= 1),
                    finished: finished, selected: selected, tabs: tabs,
                    hinting: showsHints,
                    audible: store.snapshot.panes.contains { $0.workspaceID == workspace.workspaceID && Self.isAudible($0) },
                    working: store.snapshot.panes.contains { $0.workspaceID == workspace.workspaceID && $0.agentStatus == .working },
                    // Quiet for over 12 hours, nothing running or waiting.
                    stale: !info.busy && !info.lineIsAlert && !finished
                        && (info.lastActive.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? false)
                )
            }
            model.machines.append(.init(id: machine.id, name: machine.name, status: machine.statusText, statusIsProblem: machine.statusIsProblem,
                                        statusTip: machine.statusTip, session: sessionChip(machine), spaces: spaces))
        }
        return model
    }

    /// A browser pane playing sound.
    private static func isAudible(_ pane: Pane) -> Bool {
        pane.hostKind == .browser && pane.hostID.flatMap { HostPaneStore.shared[$0]?.audible } == true
    }

    /// The session switcher on this Mac's header: its name, and how many
    /// panes in the other sessions need you.
    private func sessionChip(_ machine: Machine) -> SidebarModel.SessionChip? {
        guard machine.isLocal else { return nil }
        let others = manager.localMachines.filter { $0 !== machine }
            .reduce(0) { $0 + ($1.attention?.attention.needingAttention.count ?? 0) }
        return .init(name: machine.sessionName, othersNeedingYou: others)
    }

    // MARK: - Sessions

    /// The switcher: every session on this Mac, then new/stop/delete.
    func sessionMenu() -> NSMenu {
        manager.refreshSessions()
        let menu = NSMenu()
        let header = NSMenuItem(title: "Sessions on This Mac", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let current = localSession
        var known = manager.knownSessions
        if known.isEmpty { known = [.init(name: manager.local.session, running: true)] }
        for info in known {
            let machine = manager.localMachines.first { $0.session == info.name }
            let item = ClosureMenuItem(title: info.title, keyEquivalent: "") { [weak self] in
                guard let self else { return }
                let target = info.running ? (machine ?? info.name.map { self.manager.open(session: $0) } ?? self.manager.local) : self.manager.startSession(info.name)
                self.onShowSession?(info.name == self.manager.local.session && info.running ? self.manager.local : target)
            }
            item.state = machine === current ? .on : .off
            let waiting = machine?.attention?.attention.needingAttention.count ?? 0
            if !info.running {
                item.badge = NSMenuItemBadge(string: "stopped")
                item.toolTip = "Starts the session"
            } else if waiting > 0 {
                item.badge = NSMenuItemBadge(count: waiting)
                item.toolTip = "\(waiting) pane\(waiting == 1 ? "" : "s") need\(waiting == 1 ? "s" : "") you"
            } else if let count = machine?.store?.snapshot.workspaces.count {
                item.badge = NSMenuItemBadge(string: "\(count) space\(count == 1 ? "" : "s")")
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let new = ClosureMenuItem(title: "New Session…", keyEquivalent: "n") { [weak self] in self?.newSession(nil) }
        new.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(new)
        if case .connected = current.store?.state {
            menu.addItem(ClosureMenuItem(title: "Stop “\(current.sessionName)”…", keyEquivalent: "") { [weak self] in
                self?.confirmStopSession(current)
            })
        }
        let stopped = known.compactMap { $0.running ? nil : $0.name }
        if !stopped.isEmpty {
            let delete = NSMenuItem(title: "Delete Stopped Session", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for name in stopped {
                sub.addItem(ClosureMenuItem(title: name, keyEquivalent: "") { [weak self] in self?.confirmDeleteSession(name) })
            }
            delete.submenu = sub
            menu.addItem(delete)
        }
        return menu
    }

    /// Debug hook: logs the session switcher's items.
    @objc func debugLogSessionMenu(_: Any?) {
        func describe(_ menu: NSMenu, _ indent: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                let badge = item.badge.map { " [\($0.stringValue)]" } ?? ""
                let line = indent + (item.isSeparatorItem ? "---" : "\(item.state == .on ? "✓ " : "")\(item.title)\(badge)\(item.isEnabled ? "" : " (disabled)")")
                return [line] + (item.submenu.map { describe($0, indent + "  ") } ?? [])
            }
        }
        NSLog("bigtty: session menu:\n%@", describe(sessionMenu(), "").joined(separator: "\n"))
    }

    /// ⇧⌘S: the switcher, under this Mac's header (or the window's corner).
    @objc func showSessionSwitcher(_: Any?) {
        if sidebarVisible, sidebar.popUpSessionMenu() { return }
        guard let view = window?.contentView else { return }
        sessionMenu().popUp(positioning: nil, at: NSPoint(x: 80, y: view.bounds.maxY - 40), in: view)
    }

    /// ⌃⌘N: a new herdr session on this Mac, started and switched to.
    @objc func newSession(_: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "New Session"
        alert.informativeText = "A separate herdr session with its own spaces, like a separate workspace for another project or client. Letters, digits, - and _."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let existing = self.manager.knownSessions.first(where: { $0.name == name }), existing.running {
                self.onShowSession?(self.manager.open(session: name))
                return
            }
            guard MachineManager.isValidSessionName(name) else {
                NSSound.beep()
                return
            }
            self.onShowSession?(self.manager.startSession(name))
        }
    }

    private func confirmStopSession(_ session: Machine) {
        guard let window else { return }
        let alert = NSAlert()
        let spaces = session.store?.snapshot.workspaces.count ?? 0
        alert.messageText = "Stop the “\(session.sessionName)” session?"
        alert.informativeText = "Its \(spaces) space\(spaces == 1 ? "" : "s") close and every process running in them ends, agents included. herdr keeps the session to start again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Session").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.manager.stopSession(session.session)
            // Move to another running session, if there is one.
            if let other = self.manager.localMachines.first(where: { machine in
                guard machine !== session, case .connected = machine.store?.state else { return false }
                return true
            }) {
                self.onShowSession?(other)
            }
        }
    }

    private func confirmDeleteSession(_ name: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the “\(name)” session?"
        alert.informativeText = "Its saved layout and settings are removed. It isn’t running, so no process is affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.manager.deleteSession(name)
        }
    }

    /// Spaces in sidebar order, for ⌘1…⌘9.
    private var orderedSpaces: [SpaceRef] {
        visibleMachines.flatMap { machine -> [SpaceRef] in
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

    /// Puts a space at `index` of this machine's list (herdr's order).
    func moveSpace(_ id: String, to index: Int) {
        store.perform { try await $0.moveWorkspace(id, to: index) }
    }

    private func spaceMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            menu.addItem(item)
        }
        add("Rename Space…") { [weak self] in self?.promptRename(workspaceID: id) }
        add("New Tab") { [weak self] in self?.store.perform { try await $0.createTab(workspaceID: id) } }
        add("New Browser Tab") { [weak self] in
            guard let self else { return }
            if self.workspaceID != id { self.selectWorkspace(id) }
            self.newBrowserTab(nil)
        }
        menu.addItem(.separator())
        add("Show Changes") { [weak self] in
            guard let self else { return }
            if self.workspaceID != id { self.selectWorkspace(id) }
            self.showChanges(nil)
        }
        if let dir = spaceInfo.info[id]?.directory {
            add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)]) }
        }
        // Order decides ⌘1–9; herdr keeps it for every client.
        let order = store.snapshot.workspaces.map(\.workspaceID)
        if let index = order.firstIndex(of: id) {
            menu.addItem(.separator())
            if index > 0 {
                add("Move to Top") { [weak self] in self?.moveSpace(id, to: 0) }
                add("Move Up") { [weak self] in self?.moveSpace(id, to: index - 1) }
            }
            if index < order.count - 1 { add("Move Down") { [weak self] in self?.moveSpace(id, to: index + 1) } }
        }
        menu.addItem(.separator())
        add("Close Space…") { [weak self] in self?.confirmCloseSpace(id) }
        return menu
    }

    // MARK: - Panes

    private func paneView(for id: String) -> NSView? {
        guard let pane = store.pane(id) else { return paneViews[id] }
        if let view = paneViews[id] {
            // A terminal view is only reused for the same, live terminal: a
            // herdr restart (or another client) can put a new terminal
            // behind the same pane id.
            var connected = false
            if case .connected = store.state { connected = true }
            let staleTerminal = view.terminal.map { $0.terminalID != pane.terminalID || ($0.hasDetached && connected) } ?? false
            if view.hostKind == pane.hostKind, !staleTerminal { return view }
            // The pane was tagged (or untagged) as a host pane, or its
            // terminal changed: rebuild.
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
        wireDrag(view)
        view.apply(theme)
        view.update(pane: pane, attention: attention.reason(for: id))
        paneViews[id] = view
        return view
    }

    /// herdr forwards clicks itself from 0.9.2 (terminal.mouse); before
    /// that, only Claude Code panes get them, as typed-in mouse reports.
    /// `herdr --version` of the binaries this app runs, asked once each.
    enum LocalHerdr {
        nonisolated(unsafe) private static var cache: [String: String] = [:]
        private static let lock = NSLock()

        static func forget() { lock.withLock { cache.removeAll() } }

        static func version(of binary: String) -> String? {
            if let known = lock.withLock({ cache[binary] }) { return known }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary.hasPrefix("/") ? binary : "/usr/bin/env")
            process.arguments = binary.hasPrefix("/") ? ["--version"] : [binary, "--version"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let version = text.replacingOccurrences(of: "herdr", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            lock.withLock { cache[binary] = version }
            return version
        }
    }

    static func version(_ text: String, atLeast minimum: [Int]) -> Bool {
        let parts = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for (index, want) in minimum.enumerated() {
            let have = index < parts.count ? parts[index] : 0
            if have != want { return have > want }
        }
        return true
    }

    /// Panes drag by their top-edge band. Over a pane: an edge splits
    /// beside it, the middle swaps. Along the outer edge of the whole area:
    /// the pane spans it (full width or height). Only within this window's
    /// machine and tab.
    private func wireDrag(_ view: PaneContainerView) {
        let id = view.paneID
        view.dragPayload = { [weak self] in
            guard let self, self.store.panes(in: self.tabID ?? "").count > 1 else { return nil }
            return PaneDragPayload(machineID: self.machine.id, paneID: id)
        }
        view.dragTitle = { [weak self] in self?.store.pane(id)?.displayName ?? "Pane" }
    }

    /// The outer strip (from the area's edge inward) that means "span the
    /// whole area"; everything inside it targets the nearest pane.
    private static let edgeBand: CGFloat = 14

    /// The drop under a window point, and the area it would take (in the
    /// main area's coordinates).
    private func dropTarget(_ payload: PaneDragPayload, at point: NSPoint) -> (PaneDropTarget, NSRect)? {
        guard payload.machineID == machine.id, let tabID, let root = store.layouts[tabID]?.root,
              root.paneIDs.contains(payload.paneID), let main = mainArea else { return nil }
        let tree = splitTree.convert(splitTree.bounds, to: main)
        let p = main.convert(point, from: nil)
        guard main.bounds.contains(p) else { return nil }
        // Close to (or beyond) the area's edge: span it.
        let edges: [(HerdrClient.DropZone, CGFloat)] = [
            (.left, p.x - tree.minX), (.right, tree.maxX - p.x), (.bottom, p.y - tree.minY), (.top, tree.maxY - p.y),
        ]
        if root.paneIDs.count > 1, let (zone, distance) = edges.min(by: { $0.1 < $1.1 }), distance < Self.edgeBand {
            let span: NSRect = switch zone {
            case .left: NSRect(x: tree.minX, y: tree.minY, width: tree.width / 3, height: tree.height)
            case .right: NSRect(x: tree.maxX - tree.width / 3, y: tree.minY, width: tree.width / 3, height: tree.height)
            case .top: NSRect(x: tree.minX, y: tree.maxY - tree.height / 3, width: tree.width, height: tree.height / 3)
            case .bottom, .center: NSRect(x: tree.minX, y: tree.minY, width: tree.width, height: tree.height / 3)
            }
            return (.tabEdge(zone), span)
        }
        // Otherwise the pane under the point, or the nearest one across a gap.
        let candidates = paneViews.filter { $0.value.window != nil && $0.key != payload.paneID }
            .map { (id: $0.key, view: $0.value, frame: $0.value.convert($0.value.bounds, to: main)) }
        func distance(_ r: NSRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return hypot(dx, dy)
        }
        guard let nearest = candidates.min(by: { distance($0.frame) < distance($1.frame) }),
              distance(nearest.frame) < 24 else { return nil }
        let clamped = NSPoint(x: min(max(p.x, nearest.frame.minX), nearest.frame.maxX),
                              y: min(max(p.y, nearest.frame.minY), nearest.frame.maxY))
        let local = nearest.view.convert(clamped, from: main)
        let zone = HerdrClient.DropZone.at(local, in: nearest.view.bounds)
        let rect = nearest.view.convert(zone.highlight(in: nearest.view.bounds), to: main)
        return (.pane(nearest.id, zone), rect)
    }

    private func hoverDrop(_ payload: PaneDragPayload, at point: NSPoint) -> Bool {
        guard let (_, rect) = dropTarget(payload, at: point) else {
            mainArea?.dropHint.hide()
            return false
        }
        mainArea?.dropHint.show(rect)
        return true
    }

    private func commitDrop(_ payload: PaneDragPayload, at point: NSPoint) -> Bool {
        mainArea?.dropHint.hide()
        guard let (target, _) = dropTarget(payload, at: point) else { return false }
        drop(payload.paneID, on: target)
        return true
    }

    /// Rearranges this tab: swaps directly, otherwise rebuilds the layout
    /// into the dropped arrangement (herdr keeps every pane and process).
    private func drop(_ source: String, on target: PaneDropTarget) {
        guard let tabID, let root = store.layouts[tabID]?.root, let workspaceID = store.pane(source)?.workspaceID else { return }
        pendingFocus = source
        if case let .pane(other, .center) = target {
            splitTree.show(root.dropping(source, on: target), zoomedPane: nil)
            store.perform { try await $0.swapPanes(source, other) }
            return
        }
        let desired = root.dropping(source, on: target)
        guard !desired.sameArrangement(as: root) else { return }
        // Panes pass through a temporary tab on the way; hold this window
        // still until the move is done, so their terminals aren't torn
        // down and rebuilt for every intermediate step.
        rearranging = true
        // Show the new arrangement now; herdr catches up underneath.
        splitTree.show(desired, zoomedPane: nil)
        let client = store.client
        Task { [weak self] in
            do {
                if case let .pane(other, zone) = target {
                    try await client.movePane(source, beside: other, zone: zone, tabID: tabID, workspaceID: workspaceID)
                } else {
                    try await client.applyLayout(desired, current: root, tabID: tabID, workspaceID: workspaceID)
                }
                try? await client.focusPane(source)
            } catch {
                NSLog("bigtty: moving pane failed: \(error)")
            }
            guard let self else { return }
            self.rearranging = false
            self.store.scheduleRefresh()
            self.render()
        }
    }

    /// Debug hook: "source x y" (window points from the top-left): logs the
    /// drop target there.
    @objc func debugDropTargetAt(_ sender: Any?) {
        let parts = (sender as? String)?.split(separator: " ").map(String.init) ?? []
        guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]), let height = window?.contentView?.bounds.height else { return }
        let point = NSPoint(x: x, y: height - y)
        let target = dropTarget(PaneDragPayload(machineID: machine.id, paneID: parts[0]), at: point)
        NSLog("btty-droptarget \(parts[1]),\(parts[2]) -> \(target.map { "\($0.0)" } ?? "none")")
    }

    /// Debug hook: "source target zone" (target "tab" for the outer edge).
    @objc func debugDropPane(_ sender: Any?) {
        let parts = (sender as? String)?.split(separator: " ").map(String.init) ?? []
        guard parts.count == 3, let zone = HerdrClient.DropZone(rawValue: parts[2]) else { return }
        drop(parts[0], on: parts[1] == "tab" ? .tabEdge(zone) : .pane(parts[1], zone))
    }

    private func makeBrowser(pane: Pane, hostID: String) -> BrowserPaneView {
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .browser, tokens: pane.tokens)
        state.paneID = pane.paneID
        HostPaneStore.shared[hostID] = state
        // The registry owns the web view so agents can drive it while no
        // window shows it; this window borrows it.
        if state.machine == nil, let tag = machine.hostTag {
            state.machine = tag
            HostPaneStore.shared[hostID] = state
        }
        let browser = BrowserRegistry.shared.view(for: hostID, machine: machine)
        let id = pane.paneID
        browser.onFocus = { [weak self] in
            BrowserRegistry.shared.noteFocus(hostID)
            self?.paneGainedFocus(id)
        }
        browser.onStateChange = { [weak self] state in self?.hostTitleChanged(paneID: id, hostID: hostID, state: state) }
        // Tag panes made before addresses were shared with herdr, too.
        if state.url != nil, pane.tokens?["btty_url"] != state.url { hostTitleChanged(paneID: id, hostID: hostID, state: state) }
        browser.onClose = { [weak self] in self?.store.perform { try await $0.closePane(id) } }
        return browser
    }

    private func makeFiles(pane: Pane, hostID: String) -> FilesPaneView {
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: pane.hostKind ?? .files, tokens: pane.tokens)
        if state.path == nil { state.path = pane.cwd }
        state.paneID = pane.paneID
        if state.machine == nil, let tag = machine.hostTag { state.machine = tag }
        HostPaneStore.shared[hostID] = state
        let files = FilesRegistry.shared.view(for: hostID, machine: machine)
        let id = pane.paneID
        files.onFocus = { [weak self] in self?.paneGainedFocus(id) }
        files.onStateChange = { [weak self] state in self?.hostTitleChanged(paneID: id, hostID: hostID, state: state) }
        if state.path != nil, pane.tokens?["btty_path"] != state.path { hostTitleChanged(paneID: id, hostID: hostID, state: state) }
        files.onInsertPath = { [weak self] path in self?.insertPath(path, near: id) }
        files.onClose = { [weak self] in self?.store.perform { try await $0.closePane(id) } }
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

    /// ⇧⌘E and the title-strip button: the tab's file viewer closes if it
    /// has one, else one opens beside the focused pane in its folder.
    @objc func toggleFileViewer(_: Any?) {
        if let tabID, let files = store.panes(in: tabID).first(where: { $0.hostKind == .files }) {
            let id = files.paneID
            store.perform { try await $0.closePane(id) }
        } else {
            openFilesPane(mode: .files)
        }
    }
    @objc func showChanges(_: Any?) { openFilesPane(mode: .changes) }

    private func openFilesPane(mode: FilesPaneView.Mode) {
        guard let target = focusedPaneID else { return }
        let pane = store.pane(target)
        let home = machine.isLocal ? NSHomeDirectory() : "/"
        // The pane finds the repository root itself for Changes.
        let cwd = pane?.foregroundCwd ?? pane?.cwd ?? home
        HostPaneStore.open(
            HostPaneState(kind: mode == .changes ? .diff : .files, path: cwd, mode: mode.rawValue,
                          machine: machine.hostTag),
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
                    paneID: paneID, title: title, tokens: state.tokens(id: hostID)
                )
            }
        }
        titleUpdates[paneID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// A link clicked in a terminal opens in the tab's browser pane, or in a
    /// new one split off to the right of that terminal.
    func openURL(_ url: String, from paneID: String) {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            return openLink(url, from: paneID)
        }
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
        HostPaneStore.open(HostPaneState(kind: .browser, url: url, machine: machine.hostTag), beside: paneID, direction: .right, store: store, remote: !machine.isLocal)
    }

    /// A clicked path or non-web link. Paths, `path:line[:col]` and file://
    /// links open in the tab's files pane, resolved against the pane's
    /// directory on its machine; other schemes (mailto:) go to macOS.
    private func openLink(_ raw: String, from paneID: String) {
        guard let target = ClickedPath(raw) else {
            if let link = URL(string: raw), link.scheme != nil { NSWorkspace.shared.open(link) }
            return
        }
        let pane = store.pane(paneID)
        let machine = machine
        let source = machine.isLocal ? FileSource.local : FileSource(runner: machine.runner)
        let cwd = pane?.foregroundCwd ?? pane?.cwd ?? machine.homeDirectory ?? "/"
        let path = target.resolved(cwd: cwd, home: machine.homeDirectory)
        let line = target.line
        let relative = !target.path.hasPrefix("/") && !target.path.hasPrefix("~")
        Task.detached {
            let exists = source.exists(path)
            let isDirectory = exists && source.isDirectory(path)
            let repo = GitClient.repository(containing: exists ? path : cwd, runner: source.runner)
            // A bare name ("workspace.png" in an agent's table): find it in
            // the project.
            let matches = !exists && relative ? (repo?.files(named: target.path) ?? []) : []
            await MainActor.run {
                if exists {
                    let folder = isDirectory ? path : (path as NSString).deletingLastPathComponent
                    self.showInFiles(path: isDirectory ? nil : path, root: repo?.root ?? folder, line: line, beside: paneID)
                } else if matches.count == 1, let match = matches.first {
                    self.showInFiles(path: match, root: repo?.root ?? (match as NSString).deletingLastPathComponent, line: line, beside: paneID)
                } else if matches.count > 1, let repo {
                    self.chooseFile(matches, root: repo.root, line: line, beside: paneID)
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    /// Several project files share the clicked name: a menu at the pointer.
    private func chooseFile(_ paths: [String], root: String, line: Int?, beside paneID: String) {
        let menu = NSMenu()
        for path in paths.sorted(by: { $0.count < $1.count }).prefix(12) {
            let shown = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
            menu.addItem(ClosureMenuItem(title: shown, keyEquivalent: "") { [weak self] in
                self?.showInFiles(path: path, root: root, line: line, beside: paneID)
            })
        }
        guard let view = window?.contentView else { return }
        let point = view.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Selects `path` in the tab's files pane when it covers `root`, else
    /// opens one beside `paneID`.
    private func showInFiles(path: String?, root: String, line: Int?, beside paneID: String) {
        guard let tabID = store.pane(paneID)?.tabID else { return }
        for existing in store.panes(in: tabID) where existing.hostKind == .files || existing.hostKind == .diff {
            guard let hostID = existing.hostID, let view = FilesRegistry.shared.existing(hostID) else { continue }
            let target = path ?? root
            if target.hasPrefix(view.root == "/" ? "/" : view.root + "/") || target == view.root {
                view.setMode(.files)
                if let path { view.select(path: path, line: line) }
                pendingFocus = existing.paneID
                return
            }
        }
        HostPaneStore.open(
            HostPaneState(kind: .files, path: root, selection: path, mode: FilesPaneView.Mode.files.rawValue, line: line,
                          machine: machine.hostTag),
            beside: paneID, direction: .right, store: store, remote: !machine.isLocal
        )
    }

    /// Debug hook: scrolls the focused terminal by N lines (negative: down).
    @objc func debugScroll(_ sender: Any?) {
        guard let lines = (sender as? String).flatMap(Int32.init), let id = focusedPaneID else { return }
        paneViews[id]?.terminal?.debugScroll(lines: lines)
    }

    /// Debug hook: behaves like ⌘-clicking a link in the focused terminal.
    /// Debug hook: pastes the image file at a path as if it were on the
    /// clipboard, through a private pasteboard.
    @objc func debugPasteImage(_ sender: Any?) {
        guard let path = sender as? String, let image = NSImage(contentsOfFile: path) else { return }
        let board = NSPasteboard(name: .init("dev.bigtty.debug-paste"))
        board.clearContents()
        board.writeObjects([image])
        NSLog("bigtty: debugPasteImage handled=\(pasteImage(from: board))")
    }

    /// Debug hook: `[pane-id] word` ⌘-clicks the word in that terminal.
    @objc func debugCommandClick(_ sender: Any?) {
        guard let arg = sender as? String else { return }
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let (id, word) = parts.count == 2 && paneViews[parts[0]] != nil ? (parts[0], parts[1]) : (focusedPaneID, arg)
        if let id { paneViews[id]?.terminal?.debugCommandClick(word) }
    }

    @objc func debugOpenURL(_ sender: Any?) {
        if let url = sender as? String, let pane = focusedPaneID { openURL(url, from: pane) }
    }

    /// Debug hook: selects a path in the focused files pane; `changes`
    /// or `files` switches its mode instead.
    @objc func debugFilesSelect(_ sender: Any?) {
        guard let arg = sender as? String, let id = focusedPaneID, let files = paneViews[id]?.files else { return }
        if let mode = FilesPaneView.Mode(rawValue: arg) { files.setMode(mode) } else { files.select(path: arg) }
    }

    /// A new tab in this space that opens as a browser.
    @objc func newBrowserTab(_: Any?) {
        guard let workspaceID else { return }
        pendingAddressFocus = true
        tabID = nil // follow herdr to the new (focused) tab, as ⌘T does
        HostPaneStore.openTab(HostPaneState(kind: .browser, machine: machine.hostTag),
                              in: workspaceID, store: store, remote: !machine.isLocal)
    }

    /// Turns the focused pane (e.g. one just split off) into a browser.
    @objc func openBrowserHere(_: Any?) {
        convertFocusedPane(to: HostPaneState(kind: .browser, machine: machine.hostTag), focusAddress: true)
    }

    /// Turns the focused pane into a files pane for its folder.
    @objc func openFilesHere(_: Any?) {
        guard let pane = focusedPaneID.flatMap({ store.pane($0) }) else { return }
        let cwd = pane.foregroundCwd ?? pane.cwd ?? machine.homeDirectory ?? "/"
        convertFocusedPane(to: HostPaneState(kind: .files, path: cwd, mode: FilesPaneView.Mode.files.rawValue,
                                             machine: machine.hostTag), focusAddress: false)
    }

    /// Only a pane idle at its shell prompt is replaced; a running program
    /// or agent is never killed for it.
    private func convertFocusedPane(to state: HostPaneState, focusAddress: Bool) {
        guard let paneID = focusedPaneID, let pane = store.pane(paneID) else { return }
        guard pane.hostKind == nil else { NSSound.beep(); return }
        let client = store.client
        let remote = !machine.isLocal
        Task { [weak self] in
            let processes = (try? await client.foregroundProcesses(of: paneID)) ?? []
            guard let self else { return }
            let idle = pane.agent == nil && !processes.isEmpty && processes.allSatisfy { HostPaneStore.shells.contains($0) }
            guard idle else {
                let alert = NSAlert()
                alert.messageText = "This pane is busy"
                alert.informativeText = "\(processes.first ?? "A program") is running in it. Open the \(state.kind == .browser ? "browser" : "files") in a split instead?"
                alert.addButton(withTitle: "Split Right")
                alert.addButton(withTitle: "Cancel")
                let open = { HostPaneStore.open(state, beside: paneID, direction: .right, store: self.store, remote: remote) }
                if let window = self.window {
                    alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { _ = open() } }
                } else if alert.runModal() == .alertFirstButtonReturn { _ = open() }
                return
            }
            if focusAddress { self.pendingAddressFocus = true }
            self.pendingFocus = paneID
            HostPaneStore.convert(paneID, to: state, store: self.store, remote: remote)
        }
    }

    /// A browser pane showing `url`, beside the focused pane.
    func openBrowserPane(url: String) {
        guard let target = focusedPaneID else { return }
        HostPaneStore.open(HostPaneState(kind: .browser, url: url, machine: machine.hostTag), beside: target, direction: .right, store: store, remote: !machine.isLocal)
    }

    @objc func newBrowserPane(_: Any?) {
        guard let target = focusedPaneID else { return }
        pendingAddressFocus = true
        HostPaneStore.open(HostPaneState(kind: .browser, machine: machine.hostTag), beside: target, direction: .right, store: store, remote: !machine.isLocal)
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

    /// Everything the user is looking at: the focused pane at once, and the
    /// rest of the tab once it has been on screen a moment, since a ring you
    /// can see is a ring you've seen.
    var viewedPanes: Set<String> {
        guard let focused = viewedPane else { return [] }
        guard zoomedPane == nil, let since = shownSince, Date().timeIntervalSince(since) >= Self.seenAfter else { return [focused] }
        return Set(paneViews.keys)
    }

    private static let seenAfter: TimeInterval = 2
    private var shownSince: Date?
    private var shownKey: String?
    private var zoomedPane: String?

    /// Starts the "seen" clock when the tab (or zoom) on screen changes.
    private func noteShown(tab: String?, zoomed: String?) {
        zoomedPane = zoomed
        let key = (tab ?? "") + "|" + (zoomed ?? "")
        guard key != shownKey else { return }
        shownKey = key
        restartSeenClock()
    }

    private func restartSeenClock() {
        let started = Date()
        shownSince = started
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seenAfter + 0.1) { [weak self] in
            guard let self, self.shownSince == started else { return }
            self.attention.viewChanged()
        }
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
        noteVisited(SpaceRef(machine: machine.id, workspace: id))
        render()
    }

    // MARK: - Recent spaces (⌃⌘Tab)

    /// Spaces by when you were last in them, newest first, across windows.
    private static var recentSpaces: [SpaceRef] = []
    /// While ⌃⌘ is held after ⌃⌘Tab: the list being stepped through.
    private static var cycle: (list: [SpaceRef], index: Int)?

    private func noteVisited(_ ref: SpaceRef) {
        guard Self.cycle == nil else { return }
        Self.recentSpaces.removeAll { $0 == ref }
        Self.recentSpaces.insert(ref, at: 0)
        if Self.recentSpaces.count > 30 { Self.recentSpaces.removeLast() }
    }

    /// ⌃⌘Tab: back to the space you were in before; keep ⌃⌘ held and press
    /// Tab again for older ones (⇧ goes the other way), like ⌘Tab for apps.
    @objc func recentSpace(_: Any?) { stepRecent(by: 1) }
    @objc func recentSpaceBack(_: Any?) { stepRecent(by: -1) }

    private func stepRecent(by step: Int) {
        if Self.cycle == nil {
            // Only spaces that still exist, the current one first.
            let live = Set(manager.all.flatMap { machine -> [SpaceRef] in
                (machine.store?.snapshot.workspaces ?? []).map { SpaceRef(machine: machine.id, workspace: $0.workspaceID) }
            })
            var list = Self.recentSpaces.filter(live.contains)
            if let workspaceID {
                let here = SpaceRef(machine: machine.id, workspace: workspaceID)
                list.removeAll { $0 == here }
                list.insert(here, at: 0)
            }
            guard list.count > 1 else { return NSSound.beep() }
            Self.cycle = (list, 0)
        }
        guard var cycle = Self.cycle else { return }
        cycle.index = (cycle.index + step + cycle.list.count) % cycle.list.count
        Self.cycle = cycle
        sidebar.onSelectSpace?(cycle.list[cycle.index].key)
        // A tap with the modifiers already up (a menu click) ends right away.
        let held = NSEvent.modifierFlags.intersection([.command, .control]) == [.command, .control]
        if !held { endRecentCycle() }
    }

    /// ⌃ or ⌘ let go: the space landed on becomes the most recent.
    func endRecentCycle() {
        guard let cycle = Self.cycle else { return }
        Self.cycle = nil
        noteVisited(cycle.list[cycle.index])
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

    @objc func nextPane(_: Any?) { cyclePane(by: 1) }
    @objc func previousPane(_: Any?) { cyclePane(by: -1) }

    /// ⌘] / ⌘[: the next or previous pane in layout order, wrapping.
    private func cyclePane(by offset: Int) {
        guard let tabID, let panes = store.layouts[tabID]?.root.paneIDs, panes.count > 1 else { return }
        let current = panes.firstIndex(of: focusedPaneID ?? "") ?? 0
        let next = panes[(current + offset + panes.count) % panes.count]
        if let view = paneViews[next] {
            pendingFocus = next
            window?.makeFirstResponder(view.browser?.webView ?? view.content)
            paneGainedFocus(next)
        } else {
            lastFocusedPane = nil
            store.perform { try await $0.focusPane(next) }
        }
    }

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

    /// ⌘1…⌘9: spaces in sidebar order. Which spaces sit in the first nine
    /// is up to you: drag them, or Move to Top.
    @objc func selectSpaceByNumber(_ sender: Any?) {
        guard let n = Self.number(sender), (1...9).contains(n) else { return }
        let spaces = orderedSpaces
        guard spaces.indices.contains(n - 1) else { return NSSound.beep() }
        sidebar.onSelectSpace?(spaces[n - 1].key)
    }

    /// ⌃1…⌃8: tabs of this space; ⌃9 is the last tab, as in browsers.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let n = Self.number(sender), let workspaceID else { return }
        let tabs = store.tabs(in: workspaceID)
        guard !tabs.isEmpty else { return }
        if n == 9 { return selectTab(tabs[tabs.count - 1].tabID) }
        guard n - 1 < tabs.count else { return NSSound.beep() }
        selectTab(tabs[n - 1].tabID)
    }

    @objc func nextSpace(_: Any?) { cycleSpace(by: 1) }
    @objc func previousSpace(_: Any?) { cycleSpace(by: -1) }

    private func cycleSpace(by offset: Int) {
        let spaces = orderedSpaces
        guard !spaces.isEmpty else { return }
        let current = spaces.firstIndex { $0.machine == machine.id && $0.workspace == workspaceID } ?? 0
        sidebar.onSelectSpace?(spaces[(current + offset + spaces.count) % spaces.count].key)
    }

    /// A menu item's tag, or a number passed by a debug hook.
    private static func number(_ sender: Any?) -> Int? {
        (sender as? NSMenuItem)?.tag ?? (sender as? String).flatMap(Int.init)
    }

    /// The folder new spaces start in: the focused pane's working directory.
    var currentDirectory: String? {
        let pane = store.pane(focusedPaneID)
        return pane?.foregroundCwd ?? pane?.cwd
    }

    @objc func toggleSidebar(_: Any?) {
        sidebarVisible.toggle()
    }

    /// ⌘N: a space in the focused pane's folder, named after it.
    @objc func newSpaceHere(_: Any?) {
        let pane = focusedPaneID.flatMap { store.pane($0) }
        let cwd = pane?.foregroundCwd ?? pane?.cwd ?? machine.homeDirectory ?? NSHomeDirectory()
        if pinnedWorkspaceID == nil { workspaceID = nil }
        store.perform { try await $0.createWorkspace(cwd: cwd, label: (cwd as NSString).lastPathComponent) }
    }

    @objc func renameSpace(_: Any?) {
        if let workspaceID { promptRename(workspaceID: workspaceID) }
    }

    @objc func closeSpace(_: Any?) {
        if let workspaceID { confirmCloseSpace(workspaceID) }
    }

    // MARK: - Text size (View ▸ Bigger / Smaller / Actual Size)

    /// The browser pane in focus zooms its page; anywhere else the
    /// terminal font changes (for every terminal, like Ghostty's config).
    @objc func makeTextBigger(_: Any?) { changeTextSize(by: 1) }
    @objc func makeTextSmaller(_: Any?) { changeTextSize(by: -1) }
    @objc func makeTextActualSize(_: Any?) { changeTextSize(by: 0) }

    private func changeTextSize(by step: Int) {
        if let id = focusedPaneID, let browser = paneViews[id]?.browser {
            browser.webView.pageZoom = step == 0 ? 1 : min(3, max(0.5, browser.webView.pageZoom + CGFloat(step) * 0.1))
            return
        }
        let base = 13.0
        let current = Settings.fontSize > 0 ? Settings.fontSize : base
        Settings.fontSize = step == 0 ? 0 : min(36, max(8, current + Double(step)))
        TerminalAppearance.apply(to: terminalController)
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

    func windowDidResignKey(_: Notification) { hintTrigger.hide() }

    func windowDidBecomeKey(_: Notification) {
        restartSeenClock()
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
    static let bigttySettingsChanged = Notification.Name("BigttySettingsChanged")
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

/// The title bar is hidden and our views fill its strip, so they'd swallow
/// the double-click that zooms or minimizes a window. Catch it here and do
/// what System Settings ▸ Desktop & Dock says.
final class MainWindow: NSWindow {
    /// Height of the strip that acts as the title bar.
    static let titleStrip: CGFloat = 40

    /// Sees every event first; true means it was used (shortcut sheet).
    var eventObserver: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if eventObserver?(event) == true { return }
        if event.type == .leftMouseDown, event.clickCount == 2, isTitleStrip(event) {
            titleBarDoubleClicked()
            return
        }
        super.sendEvent(event)
    }

    private func isTitleStrip(_ event: NSEvent) -> Bool {
        guard let content = contentView, event.locationInWindow.y >= content.bounds.height - Self.titleStrip else { return false }
        // The traffic lights handle their own clicks.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(kind), button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                return false
            }
        }
        // Panes, buttons and fields keep their own double-clicks; plain
        // labels (the space name) act like title text.
        var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current is PaneContainerView || current is NSTextView { return false }
            if let field = current as? NSTextField, !field.isEditable, !field.isSelectable {
                view = current.superview
                continue
            }
            if current is NSControl { return false }
            view = current.superview
        }
        return true
    }

    private func titleBarDoubleClicked() {
        let defaults = UserDefaults.standard
        let action = defaults.string(forKey: "AppleActionOnDoubleClick")
            ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize": performMiniaturize(nil)
        case "None": break
        default: performZoom(nil) // Maximize (zoom), and Fill on newer macOS
        }
    }
}

/// Sidebar on the left with a draggable edge; the main area on the right.
@MainActor
private final class RootView: NSView {
    private let sidebar: NSView
    private let main: MainArea
    private var sidebarWidth: CGFloat = Settings.sidebarWidth
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

    /// The material spans the window (gaps between panes too), or only
    /// the sidebar with an opaque content side.
    var translucentContent = true {
        didSet { needsLayout = true; needsDisplay = true }
    }

    /// Full screen has no desktop behind the window for the material to
    /// show, so it paints its own backdrop: the theme's window color, the
    /// sidebar a shade apart, a soft glow from the top.
    var fullScreen = false {
        didSet { needsLayout = true; needsDisplay = true }
    }

    override func draw(_: NSRect) {
        if fullScreen {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            background.setFill()
            bounds.fill()
            let glow = NSGradient(colors: [
                NSColor.controlAccentColor.withAlphaComponent(dark ? 0.07 : 0.05),
                background.withAlphaComponent(0),
            ])
            glow?.draw(in: NSRect(x: 0, y: bounds.height * 0.55, width: bounds.width, height: bounds.height * 0.45), angle: -90)
            if sidebarVisible {
                (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.035).setFill()
                NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
                NSColor.separatorColor.withAlphaComponent(0.5).setFill()
                NSRect(x: sidebarWidth - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
            }
            return
        }
        guard !translucentContent else { return }
        background.setFill()
        NSRect(x: sidebarVisible ? sidebarWidth : 0, y: 0, width: bounds.width, height: bounds.height).fill()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        let b = bounds
        let w = sidebarVisible ? sidebarWidth : 0
        sidebar.frame = NSRect(x: 0, y: 0, width: w, height: b.height)
        material.frame = translucentContent ? b : sidebar.frame
        material.isHidden = fullScreen || (!sidebarVisible && !translucentContent)
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
    override func mouseUp(with _: NSEvent) {
        // Remembered for new windows and the next launch.
        if dragging { Settings.sidebarWidth = sidebarWidth }
        dragging = false
    }

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
    var content: NSView {
        didSet {
            guard content !== oldValue else { return }
            oldValue.removeFromSuperview()
            addSubview(content, positioned: .below, relativeTo: placeholder)
            needsLayout = true
        }
    }
    let placeholder: PlaceholderView
    let topBar: CollapsedTopBar
    /// Where a dragged pane will land, over the whole split area.
    let dropHint = DropHighlight()
    /// Catches pane drags anywhere over the panes, gaps included.
    let dropSurface = DropSurface()

    /// The gaps between panes aren't window background: a grab that just
    /// misses a pane's edge must not drag the window.
    override var mouseDownCanMoveWindow: Bool { false }
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
        addSubview(dropHint)
        addSubview(dropSurface)
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
        dropSurface.frame = b
    }
}

/// Shown instead of the sidebar's top when it is hidden.
@MainActor
private final class CollapsedTopBar: NSView {
    var fullScreen = false { didSet { needsLayout = true } }
    var onShowSidebar: (() -> Void)?
    var onToggleFiles: (() -> Void)?
    private let button = NSButton()
    private let filesButton = NSButton()
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
        button.toolTip = "Show Sidebar (⌃⌘S)"
        filesButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "File Viewer")
        filesButton.isBordered = false
        filesButton.contentTintColor = .secondaryLabelColor
        filesButton.target = self
        filesButton.action = #selector(toggleFiles)
        filesButton.toolTip = "Toggle File Viewer (⇧⌘E)"
        addSubview(filesButton)
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
        // Right of the traffic lights; full screen has none.
        let x: CGFloat = fullScreen ? 10 : 84
        button.frame = NSRect(x: x, y: y - 3, width: 26, height: 24)
        filesButton.frame = NSRect(x: x + 26, y: y - 3, width: 26, height: 24)
        let sw = ceil(space.intrinsicContentSize.width) + 4
        space.frame = NSRect(x: x + 58, y: y, width: sw, height: 18)
        tab.frame = NSRect(x: x + 58 + sw + 8, y: y + 1, width: 200, height: 16)
        let aw = alert.intrinsicContentSize.width
        alert.frame = NSRect(x: bounds.width - aw - 16, y: y + 1, width: aw, height: 16)
        alertDot.frame = NSRect(x: bounds.width - aw - 28, y: y + 5, width: 7, height: 7)
    }

    @objc private func show() { onShowSidebar?() }
    @objc private func toggleFiles() { onToggleFiles?() }
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
    private let copyInstall = NSButton(title: "Copy Install Command", target: nil, action: nil)
    static let installCommand = "curl -fsSL https://herdr.dev/install.sh | sh"
    /// No herdr binary anywhere bigtty looks: offer to install it first.
    private var herdrMissing = false
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
        copyInstall.bezelStyle = .rounded
        copyInstall.target = self
        copyInstall.action = #selector(copyInstallClicked)
        footnote.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footnote.textColor = .tertiaryLabelColor
        footnote.alignment = .center
        action.bezelStyle = .rounded
        action.keyEquivalent = "\r"
        action.target = self
        action.action = #selector(actionClicked)
        footnote.isSelectable = true
        for view in [spinner, icon, title, detail, start, copyInstall, connect, footnote, action] { addSubview(view) }
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
            herdrMissing = !FileManager.default.isExecutableFile(atPath: binary)
            if herdrMissing {
                title.stringValue = "herdr isn’t installed"
                detail.stringValue = "bigtty shows the spaces, agents and terminals of herdr (herdr.dev), which keeps them running. Install it in a terminal with the command below, then click Start herdr. Or connect to a machine that already runs herdr."
                footnote.stringValue = Self.installCommand
            } else {
                title.stringValue = "herdr isn’t running"
                detail.stringValue = "bigtty shows the spaces, agents and terminals of a herdr server. Start one here, or connect to a machine that already runs herdr."
                footnote.stringValue = "looked for \((socket as NSString).abbreviatingWithTildeInPath) · herdr at \((binary as NSString).abbreviatingWithTildeInPath)"
            }
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
        copyInstall.isHidden = !(notRunning && herdrMissing)
        // Return copies the install command until herdr is there to start.
        start.keyEquivalent = copyInstall.isHidden ? "\r" : ""
        copyInstall.keyEquivalent = copyInstall.isHidden ? "" : "\r"
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
        let buttons = [copyInstall, start, connect].filter { !$0.isHidden }
        buttons.forEach { $0.sizeToFit() }
        var x = midX - (buttons.reduce(0) { $0 + $1.frame.width } + CGFloat(max(0, buttons.count - 1)) * 10) / 2
        y -= 44
        for button in buttons {
            button.frame.origin = NSPoint(x: x, y: y)
            x += button.frame.width + 10
        }
        footnote.frame = NSRect(x: 0, y: y - 34, width: bounds.width, height: 16)
    }

    @objc private func startClicked() {
        // Installed since this screen came up? Then start it; else say so.
        guard !herdrMissing || HerdrEndpoint.locateHerdr() != nil else {
            NSSound.beep()
            detail.stringValue = "herdr still isn’t installed. Run the command below in a terminal, then click Start herdr again."
            needsLayout = true
            return
        }
        onStart?()
    }

    @objc private func copyInstallClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
        copyInstall.title = "Copied"
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyInstall.title = "Copy Install Command"
            self?.needsLayout = true
        }
    }
    @objc private func actionClicked() { onAction?() }
    @objc private func connectClicked() { onConnect?() }
}
