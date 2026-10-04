import AppKit
import HerdrKit

/// A space on some machine.
struct SpaceRef: Hashable {
    let machine: String
    let workspace: String

    /// "machine|workspace", for places that key by string (sidebar, menus).
    var key: String { machine + "|" + workspace }

    init(machine: String, workspace: String) {
        self.machine = machine
        self.workspace = workspace
    }

    init?(key: String) {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        machine = parts[0]
        workspace = parts[1]
    }
}

/// The machines bigtty shows: this Mac first, then remotes saved here
/// or in herdr's own machine list (`herdr machine add`).
@MainActor
final class MachineManager {
    struct Saved: Codable, Equatable {
        let id: String
        let name: String
        let target: String
        let session: String?
    }

    /// A herdr session on this Mac, as `herdr session list` reports it.
    struct SessionInfo: Equatable {
        /// nil is the default session.
        let name: String?
        let running: Bool
        var title: String { name ?? "default" }
    }

    /// This Mac's default session (or the one BIGTTY_SESSION names).
    let local: Machine
    /// This Mac's other herdr sessions that are running (or were opened):
    /// connected in the background so their agents still reach you.
    private(set) var sessions: [Machine] = []
    /// Every session on this Mac, stopped ones too, for the switcher.
    private(set) var knownSessions: [SessionInfo] = []
    private(set) var remotes: [Machine] = []
    /// A remote's other herdr sessions that are running, by its id.
    private(set) var remoteSessions: [String: [Machine]] = [:]
    /// Every herdr session on each remote, by its id, for the switcher.
    private(set) var remoteKnown: [String: [SessionInfo]] = [:]
    /// The session each remote shows: its id to the session's name (a
    /// remote's own session when unset).
    private var remoteShown: [String: String] = UserDefaults.standard.dictionary(forKey: "remoteSessions") as? [String: String] ?? [:]
    private var sessionTicks = 0
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var sessionTimer: Timer?

    var all: [Machine] { [local] + sessions + remotes + remotes.flatMap { remoteSessions[$0.id] ?? [] } }
    /// One machine per session on this Mac.
    var localMachines: [Machine] { [local] + sessions }

    /// The session new windows show and the sidebar lists; windows move
    /// between sessions with the switcher.
    var activeLocal: Machine {
        get { sessions.first { $0.id == activeLocalID } ?? local }
        set {
            guard newValue.isLocal, newValue.id != activeLocalID else { return }
            activeLocalID = newValue.id
            if !Self.sessionsPinned { UserDefaults.standard.set(newValue.session, forKey: "activeSession") }
            changed()
        }
    }
    private var activeLocalID = "local"

    /// BIGTTY_SESSION pins the app to one session (test copies).
    private static let sessionsPinned = !(ProcessInfo.processInfo.environment["BIGTTY_SESSION"] ?? "").isEmpty
    /// Test copies may still find other named sessions (never the default
    /// one, which is the user's) with BIGTTY_TEST_SESSIONS=1.
    private static let discovers = !sessionsPinned || ProcessInfo.processInfo.environment["BIGTTY_TEST_SESSIONS"] == "1"

