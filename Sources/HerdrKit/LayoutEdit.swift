import Foundation

/// Where a dragged pane goes.
public enum PaneDropTarget: Equatable, Sendable {
    /// Beside (or in place of, for `.center`) one pane.
    case pane(String, HerdrClient.DropZone)
    /// Along an outer edge of the whole tab: full width or full height.
    case tabEdge(HerdrClient.DropZone)
}

extension LayoutNode {
    public var firstLeaf: String {
        switch self {
        case let .pane(id): id
        case let .split(_, _, first, _): first.firstLeaf
        }
    }

    /// The tree without `id`; its sibling takes the parent's place.
    public func removing(_ id: String) -> LayoutNode? {
        switch self {
        case let .pane(pane): return pane == id ? nil : self
        case let .split(direction, ratio, first, second):
            let a = first.removing(id), b = second.removing(id)
            guard let a else { return b }
            guard let b else { return a }
            return .split(direction: direction, ratio: ratio, first: a, second: b)
        }
    }

    /// Puts `node` on `zone` of `self` (a subtree or the whole tab).
    public func wrapped(with node: LayoutNode, zone: HerdrClient.DropZone) -> LayoutNode {
        switch zone {
        case .left: .split(direction: .right, ratio: 0.5, first: node, second: self)
        case .right: .split(direction: .right, ratio: 0.5, first: self, second: node)
        case .top: .split(direction: .down, ratio: 0.5, first: node, second: self)
        case .bottom: .split(direction: .down, ratio: 0.5, first: self, second: node)
        case .center: node
        }
    }

    /// Replaces the leaf `id` with `transform(leaf)`.
    func replacingLeaf(_ id: String, with transform: (LayoutNode) -> LayoutNode) -> LayoutNode {
        switch self {
        case let .pane(pane): return pane == id ? transform(self) : self
        case let .split(direction, ratio, first, second):
            return .split(direction: direction, ratio: ratio,
                          first: first.replacingLeaf(id, with: transform),
                          second: second.replacingLeaf(id, with: transform))
        }
    }

    /// Swaps two leaves.
    func swapping(_ a: String, _ b: String) -> LayoutNode {
        switch self {
        case let .pane(id): return id == a ? .pane(id: b) : id == b ? .pane(id: a) : self
        case let .split(direction, ratio, first, second):
            return .split(direction: direction, ratio: ratio, first: first.swapping(a, b), second: second.swapping(a, b))
        }
    }

    /// The layout after dropping `source` on `target`. `self` is the target
    /// tab's layout; `source` may come from another tab.
    public func dropping(_ source: String, on target: PaneDropTarget) -> LayoutNode {
        let inTab = paneIDs.contains(source)
        switch target {
        case let .pane(id, .center):
            guard inTab else { return replacingLeaf(id) { _ in .pane(id: source) } }
            return swapping(source, id)
        case let .pane(id, zone):
            guard id != source else { return self }
            let base = (inTab ? removing(source) : self) ?? self
            return base.replacingLeaf(id) { $0.wrapped(with: .pane(id: source), zone: zone) }
        case let .tabEdge(zone):
            guard let base = inTab ? removing(source) : self else { return self }
            return base.wrapped(with: .pane(id: source), zone: zone)
        }
    }

    /// Every split with its path from the root (false = first child).
    public var splits: [(path: [Bool], ratio: Double)] {
        func walk(_ node: LayoutNode, _ path: [Bool]) -> [(path: [Bool], ratio: Double)] {
            guard case let .split(_, ratio, first, second) = node else { return [] }
            return [(path, ratio)] + walk(first, path + [false]) + walk(second, path + [true])
        }
        return walk(self, [])
    }

    /// Same shape and same panes in the same places (ratios aside).
    public func sameArrangement(as other: LayoutNode) -> Bool {
        switch (self, other) {
        case let (.pane(a), .pane(b)): a == b
        case let (.split(d1, _, f1, s1), .split(d2, _, f2, s2)): d1 == d2 && f1.sameArrangement(as: f2) && s1.sameArrangement(as: s2)
        default: false
        }
    }
}

extension HerdrClient {
    /// Puts `source` beside `target` in the same tab: out to a temporary
    /// tab and straight back next to the target (herdr won't move a pane
    /// within its own tab), then a swap for left/top. Two or three calls,
    /// against a rebuild's two per pane.
    public func movePane(_ source: String, beside target: String, zone: DropZone, tabID: String, workspaceID: String) async throws {
        guard source != target, zone != .center else {
            if zone == .center { try await swapPanes(source, target) }
            return
        }
        try await movePaneToNewTab(source, workspaceID: workspaceID)
        try await movePane(source, toTab: tabID, beside: target, split: zone == .left || zone == .right ? "right" : "down")
        if zone == .left || zone == .top { try await swapPanes(source, target) }
    }

    /// Rebuilds `tabID` into `desired`, keeping every pane and its process.
    /// herdr only splits single panes and won't move a pane within its own
    /// tab, so: park every pane but one in a temporary tab, split them back
    /// in shape order, swap panes into their places, then restore ratios.
    /// `current` is the tab's layout now; panes in `desired` from another
    /// tab are brought in too.
    public func applyLayout(_ desired: LayoutNode, current: LayoutNode, tabID: String, workspaceID: String) async throws {
        guard !desired.sameArrangement(as: current) else { return }
        let wanted = desired.paneIDs
        guard let anchor = current.paneIDs.first(where: wanted.contains) else { return }

        // 1. Everything but the anchor waits in one temporary tab.
        var parked: [String] = []
        var parkingTab: String?
        for pane in wanted where pane != anchor {
            if let parkingTab {
                try await movePane(pane, toTab: parkingTab, beside: parked.last, split: "right")
            } else {
                try await movePaneToNewTab(pane, workspaceID: workspaceID)
                parkingTab = try await tab(ofPane: pane)
            }
            parked.append(pane)
        }

        // 2. Rebuild the shape: a split puts the next parked pane beside the
        // pane holding that subtree's place.
        var slots: [String: String] = [:] // desired leaf -> pane there now
        var pool = parked[...]
        func build(_ node: LayoutNode, holder: String) async throws {
            switch node {
            case let .pane(id):
                slots[id] = holder
            case let .split(direction, _, first, second):
                guard let next = pool.popFirst() else { return }
                try await movePane(next, toTab: tabID, beside: holder, split: direction.rawValue)
                try await build(first, holder: holder)
                try await build(second, holder: next)
            }
        }
        try await build(desired, holder: anchor)

        // 3. Swap panes into their places.
        var at = slots // slot -> pane
        for slot in wanted {
            guard let occupant = at[slot], occupant != slot,
                  let other = at.first(where: { $0.value == slot })?.key else { continue }
            try await swapPanes(occupant, slot)
            at[slot] = slot
            at[other] = occupant
        }

        // 4. Ratios.
        for split in desired.splits where abs(split.ratio - 0.5) > 0.001 {
            try await setSplitRatio(tabID: tabID, path: split.path, ratio: split.ratio)
        }
    }

    func tab(ofPane paneID: String) async throws -> String? {
        let result = try await call("pane.get", ["pane_id": .string(paneID)])
        return result["pane"]?["tab_id"]?.stringValue
    }
}
