import AppKit
import GhosttyTerminal
import HerdrKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var manager: MachineManager!
    private(set) var terminalController: TerminalController!
    private var controlServer: ControlServer?
    /// One per local session, keyed by machine id.
    private var controlAPIs: [String: ControlAPI] = [:]
    private var windows: [MainWindowController] = []

    /// The store of the session this Mac shows right now.
    private var localStore: SessionStore { manager.activeLocal.store! }

    /// Each space gets its own window, cmux-style. Off: sidebar windows that
    /// switch between spaces.
    private var windowPerSpace: Bool {
        get { Settings.windowPerSpace }
        set { Settings.windowPerSpace = newValue }
    }

    /// Spaces whose window the user closed; they stay closed until asked for.
    private var dismissedSpaces: Set<SpaceRef> = []
    /// Spaces this app just created; their windows open in front.
    private var spacesToActivate: Set<SpaceRef> = []
    private var knownSpaces: Set<SpaceRef> = []

    func applicationDidFinishLaunching(_: Notification) {
        let env = ProcessInfo.processInfo.environment
        // Debug: BIGTTY_APPEARANCE=light|dark overrides the system setting.
        if let look = env["BIGTTY_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
        }
        terminalController = Self.makeTerminalController()
        watchGhosttyConfig()
        let endpoint = HerdrEndpoint(session: env["BIGTTY_SESSION"].flatMap { $0.isEmpty ? nil : $0 })
        manager = MachineManager(localEndpoint: endpoint)
        // View ▸ Enter Full Screen is ours; don't let AppKit add a second one.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        NSApp.mainMenu = MainMenu.build()
        NSApp.windowsMenu?.delegate = self
        manager.observe { [weak self] in self?.machinesChanged() }
        wireMachines()
        startControlServer()
        WebExtensions.start()
        // An extension's own pages (uBlock's dashboard) open in a browser pane.
        NotificationCenter.default.addObserver(forName: .bigttyExtensionOpenURL, object: nil, queue: .main) { [weak self] note in
            let url = note.object as? String
            MainActor.assumeIsolated {
                if let url { self?.keyWindow?.openBrowserPane(url: url) }
            }
        }
        DebugDump.install { [weak self] in self?.debugDescription ?? "" }
        DebugDump.installTyping { NSApp.keyWindow?.firstResponder as? HerdrTerminalView
            ?? (ProcessInfo.processInfo.environment["BIGTTY_DEBUG_TYPE_BACK"] == nil ? Array(NSApp.orderedWindows) : NSApp.orderedWindows.reversed()).lazy.compactMap { $0.firstResponder as? HerdrTerminalView }.first }
        // Until herdr answers, one unpinned window shows the connection state;
        // in space mode it is then adopted by the first space.
        openWindow(pinnedTo: nil)
        if !windowPerSpace, let extra = env["BIGTTY_DEBUG_WINDOWS"].flatMap(Int.init), extra > 1 {
            for _ in 1..<extra { openWindow(pinnedTo: nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Each machine reveals panes and asks which ones are on screen through
    /// the windows showing it.
    private func wireMachines() {
        for machine in manager.all where machine.viewedPanesUnset {
            machine.viewedPanes = { [weak self, weak machine] in
                guard let self, let machine else { return [] }
                return Set(self.windows.filter { $0.machine === machine }.reduce(into: Set<String>()) { $0.formUnion($1.viewedPanes) })
            }
            machine.reveal = { [weak self, weak machine] pane in
                guard let self, let machine else { return }
                self.reveal(pane, on: machine)
            }
            machine.viewedPanesUnset = false
        }
    }

    private func machinesChanged() {
        wireMachines()
        reconcileSpaceWindows()
        if case .connected = localStore.state {
            let connected = manager.all.filter { $0.status == .connected }
            let live = Set(connected.compactMap(\.store).flatMap { $0.snapshot.panes.compactMap(\.hostID) })
            HostPaneStore.shared.prune(keeping: live, connectedMachines: Set(connected.map(\.id)))
            BrowserRegistry.shared.prune(keeping: live)
            FilesRegistry.shared.prune(keeping: live)
        }
    }

    /// The user's own Ghostty config, with Settings ▸ Terminal on top.
    private static func makeTerminalController() -> TerminalController {
        TerminalAppearance.makeController()
    }

    /// Edits to the Ghostty config apply live.
    private var configWatcher: FileWatcher?

    private func watchGhosttyConfig() {
        let dir = ((TerminalAppearance.configPath() ?? NSHomeDirectory() + "/.config/ghostty/config.ghostty") as NSString)
            .deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        configWatcher = FileWatcher(path: dir) { [weak self] paths in
            guard let self, paths.contains(where: { ($0 as NSString).lastPathComponent.hasPrefix("config") }) else { return }
            TerminalAppearance.apply(to: self.terminalController)
        }
    }

    /// In space mode closing every window just hides the spaces; the app
    /// stays running for notifications and the Dock badge.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { !windowPerSpace }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible {
            if windowPerSpace, let first = allSpaces.first {
                showSpace(first)
            } else if windows.isEmpty {
                openWindow(pinnedTo: nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_: Notification) {
        controlServer?.stop()
        // Terminal channels release control on deinit; herdr keeps the panes.
        windows.removeAll()
        for machine in manager.all { machine.disconnect() }
    }

    // MARK: - Control socket

    private func startControlServer() {
        let server = ControlServer { [weak self] method, params in
            guard let api = await self?.controlAPI(for: params) else {
                throw ControlServer.Failure(code: "unavailable", message: "bigtty is quitting")
            }
            return try await api.handle(method, params)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("bigtty: control socket unavailable: \(error)")
        }
    }

    /// The API for the caller's herdr session (`ghr` sends the socket from
    /// HERDR_SOCKET_PATH), else the session on screen.
    private func controlAPI(for params: JSONValue) -> ControlAPI? {
        let socket = params["caller_socket"]?.stringValue
        let machine = manager.localMachines.first { socket != nil && $0.store?.client.endpoint.socketPath == socket }
            ?? keyWindow.flatMap { $0.machine.isLocal ? $0.machine : nil } ?? manager.activeLocal
        if let api = controlAPIs[machine.id] { return api }
        guard let store = machine.store else { return nil }
        let api = ControlAPI(store: store)
        api.focusedPane = { [weak self, weak machine] in
            let key = self?.windows.first { $0.window?.isKeyWindow == true && $0.machine === machine }
                ?? self?.windows.first { $0.machine === machine }
            return key?.focusedPaneForControl
        }
        controlAPIs[machine.id] = api
        return api
    }

    // MARK: - Windows

    private var keyWindow: MainWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.first
    }

    @discardableResult
    private func openWindow(pinnedTo space: SpaceRef?, activate: Bool = true) -> MainWindowController {
        let controller = MainWindowController(manager: manager, terminalController: terminalController)
        controller.onStartHerdr = { [weak self, weak controller] in
            guard let machine = controller?.machine else { return }
            self?.manager.startSession(machine.session)
        }
        controller.onShowSession = { [weak self] machine in self?.showSession(machine) }
        controller.onJump = { [weak self] in self?.showJump(nil) }
        controller.onConnectMachine = { [weak self] in self?.connectMachine(nil) }
        controller.onMachineProblem = { [weak self] machine in self?.showProblem(machine) }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if let space = controller.pinnedSpace { self.dismissedSpaces.insert(space) }
            self.windows.removeAll { $0 === controller }
        }
        controller.onShowSpace = { [weak self] space in self?.showSpace(space) }
        controller.onSpaceClosed = { [weak controller] in controller?.close() }
        pin(controller, to: space)
        if let previous = windows.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 28, y: previous.frame.maxY - 28))
        }
        windows.append(controller)
        if activate || NSApp.keyWindow == nil {
            controller.showWindow(nil)
        } else {
            controller.window?.order(.below, relativeTo: NSApp.keyWindow?.windowNumber ?? 0)
        }
        return controller
    }

    private func pin(_ controller: MainWindowController, to space: SpaceRef?) {
        controller.pinnedSpace = space
        // Each space's window comes back where it was.
        if Settings.remembersLayout, let window = controller.window, let space,
           let label = manager.machine(space.machine)?.store?.workspace(space.workspace)?.label
        {
            let name = "bigtty.space.\(space.machine).\(label)"
            if window.frameAutosaveName == MainWindowController.frameName { window.setFrameAutosaveName("") }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
    }

    private func window(for space: SpaceRef) -> MainWindowController? {
        windows.first { $0.pinnedSpace == space }
    }

    /// Spaces of the session on screen and of every remote machine.
    private var allSpaces: [SpaceRef] {
        ([manager.activeLocal] + manager.remotes).flatMap { machine -> [SpaceRef] in
            guard let store = machine.store, case .connected = store.state else { return [] }
            return store.snapshot.workspaces.map { SpaceRef(machine: machine.id, workspace: $0.workspaceID) }
        }
    }

    /// Switches this Mac's session: to its focused space, or to the
    /// session itself while it has none (not running, starting).
    func showSession(_ machine: Machine) {
        guard machine.isLocal else { return }
        let previous = manager.activeLocal
        manager.activeLocal = machine
        let store = machine.store
        let space = store.flatMap { store -> SpaceRef? in
            guard case .connected = store.state else { return nil }
            let id = store.snapshot.focusedWorkspaceID ?? store.snapshot.workspaces.first?.workspaceID
            return id.map { SpaceRef(machine: machine.id, workspace: $0) }
        }
        if windowPerSpace, previous !== machine {
            // One window per space of the session on screen: the old
            // session's windows go (their spaces keep running).
            for controller in windows where controller.pinnedSpace?.machine == previous.id {
                controller.onClose = nil
                controller.close()
            }
            windows.removeAll { $0.pinnedSpace?.machine == previous.id }
            knownSpaces.removeAll()
            if windows.isEmpty { openWindow(pinnedTo: nil) }
            reconcileSpaceWindows()
            if let space { showSpace(space) } else { keyWindow?.switchMachine(to: machine) }
            return
        }
        if let space { showSpace(space) } else {
            if windows.isEmpty { openWindow(pinnedTo: nil) }
            keyWindow?.switchMachine(to: machine)
            keyWindow?.window?.makeKeyAndOrderFront(nil)
        }
        if space == nil { giveFirstSpace(machine) }
    }

    /// A session just started (or left with no spaces) gets one in the home
    /// folder once herdr answers, so switching never lands on nothing.
    private func giveFirstSpace(_ machine: Machine) {
        Task { @MainActor in
            for _ in 0..<40 {
                if case .connected = machine.store?.state { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let store = machine.store, case .connected = store.state, store.snapshot.workspaces.isEmpty,
                  manager.activeLocal === machine else { return }
            // Re-read first: the snapshot may lag the server.
            let fresh = try? await store.client.snapshot()
            if let first = fresh?.workspaces.first {
                store.scheduleRefresh()
                showSpace(SpaceRef(machine: machine.id, workspace: first.workspaceID))
                return
            }
            guard let pane = try? await store.client.createWorkspace(cwd: NSHomeDirectory()) else { return }
            store.scheduleRefresh()
            try? await Task.sleep(nanoseconds: 300_000_000)
            showSpace(SpaceRef(machine: machine.id, workspace: pane.workspaceID))
        }
    }

    /// Brings a space forward: its own window in space mode, else the key window.
    func showSpace(_ space: SpaceRef) {
        dismissedSpaces.remove(space)
        if windowPerSpace {
            (window(for: space) ?? openWindow(pinnedTo: space)).window?.makeKeyAndOrderFront(nil)
        } else {
            if windows.isEmpty { openWindow(pinnedTo: nil) }
            keyWindow?.window?.makeKeyAndOrderFront(nil)
            keyWindow?.select(space)
        }
    }

    /// In space mode, keeps one window per live space: spaces that appear
    /// get a window, spaces that close lose theirs.
    private func reconcileSpaceWindows() {
        guard windowPerSpace, case .connected = localStore.state else { return }
        let spaces = allSpaces
        let live = Set(spaces)
        let firstReconcile = knownSpaces.isEmpty
        let newSpaces = live.subtracting(knownSpaces)
        knownSpaces = live
        dismissedSpaces.formIntersection(live)

        if firstReconcile, let lobby = windows.first(where: { $0.pinnedSpace == nil }),
           let focused = localStore.snapshot.focusedWorkspaceID.map({ SpaceRef(machine: manager.activeLocal.id, workspace: $0) }) ?? spaces.first
        {
            pin(lobby, to: focused)
        }
        for space in spaces where window(for: space) == nil && !dismissedSpaces.contains(space)
            && (firstReconcile || newSpaces.contains(space))
        {
            if let lobby = windows.first(where: { $0.pinnedSpace == nil }) {
                pin(lobby, to: space)
                continue
            }
            // Spaces created elsewhere (an agent, the herdr TUI) open behind.
            openWindow(pinnedTo: space, activate: spacesToActivate.remove(space) != nil)
        }
    }

    // MARK: - Machines

    /// ⌘⇧K / sidebar: connect a machine over SSH.
    @objc func connectMachine(_: Any?) {
        guard let window = keyWindow?.window else { return }
        ConnectMachineSheet.present(on: window, manager: manager) { [weak self] machine in
            guard let self else { return }
            self.wireMachines()
            // Show it once its spaces arrive.
            self.pendingMachine = machine.id
        }
    }

    /// A machine the user just connected: jump to its first space when ready.
    private var pendingMachine: String? {
        didSet { if pendingMachine != nil { watchPendingMachine() } }
    }

    private func watchPendingMachine() {
        guard let id = pendingMachine, let machine = manager.machine(id) else { return }
        if let store = machine.store, case .connected = store.state, let first = store.snapshot.workspaces.first {
            pendingMachine = nil
            showSpace(SpaceRef(machine: id, workspace: first.workspaceID))
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.pendingMachine == id { self.watchPendingMachine() }
        }
    }

    /// Clicking a machine header: explain its state and offer the fix.
    private func showProblem(_ machine: Machine) {
        guard let window = keyWindow?.window else { return }
        let alert = NSAlert()
        var actions: [(String, () -> Void)] = []
        switch machine.status {
        case let .signIn(message), let .failed(message):
            alert.messageText = machine.status == .signIn(message) ? "Sign in to \(machine.name)" : "Can’t reach \(machine.name)"
            alert.informativeText = "SSH to \(machine.target ?? machine.name) failed: \(message)\n\nbigtty connects with your SSH keys and agent (no passwords). Its spaces keep running on the machine."
            actions = [("Try Again", { machine.connect() }), ("Open in Terminal", { [weak self] in self?.openSSHInTerminal(machine) })]
        case .notRunning:
            alert.messageText = machine.isLocal ? "herdr isn’t running" : "herdr isn’t running on \(machine.name)"
            alert.informativeText = "Start it to see its spaces."
            actions = [("Start herdr", { [weak self] in
                if machine.isLocal { self?.manager.startSession(machine.session) } else { machine.startServer() }
            })]
        case .herdrMissing:
            alert.messageText = "herdr isn’t installed on \(machine.name)"
            alert.informativeText = "Install herdr there (herdr.dev), or run herdr machine add \(machine.target ?? "") in a terminal, which offers to install it."
            actions = [("Open in Terminal", { [weak self] in self?.openSSHInTerminal(machine) })]
        case let .approval(url):
            alert.messageText = "Approve the login to \(machine.name)"
            alert.informativeText = "\(machine.target ?? machine.name) uses Tailscale SSH, which asks you to confirm this login in the browser. bigtty connects on its own once you do."
            actions = [("Open Approval Page", { NSWorkspace.shared.open(url) })]
        case .disabled:
            alert.messageText = "\(machine.name) is off"
            actions = [("Connect", { machine.connect() })]
        default:
            alert.messageText = machine.name
            alert.informativeText = [machine.target, machine.versionWarning, machine.latency.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · ")
            if !machine.isLocal { actions = [("Reconnect", { machine.connect() })] }
        }
        for (title, _) in actions { alert.addButton(withTitle: title) }
        if !machine.isLocal { alert.addButton(withTitle: "Remove Machine") }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if index < actions.count {
                actions[index].1()
            } else if index == actions.count, !machine.isLocal {
                self?.manager.remove(machine.id)
            }
        }
    }

    /// Opens a local terminal tab running `ssh <target>`, for signing in or
    /// accepting a host key by hand.
    private func openSSHInTerminal(_ machine: Machine) {
        guard let target = machine.target, let workspace = localStore.snapshot.focusedWorkspaceID ?? localStore.snapshot.workspaces.first?.workspaceID else { return }
        let store = localStore
        Task {
            try? await store.client.createTab(workspaceID: workspace)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let snapshot = try? await store.client.snapshot()
            if let pane = snapshot?.panes.first(where: { $0.paneID == snapshot?.focusedPaneID }) {
                try? await store.client.sendText(paneID: pane.paneID, text: "ssh \(SSHTunnel.shellQuote(target))\r")
            }
            store.scheduleRefresh()
        }
        if let local = keyWindow, !local.machine.isLocal { local.switchMachine(to: manager.activeLocal) }
    }

    // MARK: - Jump

    /// Debug hook: connect a machine like the Connect sheet does (`target`).
    @objc func debugAddMachine(_ sender: Any?) {
        guard let target = sender as? String else { return }
        guard let machine = manager.add(target: target, name: nil, session: nil) else { return }
        wireMachines()
        machine.observe { [weak machine] in
            if machine?.status == .notRunning { machine?.startServer() }
        }
        pendingMachine = machine.id
    }

    /// Debug hook: start herdr on (or reconnect) every remote machine.
    @objc func debugStartMachines(_: Any?) {
        for machine in manager.remotes {
            if machine.status == .notRunning { machine.startServer() } else { machine.connect() }
        }
    }

    /// Debug hook: show a remote machine's first space in the key window.
    @objc func debugShowRemote(_: Any?) {
        guard let machine = manager.remotes.first, let first = machine.store?.snapshot.workspaces.first else { return }
        showSpace(SpaceRef(machine: machine.id, workspace: first.workspaceID))
    }

    /// Debug hook: re-apply terminal settings, as Settings ▸ Reload does.
    @objc func debugReloadTerminal(_: Any?) {
        TerminalAppearance.apply(to: terminalController)
    }

    /// Debug hook: switch to a session by name as the switcher does
    /// (starting it if stopped).
    @objc func debugSwitchSession(_ sender: Any?) {
        guard let name = sender as? String else { return }
        jump(to: .session(name == manager.local.session ? manager.local.session : name))
    }

    /// Debug hook: a README screenshot of the main window, to a path.
    @objc func debugScreenshot(_ sender: Any?) {
        // "settings:<path>" pictures the Settings window instead.
        guard var path = sender as? String else { return }
        var window = keyWindow?.window ?? NSApp.orderedWindows.first(where: { $0 is MainWindow })
        if path.hasPrefix("settings:") {
            path = String(path.dropFirst("settings:".count))
            window = SettingsWindowController.shared.window
        }
        guard let window else { return }
        // Settings: its page only (the toolbar's glass selection doesn't render off screen).
        DebugDump.writeScreenshot(of: window, to: path, contentOnly: window === SettingsWindowController.shared.window)
    }

    /// Debug hook: opens Settings on a tab by its label ("Terminal").
    @objc func debugSettingsTab(_ sender: Any?) {
        showSettings(nil)
        guard let label = sender as? String,
              let tabs = SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { $0.label == label }) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    /// Debug hook: "WxH" content size for the main window, e.g. 1600x1000.
    @objc func debugWindowSize(_ sender: Any?) {
        guard let parts = (sender as? String)?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2,
              let window = keyWindow?.window else { return }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
    }

    /// Debug hook: filter the open palette.
    @objc func debugPaletteType(_ sender: Any?) {
        JumpPalette.shared.debugType(sender as? String ?? "")
    }

    @objc func showJump(_: Any?) {
        JumpPalette.shared.show(manager: manager) { [weak self] target in
            self?.jump(to: target)
        }
    }

    private func jump(to target: JumpPalette.Target) {
        switch target {
        case let .space(space):
            showSpace(space)
        case let .pane(machineID, pane):
            if let machine = manager.machine(machineID) { reveal(pane, on: machine) }
        case let .machine(id):
            guard let machine = manager.machine(id) else { return }
            if machine.status == .connected, let first = machine.store?.snapshot.workspaces.first {
                showSpace(SpaceRef(machine: id, workspace: first.workspaceID))
            } else {
                showProblem(machine)
            }
        case .newSpace:
            keyWindow?.newWorkspace(nil)
        case let .action(selector):
            NSApp.sendAction(selector, to: nil, from: nil)
        case .connectMachine:
            connectMachine(nil)
        case let .session(name):
            let running = manager.knownSessions.first { $0.name == name }?.running ?? (name == manager.local.session)
            let machine = running ? (name.map { manager.open(session: $0) } ?? manager.local) : manager.startSession(name)
            showSession(machine)
        }
    }

    @objc func toggleWindowPerSpace(_: Any?) {
        windowPerSpace.toggle()
        for controller in windows { controller.onClose = nil; controller.close() }
        windows.removeAll()
        dismissedSpaces.removeAll()
        knownSpaces.removeAll()
        openWindow(pinnedTo: nil)
        reconcileSpaceWindows()
    }

    /// The About panel: what bigtty is, the herdr it talks to, where to
    /// go next, and whose work it stands on.
    @objc func showAbout(_: Any?) {
        let body = NSFont.systemFont(ofSize: 11)
        let small = NSFont.systemFont(ofSize: 10)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let text = NSMutableAttributedString()
        func add(_ string: String, font: NSFont = body, color: NSColor = .labelColor, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: center]
            if let link { attributes[.link] = URL(string: link) }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        add("A native Mac home for your terminal agents.\n", color: .secondaryLabelColor)
        let endpoint = localStore.client.endpoint
        var herdr = "herdr not running"
        if case let .connected(version) = localStore.state { herdr = "herdr \(version)" }
        let session = manager.activeLocal.sessionName
        let others = manager.all.count - 1
        add("\(herdr) · session \(session)" + (others > 0 ? " · \(others) more connected" : "") + "\n", font: small, color: .tertiaryLabelColor)
        add((endpoint.herdrBinary as NSString).abbreviatingWithTildeInPath + "\n\n", font: small, color: .tertiaryLabelColor)
        add("GitHub", link: "https://github.com/v1k45/bigtty")
        add("  ·  ")
        add("Report an Issue", link: "https://github.com/v1k45/bigtty/issues/new")
        add("  ·  ")
        add("herdr", link: "https://herdr.dev")
        add("\n\nBuilt on ", font: small, color: .secondaryLabelColor)
        add("herdr", font: small, link: "https://herdr.dev")
        add(", ", font: small, color: .secondaryLabelColor)
        add("Ghostty", font: small, link: "https://ghostty.org")
        add(" via ", font: small, color: .secondaryLabelColor)
        add("libghostty-spm", font: small, link: "https://github.com/Lakr233/libghostty-spm")
        add(", and themes from ", font: small, color: .secondaryLabelColor)
        add("iTerm2-Color-Schemes", font: small, link: "https://github.com/mbadolato/iTerm2-Color-Schemes")
        add(".", font: small, color: .secondaryLabelColor)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "bigtty",
            .applicationVersion: version,
            .version: "",
            .credits: text,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "MIT licensed · © 2026 the bigtty authors",
        ])
        NSApp.activate()
    }

    /// Edit ▸ Paste: an image into a terminal becomes a file path (see
    /// `MainWindowController.pasteImage`); anything else is a normal paste.
    @objc func pasteSmart(_ sender: Any?) {
        if let controller = windows.first(where: { $0.window === NSApp.keyWindow }), controller.pasteImage() { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    @objc func toggleTranslucency(_: Any?) {
        Settings.translucentWindow.toggle()
        Settings.changed()
    }

    @objc func toggleDimming(_: Any?) {
        Settings.dimUnfocused.toggle()
        Settings.changed()
    }

    @objc func showSettings(_: Any?) {
        let settings = SettingsWindowController.shared
        settings.herdrDescription = { [weak self] in
            guard let self else { return "" }
            let endpoint = self.localStore.client.endpoint
            var version = "not running"
            if case let .connected(v) = self.localStore.state { version = v }
            let session = endpoint.session ?? "default session"
            return "\((endpoint.herdrBinary as NSString).abbreviatingWithTildeInPath) · \(version) · \(session)"
        }
        settings.onWindowModeChange = { [weak self] in self?.toggleWindowPerSpace(nil) }
        settings.onTerminalChange = { [weak self] in
            guard let self else { return }
            TerminalAppearance.apply(to: self.terminalController)
        }
        settings.show()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleWindowPerSpace(_:)) { item.state = windowPerSpace ? .on : .off }
        if item.action == #selector(toggleDimming(_:)) { item.state = Settings.dimUnfocused ? .on : .off }
        if item.action == #selector(toggleTranslucency(_:)) { item.state = Settings.translucentWindow ? .on : .off }
        return true
    }

    /// ⌘N: in space mode, a new space in the current folder, in its own
    /// window; otherwise another sidebar window.
    @objc func newWindow(_: Any?) {
        guard windowPerSpace else {
            openWindow(pinnedTo: nil)
            return
        }
        let key = windows.first { $0.window?.isKeyWindow == true }
        let machine = key?.machine ?? manager.activeLocal
        let cwd = key?.currentDirectory ?? (machine.isLocal ? NSHomeDirectory() : nil)
        guard let store = machine.store else { return }
        Task {
            do {
                let pane = try await store.client.createWorkspace(cwd: cwd)
                spacesToActivate.insert(SpaceRef(machine: machine.id, workspace: pane.workspaceID))
                store.scheduleRefresh()
            } catch {
                NSLog("bigtty: could not create space: \(error)")
            }
        }
    }

    // MARK: - Attention

    /// Shows the pane in its space's window (space mode) or the key window.
    private func reveal(_ pane: Pane, on machine: Machine) {
        let space = SpaceRef(machine: machine.id, workspace: pane.workspaceID)
        if windowPerSpace {
            dismissedSpaces.remove(space)
            (window(for: space) ?? openWindow(pinnedTo: space)).reveal(pane)
            return
        }
        if windows.isEmpty { openWindow(pinnedTo: nil) }
        guard let target = keyWindow else { return }
        target.switchMachine(to: machine)
        target.reveal(pane)
    }

    @objc func installAgentSkill(_: Any?) {
        let done = AgentSkill.install()
        let alert = NSAlert()
        alert.messageText = done.isEmpty ? "Nothing was installed" : "Agents can now use ghr"
        alert.informativeText = done.isEmpty
            ? "Could not write ~/.local/bin/ghr or any skills folder."
            : done.joined(separator: "\n") + "\n\nAgents in herdr panes can run `ghr browser …`."
        alert.runModal()
    }

    /// ⌘⇧U: the next pane needing you, blocked first, on any machine.
    @objc func jumpToNextUnread(_: Any?) {
        let current = keyWindow?.viewedPane
        for machine in manager.all {
            guard let attention = machine.attention, !attention.attention.needingAttention.isEmpty else { continue }
            attention.jumpToNext(after: current)
            return
        }
        NSSound.beep()
    }

    // MARK: - Window menu lists every space, open or not

    private static let spaceItemTag = 7001

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.spaceItemTag { menu.removeItem(item) }
        for machine in manager.all {
            guard let store = machine.store, case .connected = store.state, !store.snapshot.workspaces.isEmpty else { continue }
            let header = NSMenuItem.sectionHeader(title: machine.name)
            header.tag = Self.spaceItemTag
            menu.addItem(header)
            for space in store.snapshot.workspaces {
                let count = machine.attention?.count(inWorkspace: space.workspaceID) ?? 0
                let title = count > 0 ? "\(space.label)  (\(count))" : space.label
                let item = NSMenuItem(title: title, action: #selector(showSpaceFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = SpaceRef(machine: machine.id, workspace: space.workspaceID).key
                item.tag = Self.spaceItemTag
                menu.addItem(item)
            }
        }
    }

    @objc private func showSpaceFromMenu(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String, let space = SpaceRef(key: key) { showSpace(space) }
    }

    override var debugDescription: String {
        var out = "windowPerSpace=\(windowPerSpace)\n"
        for machine in manager.all {
            let spaces = machine.store?.snapshot.workspaces.map(\.workspaceID) ?? []
            out += "machine \(machine.id) \(machine.name) status=\(machine.status) text=\(machine.statusText) socks=\(machine.socksPort ?? 0) error=\(machine.lastError ?? "-") spaces=\(spaces)\n"
        }
        out += "extensions: \(WebExtensions.status) \(WebExtensions.debugDetail)\n"
        out += JumpPalette.shared.debugRows + "\n"
        for (i, window) in windows.enumerated() {
            let pinned = window.pinnedSpace?.key ?? "-"
            out += "--- window \(i) pinned=\(pinned) key=\(window.window?.isKeyWindow ?? false) visible=\(window.window?.isVisible ?? false)\n"
            out += window.debugDescription
        }
        return out
    }
}