    init(localEndpoint: HerdrEndpoint) {
        local = Machine(local: localEndpoint)
        local.observe { [weak self] in self?.changed() }
        if !Self.sessionsPinned, let name = UserDefaults.standard.string(forKey: "activeSession"), !name.isEmpty {
            activeLocalID = open(session: name).id
        }
        for saved in Self.load() where SSHTunnel.Config.isValid(target: saved.target) { attach(saved) }
        importHerdrMachines()
        refreshSessions()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshSessions()
                // Remotes less often: each look is an SSH command.
                self.sessionTicks += 1
                if self.sessionTicks % 3 == 0 { self.refreshRemoteSessions() }
            }
        }
    }

    // MARK: - Sessions on this Mac

    /// The machine for a named session, connecting to it if needed.
    @discardableResult
    func open(session name: String) -> Machine {
        if let existing = localMachines.first(where: { $0.session == name }) { return existing }
        let machine = Machine(local: HerdrEndpoint(session: name), id: "session:" + name)
        machine.observe { [weak self] in self?.changed() }
        sessions.append(machine)
        sessions.sort { $0.sessionName.localizedStandardCompare($1.sessionName) == .orderedAscending }
        changed()
        return machine
    }

    /// Re-reads herdr's sessions (its config folder, a connect to each
    /// socket; no process): running sessions get connected.
    func refreshSessions() {
        guard Self.discovers else { return }
        Task.detached {
            let found = HerdrEndpoint.localSessions().map { SessionInfo(name: $0.name, running: $0.running) }
            await MainActor.run { self.sessionsListed(found) }
        }
    }

    private func sessionsListed(_ found: [SessionInfo]) {
        let found = Self.sessionsPinned ? found.filter { $0.name != nil } : found
        let sorted = found.sorted { a, b in
            a.name == nil || (b.name != nil && a.title.localizedStandardCompare(b.title) == .orderedAscending)
        }
        for info in sorted where info.running {
            if let name = info.name { open(session: name) }
        }
        // Sessions deleted elsewhere (`herdr session delete`, another app)
        // are forgotten; windows showing one fall back to the default.
        let names = Set(sorted.compactMap(\.name))
        let gone = sessions.filter { machine in machine.session.map { !names.contains($0) } ?? false }
        if !gone.isEmpty {
            for machine in gone { machine.disconnect() }
            sessions.removeAll { machine in gone.contains { $0 === machine } }
            if gone.contains(where: { $0.id == activeLocalID }) { activeLocalID = local.id }
            changed()
        }
        guard sorted != knownSessions else { return }
        knownSessions = sorted
        changed()
    }

    /// Starts a named session's server in the background (detached, so it
    /// outlives the app) and returns its machine.
    @discardableResult
    func startSession(_ name: String?) -> Machine {
        let machine = name.map { open(session: $0) } ?? local
        let endpoint = HerdrEndpoint(session: name)
        let args = ([endpoint.herdrBinary] + endpoint.sessionArguments + ["server"]).map(SSHTunnel.shellQuote).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cd ~ && nohup \(args) >/dev/null 2>&1 &"]
        do { try process.run() } catch { NSLog("bigtty: could not start herdr: \(error)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshSessions() }
        return machine
    }

    /// `herdr session stop`: ends every process in it.
    func stopSession(_ name: String?) {
        run(["session", "stop", name ?? "default"])
    }

    /// `herdr session delete`, for a stopped session.
    func deleteSession(_ name: String) {
        if let machine = sessions.first(where: { $0.session == name }) {
            machine.disconnect()
            sessions.removeAll { $0 === machine }
            if activeLocalID == machine.id { activeLocal = local }
        }
        run(["session", "delete", name])
    }

    private func run(_ args: [String]) {
        guard let herdr = HerdrEndpoint.locateHerdr() else { return }
        Task.detached {
            _ = CommandRunner.local.run(herdr, args)
            await MainActor.run { self.refreshSessions() }
        }
    }

    /// Valid for `herdr --session`: letters, digits, - and _.
    nonisolated static func isValidSessionName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name != "default"
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    func machine(_ id: String) -> Machine? { all.first { $0.id == id } }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func changed() {
        // Dock badge: panes needing you across every machine.
        let count = all.reduce(0) { $0 + ($1.attention?.attention.needingAttention.count ?? 0) }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        for handler in observers.values { handler() }
    }

    // MARK: - Adding and removing

    /// Nil for a target ssh would read as an option (`-o…`) or that has spaces.
    @discardableResult
    func add(target: String, name: String?, session: String?) -> Machine? {
        guard SSHTunnel.Config.isValid(target: target) else { return nil }
        if let existing = remotes.first(where: { $0.target == target }) {
            existing.connect()
            return existing
        }
        let label = (name?.isEmpty == false ? name! : Self.defaultName(for: target))
        let saved = Saved(id: UUID().uuidString.lowercased(), name: label, target: target, session: session?.isEmpty == true ? nil : session)
        var list = Self.load()
        list.append(saved)
        Self.save(list)
        let machine = attach(saved)
        changed()
        return machine
    }

    func remove(_ id: String) {
        guard let machine = remotes.first(where: { $0.id == id }) else { return }
        machine.disconnect()
        for other in remoteSessions[id] ?? [] { other.disconnect() }
        remoteSessions[id] = nil
        remoteKnown[id] = nil
        remotes.removeAll { $0.id == id }
        Self.save(Self.load().filter { $0.id != id })
        changed()
    }

    @discardableResult
    private func attach(_ saved: Saved) -> Machine {
        let machine = Machine(id: saved.id, name: saved.name, target: saved.target, session: saved.session)
        machine.observe { [weak self, weak machine] in
            guard let self, let machine else { return }
            // Just connected: list its sessions now rather than on the timer.
            if machine.status == .connected, self.remoteKnown[machine.id] == nil { self.refreshRemoteSessions(machine) }
            self.changed()
        }
        remotes.append(machine)
        machine.connect()
        return machine
    }

    // MARK: - Sessions on remotes

    /// The session a remote shows in the sidebar: its own, or another one
    /// switched to.
    func shown(for remote: Machine) -> Machine {
        guard let name = remoteShown[remote.id], name != remote.sessionName else { return remote }
        return remoteSessions[remote.id]?.first { $0.sessionName == name } ?? remote
    }

    /// The saved remote a machine is (or is a session of).
    func remote(of machine: Machine) -> Machine? {
        remotes.first { $0.id == (machine.parentID ?? machine.id) }
    }

    /// Every session's machine on a remote: its own first.
    func sessions(of remote: Machine) -> [Machine] {
        [remote] + (remoteSessions[remote.id] ?? [])
    }

    /// Shows a remote's session in the sidebar.
    func show(_ machine: Machine) {
        guard let remote = remote(of: machine) else { return }
        remoteShown[remote.id] = machine.sessionName
        if !Self.remotesDisabled { UserDefaults.standard.set(remoteShown, forKey: "remoteSessions") }
        changed()
    }

    /// A remote's session by name, connecting to it if needed; `start`
    /// starts its herdr server when it's stopped.
    @discardableResult
    func open(session name: String?, on remote: Machine, start: Bool = false) -> Machine? {
        if name == remote.session { return remote }
        guard let name, Self.isValidSessionName(name), let target = remote.target else { return nil }
        if let existing = remoteSessions[remote.id]?.first(where: { $0.session == name }) {
            if start, existing.status == .notRunning { existing.startServer() }
            return existing
        }
        let machine = Machine(id: remote.id + "/" + name, name: remote.name, target: target, session: name, parent: remote.id)
        machine.startsWhenStopped = start
        machine.observe { [weak self] in self?.changed() }
        opened[machine.id] = Date()
        remoteSessions[remote.id, default: []].append(machine)
        remoteSessions[remote.id]?.sort { $0.sessionName.localizedStandardCompare($1.sessionName) == .orderedAscending }
        machine.connect(byUser: false)
        changed()
        return machine
    }

    /// Lists every connected remote's herdr sessions and connects the
    /// running ones, so their agents reach you too.
    func refreshRemoteSessions(_ only: Machine? = nil) {
        for remote in remotes where remote.status == .connected && (only == nil || only === remote) && !listing.contains(remote.id) {
            listing.insert(remote.id)
            let runner = remote.runner
            Task.detached {
                let found = Self.remoteSessionList(runner)
                await MainActor.run {
                    self.listing.remove(remote.id)
                    found.map { self.remoteSessionsListed($0, on: remote) }
                }
            }
        }
    }

    private var listing: Set<String> = []
    /// When each remote session's machine was made, by id.
    private var opened: [String: Date] = [:]

    private func remoteSessionsListed(_ found: [SessionInfo], on remote: Machine) {
        guard remotes.contains(where: { $0 === remote }) else { return }
        for info in found where info.running && info.name != remote.session {
            open(session: info.name, on: remote)
        }
        // Stopped or deleted elsewhere: let go, unless just opened (it may
        // be starting).
        let running = Set(found.filter(\.running).map(\.title))
        let gone = (remoteSessions[remote.id] ?? []).filter { machine in
            !running.contains(machine.sessionName) && Date().timeIntervalSince(opened[machine.id] ?? .distantPast) > 30
        }
        if !gone.isEmpty {
            for machine in gone { machine.disconnect() }
            remoteSessions[remote.id]?.removeAll { machine in gone.contains { $0 === machine } }
        }
        let sorted = found.sorted { a, b in
            a.name == nil || (b.name != nil && a.title.localizedStandardCompare(b.title) == .orderedAscending)
        }
        if sorted != remoteKnown[remote.id] || !gone.isEmpty {
            remoteKnown[remote.id] = sorted
            changed()
        }
    }

    /// herdr's sessions on a remote: its config folder, and whether each
    /// has a server socket. Nil when the command fails.
    nonisolated static func remoteSessionList(_ runner: CommandRunner) -> [SessionInfo]? {
        let script = """
        base="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
        if [ -d "$base" ]; then r=no; [ -S "$base/herdr.sock" ] && r=yes; printf '\\t%s\\n' "$r"; fi
        for d in "$base"/sessions/*/; do
          [ -d "$d" ] || continue
          n="$(basename "$d")"; r=no; [ -S "$d/herdr.sock" ] && r=yes
          printf '%s\\t%s\\n' "$n" "$r"
        done
        """
        guard let output = runner.run("sh", ["-c", script]) else { return nil }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            let name = parts[0].isEmpty ? nil : parts[0]
            if let name, !isValidSessionName(name) { return nil }
            return SessionInfo(name: name, running: parts[1] == "yes")
        }
    }

    nonisolated static func defaultName(for target: String) -> String {
        var host = target.split(separator: "@").last.map(String.init) ?? target
        host = host.split(separator: ":").first.map(String.init) ?? host
        // An address stays whole ("192.168.1.20", not "192"); a name loses
        // its domain ("box.example.com" → "box").
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        return host.split(separator: ".").first.map(String.init) ?? host
    }

    /// Machines saved with `herdr machine add` show up here too.
    private func importHerdrMachines() {
        guard let herdr = HerdrEndpoint.locateHerdr() else { return }
        Task.detached {
            guard let json = CommandRunner.local.run(herdr, ["machine", "list", "--json"]),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return }
            let entries: [JSONValue] = if case let .array(a) = value { a } else if case let .array(a)? = value["machines"] { a } else { [] }
            let found = entries.compactMap { entry -> (String, String, String?)? in
                guard entry["enabled"]?.boolValue != false,
                      let target = entry["target"]?.stringValue ?? entry["ssh_target"]?.stringValue ?? entry["ssh"]?.stringValue
                else { return nil }
                let label = entry["label"]?.stringValue ?? MachineManager.defaultName(for: target)
                return (target, label, entry["remote_session"]?.stringValue ?? entry["session"]?.stringValue)
            }
            await MainActor.run {
                for (target, label, session) in found where !self.remotes.contains(where: { $0.target == target }) {
                    self.add(target: target, name: label, session: session)
                }
            }
        }
    }

    // MARK: - Persistence

    private static let key = "machines"

    /// `BIGTTY_NO_REMOTES=1` runs with this Mac only, e.g. a test copy
    /// that must not take panes from the instance you're using.
    private static let remotesDisabled = ProcessInfo.processInfo.environment["BIGTTY_NO_REMOTES"] == "1"

    private static func load() -> [Saved] {
        if remotesDisabled { return [] }
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Saved].self, from: data)) ?? []
    }

    private static func save(_ list: [Saved]) {
        if remotesDisabled { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}
