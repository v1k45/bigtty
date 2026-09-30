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

    init(store: SessionStore, attention: AttentionCenter) {
        self.store = store
        self.attention = attention
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
            guard let result = try? await client.call("pane.read", ["pane_id": .string(id), "source": "visible", "lines": 30]),
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
        Task.detached {
            var branches: [String: String] = [:]
            for dir in dirs {
                if let out = GitClient.run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)?
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
            let listening = ProcessPorts.listeningPorts()
            let parents = ProcessPorts.parentMap()
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

/// Listening TCP ports per process, via `lsof`, and the process tree via `ps`.
enum ProcessPorts {
    static func listeningPorts() -> [Int32: Set<Int>] {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]) else { return [:] }
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

    static func parentMap() -> [Int32: Int32] {
        guard let out = run("/bin/ps", ["-axo", "pid=,ppid="]) else { return [:] }
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

    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
