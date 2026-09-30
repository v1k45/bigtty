import AppKit
import HerdrKit

/// What the sidebar shows, built by the window controller.
struct SidebarModel: Equatable {
    struct Tab: Equatable {
        let id: String
        let label: String
        let detail: String
        let selected: Bool
        let alert: Bool
        var audible = false
        /// Its shortcut, shown while ⌘ is held.
        var hint: String? = nil
    }

    struct Space: Equatable {
        let id: String
        let name: String
        let shortcut: String
        let meta: String
        let ports: [Int]
        let line: String?
        let alert: Bool
        let finished: Bool
        let selected: Bool
        let tabs: [Tab]
        /// ⌘ held: the shortcut stands out.
        var hinting = false
        var audible = false
    }

    /// This Mac's session switcher.
    struct SessionChip: Equatable {
        let name: String
        /// Panes in this Mac's other sessions that need you.
        let othersNeedingYou: Int
    }

    struct Machine: Equatable {
        let id: String
        let name: String
        let status: String
        let statusIsProblem: Bool
        var statusTip: String? = nil
        /// Set for this Mac: its header switches sessions.
        var session: SessionChip? = nil
        let spaces: [Space]
    }

    var machines: [Machine] = []
    var message: String?
}

/// The native sidebar: machines, their spaces as cards, and the selected
/// space's tabs. Plain AppKit views laid out top to bottom.
@MainActor
final class SidebarView: NSView {
    var onSelectSpace: ((String) -> Void)?
    var onSelectTab: ((String, String) -> Void)?
    var onSpaceMenu: ((String) -> NSMenu?)?
    var onNewSpace: (() -> Void)?
    var onMachineClick: ((String) -> Void)?
    var onConnectMachine: (() -> Void)?
    var onSessionMenu: (() -> NSMenu?)?

    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let connectButton = FooterButton(title: "Connect Machine…", symbol: "server.rack", shortcut: "⌥⌘K")
    private let newButton = FooterButton(title: "New Space", symbol: "plus", shortcut: "⌘N")
    private let footerLine = NSView()
    private let brand = BrandMark()
    private var model = SidebarModel()
    private var selectedID: String?

    static let titlebarHeight: CGFloat = 40

    /// No traffic lights in full screen: the brand takes their corner.
    var fullScreen = false { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
        footerLine.wantsLayer = true
        addSubview(footerLine)
        connectButton.target = self
        connectButton.action = #selector(connectClicked)
        newButton.target = self
        newButton.action = #selector(newClicked)
        addSubview(connectButton)
        addSubview(newButton)
        addSubview(brand)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let footer: CGFloat = 68
        scroll.frame = NSRect(x: 0, y: footer, width: b.width, height: max(0, b.height - footer - Self.titlebarHeight))
        footerLine.frame = NSRect(x: 0, y: footer - 0.5, width: b.width, height: 0.5)
        footerLine.layer?.backgroundColor = Theme.current?.separator.cgColor
        connectButton.frame = NSRect(x: 8, y: 34, width: b.width - 16, height: 30)
        newButton.frame = NSRect(x: 8, y: 4, width: b.width - 16, height: 30)
        // Right of the traffic lights, in the title strip.
        let mark = brand.fittingSize
        brand.frame = NSRect(x: fullScreen ? 18 : b.width - mark.width - 14,
                             y: b.height - Self.titlebarHeight + (Self.titlebarHeight - mark.height) / 2 + 2,
                             width: mark.width, height: mark.height)
        brand.isHidden = b.width < 170 && !fullScreen
        layoutList()
    }

    func update(_ model: SidebarModel) {
        guard model != self.model else { return }
        self.model = model
        rebuild()
        // A newly selected space (⌘N, ⌘K, a notification…) scrolls into view.
        let selected = model.machines.flatMap(\.spaces).first { $0.selected }?.id
        if selected != selectedID {
            selectedID = selected
            revealSelected()
        }
    }

