import Foundation

/// A long-lived `events.subscribe` connection. herdr closes it with
/// `events_lost` when the reader falls behind; callers then re-snapshot and
/// subscribe again, which `SessionStore` does.
public final class EventStream: @unchecked Sendable {
    /// Every event that needs no pane id. `pane.updated` carries agent status
    /// changes; `pane.agent_status_changed` must be subscribed per pane.
    public static let allEventTypes = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated",
        "workspace.renamed", "workspace.moved", "workspace.reordered",
        "workspace.closed", "workspace.focused",
        "worktree.created", "worktree.opened", "worktree.removed",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.updated", "pane.closed", "pane.focused", "pane.moved",
        "pane.exited", "pane.agent_detected",
        "layout.updated",
    ]

    private let socket: UnixSocket

    /// Connects and waits for `subscription_started`, so a snapshot taken
    /// after this returns cannot miss an event.
    public init(
        endpoint: HerdrEndpoint,
        types: [String] = EventStream.allEventTypes,
        agentStatusPanes: [String] = []
    ) throws {
        socket = try UnixSocket(path: endpoint.socketPath, timeout: nil)
        let perPane: [JSONValue] = agentStatusPanes.map {
            ["type": "pane.agent_status_changed", "pane_id": .string($0)]
        }
        let subscriptions = JSONValue.array(types.map { ["type": .string($0)] } + perPane)
        let request: JSONValue = [
            "id": "subscribe",
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions],
        ]
        try socket.writeLine(JSONEncoder().encode(request))
        guard let line = try socket.readLine() else {
            throw HerdrError.io("subscription closed immediately")
        }
        let reply = try JSONDecoder().decode(JSONValue.self, from: line)
        if let error = reply["error"] {
            throw HerdrError.server(
                code: error["code"]?.stringValue ?? "?",
                message: error["message"]?.stringValue ?? ""
            )
        }
    }

    /// Blocks until the next event; `nil` when the stream ends.
    public func next() throws -> HerdrEvent? {
        while let line = try socket.readLine() {
            if line.isEmpty { continue }
            if let event = try? JSONDecoder().decode(HerdrEvent.self, from: line) {
                return event
            }
            let value = try? JSONDecoder().decode(JSONValue.self, from: line)
            if let error = value?["error"] {
                throw HerdrError.server(
                    code: error["code"]?.stringValue ?? "?",
                    message: error["message"]?.stringValue ?? ""
                )
            }
        }
        return nil
    }

    public func close() {
        socket.shutdown()
        socket.close()
    }
}
