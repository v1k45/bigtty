import Foundation

/// Which panes need the user, from this client's point of view.
///
/// A pane needs attention while its agent is `blocked`, or once it turns
/// `done` until someone looks at it. herdr tracks "seen" per client, so the
/// unseen set is ours: a pane counts as seen when it is visible and focused
/// in the key window (`viewed`).
public struct Attention: Sendable, Equatable {
    public enum Reason: String, Sendable { case blocked, done }

    public struct Transition: Sendable, Equatable {
        public let paneID: String
        public let reason: Reason
    }

    private var lastStatus: [String: AgentStatus] = [:]
    public private(set) var unseenDone: Set<String> = []
    public private(set) var blocked: Set<String> = []

    public init() {}

    /// Folds in a new snapshot and returns panes that newly need attention
    /// (for notifications). `viewed` panes never produce a transition.
    public mutating func update(panes: [Pane], viewed: Set<String>) -> [Transition] {
        var transitions: [Transition] = []
        var seen: [String: AgentStatus] = [:]
        for pane in panes {
            let old = lastStatus[pane.paneID]
            let new = pane.agentStatus
            seen[pane.paneID] = new
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
        unseenDone.formIntersection(seen.keys)
        markViewed(viewed)
        return transitions
    }

    public mutating func markViewed(_ viewed: Set<String>) {
        unseenDone.subtract(viewed)
    }

    public func reason(for paneID: String) -> Reason? {
        if blocked.contains(paneID) { return .blocked }
        if unseenDone.contains(paneID) { return .done }
        return nil
    }

    public var needingAttention: Set<String> { blocked.union(unseenDone) }

    /// Panes in the order jump-to-unread visits them: blocked first, then
    /// finished, each in workspace/tab/pane order.
    public func queue(in snapshot: Snapshot) -> [Pane] {
        let workspaceOrder = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0.number) })
        let tabOrder = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0.number) })
        return snapshot.panes
            .filter { needingAttention.contains($0.paneID) }
            .sorted { a, b in
                let ra = blocked.contains(a.paneID) ? 0 : 1
                let rb = blocked.contains(b.paneID) ? 0 : 1
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
