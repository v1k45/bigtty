import AppKit
import HerdrKit

/// ⌘K: type to jump to a machine, a space, an agent or terminal, or run an
/// action, across every machine.
@MainActor
final class JumpPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = JumpPalette()

    enum Target {
        case machine(String)
        case space(SpaceRef)
        case pane(String, Pane)
        case newSpace
        case connectMachine
        /// A herdr session on this Mac (nil: the default one).
        case session(String?)
        /// A menu action by selector, sent to the key window.
        case action(Selector)
    }

    private struct Item {
        let section: String
        let title: String
        let detail: String
        let symbol: String
        let alert: Bool
        let target: Target
        let haystack: String
    }

    private enum Row {
        case header(String)
        case item(Item)
    }

    private var panel: NSPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private var items: [Item] = []
    private var rows: [Row] = []
    private var onPick: ((Target) -> Void)?

    func show(manager: MachineManager, onPick: @escaping (Target) -> Void) {
        self.onPick = onPick
        items = Self.collect(manager: manager)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.stringValue = ""
        filter()
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private static func collect(manager: MachineManager) -> [Item] {
        var items: [Item] = []
        for machine in manager.remotes {
            let detail = [machine.target, machine.statusText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            items.append(Item(
                section: "Machines", title: machine.name, detail: detail, symbol: "server.rack",
                alert: machine.statusIsProblem, target: .machine(machine.id),
                haystack: "\(machine.name) \(machine.target ?? "")".lowercased()
            ))
        }
        // Sessions on this Mac, when there is more than the default one.
        if manager.knownSessions.count > 1 {
            let active = manager.activeLocal.session
            for info in manager.knownSessions {
                let machine = manager.localMachines.first { $0.session == info.name }
                let waiting = machine?.attention?.attention.needingAttention.count ?? 0
                let spaces = machine?.store?.snapshot.workspaces.count ?? 0
                let detail = info.name == active ? "current"
                    : !info.running ? "stopped · start"
                    : waiting > 0 ? "\(waiting) need\(waiting == 1 ? "s" : "") you"
                    : "\(spaces) space\(spaces == 1 ? "" : "s")"
                items.append(Item(
                    section: "Sessions", title: info.title, detail: detail, symbol: "rectangle.stack",
                    alert: waiting > 0 && info.name != active, target: .session(info.name),
                    haystack: "session \(info.title)".lowercased()
                ))
            }
        }
        var number = 0
        let visibleLocal = manager.activeLocal
        for machine in [visibleLocal] + manager.remotes + manager.localMachines.filter({ $0 !== visibleLocal }) {
            guard let store = machine.store, let spaceInfo = machine.spaceInfo, let attention = machine.attention,
                  case .connected = store.state else { continue }
            let visible = machine === visibleLocal || !machine.isLocal
            let suffix = !machine.isLocal ? " · \(machine.name)" : visible ? "" : " · \(machine.sessionName) session"
            for workspace in store.snapshot.workspaces {
                if visible { number += 1 }
                let info = spaceInfo.info[workspace.workspaceID]
                let detail = ([info?.line, info?.branch].compactMap { $0 }.first ?? "") + suffix
                items.append(Item(
                    section: "Spaces", title: workspace.label, detail: detail + (visible && number <= 9 ? "   ⌘\(number)" : ""),
                    symbol: "square.stack", alert: info?.lineIsAlert == true,
                    target: .space(SpaceRef(machine: machine.id, workspace: workspace.workspaceID)),
                    haystack: "\(workspace.label) \(info?.branch ?? "") \(info?.directory ?? "") \(machine.name) \(machine.isLocal ? machine.sessionName : "")".lowercased()
                ))
            }
            items += collectPanes(machine: machine, store: store, attention: attention, suffix: suffix)
        }
        items.append(Item(section: "Actions", title: "New Space…", detail: "⌘N", symbol: "plus", alert: false, target: .newSpace, haystack: "new space workspace"))
        items.append(Item(section: "Actions", title: "New Browser Tab", detail: "⌥⌘T", symbol: "globe", alert: false, target: .action(#selector(PaneActions.newBrowserTab(_:))), haystack: "new browser tab web"))
        items.append(Item(section: "Actions", title: "Open Browser Here", detail: "⇧⌥⌘B", symbol: "globe", alert: false, target: .action(#selector(PaneActions.openBrowserHere(_:))), haystack: "open browser here this pane web replace"))
        items.append(Item(section: "Actions", title: "Split with Browser", detail: "⌥⌘B", symbol: "rectangle.split.2x1", alert: false, target: .action(#selector(PaneActions.newBrowserPane(_:))), haystack: "split browser pane web"))
        items.append(Item(section: "Actions", title: "Open Files Here", detail: "⇧⌥⌘F", symbol: "doc.text", alert: false, target: .action(#selector(PaneActions.openFilesHere(_:))), haystack: "open files here this pane viewer"))
        items.append(Item(section: "Actions", title: "New Session…", detail: "⌃⌘N", symbol: "rectangle.stack.badge.plus", alert: false, target: .action(#selector(PaneActions.newSession(_:))), haystack: "new session herdr"))
        items.append(Item(section: "Actions", title: "Connect a Machine…", detail: "user@host", symbol: "server.rack", alert: false, target: .connectMachine, haystack: "connect machine ssh remote server add"))
        return items
    }

    private static func collectPanes(machine: Machine, store: SessionStore, attention: AttentionCenter, suffix: String) -> [Item] {
        var items: [Item] = []
        for pane in store.snapshot.panes {
            let space = (store.workspace(pane.workspaceID)?.label ?? "") + suffix
            let agent = pane.displayAgent ?? pane.agent
            let kind = pane.hostKind
            let title: String
            let symbol: String
            switch kind {
            case .browser:
                title = HostPaneStore.shared[pane.hostID ?? ""]?.url ?? "Browser"
                symbol = "globe"
            case .files, .diff:
                let state = HostPaneStore.shared[pane.hostID ?? ""]
                title = ((state?.selection ?? state?.path ?? "Files") as NSString).lastPathComponent
                symbol = kind == .diff ? "plus.forwardslash.minus" : "folder"
            case nil:
                title = agent ?? pane.displayName
                symbol = agent == nil ? "terminal" : "sparkle"
            }
            let reason = attention.reason(for: pane.paneID)
            let status = reason == .blocked ? "needs you" : reason == .done ? "finished" : (agent != nil ? pane.agentStatus.rawValue : "")
            items.append(Item(
                section: agent != nil ? "Agents" : "Panes", title: title,
                detail: [space, status].filter { !$0.isEmpty }.joined(separator: " · "),
                symbol: symbol, alert: reason == .blocked, target: .pane(machine.id, pane),
                haystack: "\(title) \(space) \(pane.foregroundCwd ?? pane.cwd ?? "")".lowercased()
            ))
        }
        return items
    }

    private func filter() {
        let query = field.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        // Substring matches on the name rank first, then anywhere; letters
        // in order ("ghr" → "ghostherdr") only count within the name.
        func score(_ item: Item) -> Int {
            guard !query.isEmpty else { return 1 }
            let title = item.title.lowercased()
            if title.hasPrefix(query) { return 4 }
            if title.contains(query) { return 3 }
            if item.haystack.contains(query) { return 2 }
            var remaining = Substring(query)
            for char in title where remaining.first == char { remaining = remaining.dropFirst() }
            return remaining.isEmpty ? 1 : 0
        }
        let matched = items.map { ($0, score($0)) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.map(\.0)
        // Waiting agents first within their section.
        let order = ["Sessions", "Machines", "Spaces", "Agents", "Panes", "Actions"]
        rows = []
        for section in order {
            let group = matched.filter { $0.section == section }.sorted { $0.alert && !$1.alert }
            guard !group.isEmpty else { continue }
            rows.append(.header(section))
            rows += group.prefix(section == "Panes" ? 6 : 12).map { .item($0) }
        }
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
        resizePanel()
    }

    private func resizePanel() {
        guard let panel else { return }
        let height = min(CGFloat(rows.reduce(0) { $0 + (isHeader($1) ? 26 : 38) }) + 70, 460)
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func isHeader(_ row: Row) -> Bool {
        if case .header = row { return true }
        return false
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        panel.contentView = effect

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Jump to a machine, space, agent or pane"
        field.delegate = self
        let line = NSBox()
        line.boxType = .separator

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for view in [icon, field, line, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            line.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            line.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])
        return panel
    }

    // MARK: - Table

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat { isHeader(rows[row]) ? 26 : 38 }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool { !isHeader(rows[row]) }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let container = NSView()
            label.frame = NSRect(x: 10, y: 4, width: 300, height: 15)
            container.addSubview(label)
            return container
        case let .item(item):
            return PaletteCell(item.title, item.detail, item.symbol, item.alert)
        }
    }

    // MARK: - Keys

    func controlTextDidChange(_: Notification) { filter() }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pickSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): panel?.orderOut(nil); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        var row = table.selectedRow
        repeat {
            row += delta
        } while row >= 0 && row < rows.count && isHeader(rows[row])
        guard row >= 0, row < rows.count else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func pickSelected() {
        let row = table.selectedRow
        guard row >= 0, case let .item(item) = rows[row] else { return }
        panel?.orderOut(nil)
        onPick?(item.target)
    }

    func windowDidResignKey(_: Notification) { panel?.orderOut(nil) }

    /// For the debug dump: what the palette lists right now.
    var debugRows: String {
        guard panel?.isVisible == true else { return "palette: hidden" }
        return "palette (\(field.stringValue)):\n" + rows.enumerated().map { index, row -> String in
            switch row {
            case let .header(title): return "  [\(title)]"
            case let .item(item): return "  \(index == table.selectedRow ? ">" : " ") \(item.title) — \(item.detail)"
            }
        }.joined(separator: "\n")
    }

    /// Debug hook: types into the palette's field.
    func debugType(_ text: String) {
        field.stringValue = text
        filter()
    }
}

/// Borderless-looking panels still need to become key for typing.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PaletteCell: NSTableCellView {
    init(_ title: String, _ detail: String, _ symbol: String, _ alert: Bool) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = alert ? .controlAccentColor : .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13.5)
        name.lineBreakMode = .byTruncatingMiddle
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = alert ? .controlAccentColor : .secondaryLabelColor
        sub.alignment = .right
        sub.lineBreakMode = .byTruncatingTail
        for view in [icon, name, sub] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            sub.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            sub.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sub.centerYAnchor.constraint(equalTo: centerYAnchor),
            sub.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}
