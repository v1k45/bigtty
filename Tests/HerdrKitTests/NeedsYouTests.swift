import Foundation
@testable import HerdrKit
import Testing

@Suite struct NeedsYouTests {
    func pane(_ id: String, _ status: AgentStatus, tab: String = "t1", workspace: String = "w1") -> Pane {
        Pane(
            paneID: id, terminalID: "term_\(id)", workspaceID: workspace, tabID: tab, focused: false,
            cwd: nil, foregroundCwd: nil, agentStatus: status, agent: "claude", displayAgent: nil,
            label: nil, title: nil, terminalTitle: nil, tokens: nil, revision: 0
        )
    }

    func snapshot(_ panes: [Pane]) -> Snapshot {
        let workspaces = Array(Set(panes.map(\.workspaceID))).sorted().enumerated().map { index, id in
            Workspace(workspaceID: id, number: index + 1, label: id, focused: false, paneCount: 1, tabCount: 1,
                      activeTabID: "", agentStatus: .idle, tokens: nil)
        }
        let tabs = Array(Set(panes.map { "\($0.workspaceID)/\($0.tabID)" })).sorted().map { key in
            let parts = key.split(separator: "/").map(String.init)
            return Tab(tabID: parts[1], workspaceID: parts[0], number: Int(parts[1].dropFirst()) ?? 1, label: "",
                       focused: false, paneCount: 1, agentStatus: .idle)
        }
        return Snapshot(version: "", protocol: 0, focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil,
                        workspaces: workspaces, tabs: tabs, panes: panes)
    }

    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func items(_ attention: Attention, _ panes: [Pane]) -> [NeedsYouItem] {
        NeedsYou.ranked(NeedsYou.items(attention: attention, snapshot: snapshot(panes), machineID: "m", machineOrder: 0))
    }

    @Test func ranksByKind() {
        var attention = Attention()
        let start = [pane("done", .working), pane("ask", .idle), pane("seen", .idle), pane("idle", .idle)]
        _ = attention.update(panes: start, viewed: [], now: t0)
        let later = [pane("done", .done), pane("ask", .blocked), pane("seen", .blocked), pane("idle", .idle)]
        _ = attention.update(panes: later, viewed: ["seen"], now: t0 + 10)
        let ranked = items(attention, later)
        #expect(ranked.map(\.paneID) == ["ask", "seen", "done"])
        #expect(ranked.map(\.kind) == [.blocked, .waiting, .finished])
    }

    @Test func idleAndWorkingAgentsAreLeftOut() {
        var attention = Attention()
        let panes = [pane("a", .idle), pane("b", .working), pane("c", .done)]
        _ = attention.update(panes: panes, viewed: [], now: t0)
        // Already done on connect: not news either.
        #expect(items(attention, panes).isEmpty)
    }

    @Test func longestWaitingFirstWithinAKind() {
        var attention = Attention()
        _ = attention.update(panes: [pane("a", .idle, workspace: "w1"), pane("b", .idle, workspace: "w2")], viewed: [], now: t0)
        _ = attention.update(panes: [pane("a", .idle, workspace: "w1"), pane("b", .blocked, workspace: "w2")], viewed: [], now: t0 + 5)
        let panes = [pane("a", .blocked, workspace: "w1"), pane("b", .blocked, workspace: "w2")]
        _ = attention.update(panes: panes, viewed: [], now: t0 + 60)
        // b has waited since t0+5, a only since t0+60, though a's space comes first.
        #expect(items(attention, panes).map(\.paneID) == ["b", "a"])
        #expect(items(attention, panes).first?.since == t0 + 5)
    }

    @Test func tiesBreakBySpaceThenTab() {
        var attention = Attention()
        let start = [pane("c", .idle, tab: "t2", workspace: "w1"), pane("b", .idle, tab: "t1", workspace: "w2"), pane("a", .idle, tab: "t1", workspace: "w1")]
        _ = attention.update(panes: start, viewed: [], now: t0)
        let panes = start.map { pane($0.paneID, .blocked, tab: $0.tabID, workspace: $0.workspaceID) }
        _ = attention.update(panes: panes, viewed: [], now: t0 + 1)
        #expect(items(attention, panes).map(\.paneID) == ["a", "c", "b"])
    }

    @Test func loginsOutrankEverything() {
        let agent = NeedsYouItem(kind: .blocked, machineID: "local", paneID: "p", since: t0, order: [0, 1, 1])
        let login = NeedsYouItem(kind: .login, machineID: "box", order: [2])
        let done = NeedsYouItem(kind: .finished, machineID: "local", paneID: "q", since: t0 - 100, order: [0, 1, 1])
        #expect(NeedsYou.ranked([done, agent, login]) == [login, agent, done])
    }

    @Test func unknownAgeGoesAfterKnown() {
        let known = NeedsYouItem(kind: .blocked, machineID: "b", paneID: "p", since: t0, order: [1])
        let unknown = NeedsYouItem(kind: .blocked, machineID: "a", paneID: "q", since: nil, order: [0])
        #expect(NeedsYou.ranked([unknown, known]) == [known, unknown])
    }

    @Test func viewingClearsBlockedAndFinished() {
        var attention = Attention()
        _ = attention.update(panes: [pane("a", .working), pane("b", .working)], viewed: [], now: t0)
        let panes = [pane("a", .blocked), pane("b", .done)]
        _ = attention.update(panes: panes, viewed: [], now: t0 + 1)
        attention.markViewed(["a", "b"])
        // a still waits on you, quieter; b is gone.
        #expect(items(attention, panes).map(\.kind) == [.waiting])
    }

    @Test func dismissHidesUntilStateChanges() {
        var attention = Attention()
        _ = attention.update(panes: [pane("a", .working)], viewed: [], now: t0)
        _ = attention.update(panes: [pane("a", .blocked)], viewed: [], now: t0 + 1)
        attention.dismiss("a")
        #expect(items(attention, [pane("a", .blocked)]).isEmpty)
        #expect(attention.needingAttention.isEmpty)
        _ = attention.update(panes: [pane("a", .blocked)], viewed: [], now: t0 + 2)
        #expect(items(attention, [pane("a", .blocked)]).isEmpty)
        // Working again, then blocked again: back on the list.
        _ = attention.update(panes: [pane("a", .working)], viewed: [], now: t0 + 3)
        _ = attention.update(panes: [pane("a", .blocked)], viewed: [], now: t0 + 4)
        #expect(items(attention, [pane("a", .blocked)]).map(\.kind) == [.blocked])
    }

    @Test func closedPanesAreForgotten() {
        var attention = Attention()
        _ = attention.update(panes: [pane("a", .working)], viewed: [], now: t0)
        _ = attention.update(panes: [pane("a", .blocked)], viewed: [], now: t0 + 1)
        attention.dismiss("a")
        _ = attention.update(panes: [], viewed: [], now: t0 + 2)
        #expect(attention.since.isEmpty)
        #expect(attention.dismissed.isEmpty)
    }
}
