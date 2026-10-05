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

/// A machine (or one of its herdr sessions) that can't be reached.
public struct ConnectionProblem: Sendable, Equatable {
    public let machineID: String
    /// The SSH target: every session on it shares the one connection, so
    /// they fail together.
    public let host: String
    /// The latest error.
    public let message: String
    /// Unreachable since; kept across retries, reset by a connect.
    public let since: Date?
    /// The saved machine itself, rather than another session of it.
    public let isSaved: Bool
    public let order: Int

    public init(machineID: String, host: String, message: String, since: Date?, isSaved: Bool, order: Int) {
        self.machineID = machineID
        self.host = host
        self.message = message
        self.since = since
        self.isSaved = isSaved
        self.order = order
    }

    /// What a dismissal is tied to: a new error, or failing again after
    /// a reconnect, is news again.
    public var state: String { "\(message)|\(since?.timeIntervalSince1970 ?? 0)" }
}

extension NeedsYou {
    /// One problem per host, however many of its sessions fail: the saved
    /// machine's (else the first session's) latest error, unreachable since
    /// the earliest of them.
    public static func perHost(_ problems: [ConnectionProblem]) -> [ConnectionProblem] {
        var byHost: [String: [ConnectionProblem]] = [:]
        var hosts: [String] = []
        for problem in problems {
            if byHost[problem.host] == nil { hosts.append(problem.host) }
            byHost[problem.host, default: []].append(problem)
        }
        return hosts.compactMap { host in
            let group = byHost[host] ?? []
            guard let lead = group.first(where: \.isSaved) ?? group.min(by: { $0.order < $1.order }) else { return nil }
            let since = group.compactMap(\.since).min()
            return ConnectionProblem(machineID: lead.machineID, host: host, message: lead.message, since: since,
                                     isSaved: lead.isSaved, order: group.map(\.order).min() ?? lead.order)
        }
    }

    /// Seconds before reconnect attempt `attempt` (1-based): quick at
    /// first, for a blip, then backing off to every few minutes.
    public static func reconnectDelay(attempt: Int) -> Int {
        [5, 10, 30, 60, 120][safe: attempt - 1] ?? 300
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
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
