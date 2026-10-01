import Foundation

/// herdr's NDJSON socket API. The server answers one request per connection,
/// so every call opens a fresh socket.
public struct HerdrClient: Sendable {
    public let endpoint: HerdrEndpoint
    public var timeout: TimeInterval = 5

    public init(endpoint: HerdrEndpoint) {
        self.endpoint = endpoint
    }

    private struct Request: Encodable {
        let id: String
        let method: String
        let params: JSONValue
    }

    private struct Response: Decodable {
        struct ErrorBody: Decodable { let code: String; let message: String }
        let result: JSONValue?
        let error: ErrorBody?
    }

    /// Sends one request and returns its `result` object.
    @discardableResult
    public func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let path = endpoint.socketPath
        let timeout = timeout
        return try await Task.detached {
            let socket = try UnixSocket(path: path, timeout: timeout)
            defer { socket.close() }
            let request = Request(id: UUID().uuidString, method: method, params: params)
            try socket.writeLine(JSONEncoder().encode(request))
            guard let line = try socket.readLine() else {
                throw HerdrError.io("connection closed before \(method) replied")
            }
            let response = try JSONDecoder().decode(Response.self, from: line)
            if let error = response.error {
                throw HerdrError.server(code: error.code, message: error.message)
            }
            guard let result = response.result else { throw HerdrError.decode("\(method): no result") }
            return result
        }.value
    }

    func call<T: Decodable>(_ method: String, _ params: JSONValue = [:], key: String, as _: T.Type) async throws -> T {
        let result = try await call(method, params)
        guard let value = result[key] else { throw HerdrError.decode("\(method): missing \(key)") }
        do { return try value.decode(T.self) } catch { throw HerdrError.decode("\(method): \(error)") }
    }

    // MARK: - Typed helpers

    public func ping() async throws -> Pong {
        try await call("ping").decode(Pong.self)
    }

    public func snapshot() async throws -> Snapshot {
        try await call("session.snapshot", key: "snapshot", as: Snapshot.self)
    }

    public func layout(tabID: String) async throws -> TabLayout {
        try await call("layout.export", ["tab_id": .string(tabID)], key: "layout", as: TabLayout.self)
    }

    @discardableResult
    public func split(paneID: String, direction: SplitDirection, ratio: Double? = nil, focus: Bool = true) async throws -> Pane {
        var params: [String: JSONValue] = [
            "target_pane_id": .string(paneID),
            "direction": .string(direction.rawValue),
            "focus": .bool(focus),
        ]
        if let ratio { params["ratio"] = .number(ratio) }
        return try await call("pane.split", .object(params), key: "pane", as: Pane.self)
    }

    public func setSplitRatio(tabID: String, path: [Bool], ratio: Double) async throws {
        try await call("layout.set_split_ratio", [
            "tab_id": .string(tabID),
            "path": .array(path.map(JSONValue.bool)),
            "ratio": .number(ratio),
        ])
    }

    public func focusPane(_ paneID: String) async throws {
        try await call("pane.focus", ["pane_id": .string(paneID)])
    }

    public func focusDirection(_ direction: String, from paneID: String?) async throws {
        var params: [String: JSONValue] = ["direction": .string(direction)]
        if let paneID { params["pane_id"] = .string(paneID) }
        try await call("pane.focus_direction", .object(params))
    }

    public func resizePane(_ paneID: String?, direction: String, amount: Double? = nil) async throws {
        var params: [String: JSONValue] = ["direction": .string(direction)]
        if let paneID { params["pane_id"] = .string(paneID) }
        if let amount { params["amount"] = .number(amount) }
        try await call("pane.resize", .object(params))
    }

    public func zoomPane(_ paneID: String?) async throws {
        var params: [String: JSONValue] = [:]
        if let paneID { params["pane_id"] = .string(paneID) }
        try await call("pane.zoom", .object(params))
    }

    /// Where a dragged pane lands relative to the pane it's dropped on.
    public enum DropZone: String, Sendable {
        case left, right, top, bottom
        /// Trade places.
        case center
    }

    public func swapPanes(_ source: String, _ target: String) async throws {
        try await call("pane.swap", ["source_pane_id": .string(source), "target_pane_id": .string(target)])
    }

    /// Moves `paneID` next to `target` in `tabID` (right of or below it).
    public func movePane(_ paneID: String, toTab tabID: String, beside target: String?, split: String) async throws {
        var destination: [String: JSONValue] = ["type": "tab", "tab_id": .string(tabID), "split": .string(split)]
        if let target { destination["target_pane_id"] = .string(target) }
        try await call("pane.move", ["pane_id": .string(paneID), "destination": .object(destination), "focus": true])
    }

    public func movePaneToNewTab(_ paneID: String, workspaceID: String) async throws {
        try await call("pane.move", ["pane_id": .string(paneID), "destination": ["type": "new_tab", "workspace_id": .string(workspaceID)]])
    }

    public func closePane(_ paneID: String) async throws {
        try await call("pane.close", ["pane_id": .string(paneID)])
    }

    public func focusTab(_ tabID: String) async throws {
        try await call("tab.focus", ["tab_id": .string(tabID)])
    }

    public func createTab(workspaceID: String) async throws {
        try await call("tab.create", ["workspace_id": .string(workspaceID), "focus": true])
    }

    /// Creates a focused tab and returns its first pane.
    public func createTab(in workspaceID: String) async throws -> Pane {
        try await call("tab.create", ["workspace_id": .string(workspaceID), "focus": true], key: "root_pane", as: Pane.self)
    }

    /// The names of a pane's foreground processes (a shell at its prompt, or
    /// whatever runs in it).
    public func foregroundProcesses(of paneID: String) async throws -> [String] {
        let info = try await call("pane.process_info", ["pane_id": .string(paneID)])
        guard case let .array(processes)? = info["process_info"]?["foreground_processes"] else { return [] }
        return processes.compactMap { $0["name"]?.stringValue }
    }

    public func closeTab(_ tabID: String) async throws {
        try await call("tab.close", ["tab_id": .string(tabID)])
    }

    public func focusWorkspace(_ workspaceID: String) async throws {
        try await call("workspace.focus", ["workspace_id": .string(workspaceID)])
    }

    /// Returns the new workspace's first pane.
    @discardableResult
    public func createWorkspace(cwd: String?, label: String? = nil, focus: Bool = true) async throws -> Pane {
        var params: [String: JSONValue] = ["focus": .bool(focus)]
        if let cwd { params["cwd"] = .string(cwd) }
        if let label { params["label"] = .string(label) }
        return try await call("workspace.create", .object(params), key: "root_pane", as: Pane.self)
    }

    /// Moves a workspace to `index` in herdr's order (shared by every client).
    public func moveWorkspace(_ workspaceID: String, to index: Int) async throws {
        _ = try await call("workspace.move", ["workspace_id": .string(workspaceID), "insert_index": .number(Double(max(0, index)))])
    }

    public func renameWorkspace(_ workspaceID: String, label: String) async throws {
        try await call("workspace.rename", ["workspace_id": .string(workspaceID), "label": .string(label)])
    }

    public func closeWorkspace(_ workspaceID: String) async throws {
        try await call("workspace.close", ["workspace_id": .string(workspaceID)])
    }

    /// The pane's recent output as plain text, soft wraps joined (what
    /// search looks through).
    public func readPane(_ paneID: String, lines: Int = 3000) async throws -> String {
        let result = try await call("pane.read", [
            "pane_id": .string(paneID), "source": "recent_unwrapped", "lines": .number(Double(lines)),
        ])
        return result["read"]?["text"]?.stringValue ?? ""
    }

    public func sendText(paneID: String, text: String) async throws {
        try await call("pane.send_text", ["pane_id": .string(paneID), "text": .string(text)])
    }

    public func reportMetadata(paneID: String, title: String?, tokens: [String: String]) async throws {
        var params: [String: JSONValue] = [
            "pane_id": .string(paneID),
            "source": "bigtty",
            "tokens": .object(tokens.mapValues(JSONValue.string)),
        ]
        if let title { params["title"] = .string(title) }
        try await call("pane.report_metadata", .object(params))
    }
}
