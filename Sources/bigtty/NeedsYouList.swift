import AppKit
import HerdrKit

/// Everything waiting on you, across every machine and session, most urgent
/// first: the sidebar's Needs You section and the ⇧⌘K list.
@MainActor
struct NeedsYouEntry {
    let item: NeedsYouItem
    let machine: Machine
    let pane: Pane?
    /// The space (or, for a login, the machine).
    let title: String
    /// What it wants: "claude: Allow this edit?", "claude finished".
    let line: String
    /// "This Mac", "workbox", "workbox · dev session".
    let place: String

    var kind: NeedsYouItem.Kind { item.kind }
    var id: String { item.id }

    /// "3m" since it started waiting, if known.
    var age: String? { item.since.map { SpaceInfoCenter.age(since: $0) } }

    var symbol: String {
        switch kind {
        case .login: "lock"
        case .blocked: "exclamationmark.bubble"
        case .waiting: "hourglass"
        case .finished: "checkmark.circle"
        }
    }

    /// Calls for you now (accent-colored), rather than just being on the list.
    var urgent: Bool { kind == .login || kind == .blocked }

    static func collect(_ manager: MachineManager) -> [NeedsYouEntry] {
        var entries: [String: NeedsYouEntry] = [:]
        var items: [NeedsYouItem] = []
        for (index, machine) in manager.all.enumerated() {
            let place = Self.place(machine, manager: manager)
            if machine.needsLogin {
                let item = NeedsYouItem(kind: .login, machineID: machine.id, order: [index])
                items.append(item)
                entries[item.id] = NeedsYouEntry(item: item, machine: machine, pane: nil, title: machine.name,
                                                 line: machine.loginLine, place: place)
                continue
            }
            guard let store = machine.store, let attention = machine.attention, case .connected = store.state else { continue }
            let info = machine.spaceInfo
            for item in NeedsYou.items(attention: attention.attention, snapshot: store.snapshot, machineID: machine.id, machineOrder: index) {
                guard let paneID = item.paneID, let pane = store.pane(paneID) else { continue }
                let space = store.workspace(pane.workspaceID).map {
                    MainWindowController.spaceName($0, store: store, agentTitles: info?.agentTitles ?? [:])
                } ?? pane.workspaceID
                let agent = pane.displayAgent ?? pane.agent ?? "agent"
                let line = switch item.kind {
                case .blocked: info?.question(for: paneID).map { "\(agent): \($0)" } ?? "\(agent) needs you"
                case .waiting: "\(agent) · waiting for you"
                case .finished: "\(agent) finished"
                case .login: ""
                }
                items.append(item)
                entries[item.id] = NeedsYouEntry(item: item, machine: machine, pane: pane, title: space, line: line, place: place)
            }
        }
        return NeedsYou.ranked(items).compactMap { entries[$0.id] }
    }

    /// Where an entry is, when that isn't this Mac's current session.
    private static func place(_ machine: Machine, manager: MachineManager) -> String {
        if machine.isLocal { return machine === manager.activeLocal ? "" : "\(machine.sessionName) session" }
        return machine.parentID != nil ? "\(machine.name) · \(machine.sessionName) session" : machine.name
    }

    /// Goes to it: the pane, or the login's approval page or problem.
    func open(showProblem: (Machine) -> Void) {
        if let pane {
            machine.reveal(pane)
        } else if case let .approval(url) = machine.status {
            NSWorkspace.shared.open(url)
        } else {
            showProblem(machine)
        }
    }

    /// Off the list until its state changes; false if it can't be (a login).
    @discardableResult
    func dismiss() -> Bool {
        guard let pane, let attention = machine.attention else { return false }
        attention.dismiss(pane.paneID)
        return true
    }
}

extension Machine {
    /// A login that's stuck on you: approval, sign-in, or a failure.
    var needsLogin: Bool {
        guard !isLocal else { return false }
        switch status {
        case .approval, .signIn, .failed, .herdrMissing: return true
        default: return false
        }
    }

    var loginLine: String {
        switch status {
        case .approval: "Approve the login in your browser"
        case .signIn: "Sign in to connect"
        case .herdrMissing: "herdr isn’t installed"
        case let .failed(message): "Can’t connect: \(message)"
        default: statusText
        }
    }
}
