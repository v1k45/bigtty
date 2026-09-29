import AppKit
import GhosttyTerminal
import HerdrKit

/// One app window: sidebar of workspaces, tab strip, and the selected tab's
/// split tree. Each window keeps its own workspace/tab selection.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, PaneActions {
    private let store: SessionStore
    private let attention: AttentionCenter
    private let terminalController: TerminalController
    private let sidebar = SidebarView()
    private let tabStrip = TabStripView()
    private let splitTree = SplitTreeView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var observer: UUID?
    private var attentionObserver: UUID?
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
    private var main: MainContentView!

    var onClose: (() -> Void)?
    /// In window-per-space mode the window shows exactly this workspace, and
    /// picking another one in the sidebar opens that space's window instead.
    var pinnedWorkspaceID: String? {
        didSet {
            guard pinnedWorkspaceID != oldValue else { return }
            if let id = pinnedWorkspaceID {
                workspaceID = id
                tabID = nil
                lastFocusedPane = nil
            }
            render()
        }
    }
    var onShowSpace: ((String) -> Void)?
    /// The pinned workspace no longer exists in herdr.
    var onSpaceClosed: (() -> Void)?

    var sidebarVisible: Bool {
        get { root.sidebarVisible }
        set {
            root.sidebarVisible = newValue
            main.tabsInTitlebar = !newValue
        }
    }

    init(store: SessionStore, attention: AttentionCenter, terminalController: TerminalController) {
        self.store = store
        self.attention = attention
        self.terminalController = terminalController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 600, height: 360)
        window.setFrameAutosaveName("GhostHerdrMain")
        window.tabbingMode = .disallowed
        theme = Theme(controller: terminalController)
        super.init(window: window)
        window.delegate = self
        buildLayout()
        wireActions()
        observer = store.observe { [weak self] in self?.render() }
        attentionObserver = attention.observe { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        guard let window else { return }
        main = MainContentView(tabStrip: tabStrip, content: splitTree)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        main.addSubview(emptyLabel)
        main.emptyLabel = emptyLabel

        root = RootView(sidebar: sidebar, main: main)
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
        window.backgroundColor = theme.background
        root.sidebarBackground = theme.sidebar
        main.background = theme.chrome
        for view in paneViews.values { view.apply(theme) }
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        window.contentView.map(redraw)
    }

    private func wireActions() {
        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
            if self.pinnedWorkspaceID != nil, id != self.pinnedWorkspaceID {
                self.onShowSpace?(id)
            } else {
                self.selectWorkspace(id)
            }
        }
        sidebar.onNewWorkspace = { [weak self] in self?.newWorkspace(nil) }
        sidebar.onClose = { [weak self] id in self?.store.perform { try await $0.closeWorkspace(id) } }
        sidebar.onRename = { [weak self] id in self?.promptRename(workspaceID: id) }
        tabStrip.onSelect = { [weak self] id in self?.selectTab(id) }
        tabStrip.onClose = { [weak self] id in self?.store.perform { try await $0.closeTab(id) } }
        tabStrip.onNew = { [weak self] in self?.newTab(nil) }
    }

    // MARK: - Rendering

    private func render() {
        let snapshot = store.snapshot
        if let pinned = pinnedWorkspaceID {
            if store.workspace(pinned) == nil {
                if case .connected = store.state { onSpaceClosed?() }
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

        let workspaceBadges = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.workspaceID, attention.count(inWorkspace: $0.workspaceID))
        })
        sidebar.update(workspaces: snapshot.workspaces, badges: workspaceBadges, selected: workspaceID, status: statusText)
        let tabs = workspaceID.map(store.tabs(in:)) ?? []
        let tabBadges = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabID, attention.count(inTab: $0.tabID)) })
        tabStrip.update(tabs: tabs, badges: tabBadges, selected: tabID)
        tabStrip.spaceTitle = pinnedWorkspaceID.flatMap { store.workspace($0)?.label }

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
        splitTree.show(layout?.root, zoomedPane: layout?.zoomed == true ? herdrFocus : nil)
        for (id, view) in paneViews {
            view.update(pane: store.pane(id), attention: attention.reason(for: id))
            view.isFocusedPane = id == focused
        }

        emptyLabel.stringValue = switch store.state {
        case .connecting: "Connecting to herdr…"
        case let .disconnected(reason): "herdr is not reachable\n\(reason)\n\nStart it with `herdr` in a terminal."
        case .connected: layout == nil ? "No tab selected" : ""
        }
        emptyLabel.isHidden = layout != nil

        if let target = pendingFocus ?? (lastFocusedPane == nil ? focused : nil), let view = paneViews[target] {
            pendingFocus = nil
            lastFocusedPane = target
            window?.makeFirstResponder(view.content)
        }
        window?.title = store.workspace(workspaceID)?.label ?? "GhostHerdr"
    }

    private var statusText: String {
        switch store.state {
        case .connecting: "connecting…"
        case let .connected(version): "herdr \(version)"
        case .disconnected: "disconnected"
        }
    }

    private func paneView(for id: String) -> NSView? {
        if let view = paneViews[id] { return view }
        guard let pane = store.pane(id) else { return nil }
        let terminal = HerdrTerminalView(pane: pane, endpoint: store.client.endpoint, controller: terminalController)
        terminal.onFocus = { [weak self] in self?.paneGainedFocus(id) }
        let view = PaneContainerView(paneID: id, content: terminal)
        view.apply(theme)
        view.update(pane: pane, attention: attention.reason(for: id))
        paneViews[id] = view
        return view
    }

    private func paneGainedFocus(_ id: String) {
        lastFocusedPane = id
        for (paneID, view) in paneViews { view.isFocusedPane = paneID == id }
        attention.viewChanged()
        guard let tabID, store.layouts[tabID]?.focusedPaneID != id else { return }
        store.perform { try await $0.focusPane(id) }
    }

    /// The pane the user is looking at in this window, if it is key.
    var viewedPane: String? {
        guard window?.isKeyWindow == true, window?.isVisible == true,
              let id = lastFocusedPane, paneViews[id] != nil else { return nil }
        return id
    }

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

    private func selectWorkspace(_ id: String) {
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

    @objc func closePane(_: Any?) {
        guard let pane = focusedPaneID else { return }
        store.perform { try await $0.closePane(pane) }
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

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let workspaceID, let n = (sender as? NSMenuItem)?.tag else { return }
        let tabs = store.tabs(in: workspaceID)
        if n - 1 < tabs.count { selectTab(tabs[n - 1].tabID) }
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
        panel.prompt = "Open Workspace"
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
        alert.messageText = "Rename Workspace"
        let field = NSTextField(string: workspace.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let label = field.stringValue
            self?.store.perform { try await $0.renameWorkspace(workspaceID, label: label) }
        }
    }

    override var debugDescription: String {
        var out = "window=\(window?.frame ?? .zero) tree=\(splitTree.frame)\n"
        out += "workspace=\(workspaceID ?? "-") tab=\(tabID ?? "-") focused=\(focusedPaneID ?? "-")\n"
        for (id, view) in paneViews.sorted(by: { $0.key < $1.key }) {
            out += "pane \(id) frame=\(view.frame) \(view.terminal?.debugDescription ?? "")\n"
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
        if let observer { store.removeObserver(observer) }
        if let attentionObserver { attention.removeObserver(attentionObserver) }
        onClose?()
    }
}

/// Sidebar on the left with a draggable edge, main content on the right.
@MainActor
private final class RootView: NSView {
    private let sidebar: NSView
    private let main: NSView
    private var sidebarWidth: CGFloat = 220
    private var dragging = false
    var sidebarVisible = true {
        didSet {
            sidebar.isHidden = !sidebarVisible
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private var visibleWidth: CGFloat { sidebarVisible ? sidebarWidth : 0 }
    var onAppearanceChange: (() -> Void)?
    var sidebarBackground: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    init(sidebar: NSView, main: NSView) {
        self.sidebar = sidebar
        self.main = main
        super.init(frame: .zero)
        addSubview(sidebar)
        addSubview(main)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let w = visibleWidth
        sidebar.frame = NSRect(x: 0, y: 0, width: w, height: b.height)
        let gap: CGFloat = sidebarVisible ? 1 : 0
        main.frame = NSRect(x: w + gap, y: 0, width: b.width - w - gap, height: b.height)
    }

    override func draw(_: NSRect) {
        guard sidebarVisible else { return }
        sidebarBackground.setFill()
        NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
        (Theme.current?.divider ?? .separatorColor).setFill()
        NSRect(x: sidebarWidth, y: 0, width: 1, height: bounds.height).fill()
    }

    private var edge: NSRect { NSRect(x: sidebarWidth - 3, y: 0, width: 7, height: bounds.height) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        sidebarVisible && edge.contains(convert(point, from: superview)) ? self : super.hitTest(point)
    }

    override func resetCursorRects() {
        if sidebarVisible { addCursorRect(edge, cursor: .resizeLeftRight) }
    }
    override func mouseDown(with _: NSEvent) { dragging = true }
    override func mouseUp(with _: NSEvent) { dragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        sidebarWidth = min(max(convert(event.locationInWindow, from: nil).x, 160), 400)
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}

/// Tab strip on top, split tree below, both clear of the title bar.
@MainActor
private final class MainContentView: NSView {
    let tabStrip: TabStripView
    let content: NSView
    weak var emptyLabel: NSTextField?
    var background: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var tabsInTitlebar = false { didSet { needsLayout = true } }

    override func draw(_: NSRect) {
        background.setFill()
        bounds.fill()
    }

    init(tabStrip: TabStripView, content: NSView) {
        self.tabStrip = tabStrip
        self.content = content
        super.init(frame: .zero)
        addSubview(tabStrip)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let titlebar: CGFloat = 28
        let b = bounds
        if tabsInTitlebar {
            // No sidebar: tabs share the title bar row, clear of the traffic lights.
            tabStrip.leadingInset = 78
            tabStrip.frame = NSRect(x: 0, y: b.height - TabStripView.height - 2, width: b.width, height: TabStripView.height)
        } else {
            tabStrip.leadingInset = 8
            tabStrip.frame = NSRect(x: 0, y: b.height - titlebar - TabStripView.height, width: b.width, height: TabStripView.height)
        }
        content.frame = NSRect(x: 0, y: 0, width: b.width, height: tabStrip.frame.minY)
        if let emptyLabel {
            emptyLabel.frame = NSRect(x: 20, y: b.midY - 60, width: b.width - 40, height: 120)
        }
    }
}
