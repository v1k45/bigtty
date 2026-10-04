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
        /// A choice offered by `choose` (Move Pane to…).
        case perform(@MainActor () -> Void)
    }

    /// One option for `choose`.
    struct Choice {
        let section: String
        let title: String
        let detail: String
        let symbol: String
        let enabled: Bool
        let run: @MainActor () -> Void
    }

    private struct Item {
        let section: String
        let title: String
        let detail: String
        let symbol: String
        let alert: Bool
        let target: Target
        let haystack: String
        /// Letters to highlight in the title (UTF-16 ranges).
        var highlights: [NSRange] = []
        /// Terminal output lines show in a monospaced face.
        var monospaced = false
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
    private weak var manager: MachineManager?

    /// Only these sections, in this order, while choosing (nil: jumping).
    private var choosing: [String]?

    /// The palette as a picker: just `choices`, no terminal search.
    func choose(_ choices: [Choice], placeholder: String) {
        choosing = choices.map(\.section).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        onPick = { target in if case let .perform(run) = target { run() } }
        items = choices.filter(\.enabled).map {
            Item(section: $0.section, title: $0.title, detail: $0.detail, symbol: $0.symbol, alert: false,
                 target: .perform($0.run), haystack: $0.detail.lowercased())
        }
        present(placeholder: placeholder)
    }

    func show(manager: MachineManager, onPick: @escaping (Target) -> Void) {
        choosing = nil
        self.onPick = onPick
        self.manager = manager
        items = Self.collect(manager: manager)
        // Terminal text for "In Terminals": read in the background, the
        // results refresh as it arrives.
        TerminalIndex.shared.onUpdate = { [weak self] in
            guard let self, self.panel?.isVisible == true, !self.field.stringValue.isEmpty else { return }
            self.filter()
        }
        TerminalIndex.shared.refresh(manager.all)
        present(placeholder: Self.jumpPlaceholder)
    }

    private static let jumpPlaceholder = "Jump to a space, agent or pane, or search terminal output"

    private func present(placeholder: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.placeholderString = placeholder
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
        let shownRemotes = manager.remotes.map { manager.shown(for: $0) }
        let otherRemotes = manager.remotes.flatMap { manager.sessions(of: $0) }.filter { m in !shownRemotes.contains { $0 === m } }
        for machine in [visibleLocal] + shownRemotes + manager.localMachines.filter({ $0 !== visibleLocal }) + otherRemotes {
            guard let store = machine.store, let spaceInfo = machine.spaceInfo, let attention = machine.attention,
                  case .connected = store.state else { continue }
            let visible = machine === visibleLocal || shownRemotes.contains { $0 === machine }
            let remoteSession = machine.session.map { " (\($0))" } ?? ""
            let suffix = !machine.isLocal ? " · \(machine.name)\(remoteSession)" : visible ? "" : " · \(machine.sessionName) session"
            for workspace in store.snapshot.workspaces {
                if visible { number += 1 }
                let info = spaceInfo.info[workspace.workspaceID]
                let name = MainWindowController.spaceName(workspace, store: store, agentTitles: spaceInfo.agentTitles)
                let detail = ([info?.line, info?.branch].compactMap { $0 }.first ?? "") + suffix
                items.append(Item(
                    section: "Spaces", title: name, detail: detail + (visible && number <= 9 ? "   ⌘\(number)" : ""),
                    symbol: "square.stack", alert: info?.lineIsAlert == true,
                    target: .space(SpaceRef(machine: machine.id, workspace: workspace.workspaceID)),
                    haystack: "\(name) \(workspace.label) \(info?.branch ?? "") \(info?.directory ?? "") \(machine.name) \(machine.sessionName)".lowercased()
                ))
            }
            items += collectPanes(machine: machine, store: store, attention: attention, suffix: suffix)
        }
        items.append(Item(section: "Actions", title: "New Space…", detail: "⌘N", symbol: "plus", alert: false, target: .newSpace, haystack: "new space workspace"))
        items.append(Item(section: "Actions", title: "Pin / Unpin Pane", detail: "⌥⌘P", symbol: "pin", alert: false, target: .action(#selector(PaneActions.togglePin(_:))), haystack: "pin unpin pane follow sticky keep"))
        items.append(Item(section: "Actions", title: "Move Pane to…", detail: "⌃⌥⌘1–9", symbol: "arrow.right.square", alert: false, target: .action(#selector(PaneActions.movePaneTo(_:))), haystack: "move pane to space tab send"))
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
            let space = (store.workspace(pane.workspaceID).map {
                MainWindowController.spaceName($0, store: store, agentTitles: machine.spaceInfo?.agentTitles ?? [:])
            } ?? "") + suffix
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
                // What the pane is about (Claude's conversation title) over
                // the program's name; the agent goes in the detail.
                title = (pane.label?.isEmpty == false ? pane.label : nil) ?? pane.title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? machine.spaceInfo?.agentTitles[pane.paneID] ?? pane.shownTitle ?? agent ?? pane.displayName
                symbol = agent == nil ? "terminal" : "sparkle"
            }
            let reason = attention.reason(for: pane.paneID)
            let status = reason == .blocked ? "needs you" : reason == .done ? "finished" : (agent != nil ? pane.agentStatus.rawValue : "")
            items.append(Item(
                section: agent != nil ? "Agents" : "Panes", title: title,
                detail: [space, agent ?? "", status].filter { !$0.isEmpty }.joined(separator: " · "),
                symbol: symbol, alert: reason == .blocked, target: .pane(machine.id, pane),
                haystack: "\(title) \(agent ?? "") \(pane.terminalTitle ?? "") \(space) \(pane.foregroundCwd ?? pane.cwd ?? "")".lowercased()
            ))
        }
        return items
    }

    private func filter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Fuzzy on the name (highlighted); the rest of what describes an
        // item (folder, branch, machine) counts less.
        var matched: [(Item, Int)] = []
        for item in items {
            guard !query.isEmpty else { matched.append((item, 0)); continue }
            if let result = FuzzyMatch.matchWords(query, in: item.title) {
                var hit = item
                hit.highlights = Self.ranges(result.positions)
                matched.append((hit, result.score * 2 + 100))
            } else if Self.containsWords(query, in: item.haystack) {
                // Folder, branch, machine: plain words, not scattered
                // letters (in a long description those match almost anything).
                matched.append((item, 10))
            }
        }
        matched.sort { $0.1 > $1.1 }
        // What the terminals show: newest lines first.
        var terminal: [Item] = []
        if query.count >= 2, choosing == nil, let manager {
            terminal = TerminalIndex.shared.search(query, in: manager.all).map { hit in
                let machine = manager.machine(hit.machineID)
                let store = machine?.store
                let space = store.flatMap { store in
                    store.workspace(hit.pane.workspaceID).map {
                        MainWindowController.spaceName($0, store: store, agentTitles: machine?.spaceInfo?.agentTitles ?? [:])
                    }
                } ?? ""
                // The pane by what it's about, else its agent, else its
                // folder (a shell's title is just user@host:dir).
                let pane = hit.pane
                let paneName = machine?.spaceInfo?.agentTitles[pane.paneID] ?? pane.title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? pane.displayAgent ?? pane.agent ?? (pane.foregroundCwd ?? pane.cwd).map { ($0 as NSString).lastPathComponent }
                let where_ = [space, paneName, machine.map { $0.isLocal ? ($0.id == "local" ? nil : $0.sessionName) : $0.name } ?? nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return Item(section: "In Terminals", title: hit.snippet, detail: where_, symbol: "text.magnifyingglass",
                            alert: false, target: .pane(hit.machineID, hit.pane), haystack: "",
                            highlights: [hit.match], monospaced: true)
            }
        }
        // Waiting agents first within their section.
        let order = choosing ?? ["Sessions", "Machines", "Spaces", "Agents", "Panes", "In Terminals", "Actions"]
        let all = matched.map(\.0) + terminal
        rows = []
        for section in order {
            var group = all.filter { $0.section == section }
            if query.isEmpty { group.sort { $0.alert && !$1.alert } }
            guard !group.isEmpty else { continue }
            rows.append(.header(section))
            rows += group.prefix(section == "Panes" ? 6 : section == "In Terminals" ? 8 : 12).map { .item($0) }
        }
        // With a query, the best match leads regardless of section.
        if !query.isEmpty, let best = matched.first?.0, let at = rows.firstIndex(where: { row in
            if case let .item(item) = row { return item.title == best.title && item.section == best.section }
            return false
        }), let header = rows[..<at].lastIndex(where: isHeader), header != 0 {
            let block = rows[header..<(rows[(at + 1)...].firstIndex(where: isHeader) ?? rows.count)]
            rows.removeSubrange(block.indices)
            rows.insert(contentsOf: block, at: 0)
        }
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
        resizePanel()
    }

    /// Every word of the query appears in `text` (case-insensitive).
    private static func containsWords(_ query: String, in text: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        return !words.isEmpty && words.allSatisfy { text.contains($0) }
    }

    /// Positions to ranges, runs merged.
    private static func ranges(_ positions: [Int]) -> [NSRange] {
        var ranges: [NSRange] = []
        for position in positions {
            if let last = ranges.last, last.location + last.length == position {
                ranges[ranges.count - 1].length += 1
            } else {
                ranges.append(NSRange(location: position, length: 1))
            }
        }
        return ranges
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
        field.placeholderString = Self.jumpPlaceholder
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
            return PaletteCell(item.title, item.detail, item.symbol, item.alert, highlights: item.highlights, monospaced: item.monospaced)
        }
    }

    // MARK: - Keys

    func controlTextDidChange(_: Notification) { filter() }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        // ⌥Return arrives as its own command (Move Pane to… reads ⌥ as "stay").
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            pickSelected(); return true
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
    init(_ title: String, _ detail: String, _ symbol: String, _ alert: Bool, highlights: [NSRange] = [], monospaced: Bool = false) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = alert ? .controlAccentColor : .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        let font: NSFont = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13.5)
        name.font = font
        name.lineBreakMode = monospaced ? .byTruncatingTail : .byTruncatingMiddle
        if !highlights.isEmpty {
            // Matched letters: bold and accent-tinted, the rest as usual.
            let text = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let bold = monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold) : NSFont.systemFont(ofSize: 13.5, weight: .semibold)
            for range in highlights where range.location >= 0 && range.location + range.length <= text.length {
                text.addAttributes([.font: bold, .foregroundColor: NSColor.controlAccentColor], range: range)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = name.lineBreakMode
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            name.attributedStringValue = text
        }
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
