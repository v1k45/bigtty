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

/// The machines GhostHerdr shows: this Mac first, then remotes saved here
/// or in herdr's own machine list (`herdr machine add`).
@MainActor
final class MachineManager {
    struct Saved: Codable, Equatable {
        let id: String
        let name: String
        let target: String
        let session: String?
    }

    let local: Machine
    private(set) var remotes: [Machine] = []
    private var observers: [UUID: @MainActor () -> Void] = [:]

    var all: [Machine] { [local] + remotes }

    init(localEndpoint: HerdrEndpoint) {
        local = Machine(local: localEndpoint)
        local.observe { [weak self] in self?.changed() }
        for saved in Self.load() where SSHTunnel.Config.isValid(target: saved.target) { attach(saved) }
        importHerdrMachines()
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
        remotes.removeAll { $0.id == id }
        Self.save(Self.load().filter { $0.id != id })
        changed()
    }

    @discardableResult
    private func attach(_ saved: Saved) -> Machine {
        let machine = Machine(id: saved.id, name: saved.name, target: saved.target, session: saved.session)
        machine.observe { [weak self] in self?.changed() }
        remotes.append(machine)
        machine.connect()
        return machine
    }

    nonisolated static func defaultName(for target: String) -> String {
        var host = target.split(separator: "@").last.map(String.init) ?? target
        host = host.split(separator: ":").first.map(String.init) ?? host
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

    /// `GHOSTHERDR_NO_REMOTES=1` runs with this Mac only, e.g. a test copy
    /// that must not take panes from the instance you're using.
    private static let remotesDisabled = ProcessInfo.processInfo.environment["GHOSTHERDR_NO_REMOTES"] == "1"

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