    private func revealSelected() {
        guard let card = list.subviews.compactMap({ $0 as? SpaceCard }).first(where: { $0.space.selected }) else { return }
        layoutSubtreeIfNeeded()
        let frame = card.frame.insetBy(dx: 0, dy: -12)
        let visible = scroll.contentView.documentVisibleRect
        guard !visible.contains(frame) else { return }
        // Just enough to show it, with a little context around.
        let y = frame.minY < visible.minY ? frame.minY : frame.maxY - visible.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: max(0, y)))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Re-applies theme colors (appearance changes).
    func refreshTheme() {
        rebuild()
        needsLayout = true
    }

    private func rebuild() {
        list.subviews.forEach { $0.removeFromSuperview() }
        for machine in model.machines {
            let header = MachineHeader(machine: machine)
            header.onClick = { [weak self, weak header] in
                guard let self else { return }
                if machine.session != nil, let header { self.popUpSessionMenu(under: header) } else { self.onMachineClick?(machine.id) }
            }
            list.addSubview(header)
            if let message = model.message, machine == model.machines.first {
                list.addSubview(MessageRow(text: message))
            }
            for space in machine.spaces {
                let card = SpaceCard(space: space)
                card.onClick = { [weak self] in self?.onSelectSpace?(space.id) }
                card.onTab = { [weak self] tab in self?.onSelectTab?(space.id, tab) }
                card.menuProvider = { [weak self] in self?.onSpaceMenu?(space.id) }
                list.addSubview(card)
            }
        }
        layoutList()
    }

    private func layoutList() {
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        for view in list.subviews {
            let height = (view as? SidebarRow)?.height(forWidth: width - 16) ?? 24
            view.frame = NSRect(x: 8, y: y, width: width - 16, height: height)
            y += height + 3
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentSize.height))
    }

    /// Opens the session switcher under this Mac's header; false if the
    /// header isn't there.
    @discardableResult
    func popUpSessionMenu() -> Bool {
        guard let header = list.subviews.compactMap({ $0 as? MachineHeader }).first(where: \.isSessionSwitcher) else { return false }
        header.scrollToVisible(header.bounds)
        popUpSessionMenu(under: header)
        return true
    }

    private func popUpSessionMenu(under header: MachineHeader) {
        guard let menu = onSessionMenu?() else { return }
        header.pressed = true
        menu.popUp(positioning: nil, at: NSPoint(x: 6, y: header.bounds.maxY + 2), in: header)
        header.pressed = false
    }

    @objc private func connectClicked() { onConnectMachine?() }
    @objc private func newClicked() { onNewSpace?() }
}

/// App icon and name, quiet, in the sidebar's title strip.
private final class BrandMark: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "GhostHerdr")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .secondaryLabelColor
        addSubview(icon)
        addSubview(name)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // Title-strip behavior (drag, double-click to zoom) stays the window's.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override var fittingSize: NSSize {
        NSSize(width: 18 + 5 + ceil(name.intrinsicContentSize.width) + 4, height: 18)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 0, width: 18, height: 18)
        let text = name.intrinsicContentSize
        name.frame = NSRect(x: 23, y: (bounds.height - text.height) / 2, width: ceil(text.width) + 4, height: text.height)
    }
}

// MARK: - Rows

@MainActor
private protocol SidebarRow: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class MessageRow: NSView, SidebarRow {
    private let label = NSTextField(wrappingLabelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.isSelectable = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func height(forWidth width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width - 20
        return label.fittingSize.height + 12
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 6)
    }
}

private final class MachineHeader: NSView, SidebarRow {
    // The window drags by its background; rows and cards must take the
    // click instead, over their whole area, even in an inactive window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var onClick: (() -> Void)?
    private let isProblem: Bool
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    /// This Mac's session: name, chevron, and a badge for the others.
    private let chip = NSView()
    private let chipLabel = NSTextField(labelWithString: "")
    private let chipChevron = NSImageView()
    private let chipBadge = NSTextField(labelWithString: "")
    let isSessionSwitcher: Bool
    private var hovering = false { didSet { updateChip() } }
    var pressed = false { didSet { updateChip() } }

