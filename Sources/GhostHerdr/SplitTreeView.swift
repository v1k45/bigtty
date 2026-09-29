import AppKit
import HerdrKit

/// Lays out a herdr split tree. Leaves come from `paneView(for:)`, which the
/// window controller caches so terminals survive layout changes.
@MainActor
final class SplitTreeView: NSView {
    var paneView: (String) -> NSView? = { _ in nil }
    /// A divider drag ended: `path` walks from the root (false = first child).
    var onRatioChange: ((_ path: [Bool], _ ratio: Double) -> Void)?

    private var root: LayoutNode?
    private var zoomedPane: String?

    func show(_ layout: LayoutNode?, zoomedPane: String?) {
        guard layout != root || zoomedPane != self.zoomedPane || subviews.isEmpty else { return }
        root = layout
        self.zoomedPane = zoomedPane
        rebuild()
    }

    func rebuild() {
        let content: NSView?
        if let zoomedPane {
            content = paneView(zoomedPane)
        } else if let root {
            content = build(root, path: [])
        } else {
            content = nil
        }
        // Detach everything first so a reused pane view is never parented twice.
        for view in subviews { view.removeFromSuperview() }
        if let content {
            content.frame = bounds
            addSubview(content)
        }
    }

    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }

    private func build(_ node: LayoutNode, path: [Bool]) -> NSView? {
        switch node {
        case let .pane(id):
            let view = paneView(id)
            view?.removeFromSuperview()
            return view
        case let .split(direction, ratio, first, second):
            guard let a = build(first, path: path + [false]),
                  let b = build(second, path: path + [true])
            else { return build(first, path: path + [false]) ?? build(second, path: path + [true]) }
            let split = SplitNodeView(direction: direction, ratio: ratio, first: a, second: b)
            split.onRatioCommit = { [weak self] ratio in self?.onRatioChange?(path, ratio) }
            return split
        }
    }
}

/// Two children and a draggable divider.
@MainActor
final class SplitNodeView: NSView {
    let direction: SplitDirection
    private(set) var ratio: Double
    private let first: NSView
    private let second: NSView
    var onRatioCommit: ((Double) -> Void)?

    private let dividerThickness: CGFloat = 1
    private let dividerHitSlop: CGFloat = 4
    private var dragging = false

    init(direction: SplitDirection, ratio: Double, first: NSView, second: NSView) {
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
        super.init(frame: .zero)
        first.autoresizingMask = []
        second.autoresizingMask = []
        addSubview(first)
        addSubview(second)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private var isHorizontal: Bool { direction == .right }

    private var dividerRect: NSRect {
        let b = bounds
        if isHorizontal {
            let x = (b.width - dividerThickness) * ratio
            return NSRect(x: x, y: 0, width: dividerThickness, height: b.height)
        }
        // AppKit's origin is bottom-left; herdr's first child is on top.
        let y = b.height - (b.height - dividerThickness) * ratio - dividerThickness
        return NSRect(x: 0, y: y, width: b.width, height: dividerThickness)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let d = dividerRect
        if isHorizontal {
            first.frame = NSRect(x: 0, y: 0, width: d.minX, height: b.height)
            second.frame = NSRect(x: d.maxX, y: 0, width: b.width - d.maxX, height: b.height)
        } else {
            first.frame = NSRect(x: 0, y: d.maxY, width: b.width, height: b.height - d.maxY)
            second.frame = NSRect(x: 0, y: 0, width: b.width, height: d.minY)
        }
    }

    override func draw(_: NSRect) {
        (Theme.current?.divider ?? .separatorColor).setFill()
        dividerRect.fill()
    }

    private var hitRect: NSRect {
        dividerRect.insetBy(dx: isHorizontal ? -dividerHitSlop : 0, dy: isHorizontal ? 0 : -dividerHitSlop)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if hitRect.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(hitRect, cursor: isHorizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with _: NSEvent) { dragging = true }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        let raw = isHorizontal ? p.x / b.width : (b.height - p.y) / b.height
        ratio = min(max(Double(raw), 0.1), 0.9)
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with _: NSEvent) {
        guard dragging else { return }
        dragging = false
        onRatioCommit?(ratio)
    }
}
