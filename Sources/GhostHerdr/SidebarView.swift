import AppKit
import HerdrKit

/// Vertical list of herdr workspaces with their rolled-up agent state.
@MainActor
final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((String) -> Void)?
    var onNewWorkspace: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private var workspaces: [Workspace] = []
    private var badges: [String: Int] = [:]
    private var selectedID: String?
    private var suppressSelection = false

    override init(frame: NSRect) {
        super.init(frame: frame)

        let column = NSTableColumn(identifier: .init("workspace"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.menu = makeMenu()

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        addSubview(scroll)

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        addSubview(footer)

        addButton.bezelStyle = .accessoryBarAction
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Workspace")
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addWorkspace)
        addSubview(addButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let top: CGFloat = 36 // clear of the traffic lights
        scroll.frame = NSRect(x: 0, y: 28, width: b.width, height: b.height - 28 - top)
        addButton.frame = NSRect(x: b.width - 30, y: 4, width: 22, height: 20)
        footer.frame = NSRect(x: 10, y: 6, width: b.width - 44, height: 14)
    }

    func update(workspaces: [Workspace], badges: [String: Int], selected: String?, status: String) {
        footer.stringValue = status
        guard workspaces != self.workspaces || badges != self.badges || selected != selectedID else { return }
        self.workspaces = workspaces
        self.badges = badges
        selectedID = selected
        suppressSelection = true
        table.reloadData()
        if let index = workspaces.firstIndex(where: { $0.workspaceID == selected }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        suppressSelection = false
    }

    // MARK: - Table

    func numberOfRows(in _: NSTableView) -> Int { workspaces.count }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: WorkspaceCell.identifier, owner: nil) as? WorkspaceCell
            ?? WorkspaceCell()
        cell.configure(workspaces[row], badge: badges[workspaces[row].workspaceID] ?? 0)
        return cell
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        WorkspaceRowView()
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !suppressSelection, table.selectedRow >= 0 else { return }
        let id = workspaces[table.selectedRow].workspaceID
        selectedID = id
        onSelect?(id)
    }

    // MARK: - Actions

    @objc private func addWorkspace() { onNewWorkspace?() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename…", action: #selector(renameClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Workspace", action: #selector(closeClicked), keyEquivalent: "").target = self
        return menu
    }

    private var clickedID: String? {
        table.clickedRow >= 0 ? workspaces[table.clickedRow].workspaceID : nil
    }

    @objc private func renameClicked() { if let id = clickedID { onRename?(id) } }
    @objc private func closeClicked() { if let id = clickedID { onClose?(id) } }
}

private final class WorkspaceRowView: NSTableRowView {
    override func drawSelection(in _: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override func drawBackground(in _: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

private final class WorkspaceCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceCell")
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let badge = BadgeView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        for v in [label, detail, dot, badge] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func configure(_ workspace: Workspace, badge count: Int) {
        label.stringValue = workspace.label
        badge.count = count
        detail.stringValue = count == 0 && workspace.tabCount > 1 ? "\(workspace.tabCount)" : ""
        needsLayout = true
        dot.layer?.backgroundColor = workspace.agentStatus.color?.cgColor ?? NSColor.clear.cgColor
        toolTip = "\(workspace.label) — \(workspace.agentStatus.rawValue)"
    }

    override func layout() {
        super.layout()
        let b = bounds
        dot.frame = NSRect(x: 18, y: b.midY - 4, width: 8, height: 8)
        detail.frame = NSRect(x: b.width - 42, y: b.midY - 8, width: 24, height: 16)
        label.frame = NSRect(x: 34, y: b.midY - 9, width: b.width - 80, height: 18)
        let size = badge.intrinsicContentSize
        badge.frame = NSRect(x: b.width - 18 - size.width, y: b.midY - size.height / 2, width: size.width, height: size.height)
    }
}
