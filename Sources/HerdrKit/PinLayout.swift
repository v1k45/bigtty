import Foundation

/// Where pinned panes sit in a tab: a full-height column on the right, the
/// pins stacked top to bottom, beside everything else in the tab.
public enum PinLayout {
    /// `others` with the pins as a column taking `width` (0…1) of the tab.
    public static func column(others: LayoutNode, pins: [String], width: Double) -> LayoutNode {
        .split(direction: .right, ratio: 1 - width, first: others, second: stack(pins))
    }

    /// Pins one above the other, equal heights.
    static func stack(_ pins: [String]) -> LayoutNode {
        guard let first = pins.first else { return .pane(id: "") }
        guard pins.count > 1 else { return .pane(id: first) }
        return .split(direction: .down, ratio: 1 / Double(pins.count), first: .pane(id: first), second: stack(Array(pins.dropFirst())))
    }

    /// Whether `root` already has `pins`, in order, as its right column.
    public static func isColumn(_ root: LayoutNode, pins: [String]) -> Bool {
        guard case let .split(.right, _, first, second) = root else { return false }
        return second.sameArrangement(as: stack(pins)) && Set(first.paneIDs).isDisjoint(with: pins)
    }

    /// The pane along the tab's right edge that spans its full height
    /// (following right splits' second halves), with the share of the
    /// width it has: splitting it right gives a full-height column.
    public static func rightEdgeLeaf(_ root: LayoutNode) -> (id: String, share: Double)? {
        var node = root
        var share = 1.0
        while case let .split(.right, ratio, _, second) = node {
            share *= 1 - ratio
            node = second
        }
        guard case let .pane(id) = node else { return nil }
        return (id, share)
    }

    /// The ratio for splitting a pane with `share` of the width so the new
    /// right part takes `width` of the whole tab.
    public static func splitRatio(share: Double, width: Double) -> Double {
        min(0.9, max(0.1, 1 - width / max(share, 0.0001)))
    }
}