    init(machine: SidebarModel.Machine) {
        isProblem = machine.statusIsProblem || machine.status.contains("not running")
        isSessionSwitcher = machine.session != nil
        super.init(frame: .zero)
        toolTip = isProblem ? "Click for details" : nil
        icon.image = NSImage(systemSymbolName: machine.name == "This Mac" ? "laptopcomputer" : "server.rack", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        name.stringValue = machine.name
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = .secondaryLabelColor
        status.stringValue = machine.status
        toolTip = machine.statusTip
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = machine.statusIsProblem ? .systemOrange : .secondaryLabelColor
        status.alignment = .right
        for view in [icon, name, status] { addSubview(view) }
        if let session = machine.session {
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 6
            chipLabel.stringValue = session.name
            chipLabel.font = .systemFont(ofSize: 11, weight: .medium)
            chipLabel.textColor = .labelColor
            chipLabel.lineBreakMode = .byTruncatingTail
            chipChevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Switch session")
            chipChevron.symbolConfiguration = .init(pointSize: 8.5, weight: .semibold)
            chipChevron.contentTintColor = .secondaryLabelColor
            chipBadge.stringValue = "\(session.othersNeedingYou)"
            chipBadge.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
            chipBadge.textColor = .white
            chipBadge.alignment = .center
            chipBadge.wantsLayer = true
            chipBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            chipBadge.layer?.cornerRadius = 7
            chipBadge.isHidden = session.othersNeedingYou == 0
            for view in [chipLabel, chipChevron, chipBadge] as [NSView] { chip.addSubview(view) }
            addSubview(chip)
            toolTip = session.othersNeedingYou > 0
                ? "Session “\(session.name)” · \(session.othersNeedingYou) waiting in other sessions · ⇧⌘S to switch"
                : "Session “\(session.name)” · click or ⇧⌘S to switch sessions"
            updateChip()
        }
    }

    private func updateChip() {
        guard isSessionSwitcher else { return }
        let alpha: CGFloat = pressed ? 0.16 : hovering ? 0.11 : 0.06
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard isSessionSwitcher else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func height(forWidth _: CGFloat) -> CGFloat { 30 }

    override func mouseDown(with _: NSEvent) { onClick?() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 10, width: 14, height: 14)
        let nameWidth = min(ceil(name.intrinsicContentSize.width) + 2, bounds.width * 0.5)
        name.frame = NSRect(x: 29, y: 10, width: nameWidth, height: 15)
        let statusX = 29 + nameWidth + 8
        var right = bounds.width - 4
        if isSessionSwitcher {
            let badge = chipBadge.isHidden ? 0 : max(14, ceil(chipBadge.intrinsicContentSize.width) + 8)
            let text = min(ceil(chipLabel.intrinsicContentSize.width) + 6, max(30, bounds.width * 0.45))
            let width = 8 + text + 4 + 9 + (badge > 0 ? 5 + badge : 0) + 7
            chip.frame = NSRect(x: bounds.width - 4 - width, y: 6, width: width, height: 22)
            chipLabel.frame = NSRect(x: 8, y: 3.5, width: text, height: 15)
            chipChevron.frame = NSRect(x: 8 + text + 4, y: 6, width: 9, height: 10)
            chipBadge.frame = NSRect(x: 8 + text + 4 + 9 + 5, y: 4, width: badge, height: 14)
            right = chip.frame.minX - 6
        } else {
            right = bounds.width - 10
        }
        status.frame = NSRect(x: statusX, y: 10, width: max(0, right - statusX), height: 15)
        status.lineBreakMode = .byTruncatingHead
    }
}

/// One space: name, shortcut, branch and folder, ports and the agent line;
/// the selected space also lists its tabs.
private final class SpaceCard: NSView, SidebarRow {
    // The window drags by its background; rows and cards must take the
    // click instead, over their whole area, even in an inactive window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// The whole card is one button (labels must not take the click or
    /// show a text cursor); only its tab rows are separate.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is TabRow { return current }
            view = current.superview
        }
        return self
    }

    let space: SidebarModel.Space
    var onClick: (() -> Void)?
    var onTab: ((String) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let speaker = NSImageView()
    private let meta = NSTextField(labelWithString: "")
    private let line = NSTextField(wrappingLabelWithString: "")
    private var chips: [NSTextField] = []
    private var tabRows: [TabRow] = []
    private var hovering = false { didSet { updateBackground() } }

    init(space: SidebarModel.Space) {
        self.space = space
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = space.alert ? NSColor.controlAccentColor.cgColor : NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        dot.isHidden = !(space.alert || space.finished)

        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing audio")
        speaker.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        speaker.contentTintColor = .controlAccentColor
        speaker.isHidden = !space.audible
        addSubview(speaker)
        name.stringValue = space.name
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        shortcut.stringValue = space.shortcut
        shortcut.font = .systemFont(ofSize: 11, weight: space.hinting ? .bold : .regular)
        shortcut.textColor = space.hinting ? .controlAccentColor : .tertiaryLabelColor
        shortcut.alignment = .right
        meta.stringValue = space.meta
        meta.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingMiddle
        line.stringValue = space.line ?? ""
        line.font = .systemFont(ofSize: 11.5)
        line.textColor = space.alert ? NSColor.controlAccentColor.blended(withFraction: 0.35, of: .labelColor) : .secondaryLabelColor
        line.maximumNumberOfLines = space.alert ? 2 : 1
        line.lineBreakMode = .byTruncatingTail
        line.isHidden = space.line == nil
        line.isSelectable = false
        for view in [dot, name, shortcut, meta, line] { addSubview(view) }

        for port in space.ports.prefix(3) {
            let chip = NSTextField(labelWithString: ":\(port)")
            chip.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            chip.textColor = .secondaryLabelColor
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 4
            effectiveAppearance.performAsCurrentDrawingAppearance {
                chip.layer?.backgroundColor = Theme.sidebarRow.cgColor
            }
            chip.alignment = .center
            chips.append(chip)
            addSubview(chip)
        }
        for tab in space.tabs {
            let row = TabRow(tab: tab)
            row.onClick = { [weak self] in self?.onTab?(tab.id) }
            tabRows.append(row)
            addSubview(row)
        }
        updateBackground()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(space.name), \(space.line ?? "")")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func updateBackground() {
        let theme = Theme.current
        if space.alert {
            layer?.backgroundColor = theme?.accentWash.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = theme?.accentLine.cgColor
        } else {
            layer?.borderWidth = 0
            let fill = space.selected ? Theme.sidebarSelection : hovering ? Theme.sidebarHover : nil
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = fill?.cgColor
            }
        }
    }

    private var lineHeight: CGFloat {
        guard !line.isHidden else { return 0 }
        return space.alert ? 30 : 15
    }

    func height(forWidth _: CGFloat) -> CGFloat {
        var h: CGFloat = 8 + 17 + 16
        if !line.isHidden || !chips.isEmpty { h += 3 + max(lineHeight, chips.isEmpty ? 0 : 16) }
        if !tabRows.isEmpty { h += 6 + CGFloat(tabRows.count) * 23 }
        return h + 9
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var x: CGFloat = 10
        if !dot.isHidden {
            dot.frame = NSRect(x: 10, y: 13, width: 7, height: 7)
            x = 23
        }
        name.frame = NSRect(x: x, y: 8, width: w - x - (space.audible ? 58 : 40), height: 17)
        shortcut.frame = NSRect(x: w - 42, y: 9, width: 32, height: 15)
        speaker.frame = NSRect(x: w - 58, y: 10, width: 14, height: 13)
        meta.frame = NSRect(x: 10, y: 26, width: w - 20, height: 15)
        var y: CGFloat = 44
        var lx: CGFloat = 10
        for chip in chips {
            let cw = chip.intrinsicContentSize.width + 10
            chip.frame = NSRect(x: lx, y: y, width: cw, height: 16)
            lx += cw + 5
        }
        if !line.isHidden {
            line.frame = NSRect(x: lx, y: y, width: w - lx - 10, height: lineHeight)
        }
        if !line.isHidden || !chips.isEmpty { y += max(lineHeight, chips.isEmpty ? 0 : 16) + 3 }
        y += 3
        for row in tabRows {
            row.frame = NSRect(x: 6, y: y, width: w - 12, height: 22)
            y += 23
        }
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if tabRows.contains(where: { $0.frame.contains(point) }) { return super.mouseDown(with: event) }
        onClick?()
    }

    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
}

