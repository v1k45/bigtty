@testable import bigtty
import Foundation
import HerdrKit
import Testing

/// ⌘T and ⌘N show what they made once herdr's snapshot has it, and until
/// then keep the window where it is, however many snapshots come first.
@Suite struct AwaitedTabTests {
    func pane(_ id: String, tab: String, workspace: String) throws -> Pane {
        let json = """
        {"pane_id":"\(id)","terminal_id":"term_\(id)","workspace_id":"\(workspace)","tab_id":"\(tab)",
         "focused":true,"agent_status":"unknown","revision":0}
        """
        return try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
    }

    func snapshot(tabs: [(id: String, workspace: String)], focusedTab: String) throws -> Snapshot {
        let rows = tabs.enumerated().map { i, tab in
            """
            {"tab_id":"\(tab.id)","workspace_id":"\(tab.workspace)","number":\(i + 1),"label":"\(i + 1)",
             "focused":\(tab.id == focusedTab),"pane_count":1,"agent_status":"unknown"}
            """
        }
        let json = """
        {"version":"0.9.3","protocol":1,"focused_workspace_id":"w1","focused_tab_id":"\(focusedTab)",
         "focused_pane_id":null,"workspaces":[],"tabs":[\(rows.joined(separator: ","))],"panes":[]}
        """
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    @Test func waitsThroughSnapshotsThatPredateTheTab() throws {
        let start = Date()
        let awaited = AwaitedTab(try pane("w1:p2", tab: "w1:t2", workspace: "w1"), since: start)
        #expect(awaited.tabID == "w1:t2")
        #expect(awaited.paneID == "w1:p2")
        // A busy pane retitling: snapshot after snapshot without the new tab
        // (herdr's focus still on the old one). The window must not move.
        let before = try snapshot(tabs: [("w1:t1", "w1")], focusedTab: "w1:t1")
        for tick in 1...20 {
            #expect(awaited.step(in: before, now: start.addingTimeInterval(Double(tick) * 0.05)) == .wait)
        }
        let after = try snapshot(tabs: [("w1:t1", "w1"), ("w1:t2", "w1")], focusedTab: "w1:t2")
        #expect(awaited.step(in: after, now: start.addingTimeInterval(1.1)) == .show)
    }

    @Test func aNewSpaceArrivesWithItsFirstTab() throws {
        let awaited = AwaitedTab(try pane("w2:p1", tab: "w2:t1", workspace: "w2"))
        #expect(awaited.workspaceID == "w2")
        #expect(awaited.step(in: try snapshot(tabs: [("w1:t1", "w1")], focusedTab: "w1:t1")) == .wait)
        #expect(awaited.step(in: try snapshot(tabs: [("w1:t1", "w1"), ("w2:t1", "w2")], focusedTab: "w2:t1")) == .show)
    }

    @Test func aTabThatNeverArrivesIsForgotten() throws {
        let start = Date()
        let awaited = AwaitedTab(try pane("w1:p2", tab: "w1:t2", workspace: "w1"), since: start)
        let before = try snapshot(tabs: [("w1:t1", "w1")], focusedTab: "w1:t1")
        #expect(awaited.step(in: before, now: start.addingTimeInterval(AwaitedTab.patience - 1)) == .wait)
        #expect(awaited.step(in: before, now: start.addingTimeInterval(AwaitedTab.patience + 1)) == .forget)
    }
}
