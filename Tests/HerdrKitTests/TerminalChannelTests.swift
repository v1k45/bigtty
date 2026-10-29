import Foundation
@testable import HerdrKit
import Testing

/// Channels against a stand-in herdr. A channel kept past its stream's end
/// (a reclaim probe herdr refused, a pane that went away) must not keep its
/// pipes open: enough of them fill the descriptor table, and every later
/// launch fails with "Bad file descriptor".
@Suite(.serialized) struct TerminalChannelTests {
    /// A herdr that refuses the attach and exits, as it does while another
    /// client holds the pane.
    @Test func refusedChannelsGiveBackTheirDescriptors() async throws {
        try await expectNoDescriptorsHeld(script: """
            echo '{"type":"terminal.closed","reason":"already has an attached client"}'
            """, close: false)
    }

    /// A herdr that streams until we close the channel.
    @Test func closedChannelsGiveBackTheirDescriptors() async throws {
        try await expectNoDescriptorsHeld(script: "cat >/dev/null", close: true)
    }

    private func expectNoDescriptorsHeld(script: String, close: Bool) async throws {
        let herdr = try fakeHerdr(script)
        defer { try? FileManager.default.removeItem(atPath: herdr) }
        let endpoint = HerdrEndpoint(session: "btty-test", herdrBinary: herdr)
        let before = openDescriptors()
        let ended = Counter()
        // Kept alive for the whole test, as a leaked channel would be.
        var channels: [TerminalChannel] = []
        for _ in 0..<20 {
            let channel = TerminalChannel(endpoint: endpoint, terminalID: "t1")
            channel.onClosed = { _ in ended.add() }
            try channel.start(columns: 80, rows: 24)
            channels.append(channel)
        }
        if close { channels.forEach { $0.close() } }
        if !close { try await waitUntil { ended.value == channels.count } }
        try await waitUntil { channels.allSatisfy { !$0.isRunning } }
        try await waitUntil { openDescriptors() <= before }
        #expect(openDescriptors() <= before)
        withExtendedLifetime(channels) {}
    }

    private func fakeHerdr(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "fake-herdr-\(UUID().uuidString)"
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
