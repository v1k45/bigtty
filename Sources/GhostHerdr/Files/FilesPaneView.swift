import AppKit

/// A files pane: a tree of the workspace (or its git changes) on the left,
/// the selected file or diff on the right. Refreshes live as files change.
@MainActor
final class FilesPaneView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Mode: String { case files, changes }

    let hostID: String
    /// `.files` or `.diff`, as tagged in herdr; only the starting mode.
    let kind: HostPaneKind
    private(set) var root: String
    private(set) var mode: Mode
    private(set) var selection: String?

    private let modeControl = NSSegmentedControl(labels: ["Files", "Changes"], trackingMode: .selectOne, target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let divider = PaneDivider()
    let code = CodeView()
    private var treeWidth: CGFloat = 240

    private var tree: FileNode
    private var changes: [FileNode] = []
    private var status = GitClient.Status(top: "", changes: [:])
    private var git: GitClient?
    private var watcher: FileWatcher?

    var onFocus: (() -> Void)?
    var onStateChange: ((HostPaneState) -> Void)?
    /// Insert a path into the tab's terminal (context menu).
    var onInsertPath: ((String) -> Void)?

    static let toolbarHeight: CGFloat = 30

    init(hostID: String, state: HostPaneState) {
        self.hostID = hostID
        kind = state.kind
        root = state.path.map { GitClient.isDirectory($0) ? $0 : ($0 as NSString).deletingLastPathComponent } ?? NSHomeDirectory()
        mode = state.kind == .diff || state.mode == Mode.changes.rawValue ? .changes : .files
        selection = state.selection ?? (state.path.flatMap { GitClient.isDirectory($0) ? nil : $0 })
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
        addSubview(divider)
        divider.onDrag = { [weak self] x in
            guard let self else { return }
            self.treeWidth = min(max(x, 120), self.bounds.width - 160)
            self.needsLayout = true
        }

        git = GitClient.repository(containing: root)
        watcher = FileWatcher(path: root) { [weak self] paths in self?.filesChanged(paths) }
        reload()
        if let selection { select(path: selection, line: state.line) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let h = Self.toolbarHeight
        let y = b.height - h + (h - 22) / 2
        let control = modeControl.fittingSize
        modeControl.frame = NSRect(x: 8, y: y, width: control.width, height: 22)
        titleLabel.frame = NSRect(x: modeControl.frame.maxX + 10, y: y + 3, width: max(0, b.width - modeControl.frame.maxX - 20), height: 16)
        let body = max(0, b.height - h)
        let tree = min(treeWidth, max(120, b.width * 0.45))
        outlineScroll.frame = NSRect(x: 0, y: 0, width: tree, height: body)
        divider.frame = NSRect(x: tree, y: 0, width: 1, height: body)
        code.frame = NSRect(x: tree + 1, y: 0, width: max(0, b.width - tree - 1), height: body)
        code.dark = Theme.current?.isDark ?? true
    }

    // MARK: - Data

    private func reload() {
        status = git?.status() ?? GitClient.Status(top: "", changes: [:])
        titleLabel.stringValue = (root as NSString).abbreviatingWithTildeInPath + (git == nil ? "" : "  ·  \(status.changes.count) changed")
        switch mode {
        case .files:
            tree.invalidate()
        case .changes:
            changes = status.changes.keys.sorted().map { FileNode(path: $0, isDirectory: false) }
        }
        let expanded = expandedPaths()
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
            if let node = outline.item(atRow: row) as? FileNode, paths.contains(node.path) { outline.expandItem(node) }
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

    /// Shows a path: expands the tree down to it (or switches list) and loads it.
    func select(path: String, line: Int? = nil) {
        selection = path
        if mode == .files, path.hasPrefix(root) {
            var node = tree
            let parts = String(path.dropFirst(root.count)).split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                guard let child = node.children.first(where: { $0.name == part }) else { break }
                outline.expandItem(child)
                node = child
            }
        }
        reselect()
        let row = outline.selectedRow
        if row >= 0 { outline.scrollRowToVisible(row) }
        showSelection()
        if let line { code.reveal(line: line) }
        publish()
    }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        modeControl.selectedSegment = mode == .files ? 0 : 1
        reload()
        publish()
    }

    private func showSelection() {
        guard let selection else {
            code.showMessage(mode == .changes
                ? (git == nil ? "Not a git repository" : (changes.isEmpty ? "No changes" : "Select a changed file"))
                : "Select a file")
            return
        }
        if mode == .changes, let git {
            let untracked = status.changes[selection] == .untracked
            code.showAttributed(DiffRenderer.render(git.diff(selection, untracked: untracked), dark: code.dark), identity: "diff:" + selection)
        } else if GitClient.isDirectory(selection) {
            code.showMessage((selection as NSString).lastPathComponent + "/")
        } else {
            code.showFile(selection)
        }
    }

    private func publish() {
        var state = HostPaneStore.shared[hostID] ?? HostPaneState(kind: .files)
        state.path = root
        state.selection = selection
        state.mode = mode.rawValue
        HostPaneStore.shared[hostID] = state
        onStateChange?(state)
    }

    @objc private func modeChanged() {
        setMode(modeControl.selectedSegment == 0 ? .files : .changes)
    }

    // MARK: - Outline

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return mode == .files ? tree.children.count : changes.count }
        return node.children.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return mode == .files ? tree.children[index] : changes[index] }
        return node.children[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        mode == .files && (item as? FileNode)?.isDirectory == true
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
        if node.isDirectory, mode == .files {
            selection = node.path
            publish()
            return
        }
        selection = node.path
        showSelection()
        publish()
    }

    // MARK: - Context menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("Insert Path in Terminal", #selector(insertPath)),
            ("Copy Path", #selector(copyPath)),
            ("Open in Default App", #selector(openInDefaultApp)),
            ("Reveal in Finder", #selector(revealInFinder)),
        ] {
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
        if let path = clickedPath, !GitClient.isDirectory(path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    @objc private func revealInFinder() {
        if let path = clickedPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onFocus?() }
        return hit
    }
}

/// A lazily listed file or directory.
final class FileNode {
    let path: String
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
    private var cached: [FileNode]?

    private static let hidden: Set<String> = [".git", ".DS_Store", ".build", ".swiftpm", "node_modules", "__pycache__"]

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    var children: [FileNode] {
        if let cached { return cached }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let nodes = names.filter { !Self.hidden.contains($0) }.map { name -> FileNode in
            let full = (path as NSString).appendingPathComponent(name)
            return FileNode(path: full, isDirectory: GitClient.isDirectory(full))
        }
        let sorted = nodes.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        cached = sorted
        return sorted
    }

    /// Drops cached listings (recursively), keeping node identity for
    /// expansion state where names are unchanged.
    func invalidate() {
        guard let cached else { return }
        let fresh = Set(((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !Self.hidden.contains($0) })
        if Set(cached.map(\.name)) != fresh {
            self.cached = nil
            return
        }
        for child in cached where child.isDirectory { child.invalidate() }
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
