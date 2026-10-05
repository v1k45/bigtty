import Foundation

/// Which panes need the user, from this client's point of view.
///
/// A pane needs attention once its agent turns `blocked` or `done`, until
/// someone looks at it. herdr tracks "seen" per client, so the unseen sets
/// are ours: a pane counts as seen when it is visible and focused in the key
/// window (`viewed`). A blocked pane that was seen stays quiet until it
/// stops being blocked and gets blocked again.
public struct Attention: Sendable, Equatable {
    public enum Reason: String, Sendable { case blocked, done }

    public struct Transition: Sendable, Equatable {
        public let paneID: String
        public let reason: Reason
    }

    private var lastStatus: [String: AgentStatus] = [:]
    public private(set) var unseenDone: Set<String> = []
    public private(set) var blocked: Set<String> = []
    /// Blocked panes the user has already looked at.
    public private(set) var seenBlocked: Set<String> = []
    /// When each pane's agent entered its current state (as far as this
    /// client knows: panes there on connect count from then).
    public private(set) var since: [String: Date] = [:]
    /// Panes dismissed from Needs You, until their agent's state changes.
    public private(set) var dismissed: Set<String> = []

    public init() {}

    /// Folds in a new snapshot and returns panes that newly need attention
    /// (for notifications). `viewed` panes never produce a transition.
    public mutating func update(panes: [Pane], viewed: Set<String>, now: Date = Date()) -> [Transition] {
        var transitions: [Transition] = []
        var seen: [String: AgentStatus] = [:]
        for pane in panes {
            let old = lastStatus[pane.paneID]
            let new = pane.agentStatus
            seen[pane.paneID] = new
            if old != new {
                since[pane.paneID] = now
                dismissed.remove(pane.paneID)
            }
            if new == .blocked, old != .blocked, !viewed.contains(pane.paneID) {
                transitions.append(Transition(paneID: pane.paneID, reason: .blocked))
            }
            // Only a finish we witnessed counts; a pane that was already
            // done when we connected is not news.
            if new == .done, old != nil, old != .done, !viewed.contains(pane.paneID) {
                unseenDone.insert(pane.paneID)
                transitions.append(Transition(paneID: pane.paneID, reason: .done))
            }
            if new != .done { unseenDone.remove(pane.paneID) }
        }
        lastStatus = seen
        blocked = Set(panes.filter { $0.agentStatus == .blocked }.map(\.paneID))
        seenBlocked.formIntersection(blocked)
        unseenDone.formIntersection(seen.keys)
        since = since.filter { seen[$0.key] != nil }
        dismissed.formIntersection(seen.keys)
        markViewed(viewed)
        return transitions
    }

    public mutating func markViewed(_ viewed: Set<String>) {
        unseenDone.subtract(viewed)
        seenBlocked.formUnion(viewed.intersection(blocked))
    }

    /// Takes a pane off Needs You (it stops needing attention) until its
    /// agent's state changes.
    public mutating func dismiss(_ paneID: String) {
        dismissed.insert(paneID)
    }

    /// Undoes `dismiss`: the pane is back as it was.
    public mutating func undismiss(_ paneID: String) {
        dismissed.remove(paneID)
    }

    public func reason(for paneID: String) -> Reason? {
        if dismissed.contains(paneID) { return nil }
        if blocked.contains(paneID), !seenBlocked.contains(paneID) { return .blocked }
        if unseenDone.contains(paneID) { return .done }
        return nil
    }

    public var needingAttention: Set<String> { blocked.subtracting(seenBlocked).union(unseenDone).subtracting(dismissed) }

    /// Panes in the order jump-to-unread visits them: blocked first, then
    /// finished, each in workspace/tab/pane order.
    public func queue(in snapshot: Snapshot) -> [Pane] {
        let workspaceOrder = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0.number) })
        let tabOrder = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0.number) })
        return snapshot.panes
            .filter { needingAttention.contains($0.paneID) }
            .sorted { a, b in
                let ra = reason(for: a.paneID) == .blocked ? 0 : 1
                let rb = reason(for: b.paneID) == .blocked ? 0 : 1
                if ra != rb { return ra < rb }
                let wa = workspaceOrder[a.workspaceID] ?? 0, wb = workspaceOrder[b.workspaceID] ?? 0
                if wa != wb { return wa < wb }
                let ta = tabOrder[a.tabID] ?? 0, tb = tabOrder[b.tabID] ?? 0
                if ta != tb { return ta < tb }
                return a.paneID < b.paneID
            }
    }

    public func count(inTab tabID: String, panes: [Pane]) -> Int {
        panes.filter { $0.tabID == tabID && needingAttention.contains($0.paneID) }.count
    }

    public func count(inWorkspace workspaceID: String, panes: [Pane]) -> Int {
        panes.filter { $0.workspaceID == workspaceID && needingAttention.contains($0.paneID) }.count
    }
}
