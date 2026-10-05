import Foundation

/// One thing waiting on the user, for the Needs You list.
public struct NeedsYouItem: Sendable, Equatable {
    /// Most urgent first.
    public enum Kind: Int, Sendable, Comparable {
        /// A machine's login waits on you (approval, sign-in): everything on
        /// it is stuck until you act.
        case login
        /// An agent asks something you haven't looked at yet.
        case blocked
        /// An agent still waits on you, though you've seen it.
        case waiting
        /// A machine can't be reached (offline, herdr missing): worth
        /// knowing, but often nothing to do right now.
        case unreachable
        /// An agent finished while you were elsewhere.
        case finished

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public let kind: Kind
    public let machineID: String
    /// Nil for a machine's login.
    public let paneID: String?
    /// When it started waiting; nil if unknown.
    public let since: Date?
    /// Where it sits (machine, space, tab), to break ties.
    public let order: [Int]

    public init(kind: Kind, machineID: String, paneID: String? = nil, since: Date? = nil, order: [Int] = []) {
        self.kind = kind
        self.machineID = machineID
        self.paneID = paneID
        self.since = since
        self.order = order
    }

    public var id: String { "\(machineID)|\(paneID ?? "")" }
}

public enum NeedsYou {
    /// A machine's panes that wait on the user, unranked.
    public static func items(attention: Attention, snapshot: Snapshot, machineID: String, machineOrder: Int) -> [NeedsYouItem] {
        let workspaceOrder = Dictionary(snapshot.workspaces.map { ($0.workspaceID, $0.number) }, uniquingKeysWith: { a, _ in a })
        let tabOrder = Dictionary(snapshot.tabs.map { ($0.tabID, $0.number) }, uniquingKeysWith: { a, _ in a })
        return snapshot.panes.compactMap { pane in
            let kind: NeedsYouItem.Kind
            switch attention.reason(for: pane.paneID) {
            case .blocked: kind = .blocked
            case .done: kind = .finished
            case nil:
                guard pane.agentStatus == .blocked, !attention.dismissed.contains(pane.paneID) else { return nil }
                kind = .waiting
            }
            return NeedsYouItem(
                kind: kind, machineID: machineID, paneID: pane.paneID, since: attention.since[pane.paneID],
                order: [machineOrder, workspaceOrder[pane.workspaceID] ?? 0, tabOrder[pane.tabID] ?? 0]
            )
        }
    }

    /// Most urgent first: by kind, then whatever has waited longest, then
    /// where it sits.
    public static func ranked(_ items: [NeedsYouItem]) -> [NeedsYouItem] {
        items.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            switch (a.since, b.since) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.order != b.order { return a.order.lexicographicallyPrecedes(b.order) }
            return a.id < b.id
        }
    }
}

/// Things dismissed until their state changes (a machine's connection
/// problem): hidden while the state is the one they were dismissed in.
public struct DismissedUntilChanged<State: Equatable & Sendable>: Sendable {
    private var dismissed: [String: State] = [:]

    public init() {}

    public mutating func dismiss(_ id: String, in state: State) { dismissed[id] = state }

    public mutating func undismiss(_ id: String) { dismissed[id] = nil }

    /// Hidden while still in the dismissed state; any change forgets it.
    public mutating func isDismissed(_ id: String, in state: State) -> Bool {
        guard let at = dismissed[id] else { return false }
        if at == state { return true }
        dismissed[id] = nil
        return false
    }
}
