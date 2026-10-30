import AppKit

/// The list under the address bar: a child window, so it can reach past a
/// narrow pane's edge and sit above the web view. It can't become key, so
/// the field keeps the keyboard and a click here never lands on the page.
@MainActor
final class BrowserSuggestionWindow: NSPanel {
    static let rowHeight: CGFloat = 26
    static let minimumWidth: CGFloat = 340

    var onPick: ((BrowserSuggestion) -> Void)?
    private let list = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        list.wantsLayer = true
        list.layer?.cornerRadius = 8
        list.layer?.masksToBounds = true
        list.layer?.borderWidth = 0.5
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `showsReturn`: Return would go to the first row. It's off on a blank
    /// field, where Return does nothing until a row is chosen.
    func show(_ rows: [BrowserSuggestion], selected: Int?, showsReturn: Bool, under anchor: NSView) {
        list.subviews.forEach { $0.removeFromSuperview() }
        let theme = Theme.current
        list.layer?.backgroundColor = theme?.pane.cgColor
        list.layer?.borderColor = theme?.separator.cgColor
        let height = CGFloat(rows.count) * Self.rowHeight + 8
        place(under: anchor, height: height)
        let width = frame.width
        for (index, row) in rows.enumerated() {
            let enter = index == selected || (selected == nil && index == 0 && showsReturn)
            let view = BrowserSuggestionRow(row, returnKey: enter, selected: index == selected)
            view.onPick = { [weak self] in self?.onPick?(row) }
            view.frame = NSRect(x: 4, y: height - 4 - CGFloat(index + 1) * Self.rowHeight, width: width - 8, height: Self.rowHeight)
            list.addSubview(view)
        }
        if let parent = anchor.window, parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    /// Under the address bar, inside the window: a pane at its edge shifts it.
    func place(under anchor: NSView, height: CGFloat? = nil) {
        guard let parent = anchor.window else { return }
        let height = height ?? frame.height
        let box = anchor.convert(anchor.bounds, to: nil)
        let width = min(max(box.width, Self.minimumWidth), parent.frame.width - 16)
        let x = max(8, min(box.minX, parent.frame.width - width - 8))
        let origin = parent.convertPoint(toScreen: NSPoint(x: x, y: box.minY - height - 3))
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

@MainActor
private final class BrowserSuggestionRow: NSView {
    var onPick: (() -> Void)?
    private let selected: Bool
    private var hoverArea: NSTrackingArea?

    init(_ row: BrowserSuggestion, returnKey: Bool, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        let (symbol, label): (String, String) = switch row.kind {
        case .go: ("arrow.right", "Go")
        case .openTab: ("square.on.square", "Open tab")
        case .devServer: ("server.rack", "Dev server")
        case .history: ("clock", "History")
        case .search: ("magnifyingglass", "Search")
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 7, y: 6, width: 14, height: 14)
        addSubview(icon)
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: row.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let enter = NSTextField(labelWithString: returnKey ? "⏎" : "")
        enter.font = .systemFont(ofSize: 11)
        enter.textColor = .tertiaryLabelColor
        stack = [title, detail, enter]
        stack.forEach(addSubview)
        update()
    }

    private var stack: [NSTextField] = []

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width
        let (title, detail, enter) = (stack[0], stack[1], stack[2])
        let right = width - 22
        enter.frame = NSRect(x: right, y: 5, width: 16, height: 15)
        // The detail gets up to 45% of the row; the title has the rest.
        let room = right - 28
        let measured = (detail.stringValue as NSString).size(withAttributes: [.font: detail.font as Any]).width
        let detailWidth = detail.stringValue.isEmpty ? 0 : min(ceil(measured) + 6, room * 0.45)
        detail.isHidden = detailWidth == 0
        detail.frame = NSRect(x: right - detailWidth - 4, y: 5, width: detailWidth, height: 15)
        title.frame = NSRect(x: 28, y: 5, width: room - detailWidth - 8, height: 16)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func mouseDown(with _: NSEvent) { onPick?() }

    private var hovering = false { didSet { update() } }

    private func update() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? Theme.sidebarSelection : hovering ? Theme.sidebarHover : NSColor.clear).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }
}

/// What the address bar offers while you type. It owns the list and the
/// inline completion; the field keeps the focus throughout. Results arrive
/// late, so each is checked against the current text before it's used, and
/// Return always acts on the text in the field, never on a result on its way.
@MainActor
final class BrowserAddressCompleter {
    private weak var pane: BrowserPaneView?
    private let window = BrowserSuggestionWindow()
    private(set) var rows: [BrowserSuggestion] = []
    private(set) var selected: Int?
    /// What was really typed: the field may also hold a completion.
    private var typed = ""
    private var generation = 0

