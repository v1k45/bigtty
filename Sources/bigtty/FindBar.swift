import AppKit

/// What a find bar reports: "3 of 12", "No matches" and so on.
enum FindStatus: Equatable {
    case idle
    /// `current` is 0-based, or nil when the matches are counted but none
    /// is selected yet.
    case matches(current: Int?, total: Int)
    case unavailable(String)

    var label: String {
        switch self {
        case .idle: ""
        case let .matches(_, total) where total == 0: "No matches"
        case let .matches(current?, total): "\(current + 1) of \(total)"
        case let .matches(nil, total): total == 1 ? "1 match" : "\(total) matches"
        case let .unavailable(reason): reason
        }
    }
}

/// A pane's side of ⌘F: the terminal searches herdr's scrollback, the
/// browser the page, the files pane the open file. The bar is the same.
@MainActor protocol FindDriver: AnyObject {
    /// Called with every new status.
    var onFindStatus: ((FindStatus) -> Void)? { get set }
    /// Points between the content's top edge and the bar (toolbars).
    var findBarInset: CGFloat { get }
    /// "Next" goes up: a terminal starts at the newest match and Return
    /// walks back through older output, as in other terminals.
    var findsUpward: Bool { get }
    /// What gets focus back when the bar closes.
    var findFocusView: NSView { get }
    /// Searches for `query` (empty clears), selecting the nearest match.
    func find(_ query: String)
    func findNext(backwards: Bool)
    /// Clears highlights.
    func endFind()
    /// Selected text, for Use Selection for Find (⌘E).
    func selectionForFind(_ done: @escaping (String?) -> Void)
}

/// The floating find bar, top right of a pane: field, "3 of 12", ↑ ↓, ×.
/// Return / ⌘G find the next match, ⇧Return / ⇧⌘G the previous one, Esc
/// closes.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    /// Shared across panes, like the system find pasteboard: ⌘G in a pane
    /// that hasn't searched yet looks for the last thing searched anywhere.
    static var lastQuery = ""

    weak var driver: FindDriver?
    var onClose: (() -> Void)?

    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let up = NSButton()
    private let down = NSButton()
    private let close = NSButton()

    static let height: CGFloat = 30
    static let width: CGFloat = 330

    init(driver: FindDriver) {
        self.driver = driver
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            return shadow
        }()

        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .small
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(queryChanged)
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.lineBreakMode = .byTruncatingHead
        let upward = driver.findsUpward
        configure(up, "chevron.up", upward ? "Next Match (⌘G)" : "Previous Match (⇧⌘G)", #selector(upClicked))
        configure(down, "chevron.down", upward ? "Previous Match (⇧⌘G)" : "Next Match (⌘G)", #selector(downClicked))
        configure(close, "xmark", "Done (Esc)", #selector(closeClicked))
        for view in [field, count, up, down, close] as [NSView] { addSubview(view) }

        driver.onFindStatus = { [weak self] status in self?.show(status) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.target = self
        button.action = action
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = (Theme.current?.cardStrong ?? .windowBackgroundColor).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        let b = bounds
        let buttonY = (b.height - 22) / 2
        close.frame = NSRect(x: b.width - 26, y: buttonY, width: 22, height: 22)
        down.frame = NSRect(x: close.frame.minX - 24, y: buttonY, width: 22, height: 22)
        up.frame = NSRect(x: down.frame.minX - 22, y: buttonY, width: 22, height: 22)
        let countWidth: CGFloat = count.stringValue.isEmpty ? 0 : min(110, count.intrinsicContentSize.width + 4)
        count.frame = NSRect(x: up.frame.minX - countWidth - 4, y: (b.height - 15) / 2, width: countWidth, height: 15)
        let fieldX: CGFloat = 6
        field.frame = NSRect(x: fieldX, y: (b.height - 22) / 2, width: max(40, count.frame.minX - fieldX - 6), height: 22)
    }

    /// Focuses the field with its text selected, ready to type over.
    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func search() {
        Self.lastQuery = query
        driver?.find(query)
    }

    func findNext(backwards: Bool) {
        guard !query.isEmpty else { return }
        Self.lastQuery = query
        driver?.findNext(backwards: backwards)
    }

    private func show(_ status: FindStatus) {
        count.stringValue = status.label
        switch status {
        case .matches(_, 0): count.textColor = .systemRed
        case .unavailable: count.textColor = .tertiaryLabelColor
        default: count.textColor = .secondaryLabelColor
        }
        needsLayout = true
    }

    @objc private func queryChanged() { search() }
    @objc private func upClicked() { findNext(backwards: !(driver?.findsUpward ?? false)) }
    @objc private func downClicked() { findNext(backwards: driver?.findsUpward ?? false) }
    @objc private func closeClicked() { onClose?() }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            findNext(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            findNext(backwards: true)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    /// ⌘G / ⇧⌘G while typing: the field editor would claim them first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, field.currentEditor() != nil,
           event.charactersIgnoringModifiers?.lowercased() == "g", flags == .command || flags == [.command, .shift]
        {
            findNext(backwards: flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clicks on the bar stay on it.
    override func mouseDown(with _: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Plain-text search for the file viewer: every case- and
/// diacritic-insensitive occurrence, up to `limit`.
enum TextSearch {
    static func ranges(of query: String, in text: NSString, limit: Int = 10000) -> [NSRange] {
        guard !query.isEmpty, text.length > 0 else { return [] }
        var found: [NSRange] = []
        var location = 0
        while location < text.length, found.count < limit {
            let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound, range.length > 0 else { break }
            found.append(range)
            location = NSMaxRange(range)
        }
        return found
    }

    /// The first match at or after `location`, wrapping to the first.
    static func index(after location: Int, in ranges: [NSRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        return ranges.firstIndex { $0.location >= location } ?? 0
    }
}
