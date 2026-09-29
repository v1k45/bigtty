import Foundation
@testable import HerdrKit
import Testing

@Suite struct ModelTests {
    @Test func decodesSnapshot() throws {
        let json = #"""
        {"version":"0.9.1","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1",
         "focused_pane_id":"w1:p1",
         "workspaces":[{"workspace_id":"w1","number":1,"label":"demo","focused":true,"pane_count":2,
           "tab_count":1,"active_tab_id":"w1:t1","agent_status":"unknown"}],
         "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":true,
           "pane_count":2,"agent_status":"blocked"}],
         "panes":[{"pane_id":"w1:p1","terminal_id":"term_1","workspace_id":"w1","tab_id":"w1:t1",
           "focused":true,"cwd":"/tmp","agent_status":"working","revision":0,
           "tokens":{"ghr_kind":"browser"}, "future_field": 1}],
         "layouts":[],"agents":[]}
        """#
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.workspaces.first?.label == "demo")
        #expect(snapshot.tabs.first?.agentStatus == .blocked)
        #expect(snapshot.panes.first?.tokens?["ghr_kind"] == "browser")
        #expect(snapshot.panes.first?.displayName == "tmp")
    }

    @Test func unknownAgentStatusFallsBack() throws {
        let status = try JSONDecoder().decode([AgentStatus].self, from: Data(#"["sleeping","done"]"#.utf8))
        #expect(status == [.unknown, .done])
    }

    @Test func decodesLayoutTree() throws {
        let json = #"""
        {"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"focused_pane_id":"w1:p1",
         "root":{"type":"split","direction":"right","ratio":0.5,
           "first":{"type":"pane","pane_id":"w1:p1","cwd":"/tmp"},
           "second":{"type":"split","direction":"down","ratio":0.3,
             "first":{"type":"pane","pane_id":"w1:p2"},"second":{"type":"pane","pane_id":"w1:p3"}}}}
        """#
        let layout = try JSONDecoder().decode(TabLayout.self, from: Data(json.utf8))
        #expect(layout.root.paneIDs == ["w1:p1", "w1:p2", "w1:p3"])
        guard case let .split(direction, ratio, _, _) = layout.root else {
            Issue.record("expected split"); return
        }
        #expect(direction == .right)
        #expect(ratio == 0.5)
    }
}