    var history: BrowserHistory = .shared

    init(pane: BrowserPaneView) {
        self.pane = pane
        window.onPick = { [weak self] row in self?.pick(row, newTab: false) }
    }

    var isShowing: Bool { !rows.isEmpty }

    /// The field took focus: a blank one offers this space's pages.
    func began() {
        typed = ""
        guard let pane, pane.activePage.isBlank else { return }
        refresh("", mayComplete: false)
    }

    func textChanged(_ editor: NSTextView) {
        // Mid-composition (Japanese and the like) the text isn't final.
        guard !editor.hasMarkedText() else { return }
        let text = editor.string
        // Only typing forward completes: ⌫ must be able to remove the rest.
        let grew = text.count > typed.count && text.hasPrefix(typed)
        typed = text
        refresh(text, mayComplete: grew)
    }

    private func refresh(_ text: String, mayComplete: Bool) {
        generation += 1
        let current = generation
        selected = nil
        guard let pane else { return }
        var sources = pane.suggestionSources?() ?? .init()
        let machine = pane.machineKey
        let space = pane.spaceName?()
        let history = Settings.browserHistory ? history : nil
        let search = text.hasPrefix(":") ? "localhost" + text : text
        Task { [weak self] in
            sources.history = await history?.search(search, machine: machine, space: space, limit: BrowserSuggestions.maximumRows) ?? []
            guard let self, current == self.generation, let pane = self.pane, pane.isEditingAddress else { return }
            let rows = BrowserSuggestions.typing(text, sources: sources)
            self.show(rows)
            if mayComplete, let editor = pane.address.currentEditor() as? NSTextView { self.complete(editor, text, rows) }
        }
    }

    /// Adds the rest of the top match, selected, so typing replaces it.
    private func complete(_ editor: NSTextView, _ text: String, _ rows: [BrowserSuggestion]) {
        guard editor.string == text, !editor.hasMarkedText(), editor.selectedRange().location == (text as NSString).length,
              let first = rows.first, first.kind == .go,
              let suffix = BrowserSuggestions.completion(for: text, in: [BrowserSuggestion(kind: .history, title: "", detail: "", url: first.url)])
        else { return }
        editor.string = text + suffix
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: (suffix as NSString).length))
    }

    private func show(_ rows: [BrowserSuggestion]) {
        self.rows = rows
        guard let pane, !rows.isEmpty else { return window.dismiss() }
        window.show(rows, selected: selected, showsReturn: !typed.isEmpty, under: pane.addressAnchor)
    }

    func hide() {
        generation += 1
        rows = []
        selected = nil
        typed = ""
        window.dismiss()
    }

    /// ↓ and ↑. Past the top it's back to the text in the field.
    func move(by step: Int) {
        guard !rows.isEmpty else { return }
        let next = (selected ?? -1) + step
        selected = next < 0 ? nil : min(next, rows.count - 1)
        show(rows)
    }

    /// Return. True if a chosen row took it; otherwise the field's text goes.
    func enter(newTab: Bool) -> Bool {
        if let selected, rows.indices.contains(selected) {
            pick(rows[selected], newTab: newTab)
            return true
        }
        guard newTab, let pane else { return false }
        let text = pane.address.stringValue
        hide()
        if let url = BrowserAddress.normalize(text) { pane.openTyped(url, newTab: true) }
        return true
    }

    /// ⌘⌫ on a history row.
    func removeSelected() -> Bool {
        guard let selected, rows.indices.contains(selected), rows[selected].isHistory, let pane else { return false }
        history.remove(url: rows[selected].url.absoluteString, machine: pane.machineKey)
        rows.remove(at: selected)
        self.selected = rows.isEmpty ? nil : min(selected, rows.count - 1)
        show(rows)
        return true
    }

    private func pick(_ row: BrowserSuggestion, newTab: Bool) {
        guard let pane else { return }
        hide()
        if case let .openTab(hostPane, tab) = row.kind {
            pane.leaveAddressBar()
            pane.onShowTab?(hostPane, tab)
        } else {
            pane.openTyped(row.url, newTab: newTab)
        }
    }

    func reposition() {
        if isShowing, let pane { window.place(under: pane.addressAnchor) }
    }
}
