import Foundation
@testable import HerdrKit
import Testing

/// Talks to a real herdr server in an isolated named session. Enabled with
/// `BTTY_TEST_SESSION=<name>`; start it with `herdr --session <name> server`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BTTY_TEST_SESSION"] != nil))
struct LiveServerTests {
    let client = HerdrClient(endpoint: HerdrEndpoint(
        session: ProcessInfo.processInfo.environment["BTTY_TEST_SESSION"]
    ))

    @Test func pingAndSnapshot() async throws {
        let pong = try await client.ping()
        #expect(pong.protocol > 0)
        _ = try await client.snapshot()
    }

    @Test func splitShowsUpInLayout() async throws {
        let root = try await client.createWorkspace(cwd: "/tmp", label: "btty-test", focus: false)
        let pane = try await client.split(paneID: root.paneID, direction: .right)
        let layout = try await client.layout(tabID: root.tabID)
        #expect(layout.root.paneIDs == [root.paneID, pane.paneID])
        try await client.closeWorkspace(root.workspaceID)
    }

    @Test func terminalChannelEchoes() async throws {
        let pane = try await client.createWorkspace(cwd: "/tmp", label: "btty-echo", focus: false)

        let channel = TerminalChannel(endpoint: client.endpoint, terminalID: pane.terminalID)
        let received = Received()
        channel.onFrame = { received.append($0) }
        try channel.start(columns: 60, rows: 10)
        // Wait for the shell to draw something, then for our output.
        try await waitUntil { !received.text.isEmpty }
        try await Task.sleep(nanoseconds: 500_000_000)
        channel.sendInput(Data("echo btty-marker-$((20+22))\r".utf8))
        try await waitUntil { received.text.contains("btty-marker-42") }
        channel.close()
        try await client.closeWorkspace(pane.workspaceID)
        #expect(received.text.contains("btty-marker-42"))
    }

    @Test func searchesAndScrollsScrollback() async throws {
        let pane = try await client.createWorkspace(cwd: "/tmp", label: "btty-find", focus: false)
        // Keep a terminal attached so the pane has a size and a screen.
        let channel = TerminalChannel(endpoint: client.endpoint, terminalID: pane.terminalID)
        try channel.start(columns: 80, rows: 20)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await client.sendText(paneID: pane.paneID, text: "for i in $(seq 1 300); do echo row $i mark$((i%50)); done\n")
        var found: ScrollbackMatches?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            found = try await client.searchScrollback(paneID: pane.paneID, query: "mark0", from: .end, backward: true)
            if found?.total == 6 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let newest = try #require(found?.currentMatch)
        #expect(found?.total == 6)
        #expect(found?.currentGlobal == 5)

        // Next (older) from the newest, then back to it.
        let older = try await client.searchScrollback(paneID: pane.paneID, query: "mark0", from: newest.start, backward: true)
        #expect(older.currentGlobal == 4)
        let again = try await client.searchScrollback(
            paneID: pane.paneID, query: "mark0", from: ScrollbackMatches.cursor(before: newest.start), backward: false
        )
        #expect(again.currentMatch == newest)

        let first = try await client.searchScrollback(paneID: pane.paneID, query: "mark0", from: .init(row: 0, col: 0), backward: false)
        let scroll = try #require(try await client.scrollInfo(paneID: pane.paneID))
        let match = try #require(first.currentMatch)
        let offset = try #require(scroll.offset(revealing: match.start.row))
        let moved = try #require(try await client.scroll(paneID: pane.paneID, offsetFromBottom: offset))
        #expect(moved.viewportLine(of: match.start.row) != nil)

        channel.close()
        try await client.closeWorkspace(pane.workspaceID)
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
