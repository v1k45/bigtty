import Foundation
@testable import HerdrKit
import Testing

@Suite struct AttentionTests {
    func pane(_ id: String, _ status: AgentStatus, tab: String = "w1:t1", workspace: String = "w1") -> Pane {
        Pane(
            paneID: id, terminalID: "term_\(id)", workspaceID: workspace, tabID: tab, focused: false,
            cwd: nil, foregroundCwd: nil, agentStatus: status, agent: "claude", displayAgent: nil,
            label: nil, title: nil, terminalTitle: nil, tokens: nil, revision: 0
        )
    }

    @Test func alreadyDoneOnConnectIsNotNews() {
        var attention = Attention()
        let transitions = attention.update(panes: [pane("p1", .done)], viewed: [])
        #expect(transitions.isEmpty)
        #expect(attention.needingAttention.isEmpty)
    }

    @Test func finishingWhileAwayStaysUntilViewed() {
        var attention = Attention()
        _ = attention.update(panes: [pane("p1", .working)], viewed: [])
        let transitions = attention.update(panes: [pane("p1", .done)], viewed: [])
        #expect(transitions == [.init(paneID: "p1", reason: .done)])
        #expect(attention.reason(for: "p1") == .done)
        _ = attention.update(panes: [pane("p1", .done)], viewed: [])
        #expect(attention.reason(for: "p1") == .done)
        attention.markViewed(["p1"])
        #expect(attention.reason(for: "p1") == nil)
    }

    @Test func finishingWhileWatchedIsSilent() {
        var attention = Attention()
        _ = attention.update(panes: [pane("p1", .working)], viewed: ["p1"])
        let transitions = attention.update(panes: [pane("p1", .done)], viewed: ["p1"])
        #expect(transitions.isEmpty)
        #expect(attention.reason(for: "p1") == nil)
    }

    @Test func blockedNeedsAttentionUntilSeen() {
        var attention = Attention()
        _ = attention.update(panes: [pane("p1", .working)], viewed: [])
        #expect(attention.update(panes: [pane("p1", .blocked)], viewed: []) == [.init(paneID: "p1", reason: .blocked)])
        #expect(attention.reason(for: "p1") == .blocked)
        // Looked at while still blocked: quiet, no repeat notification.
        #expect(attention.update(panes: [pane("p1", .blocked)], viewed: ["p1"]).isEmpty)
        #expect(attention.reason(for: "p1") == nil)
        #expect(attention.needingAttention.isEmpty)
        _ = attention.update(panes: [pane("p1", .blocked)], viewed: [])
        #expect(attention.reason(for: "p1") == nil)
        // Unblocked, then blocked again: needs the user again.
        _ = attention.update(panes: [pane("p1", .working)], viewed: [])
        #expect(attention.update(panes: [pane("p1", .blocked)], viewed: []).count == 1)
        #expect(attention.reason(for: "p1") == .blocked)
    }

    @Test func focusingABlockedPaneClearsIt() {
        var attention = Attention()
        _ = attention.update(panes: [pane("p1", .blocked)], viewed: [])
        #expect(attention.reason(for: "p1") == .blocked)
        attention.markViewed(["p1"])
        #expect(attention.reason(for: "p1") == nil)
    }

    @Test func queueOrdersBlockedFirst() {
        var attention = Attention()
        let working = [pane("a", .working), pane("b", .working, tab: "w1:t2"), pane("c", .working)]
        _ = attention.update(panes: working, viewed: [])
        let later = [pane("a", .done), pane("b", .blocked, tab: "w1:t2"), pane("c", .done)]
        _ = attention.update(panes: later, viewed: [])
        let snapshot = Snapshot(
            version: "", protocol: 0, focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
            workspaces: [], tabs: [], panes: later
        )
        #expect(attention.queue(in: snapshot).map(\.paneID) == ["b", "a", "c"])
        #expect(attention.count(inTab: "w1:t1", panes: later) == 2)
    }
}
