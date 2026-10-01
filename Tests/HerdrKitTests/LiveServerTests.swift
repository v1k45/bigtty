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
