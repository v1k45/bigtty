import AppKit

/// The address field. It shows a short, coloured address at rest and the
/// exact URL once focused; the first click selects it all, the next places
/// the caret (that click reaches the field editor, not this view).
final class AddressField: NSTextField {
    /// About to take the keyboard: the moment to swap in the full URL.
    var onBeginFocus: (() -> Void)?
    /// The field editor let go of the keyboard.
    var onEndFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        onBeginFocus?()
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        guard currentEditor() == nil else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onEndFocus?()
    }
}

/// The rounded box around the field: a click on its padding focuses it.
final class AddressBox: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with _: NSEvent) { onClick?() }
}

/// ‹ and ›: a click steps, a right-click lists where that leads.
final class HistoryButton: NSButton {
    var historyMenu: (() -> NSMenu?)?

    override func menu(for _: NSEvent) -> NSMenu? { historyMenu?() }
}

/// The options menu's Zoom row: − 110% +, keeping the menu open between clicks.
final class ZoomMenuRow: NSView {
    private let label = NSTextField(labelWithString: "Zoom")
    private let value = NSTextField(labelWithString: "")
    private let smaller = NSButton()
    private let bigger = NSButton()
    private let onStep: (Int) -> Int

    /// `onStep` takes -1, 0 (actual size) or 1 and returns the new percent.
    init(percent: Int, onStep: @escaping (Int) -> Int) {
        self.onStep = onStep
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        label.font = .menuFont(ofSize: 0)
        value.font = .menuFont(ofSize: 0)
        value.alignment = .center
        value.textColor = .secondaryLabelColor
        value.toolTip = "Actual Size (⌘0)"
        value.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(reset)))
        for (button, symbol, name, action) in [
            (smaller, "minus", "Zoom Out (⌘−)", #selector(zoomOut)), (bigger, "plus", "Zoom In (⌘+)", #selector(zoomIn)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            button.isBordered = false
            button.toolTip = name
            button.target = self
            button.action = action
        }
        for view in [label, value, smaller, bigger] as [NSView] { addSubview(view) }
        show(percent)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y = (bounds.height - 16) / 2
        label.frame = NSRect(x: 20, y: y, width: 70, height: 16)
        bigger.frame = NSRect(x: bounds.width - 38, y: bounds.midY - 10, width: 24, height: 20)
        value.frame = NSRect(x: bounds.width - 88, y: y, width: 50, height: 16)
        smaller.frame = NSRect(x: bounds.width - 112, y: bounds.midY - 10, width: 24, height: 20)
    }

    private func show(_ percent: Int) { value.stringValue = "\(percent)%" }

    @objc private func zoomOut() { show(onStep(-1)) }
    @objc private func zoomIn() { show(onStep(1)) }
    @objc private func reset() { show(onStep(0)) }
}
