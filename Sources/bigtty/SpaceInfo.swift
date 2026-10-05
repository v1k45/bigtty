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
        /// Last sign of life: an agent's conversation changing, or an agent
        /// changing state. Nil if nothing's known.
        var lastActive: Date?
        /// Something is running or waiting on you: never "stale".
        var busy = false
    }

    private let store: SessionStore
    private let attention: AttentionCenter
    private(set) var info: [String: Info] = [:]
    private var branches: [String: String] = [:]
    private var ports: [String: [Int]] = [:]
    /// Agent conversation names by pane (Claude Code's session title).
    private(set) var agentTitles: [String: String] = [:]
    /// When each pane's agent conversation last changed (its session file).
    private var sessionActivity: [String: Date] = [:]
    /// When each pane's agent last changed state, seen by this app.
    private var statusChanged: [String: Date] = [:]
    private var lastStatus: [String: AgentStatus] = [:]
    /// Question text of blocked panes, read once per block.
    private var questions: [String: String] = [:]
    private var observers: [UUID: @MainActor () -> Void] = [:]
    /// What a blocked pane's agent asks, once read.
    func question(for paneID: String) -> String? { questions[paneID].flatMap { $0.isEmpty ? nil : $0 } }
    private var timer: Timer?
    private var refreshing = false

    /// Where git and port probes run: this Mac, or the machine over SSH.
    private let runner: @MainActor () -> CommandRunner

    init(store: SessionStore, attention: AttentionCenter, runner: @escaping @MainActor () -> CommandRunner = { .local }) {
        self.store = store
        self.attention = attention
        self.runner = runner
        store.observe { [weak self] in
            self?.recompute()
            self?.refreshIfShapeChanged()
        }
        attention.observe { [weak self] in self?.recompute() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1
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

    /// The pane that speaks for a space: the focused pane of its active tab,
    /// never a pinned pane passing through (its folder is somewhere else).
    private func leadPane(_ workspace: Workspace) -> Pane? {
        let all = store.panes(in: workspace.activeTabID)
        let own = all.filter { $0.tokens?["btty_pin"] == nil }
        let panes = own.isEmpty ? all : own
        return panes.first { $0.focused } ?? panes.first
    }

    private func recompute() {
        // Agent state changes are activity too.
        for pane in store.snapshot.panes where pane.agent != nil || pane.displayAgent != nil {
            if let previous = lastStatus[pane.paneID], previous != pane.agentStatus { statusChanged[pane.paneID] = Date() }
            lastStatus[pane.paneID] = pane.agentStatus
        }
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
            item.busy = agents.contains { $0.agentStatus == .working || $0.agentStatus == .blocked }
            item.lastActive = panes.compactMap { max(sessionActivity[$0.paneID] ?? .distantPast, statusChanged[$0.paneID] ?? .distantPast) }
                .max().flatMap { $0 == .distantPast ? nil : $0 }
            // "claude · idle · 3h": how long it's been quiet.
            if !item.busy, let line = item.line, !item.lineIsAlert, let last = item.lastActive {
                item.line = line + " · " + Self.age(since: last)
            }
            next[workspace.workspaceID] = item
        }
        // Every blocked agent's question, seen or not, for Needs You (cards
        // show one per space): you come back to a seen one to answer it.
        let blocked = Set(store.snapshot.panes.filter { $0.agentStatus == .blocked }.map(\.paneID))
        for pane in store.snapshot.panes where blocked.contains(pane.paneID) && questions[pane.paneID] == nil {
            fetchQuestion(pane)
        }
        // Forget questions of panes that are no longer blocked.
        questions = questions.filter { blocked.contains($0.key) }
        guard next != info else { return }
        info = next
        for handler in observers.values { handler() }
    }

    /// "now", "5m", "3h", "2d": compact, for card lines.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
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

    private var lastSlow = Date.distantPast
    /// Shell pid of each pane, keyed by pane and terminal: it only changes
    /// with the terminal, so herdr is asked once per pane.
    private var shellPIDs: [String: Int32] = [:]

    /// Branches and ports every 5 s while you're using the app, every 30 s
    /// in the background, not at all while no window is on screen.
    private func tick() {
        let onScreen = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0 is MainWindow }
        let interval: TimeInterval = !onScreen ? 60 : NSApp.isActive ? 5 : 30
        guard Date().timeIntervalSince(lastSlow) >= interval - 0.5 else { return }
        refreshSlow()
    }

    /// New spaces, panes or folders refresh right away.
    private var probedShape: Set<String> = []

    private func refreshIfShapeChanged() {
        let shape = Set(store.snapshot.panes.map { $0.paneID + "|" + $0.terminalID + "|" + ($0.foregroundCwd ?? $0.cwd ?? "") })
        guard shape != probedShape else { return }
        probedShape = shape
        refreshSlow()
    }

    private func refreshSlow() {
        guard !refreshing else { return }
        refreshing = true
        lastSlow = Date()
        let dirs = Set(store.snapshot.workspaces.compactMap { leadPane($0).flatMap { $0.foregroundCwd ?? $0.cwd } })
        let panes = store.snapshot.panes.filter { $0.hostKind == nil }
        let sessions = panes.compactMap { pane -> (pane: String, agent: String, id: String)? in
            guard let session = pane.agentSession, let id = session.value, let agent = session.agent ?? pane.agent else { return nil }
            return (pane.paneID, agent, id)
        }
        let client = store.client
        let runner = runner()
        let known = shellPIDs
        Task.detached {
            // Shell pids: only panes not seen before, in parallel.
            var pids = known.filter { key, _ in panes.contains { $0.paneID + "|" + $0.terminalID == key } }
            let missing = panes.filter { pids[$0.paneID + "|" + $0.terminalID] == nil }
            await withTaskGroup(of: (String, Int32?).self) { group in
                for pane in missing {
                    group.addTask {
                        let info = try? await client.call("pane.process_info", ["pane_id": .string(pane.paneID)])
                        return (pane.paneID + "|" + pane.terminalID, info?["process_info"]?["shell_pid"]?.intValue.map(Int32.init))
                    }
                }
                for await (key, pid) in group { if let pid { pids[key] = pid } }
            }
            var shells: [String: Set<Int32>] = [:]
            for pane in panes {
                if let pid = pids[pane.paneID + "|" + pane.terminalID] { shells[pane.workspaceID, default: []].insert(pid) }
            }
            var titles: [String: String] = [:]
            var activity: [String: Date] = [:]
            let (branches, listening, parents): ([String: String], [Int32: Set<Int>], [Int32: Int32])
            if runner.ssh == nil {
                (branches, listening, parents) = Self.localProbe(dirs: dirs, roots: shells.values.reduce(into: Set<Int32>()) { $0.formUnion($1) })
                for session in sessions {
                    titles[session.pane] = AgentTitles.local(agent: session.agent, sessionID: session.id)
                    activity[session.pane] = AgentTitles.lastActivity(agent: session.agent, sessionID: session.id)
                }
            } else {
                let remote = Self.remoteProbe(dirs: dirs, sessions: sessions.map { ($0.agent, $0.id) }, runner: runner)
                (branches, listening, parents) = (remote.branches, remote.listening, remote.parents)
                for session in sessions {
                    titles[session.pane] = remote.titles[session.id]
                    activity[session.pane] = remote.modified[session.id]
                }
            }
            var ports: [String: [Int]] = [:]
            for (workspace, roots) in shells {
                var found = Set<Int>()
                for (pid, pidPorts) in listening where ProcessPorts.descends(pid, from: roots, parents: parents) {
                    found.formUnion(pidPorts)
                }
                ports[workspace] = found.sorted()
            }
            await MainActor.run {
                self.shellPIDs = pids
                if self.agentTitles != titles {
                    self.agentTitles = titles
                    self.info = [:] // re-announce: tab names changed
                }
                self.sessionActivity = activity
                self.branches = branches
                self.ports = ports
                self.refreshing = false
                self.recompute()
            }
        }
    }

    /// This Mac: HEAD files and kernel queries, no processes spawned.
    nonisolated private static func localProbe(dirs: Set<String>, roots: Set<Int32>)
        -> ([String: String], [Int32: Set<Int>], [Int32: Int32])
    {
        var branches: [String: String] = [:]
        for dir in dirs { if let branch = LocalProcesses.gitBranch(dir) { branches[dir] = branch } }
        let parents = LocalProcesses.parentMap()
        let listening = LocalProcesses.listeningPorts(of: LocalProcesses.descendants(of: roots, parents: parents))
        return (branches, listening, parents)
    }

    /// Another machine: one SSH command for branches, sockets and the
    /// process tree.
    nonisolated private static func remoteProbe(dirs: Set<String>, sessions: [(agent: String, id: String)], runner: CommandRunner)
        -> (branches: [String: String], listening: [Int32: Set<Int>], parents: [Int32: Int32], titles: [String: String], modified: [String: Date])
    {
        let script = """
        for d in "$@"; do b=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null) && printf 'B\t%s\t%s\n' "$d" "$b"; done
        echo '--ports'
        ss -ltnpH 2>/dev/null || true
        echo '--parents'
        ps -eo pid=,ppid= 2>/dev/null || ps -axo pid=,ppid=
        echo '--titles'
        \(AgentTitles.remoteScript(sessions: sessions))
        """
        guard let out = runner.run("sh", ["-c", script, "sh"] + dirs.sorted()) else { return ([:], [:], [:], [:], [:]) }
        var modified: [String: Date] = [:]
        var titleLines: [String: [Substring]] = [:]
        var branches: [String: String] = [:]
        var section = "branches"
        var portLines: [Substring] = [], parentLines: [Substring] = []
        for line in out.split(separator: "\n") {
            if line == "--ports" { section = "ports"; continue }
            if line == "--parents" { section = "parents"; continue }
            if line == "--titles" { section = "titles"; continue }
            switch section {
            case "branches":
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                if parts.count == 3, parts[0] == "B", !parts[2].isEmpty { branches[parts[1]] = parts[2] == "HEAD" ? "detached" : parts[2] }
            case "ports": portLines.append(line)
            case "titles":
                if line.hasPrefix("T\t") { titleLines["", default: []].append(line.dropFirst(2)) }
                if line.hasPrefix("M\t") {
                    let parts = line.split(separator: "\t")
                    if parts.count == 3, let epoch = Double(parts[2]) { modified[String(parts[1])] = Date(timeIntervalSince1970: epoch) }
                }
            default: parentLines.append(line)
            }
        }
        let titles = AgentTitles.parseRemote(titleLines[""] ?? [])
        return (branches, ProcessPorts.parseSS(portLines), ProcessPorts.parseParents(parentLines), titles, modified)
    }
}

/// Parsers for another machine's `ss` and `ps` output.
enum ProcessPorts {
    /// `ss -ltnpH`: LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=1234,fd=20))
    static func parseSS(_ lines: [Substring]) -> [Int32: Set<Int>] {
        var result: [Int32: Set<Int>] = [:]
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let colon = fields[3].lastIndex(of: ":"),
                  let port = Int(fields[3][fields[3].index(after: colon)...]) else { continue }
            var rest = line
            while let range = rest.range(of: "pid=") {
                let digits = rest[range.upperBound...].prefix { $0.isNumber }
                if let pid = Int32(digits) { result[pid, default: []].insert(port) }
                rest = rest[range.upperBound...]
            }
        }
        return result
    }

    /// `ps -o pid=,ppid=` lines.
    static func parseParents(_ lines: [Substring]) -> [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for line in lines {
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
