import AppKit
import HerdrKit

extension NSPasteboard.PasteboardType {
    /// A pane being dragged: "machineID|paneID".
    static let ghostherdrPane = NSPasteboard.PasteboardType("dev.ghostherdr.pane")
}

/// What a pane drag carries.
struct PaneDragPayload: Equatable {
    let machineID: String
    let paneID: String

    var string: String { machineID + "|" + paneID }

    init(machineID: String, paneID: String) {
        self.machineID = machineID
        self.paneID = paneID
    }

    init?(_ pasteboard: NSPasteboard) {
        guard let text = pasteboard.string(forType: .ghostherdrPane) else { return nil }
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        self.init(machineID: parts[0], paneID: parts[1])
    }
}

extension HerdrClient.DropZone {
    /// The zone under `point`: the middle swaps, otherwise the nearest edge.
    static func at(_ point: NSPoint, in bounds: NSRect) -> Self {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        if (0.3...0.7).contains(x), (0.3...0.7).contains(y) { return .center }
        let distances: [(Self, CGFloat)] = [(.left, x), (.right, 1 - x), (.bottom, y), (.top, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The part of the pane the dropped pane will take.
    func highlight(in bounds: NSRect) -> NSRect {
        switch self {
        case .left: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .right: NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .top: NSRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        case .bottom: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
        case .center: bounds.insetBy(dx: bounds.width * 0.12, dy: bounds.height * 0.12)
        }
    }
}

/// The band along a pane's top edge, with a pill shown on hover: drag it
/// onto another pane to split beside it (edges) or swap (middle).
final class PaneGrip: NSView, NSDraggingSource {
    var payload: (() -> PaneDragPayload?)?
    var title: (() -> String)?
    /// This pane's drag started (true) or ended (false).
    var onDragChange: ((Bool) -> Void)?
    private var downEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        toolTip = "Drag to move this pane"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    static let size = NSSize(width: 44, height: 12)
    /// Height of the grabbable band along the pane's top edge.
    static let bandHeight: CGFloat = 10

    /// Draw the pill (hover); the band is grabbable either way.
    var showsPill = false {
        didSet { if showsPill != oldValue { needsDisplay = true } }
    }

    /// The pane's content, whose controls keep their clicks under the band.
    weak var content: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let content, let superview {
            let under = content.hitTest(content.superview?.convert(point, from: superview) ?? point)
            let label = (under as? NSTextField).map { !$0.isEditable && !$0.isSelectable } ?? false
            if (under is NSControl && !label) || under is NSTextView { return nil }
        }
        return hit
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func draw(_: NSRect) {
        guard showsPill else { return }
        let size = Self.size
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 1, width: size.width, height: size.height)
        let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        (Theme.current?.cardStrong ?? .controlBackgroundColor).setFill()
        pill.fill()
        NSColor.separatorColor.setStroke()
        pill.lineWidth = 0.5
        pill.stroke()
        // Two rows of three dots.
        NSColor.secondaryLabelColor.setFill()
        for row in 0..<2 {
            for column in 0..<3 {
                let x = rect.midX - 6 + CGFloat(column) * 6 - 1
                let y = rect.midY - 2.5 + CGFloat(row) * 4 - 1
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
            }
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let payload = payload?() else { return }
        downEvent = nil
        let item = NSPasteboardItem()
        item.setString(payload.string, forType: .ghostherdrPane)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = Self.dragImage(title: title?() ?? "Pane")
        let origin = convert(down.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(x: origin.x - image.size.width / 2, y: origin.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        beginDraggingSession(with: [dragging], event: down, source: self)
        onDragChange?(true)
        NotificationCenter.default.post(name: .ghostherdrPaneDrag, object: true)
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation { .move }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        onDragChange?(false)
        NotificationCenter.default.post(name: .ghostherdrPaneDrag, object: false)
    }

    /// A small card with the pane's name, what the pointer carries.
    private static func dragImage(title: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let width = min(260, max(120, text.size().width + 28))
        return NSImage(size: NSSize(width: width, height: 34), flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            (Theme.current?.cardStrong ?? .windowBackgroundColor).withAlphaComponent(0.95).setFill()
            card.fill()
            NSColor.controlAccentColor.setStroke()
            card.lineWidth = 1.5
            card.stroke()
            text.draw(at: NSPoint(x: 14, y: (rect.height - text.size().height) / 2))
            return true
        }
    }
}

extension Notification.Name {
    /// A pane drag began (object true) or ended (false).
    static let ghostherdrPaneDrag = Notification.Name("GhostHerdrPaneDrag")
}

/// Covers the whole pane area (gaps and margins too) while a pane is
/// dragged: terminals, web and text views would otherwise take the drop,
/// and gaps would drop nothing. The window controller resolves targets.
final class DropSurface: NSView {
    var hover: ((PaneDragPayload, NSPoint) -> Bool)?
    var commit: ((PaneDragPayload, NSPoint) -> Bool)?
    var exit: (() -> Void)?
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.ghostherdrPane])
        isHidden = true
        observer = NotificationCenter.default.addObserver(forName: .ghostherdrPaneDrag, object: nil, queue: .main) { [weak self] note in
            let active = note.object as? Bool ?? false
            MainActor.assumeIsolated {
                self?.isHidden = !active
                if !active { self?.exit?() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = PaneDragPayload(sender.draggingPasteboard),
              hover?(payload, sender.draggingLocation) == true else { return [] }
        return .move
    }

    override func draggingExited(_: NSDraggingInfo?) { exit?() }
    override func draggingEnded(_: NSDraggingInfo) { exit?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = PaneDragPayload(sender.draggingPasteboard) else { return false }
        return commit?(payload, sender.draggingLocation) ?? false
    }
}

/// Shows where a dropped pane will land.
final class DropHighlight: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.5
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    func show(_ rect: NSRect) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        // Follows the pointer at once; an animated hint trails behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect.insetBy(dx: 4, dy: 4)
        CATransaction.commit()
        isHidden = false
    }

    func hide() { isHidden = true }
}
