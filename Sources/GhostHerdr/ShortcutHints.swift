import AppKit

// Two ways to learn the keys:
// - Hold ⌘: badges appear on what they reach, in place (cmux-style):
//   ⌘1… on spaces, ⌃1… on tabs, ⌥⌘1… on panes.
// - ⌘/: a sheet of every shortcut, read from the main menu so it always
//   matches it.

/// A key-cap label, e.g. "⌥⌘2", used by the badges and the sheet.
final class KeyCap: NSView {
    private let label = NSTextField(labelWithString: "")

    init(_ text: String, size: CGFloat = 11.5, prominent: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size * 0.45
        layer?.borderWidth = prominent ? 0 : 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = prominent
            ? NSColor.controlAccentColor.cgColor
            : NSColor.labelColor.withAlphaComponent(0.07).cgColor
        label.stringValue = text
        label.font = .systemFont(ofSize: size, weight: prominent ? .bold : .medium)
        label.textColor = prominent ? .white : .labelColor
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: text.width + label.font!.pointSize * 1.1, height: text.height + label.font!.pointSize * 0.45)
    }

    override func layout() {
        super.layout()
        let text = label.intrinsicContentSize
        label.frame = NSRect(x: (bounds.width - text.width) / 2, y: (bounds.height - text.height) / 2,
                             width: text.width, height: text.height)
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The ⌘/ sheet: every shortcut, grouped by menu, in a solid panel.
@MainActor
final class ShortcutSheetView: NSView {
    private let columns = NSStackView()
    private let title = NSTextField(labelWithString: "Keyboard Shortcuts")
    private let footer = NSTextField(labelWithString: "Hold ⌘ to see shortcuts on spaces, tabs and panes · Esc to close")

    /// Columns, in order: the menus each one lists.
    private static let groups: [(String, [String])] = [
        ("General", ["File"]), ("Panes", ["Pane"]), ("Navigate", ["Go"]), ("View & Window", ["View", "Window"]),
    ]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        for view in [title, columns, footer] as [NSView] { addSubview(view) }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func mouseDown(with _: NSEvent) { onDismiss?() }
    var onDismiss: (() -> Void)?

    /// Rebuilds from the current menu; returns its size.
    func reload() -> NSSize {
        layer?.backgroundColor = (Theme.current?.cardStrong ?? .windowBackgroundColor).withAlphaComponent(0.98).cgColor
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let main = NSApp.mainMenu else { return .zero }
        for (name, menus) in Self.groups {
            let rows = menus.compactMap { menu in main.items.first(where: { $0.title == menu })?.submenu }
                .flatMap { ShortcutSheetView.shortcuts(in: $0) }
            guard !rows.isEmpty else { continue }
            columns.addArrangedSubview(column(name, rows))
        }
        let body = columns.fittingSize
        let width = max(body.width, title.intrinsicContentSize.width, footer.intrinsicContentSize.width) + 56
        let height = body.height + 118
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        let b = bounds
        title.frame = NSRect(x: 28, y: b.height - 48, width: b.width - 56, height: 20)
        let body = columns.fittingSize
        columns.frame = NSRect(x: 28, y: 48, width: body.width, height: body.height)
        footer.frame = NSRect(x: 28, y: 20, width: b.width - 56, height: 15)
    }

    private func column(_ name: String, _ rows: [(String, String)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        let header = NSTextField(labelWithString: name.uppercased())
        header.font = .systemFont(ofSize: 10.5, weight: .semibold)
        header.textColor = .secondaryLabelColor
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(10, after: header)
        for (label, keys) in rows {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 12.5)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let cap = KeyCap(keys)
            cap.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [text, cap])
            row.spacing = 16
            row.distribution = .fill // label stretches; key caps line up on the right
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
            stack.addArrangedSubview(row)
        }
        return stack
    }

    /// Visible items with a key equivalent; numbered runs ("Space 1…9",
    /// a "Pane" submenu) collapse into one row.
    static func shortcuts(in menu: NSMenu) -> [(String, String)] {
        var rows: [(String, String)] = []
        var numbered: [(String, [NSMenuItem])] = []
        for item in menu.items where !item.isHidden && !item.isSeparatorItem && !skipped(item) {
            if let submenu = item.submenu {
                let inner = submenu.items.filter { !$0.keyEquivalent.isEmpty }
                if let first = inner.first, let last = inner.last, inner.count > 2 {
                    rows.append(("\(item.title) 1–\(inner.count)", keys(first) + "…" + last.keyEquivalent.uppercased()))
                }
                continue
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            if let range = item.title.range(of: #" \d$"#, options: .regularExpression) {
                let name = String(item.title[..<range.lowerBound])
                if let index = numbered.firstIndex(where: { $0.0 == name }) { numbered[index].1.append(item) } else { numbered.append((name, [item])) }
                continue
            }
            rows.append((item.title, keys(item)))
        }
        for (name, items) in numbered {
            guard let first = items.first, let last = items.last else { continue }
            rows.append(("\(name) 1–\(items.count)", keys(first) + "…" + last.keyEquivalent.uppercased()))
        }
        return rows
    }

    /// Items macOS adds to the Window menu (tiling, Fill, fn-F full screen).
    private static func skipped(_ item: NSMenuItem) -> Bool {
        if item.keyEquivalentModifierMask.contains(.function) { return true }
        let system: Set<String> = ["Fill", "Center", "Minimize All", "Close All", "Toggle Full Screen", "Enter Full Screen", "Exit Full Screen", "Move & Resize", "Full Screen Tile"]
        return system.contains(item.title)
    }

    static func keys(_ item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let key = item.keyEquivalent
        let names: [String: String] = [
            "\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "⎋",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
        ]
        return text + (names[key] ?? key.uppercased())
    }
}

/// Watches ⌘ held on its own: after a moment, the badges show.
@MainActor
final class ShortcutHintTrigger {
    static let delay: TimeInterval = 0.4
    private var timer: Timer?
    private(set) var showing = false
    var onChange: ((Bool) -> Void)?

    /// Feed every event the window sees; never consumes it.
    func observe(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command { arm() } else if !flags.contains(.command) { hide() } else { cancelTimer() }
        case .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel:
            cancelTimer()
            // With ⌘ still held the badges stay, so ⌥⌘2 can be read and typed.
            if event.type != .keyDown { hide() }
        default:
            break
        }
    }

    private func arm() {
        cancelTimer()
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return }
                self.showing = true
                self.onChange?(true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    func hide() {
        cancelTimer()
        guard showing else { return }
        showing = false
        onChange?(false)
    }
}
