import AppKit

/// A files pane: a tree of the workspace (or its git changes) on the left,
/// the selected file or diff on the right. Works on this Mac or on a remote
/// machine (through its `FileSource`); all reading happens off the main
/// thread. Refreshes live: FSEvents locally, polling remotely.
@MainActor
final class FilesPaneView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Mode: String { case files, changes }

    let hostID: String
    /// `.files` or `.diff`, as tagged in herdr; only the starting mode.
    let kind: HostPaneKind
    let source: FileSource
    private(set) var root: String
    private(set) var mode: Mode
    private(set) var selection: String?

    private let modeControl = NSSegmentedControl(labels: ["Files", "Changes"], trackingMode: .selectOne, target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let treeButton = NSButton()
    /// The tree (or changes list) beside the file; a file opens without it.
    private var showsTree: Bool
    /// The pane's × button.
    var onClose: (() -> Void)?
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let divider = PaneDivider()
    let code = CodeView()
    private let preview = ImagePreview()
    private var treeWidth: CGFloat = 240

    private var tree: FileNode
    private var changes: [FileNode] = []
    private var status = GitClient.Status(top: "", changes: [:])
    private var git: GitClient?
    private var watcher: FileWatcher?
    private var poller: Timer?
    private var shownModified: Double?
    private var loadToken = 0
    private var pendingLine: Int?
    /// The machine's home, to show paths as ~/…
    private var home = ""

    private func displayPath(_ path: String) -> String {
        guard home.count > 1 else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var onFocus: (() -> Void)?
    var onStateChange: ((HostPaneState) -> Void)?
    /// Insert a path into the tab's terminal (context menu).
    var onInsertPath: ((String) -> Void)?

    static let toolbarHeight: CGFloat = 30
    nonisolated static let maxFileBytes = 4_000_000
    /// Images and PDFs are shown, not read as text: a full-resolution
    /// screenshot easily passes 4 MB, and a cut-off one can't be decoded.
    nonisolated static let maxPreviewBytes = 200_000_000

    init(hostID: String, state: HostPaneState, source: FileSource = .local) {
        self.hostID = hostID
        self.source = source
        kind = state.kind
        root = state.path ?? (source.isRemote ? "/" : NSHomeDirectory())
        mode = state.kind == .diff || state.mode == Mode.changes.rawValue ? .changes : .files
        selection = state.selection
        pendingLine = state.line
        showsTree = state.showsTree ?? (state.selection == nil)
        tree = FileNode(path: root, isDirectory: true)
        super.init(frame: .zero)
        clipsToBounds = true

        modeControl.selectedSegment = mode == .files ? 0 : 1
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingHead
        addSubview(modeControl)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Pane"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
        treeButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show Files")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        treeButton.isBordered = false
        treeButton.bezelStyle = .regularSquare
        treeButton.target = self
        treeButton.action = #selector(toggleTree)
        addSubview(treeButton)
        updateTreeButton()
        addSubview(titleLabel)

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 20
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openInDefaultApp)
        outline.menu = makeMenu()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false

        addSubview(outlineScroll)
        addSubview(code)
        preview.isHidden = true
        addSubview(preview)
        addSubview(divider)
        divider.onDrag = { [weak self] x in
            guard let self else { return }
            self.treeWidth = min(max(x, 120), self.bounds.width - 160)
            self.needsLayout = true
        }
        code.showMessage("Loading…")
        start()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Resolves the root (a file path means its folder), finds git, starts
    /// watching, and loads.
    private func start() {
        let source = source
        let path = root
        let wantsRepoRoot = mode == .changes
        Task.detached {
            let isDir = source.isDirectory(path)
            let folder = isDir ? path : (path as NSString).deletingLastPathComponent
            let git = GitClient.repository(containing: folder, runner: source.runner)
            let home = source.home()
            await MainActor.run {
                self.home = home
                if !isDir, self.selection == nil { self.selection = path }
                self.root = wantsRepoRoot ? (git?.root ?? folder) : folder
                self.git = git
                self.tree = FileNode(path: self.root, isDirectory: true)
                self.watch()
                self.reload()
                if let selection = self.selection { self.select(path: selection, line: self.pendingLine) }
            }
        }
    }

    private func watch() {
        if source.isRemote {
            // No FSEvents over SSH: poll git status and the open file.
            poller = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        } else {
            watcher = FileWatcher(path: root) { [weak self] paths in self?.filesChanged(paths) }
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let h = Self.toolbarHeight
        let y = b.height - h + (h - 22) / 2
        treeButton.frame = NSRect(x: 6, y: y - 1, width: 24, height: 24)
        let control = modeControl.fittingSize
        modeControl.frame = NSRect(x: treeButton.frame.maxX + 4, y: y, width: control.width, height: 22)
        closeButton.frame = NSRect(x: b.width - 30, y: y - 1, width: 24, height: 24)
        titleLabel.frame = NSRect(x: modeControl.frame.maxX + 10, y: y + 3, width: max(0, closeButton.frame.minX - modeControl.frame.maxX - 16), height: 16)
        let body = max(0, b.height - h)
        // Narrow panes give the file itself the room; the tree comes back when wider.
        let tree: CGFloat = !showsTree ? 0 : b.width < 420 ? min(b.width * 0.45, 180) : min(treeWidth, max(140, b.width * 0.35))
        outlineScroll.isHidden = tree == 0
        divider.isHidden = tree == 0
        outlineScroll.frame = NSRect(x: 0, y: 0, width: tree, height: body)
        divider.frame = NSRect(x: tree, y: 0, width: 1, height: body)
        code.frame = NSRect(x: tree + 1, y: 0, width: max(0, b.width - tree - 1), height: body)
        preview.frame = code.frame
        code.dark = Theme.current?.isDark ?? true
    }

    // MARK: - Data

    /// Re-reads git status and every listed folder, keeping expansion.
    private func reload() {
        let git = git
        let source = source
        let expanded = expandedPaths().union([root])
        Task.detached {
            let status = git?.status() ?? GitClient.Status(top: "", changes: [:])
            var listings: [String: [FileSource.Entry]] = [:]
            for dir in expanded { listings[dir] = source.list(dir) ?? [] }
            await MainActor.run { self.apply(status: status, listings: listings) }
        }
    }

    private func apply(status: GitClient.Status, listings: [String: [FileSource.Entry]]) {
        self.status = status
        updateTitle()
        let expanded = expandedPaths()
        switch mode {
        case .files:
            tree.update(with: listings)
        case .changes:
            changes = status.changes.keys.sorted().map { FileNode(path: $0, isDirectory: false) }
        }
        outline.reloadData()
        restoreExpansion(expanded)
        reselect()
        showSelection()
    }

    private func filesChanged(_ paths: [String]) {
        // Ignore churn inside .git except what changes the status.
        let relevant = paths.contains { path in
            !path.contains("/.git/") || path.hasSuffix("/.git/index") || path.hasSuffix("/.git/HEAD")
        }
        if relevant { reload() }
    }

    /// Remote refresh: a full reload when git status or the open file changed.
    private var pollCount = 0
    private func poll() {
        pollCount += 1
        let git = git
        let source = source
        let selection = selection
        let previous = status.changes
        let full = pollCount % 5 == 0
        Task.detached {
            let status = git?.status()
            let modified = selection.flatMap { source.modified($0) }
            await MainActor.run {
                let statusChanged = status.map { $0.changes != previous } ?? false
                if full || statusChanged {
                    self.reload()
                } else if let modified, modified != self.shownModified {
                    self.showSelection()
                }
            }
        }
    }

    private func expandedPaths() -> Set<String> {
        var set = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) { set.insert(node.path) }
        }
        return set
    }

    private func restoreExpansion(_ paths: Set<String>) {
        guard mode == .files else { return }
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, paths.contains(node.path), node.children != nil {
                outline.expandItem(node)
            }
            row += 1
        }
    }

    private func reselect() {
        guard let selection else { return }
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? FileNode)?.path == selection {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            return
        }
    }

    /// Shows a path: expands the tree down to it (loading folders as
    /// needed), selects it and loads it.
    func select(path: String, line: Int? = nil) {
        selection = path
        pendingLine = line
        showSelection()
        updateTitle()
        publish()
        guard mode == .files, path.hasPrefix(root) else { return reselect() }
        let parts = String(path.dropFirst(root.count)).split(separator: "/").map(String.init).dropLast()
        var chain: [String] = []
        var current = root
        for part in parts {
            current = (current as NSString).appendingPathComponent(part)
            chain.append(current)
        }
        let source = source
        Task.detached {
            var listings: [String: [FileSource.Entry]] = [:]
            for dir in chain { listings[dir] = source.list(dir) ?? [] }
            await MainActor.run {
                self.tree.update(with: listings, addingMissing: true)
                self.outline.reloadData()
                for dir in chain { if let node = self.tree.find(dir) { self.outline.expandItem(node) } }
                self.reselect()
                let row = self.outline.selectedRow
                if row >= 0 { self.outline.scrollRowToVisible(row) }
            }
        }
    }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        modeControl.selectedSegment = mode == .files ? 0 : 1
        if mode == .changes, let git, root != git.root {
            root = git.root
            tree = FileNode(path: root, isDirectory: true)
        }
        reload()
        publish()
    }

    /// Loads what's selected (file, image or diff) off the main thread.
    private func showSelection() {
        preview.isHidden = true
        guard let selection else {
            code.showMessage(mode == .changes
                ? (git == nil ? "Not a git repository" : (changes.isEmpty ? "No changes" : "Select a changed file"))
                : "Select a file")
            return
        }
        loadToken += 1
        let token = loadToken
        let source = source
        let mode = mode
        let git = git
        let untracked = status.changes[selection] == .untracked
        let isDirectoryHint = tree.find(selection)?.isDirectory
        let isPreview = ImagePreview.canShow(selection)
        Task.detached {
            if mode == .changes, let git {
                let diff = git.diff(selection, untracked: untracked)
                await MainActor.run {
                    guard token == self.loadToken else { return }
                    self.code.showAttributed(DiffRenderer.render(diff, dark: self.code.dark), identity: "diff:" + selection)
                }
                return
            }
            let isDirectory = isDirectoryHint ?? source.isDirectory(selection)
            let modified = source.modified(selection)
            let data = isDirectory ? nil : source.read(selection, limit: (isPreview ? Self.maxPreviewBytes : Self.maxFileBytes) + 1)
            await MainActor.run {
                guard token == self.loadToken else { return }
                self.shownModified = modified
                if isDirectory {
                    self.code.showMessage((selection as NSString).lastPathComponent + "/")
                } else if let data {
                    if ImagePreview.canShow(selection) {
                        self.preview.show(selection, data: data)
                        self.preview.isHidden = false
                    } else {
                        self.code.showFile(selection, data: data, limit: Self.maxFileBytes)
                        if let line = self.pendingLine {
                            self.pendingLine = nil
                            self.code.reveal(line: line)
                        }
                    }
                } else {
                    self.code.showMessage("Can’t read \((selection as NSString).lastPathComponent)")
                }
            }
        }
    }

    private func publish() {
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .files)
        state.path = root
        state.selection = selection
        state.mode = mode.rawValue
        state.showsTree = showsTree
        HostPaneStore.shared[hostID] = state
        onStateChange?(state)
    }

    @objc private func closeClicked() { onClose?() }

    @objc private func toggleTree() {
        showsTree.toggle()
        updateTreeButton()
        updateTitle()
        needsLayout = true
        reload()
        publish()
    }

    /// The folder and change count beside the tree; just the file's name
    /// when it's shown on its own (its path is in the tooltip).
    private func updateTitle() {
        if !showsTree, let selection {
            titleLabel.stringValue = (selection as NSString).lastPathComponent
            titleLabel.toolTip = displayPath(selection)
        } else {
            titleLabel.stringValue = displayPath(root) + (git == nil ? "" : "  ·  \(status.changes.count) changed")
            titleLabel.toolTip = nil
        }
    }

    private func updateTreeButton() {
        treeButton.contentTintColor = showsTree ? .controlAccentColor : .secondaryLabelColor
        treeButton.toolTip = showsTree ? "Hide Files" : "Show Files"
    }

    @objc private func modeChanged() {
        setMode(modeControl.selectedSegment == 0 ? .files : .changes)
    }

    // MARK: - Outline

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return mode == .files ? (tree.children?.count ?? 0) : changes.count }
        return node.children?.count ?? 0
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return mode == .files ? tree.children![index] : changes[index] }
        return node.children![index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        mode == .files && (item as? FileNode)?.isDirectory == true
    }

    /// Folders load when opened.
    func outlineViewItemWillExpand(_ note: Notification) {
        guard let node = note.userInfo?["NSObject"] as? FileNode, node.children == nil else { return }
        node.children = []
        let source = source
        let path = node.path
        Task.detached {
            let entries = source.list(path) ?? []
            await MainActor.run {
                guard let node = self.tree.find(path) else { return }
                node.setChildren(entries)
                self.outline.reloadItem(node, reloadChildren: true)
                self.outline.expandItem(node)
            }
        }
    }

    func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outline.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        let change = status.changes[node.path]
        // Changes list: file name first, its folder dimmed after it.
        let folder = mode == .changes
            ? ((String(node.path.dropFirst(status.top.count + 1)) as NSString).deletingLastPathComponent)
            : ""
        let dirty = node.isDirectory && status.changes.keys.contains { $0.hasPrefix(node.path + "/") }
        cell.configure(name: node.name, detail: folder, isDirectory: node.isDirectory, change: change, dirty: dirty)
        return cell
    }

    func outlineViewSelectionDidChange(_: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode, node.path != selection else { return }
        onFocus?()
        selection = node.path
        if !(node.isDirectory && mode == .files) { showSelection() }
        publish()
    }

    // MARK: - Context menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        var items: [(String, Selector)] = [
            ("Insert Path in Terminal", #selector(insertPath)),
            ("Copy Path", #selector(copyPath)),
        ]
        if !source.isRemote {
            items += [("Open in Default App", #selector(openInDefaultApp)), ("Reveal in Finder", #selector(revealInFinder))]
        }
        for (title, action) in items {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    private var clickedPath: String? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return (outline.item(atRow: row) as? FileNode)?.path
    }

    @objc private func insertPath() { if let path = clickedPath { onInsertPath?(path) } }

    @objc private func copyPath() {
        guard let path = clickedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func openInDefaultApp() {
        guard !source.isRemote, let path = clickedPath, !source.isDirectory(path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func revealInFinder() {
        if !source.isRemote, let path = clickedPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onFocus?() }
        return hit
    }
}

/// A file or folder in the tree. A folder's children are nil until listed.
final class FileNode {
    let path: String
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
    var children: [FileNode]?

    private static let hidden: Set<String> = [".git", ".DS_Store", ".build", ".swiftpm", "node_modules", "__pycache__"]

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    /// Replaces the children from a listing, reusing nodes whose names are
    /// unchanged (so expansion state survives a refresh).
    func setChildren(_ entries: [FileSource.Entry]) {
        let old = Dictionary((children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        children = entries.filter { !Self.hidden.contains($0.name) }.map { entry in
            if let node = old[entry.name], node.isDirectory == entry.isDirectory { return node }
            return FileNode(path: (path as NSString).appendingPathComponent(entry.name), isDirectory: entry.isDirectory)
        }.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Applies fresh listings to this subtree. Folders that were listed
    /// before get refreshed; with `addingMissing`, new ones get listed too.
    func update(with listings: [String: [FileSource.Entry]], addingMissing: Bool = false) {
        if let entries = listings[path], children != nil || addingMissing || listings.count == 1 {
            setChildren(entries)
        }
        for child in children ?? [] where child.isDirectory { child.update(with: listings, addingMissing: addingMissing) }
    }

    func find(_ target: String) -> FileNode? {
        if path == target { return self }
        guard target.hasPrefix(path == "/" ? "/" : path + "/") else { return nil }
        for child in children ?? [] {
            if let found = child.find(target) { return found }
        }
        return nil
    }
}

private final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.alignment = .right
        for view in [icon, label, badge] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func configure(name: String, detail: String, isDirectory: Bool, change: GitClient.Change?, dirty: Bool) {
        icon.image = NSImage(systemSymbolName: isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
        icon.contentTintColor = isDirectory ? .systemBlue : .secondaryLabelColor
        label.stringValue = name
        let color: NSColor = switch change {
        case .untracked, .added: .systemGreen
        case .deleted: .systemRed
        case .conflicted: .systemOrange
        case .modified, .renamed: .systemYellow
        case nil: dirty ? .systemYellow : .labelColor
        }
        let text = NSMutableAttributedString(string: name, attributes: [
            .foregroundColor: change == nil && !dirty ? NSColor.labelColor : color, .font: NSFont.systemFont(ofSize: 12),
        ])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 11),
            ]))
        }
        label.attributedStringValue = text
        badge.stringValue = change?.letter ?? (dirty ? "•" : "")
        badge.textColor = color
    }

    override func layout() {
        super.layout()
        let b = bounds
        icon.frame = NSRect(x: 0, y: (b.height - 14) / 2, width: 16, height: 14)
        badge.frame = NSRect(x: b.width - 22, y: (b.height - 14) / 2, width: 18, height: 14)
        label.frame = NSRect(x: 20, y: (b.height - 16) / 2, width: b.width - 44, height: 16)
    }
}

/// A 1pt vertical divider with a wider drag target.
final class PaneDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func draw(_: NSRect) {
        (Theme.current?.divider ?? .separatorColor).setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.insetBy(dx: -3, dy: 0).contains(local) ? self : nil
    }

    override func resetCursorRects() { addCursorRect(bounds.insetBy(dx: -3, dy: 0), cursor: .resizeLeftRight) }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
}
