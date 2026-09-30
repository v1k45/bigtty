import AppKit
import HerdrKit

/// Live context for each space's sidebar card: folder, git branch, listening
/// ports and a one-line summary of what its agents are doing. Refreshed in
/// the background; cards read the latest values.
@MainActor
final class SpaceInfoCenter {
    struct Info: Equatable {
        var directory: String?
        var branch: String?
        var ports: [Int] = []
        /// "claude · working", "claude: Do you want to proceed? …"
        var line: String?
        var lineIsAlert = false
    }

    private let store: SessionStore
    private let attention: AttentionCenter
    private(set) var info: [String: Info] = [:]
    private var branches: [String: String] = [:]
    private var ports: [String: [Int]] = [:]
    /// Question text of blocked panes, read once per block.
    private var questions: [String: String] = [:]
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var timer: Timer?
    private var refreshing = false

    /// Where git and port probes run: this Mac, or the machine over SSH.
    private let runner: @MainActor () -> CommandRunner

    init(store: SessionStore, attention: AttentionCenter, runner: @escaping @MainActor () -> CommandRunner = { .local }) {
        self.store = store
        self.attention = attention
        self.runner = runner
        store.observe { [weak self] in self?.recompute() }
        attention.observe { [weak self] in self?.recompute() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSlow() }
        }
        refreshSlow()
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    // MARK: - Derivation

    /// The pane that speaks for a space: the focused pane of its active tab.
    private func leadPane(_ workspace: Workspace) -> Pane? {
        let panes = store.panes(in: workspace.activeTabID)
        return panes.first { $0.focused } ?? panes.first
    }

    private func recompute() {
        var next: [String: Info] = [:]
        for workspace in store.snapshot.workspaces {
            let panes = store.snapshot.panes.filter { $0.workspaceID == workspace.workspaceID }
            let lead = leadPane(workspace)
            let dir = lead?.foregroundCwd ?? lead?.cwd
            var item = Info(directory: dir, branch: dir.flatMap { branches[$0] }, ports: ports[workspace.workspaceID] ?? [])
            let agents = panes.filter { $0.agent != nil || $0.displayAgent != nil }
            let name: (Pane) -> String = { $0.displayAgent ?? $0.agent ?? "agent" }
            if let blocked = agents.first(where: { attention.reason(for: $0.paneID) == .blocked }) {
                let question = questions[blocked.paneID]
                item.line = question.map { "\(name(blocked)): \($0)" } ?? "\(name(blocked)) needs you"
                item.lineIsAlert = true
                if question == nil { fetchQuestion(blocked) }
            } else if let done = agents.first(where: { attention.reason(for: $0.paneID) == .done }) {
                item.line = "\(name(done)) finished"
            } else if let waiting = agents.first(where: { $0.agentStatus == .blocked }) {
                // Blocked but already seen: say so, without the alert.
                item.line = "\(name(waiting)) · waiting for you"
            } else if let working = agents.first(where: { $0.agentStatus == .working }) {
                item.line = "\(name(working)) · working"
            } else if let idle = agents.first {
                item.line = "\(name(idle)) · idle"
            }
            next[workspace.workspaceID] = item
        }
        // Forget questions of panes that are no longer blocked.
        questions = questions.filter { attention.reason(for: $0.key) == .blocked }
        guard next != info else { return }
        info = next
        for handler in observers.values { handler() }
    }

    /// The agent's question, from the bottom of its screen: the last line
    /// ending in "?", else the last non-empty line.
    private func fetchQuestion(_ pane: Pane) {
        questions[pane.paneID] = questions[pane.paneID] ?? ""
        let client = store.client
        let id = pane.paneID
        Task {
            guard let result = try? await client.call("pane.read", ["pane_id": .string(id), "source": "recent_unwrapped", "lines": 40]),
                  let text = result["read"]?["text"]?.stringValue else { return }
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let question = lines.last { $0.hasSuffix("?") } ?? lines.last ?? ""
            questions[id] = String(question.prefix(140))
            recompute()
        }
    }

    // MARK: - Slow sources: git and ports

    private func refreshSlow() {
        guard !refreshing else { return }
        refreshing = true
        let dirs = Set(store.snapshot.workspaces.compactMap { leadPane($0).flatMap { $0.foregroundCwd ?? $0.cwd } })
        let workspaces = store.snapshot.workspaces
        let panesByWorkspace = Dictionary(grouping: store.snapshot.panes, by: \.workspaceID).mapValues { $0.map(\.paneID) }
        let client = store.client
        let runner = runner()
        Task.detached {
            var branches: [String: String] = [:]
            for dir in dirs {
                if let out = runner.run("git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty
                {
                    branches[dir] = out == "HEAD" ? "detached" : out
                }
            }
            // Map each space's shell processes to the ports their descendants listen on.
            var shells: [String: [Int32]] = [:]
            for workspace in workspaces {
                for paneID in panesByWorkspace[workspace.workspaceID] ?? [] {
                    if let info = try? await client.call("pane.process_info", ["pane_id": .string(paneID)]),
                       let pid = info["process_info"]?["shell_pid"]?.intValue
                    {
                        shells[workspace.workspaceID, default: []].append(Int32(pid))
                    }
                }
            }
            let listening = ProcessPorts.listeningPorts(runner)
            let parents = ProcessPorts.parentMap(runner)
            var ports: [String: [Int]] = [:]
            for (workspace, roots) in shells {
                let rootSet = Set(roots)
                var found = Set<Int>()
                for (pid, pidPorts) in listening where ProcessPorts.descends(pid, from: rootSet, parents: parents) {
                    found.formUnion(pidPorts)
                }
                ports[workspace] = found.sorted()
            }
            await MainActor.run {
                self.branches = branches
                self.ports = ports
                self.refreshing = false
                self.recompute()
            }
        }
    }
}

/// Listening TCP ports per process (`lsof` on macOS, `ss` on Linux) and
/// the process tree via `ps`.
enum ProcessPorts {
    static func listeningPorts(_ runner: CommandRunner) -> [Int32: Set<Int>] {
        if runner.ssh != nil, let out = runner.run("ss", ["-ltnpH"]) {
            // LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=1234,fd=20))
            var result: [Int32: Set<Int>] = [:]
            for line in out.split(separator: "\n") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 4, let colon = fields[3].lastIndex(of: ":"),
                      let port = Int(fields[3][fields[3].index(after: colon)...]) else { continue }
                var rest = Substring(line)
                while let range = rest.range(of: "pid=") {
                    let digits = rest[range.upperBound...].prefix { $0.isNumber }
                    if let pid = Int32(digits) { result[pid, default: []].insert(port) }
                    rest = rest[range.upperBound...]
                }
            }
            return result
        }
        guard let out = runner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]) else { return [:] }
        var result: [Int32: Set<Int>] = [:]
        var pid: Int32?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...])
            {
                result[pid, default: []].insert(port)
            }
        }
        return result
    }

    static func parentMap(_ runner: CommandRunner) -> [Int32: Int32] {
        guard let out = runner.run("ps", runner.ssh != nil ? ["-eo", "pid=,ppid="] : ["-axo", "pid=,ppid="]) else { return [:] }
        var map: [Int32: Int32] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) { map[pid] = ppid }
        }
        return map
    }

    static func descends(_ pid: Int32, from roots: Set<Int32>, parents: [Int32: Int32]) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if roots.contains(current) { return true }
            guard let parent = parents[current], parent > 1 else { return false }
            current = parent
        }
        return false
    }

}
