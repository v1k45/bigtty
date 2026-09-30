import Foundation

// Field names follow herdr's snake_case wire format through explicit coding
// keys: `convertFromSnakeCase` would also rewrite the keys of `tokens`.

public enum AgentStatus: String, Sendable, Codable, Comparable {
    case idle, working, blocked, done, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// Higher is more urgent: blocked > done > working > idle > unknown.
    var urgency: Int {
        switch self {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    public static func < (a: AgentStatus, b: AgentStatus) -> Bool { a.urgency < b.urgency }
}

public struct Workspace: Sendable, Codable, Equatable, Identifiable {
    public var id: String { workspaceID }
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let paneCount: Int
    public let tabCount: Int
    public let activeTabID: String
    public let agentStatus: AgentStatus
    public let tokens: [String: String]?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", number, label, focused
        case paneCount = "pane_count", tabCount = "tab_count"
        case activeTabID = "active_tab_id", agentStatus = "agent_status", tokens
    }
}

public struct Tab: Sendable, Codable, Equatable, Identifiable {
    public var id: String { tabID }
    public let tabID: String
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let paneCount: Int
    public let agentStatus: AgentStatus

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", workspaceID = "workspace_id", number, label, focused
        case paneCount = "pane_count", agentStatus = "agent_status"
    }
}

public struct Pane: Sendable, Codable, Equatable, Identifiable {
    public var id: String { paneID }
    public let paneID: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let focused: Bool
    public let cwd: String?
    public let foregroundCwd: String?
    public let agentStatus: AgentStatus
    public let agent: String?
    public let displayAgent: String?
    public let label: String?
    public let title: String?
    public let terminalTitle: String?
    public let tokens: [String: String]?
    public let revision: Int
    /// The agent's own session (Claude Code's session id), when herdr knows it.
    public let agentSession: AgentSession?

    public struct AgentSession: Sendable, Codable, Equatable {
        public let agent: String?
        public let value: String?
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", terminalID = "terminal_id", workspaceID = "workspace_id"
        case tabID = "tab_id", focused, cwd, foregroundCwd = "foreground_cwd"
        case agentStatus = "agent_status", agent, displayAgent = "display_agent"
        case label, title, terminalTitle = "terminal_title_stripped", tokens, revision
        case agentSession = "agent_session"
    }

    /// What the pane says it's about: its label, else the title its program
    /// set (Claude Code's conversation title, a shell's user@host:dir),
    /// without a leading status glyph ("✳ ", a spinner). Nil if neither.
    public var shownTitle: String? {
        if let label, !label.isEmpty { return label }
        guard let raw = title ?? terminalTitle else { return nil }
        let cleaned = raw.drop { !$0.isLetter && !$0.isNumber && $0 != "~" && $0 != "/" && $0 != "#" && $0 != "(" && $0 != "[" }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Best short name for headers: explicit label, agent, title, then cwd.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if let a = displayAgent ?? agent { return a }
        if let t = title ?? terminalTitle, !t.isEmpty { return t }
        if let c = foregroundCwd ?? cwd { return (c as NSString).lastPathComponent }
        return paneID
    }
}

public struct Snapshot: Sendable, Codable, Equatable {
    public let version: String
    public let `protocol`: Int
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [Pane]

    enum CodingKeys: String, CodingKey {
        case version, `protocol`
        case focusedWorkspaceID = "focused_workspace_id", focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id", workspaces, tabs, panes
    }

    public static let empty = Snapshot(
        version: "", protocol: 0, focusedWorkspaceID: nil, focusedTabID: nil,
        focusedPaneID: nil, workspaces: [], tabs: [], panes: []
    )
}

public enum SplitDirection: String, Sendable, Codable {
    /// The second child sits to the right of the first.
    case right
    /// The second child sits below the first.
    case down
}

/// A tab's split tree, from `layout.export`.
public indirect enum LayoutNode: Sendable, Equatable, Decodable {
    case pane(id: String)
    case split(direction: SplitDirection, ratio: Double, first: LayoutNode, second: LayoutNode)

    enum CodingKeys: String, CodingKey { case type, paneID = "pane_id", direction, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "split":
            self = try .split(
                direction: c.decode(SplitDirection.self, forKey: .direction),
                ratio: c.decode(Double.self, forKey: .ratio),
                first: c.decode(LayoutNode.self, forKey: .first),
                second: c.decode(LayoutNode.self, forKey: .second)
            )
        default:
            self = try .pane(id: c.decode(String.self, forKey: .paneID))
        }
    }

    public var paneIDs: [String] {
        switch self {
        case let .pane(id): [id]
        case let .split(_, _, a, b): a.paneIDs + b.paneIDs
        }
    }
}

public struct TabLayout: Sendable, Equatable, Decodable {
    public let tabID: String
    public let zoomed: Bool
    public let focusedPaneID: String?
    public let root: LayoutNode

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", zoomed, focusedPaneID = "focused_pane_id", root
    }
}

public struct HerdrEvent: Sendable, Decodable {
    public let event: String
    public let data: JSONValue
}

public struct Pong: Sendable, Decodable {
    public let version: String
    public let `protocol`: Int
}