private final class TabRow: NSView {
    // The window drags by its background; rows and cards must take the
    // click instead, over their whole area, even in an inactive window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(tab: SidebarModel.Tab) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tab.selected ? Theme.sidebarRow.cgColor : nil
        }
        icon.image = NSImage(systemSymbolName: tab.audible ? "speaker.wave.2.fill" : "terminal", accessibilityDescription: tab.audible ? "Playing audio" : nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.contentTintColor = tab.audible ? .controlAccentColor : tab.selected ? .labelColor : .secondaryLabelColor
        label.stringValue = tab.label
        label.font = .systemFont(ofSize: 12)
        label.textColor = tab.selected ? .labelColor : .secondaryLabelColor
        detail.stringValue = tab.hint ?? tab.detail
        if tab.hint != nil {
            detail.font = .systemFont(ofSize: 11, weight: .bold)
            detail.textColor = .controlAccentColor
        }
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = tab.alert ? .controlAccentColor : .secondaryLabelColor
        detail.alignment = .right
        for view in [icon, label, detail] { addSubview(view) }
        setAccessibilityRole(.button)
        setAccessibilityLabel("Tab \(tab.label)")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 6, y: (h - 12) / 2, width: 13, height: 12)
        label.frame = NSRect(x: 24, y: (h - 15) / 2, width: bounds.width - 110, height: 15)
        detail.frame = NSRect(x: bounds.width - 88, y: (h - 14) / 2, width: 82, height: 14)
    }

    override func mouseDown(with _: NSEvent) { onClick?() }
}

private final class FooterButton: NSButton {
    private let keyLabel = NSTextField(labelWithString: "")

    init(title: String, symbol: String, shortcut: String) {
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        contentTintColor = .secondaryLabelColor
        imagePosition = .imageLeading
        alignment = .left
        keyLabel.stringValue = shortcut
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.alignment = .right
        addSubview(keyLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        keyLabel.frame = NSRect(x: bounds.width - 50, y: (bounds.height - 15) / 2, width: 40, height: 15)
    }
}
