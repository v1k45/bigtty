import AppKit
import HerdrKit

/// The selected workspace's herdr tabs, left to right.
@MainActor
final class TabStripView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNew: (() -> Void)?

    private let stack = NSStackView()
    private let addButton = NSButton()
    private var tabs: [Tab] = []
    private var selectedID: String?

    static let height: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        addSubview(stack)

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addTab)
        addSubview(addButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let fitting = stack.fittingSize
        stack.frame = NSRect(x: 8, y: (bounds.height - fitting.height) / 2, width: fitting.width, height: fitting.height)
        addButton.frame = NSRect(x: stack.frame.maxX + 6, y: (bounds.height - 20) / 2, width: 22, height: 20)
    }

    override func draw(_: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func update(tabs: [Tab], selected: String?) {
        guard tabs != self.tabs || selected != selectedID else { return }
        self.tabs = tabs
        selectedID = selected
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for tab in tabs {
            let button = TabButton(tab: tab, selected: tab.tabID == selected)
            button.onClick = { [weak self] in self?.onSelect?(tab.tabID) }
            button.onClose = { [weak self] in self?.onClose?(tab.tabID) }
            stack.addArrangedSubview(button)
        }
        needsLayout = true
    }

    @objc private func addTab() { onNew?() }
}

private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let selected: Bool

    init(tab: Tab, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil

        label.stringValue = "\(tab.number)  \(tab.label == String(tab.number) ? "" : tab.label)"
            .trimmingCharacters(in: .whitespaces)
        label.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = tab.agentStatus.color?.cgColor
        addSubview(label)
        addSubview(dot)
        toolTip = "Tab \(tab.number): \(tab.label) — \(tab.agentStatus.rawValue)"

        let menu = NSMenu()
        menu.addItem(withTitle: "Close Tab", action: #selector(closeClicked), keyEquivalent: "").target = self
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(label.intrinsicContentSize.width + 28, 44), height: 22)
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 7, y: bounds.midY - 3, width: 6, height: 6)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 18, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func mouseDown(with _: NSEvent) { onClick?() }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked() { onClose?() }
}
