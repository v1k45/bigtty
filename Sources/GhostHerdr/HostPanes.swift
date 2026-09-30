import AppKit
import HerdrKit

/// Browser and file panes are real herdr panes, so herdr's layout stays the
/// single source of truth: split, move, zoom and resize work on them like
/// on any terminal. Each one runs `ghr pane-host` and is tagged with
/// `tokens.ghr_kind` / `tokens.ghr_id`; what it shows lives here, keyed by
/// that id.
enum HostPaneKind: String, Codable {
    case browser, files, diff
}

struct HostPaneState: Codable, Equatable {
    var kind: HostPaneKind
    var url: String?
    var title: String?
    /// Root folder (or file) for files/diff panes.
    var path: String?
    /// The file shown in a files pane, and its mode ("files" or "changes").
    var selection: String?
    var mode: String?
    /// A line to reveal once (from `ghr open file:line`); not persisted meaningfully.
    var line: Int?
    /// The herdr pane last seen hosting it, to re-tag after a server restart.
    var paneID: String?
    /// The machine it belongs to; `nil` is this Mac. Browser panes on a
    /// remote machine reach its `localhost` through the SSH tunnel.
    var machine: String?
}

extension Pane {
    var hostKind: HostPaneKind? { tokens?["ghr_kind"].flatMap(HostPaneKind.init(rawValue:)) }
    var hostID: String? { tokens?["ghr_id"] }
}

@MainActor
final class HostPaneStore {
    static let shared = HostPaneStore()

    private(set) var states: [String: HostPaneState] = [:]
    private let fileURL: URL
    private var saveScheduled = false

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostHerdr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("panes.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: HostPaneState].self, from: data)
        {
            states = decoded
        }
    }

    subscript(id: String) -> HostPaneState? {
        get { states[id] }
        set {
            guard states[id] != newValue else { return }
            states[id] = newValue
            scheduleSave()
        }
    }

    /// Drops state for host panes herdr no longer has. State that was never
    /// attached to a pane is kept: its split may still be in flight.
    func prune(keeping liveIDs: Set<String>, connectedMachines: Set<String> = ["local"]) {
        let before = states.count
        // A machine that isn't connected yet can't vouch for its panes: keep them.
        states = states.filter {
            liveIDs.contains($0.key) || $0.value.paneID == nil || !connectedMachines.contains($0.value.machine ?? "local")
        }
        if states.count != before { scheduleSave() }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let data = try? JSONEncoder().encode(self.states) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    static func newID(_ kind: HostPaneKind) -> String {
        "\(kind.rawValue.prefix(1))\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The `ghr` binary shipped next to the app's executable.
    static var ghrPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("ghr").path
    }

    /// Splits `target` and turns the new pane into a host pane. Returns
    /// the host id at once; the herdr pane appears shortly after.
    @discardableResult
    static func open(
        _ state: HostPaneState, beside target: String, direction: SplitDirection,
        store: SessionStore, remote: Bool = false, onPane: (@MainActor (String) -> Void)? = nil
    ) -> String {
        let id = newID(state.kind)
        shared[id] = state
        let title = hostTitle(state)
        store.perform { client in
            let pane = try await client.split(paneID: target, direction: direction)
            try await tag(pane: pane.paneID, id: id, kind: state.kind, title: title, client: client, remote: remote)
            await MainActor.run { onPane?(pane.paneID) }
        }
        return id
    }

    static func tag(pane: String, id: String, kind: HostPaneKind, title: String, client: HerdrClient, remote: Bool = false) async throws {
        try await client.reportMetadata(
            paneID: pane, title: title, tokens: ["ghr_kind": kind.rawValue, "ghr_id": id]
        )
        let command: String
        if remote {
            // No ghr on the other machine: a plain sh placeholder does the same job.
            let banner = "\\033[2J\\033[H\\n  GhostHerdr \(kind.rawValue) pane\\n  \(title.replacingOccurrences(of: "'", with: ""))\\n\\n  Open this workspace in GhostHerdr to see it.\\n"
            command = "sh -c " + shellQuote("printf '\(banner)'; stty -echo -icanon 2>/dev/null; exec cat >/dev/null")
        } else {
            command = [ghrPath, "pane-host", kind.rawValue, id, title].map(shellQuote).joined(separator: " ")
        }
        try await client.sendText(paneID: pane, text: "exec \(command)\r")
    }

    /// herdr drops pane tags on a restart or live handoff while the pane's
    /// placeholder keeps running. Untagged panes are checked once: one
    /// running `ghr pane-host <kind> <id>` (or, remotely, our placeholder in
    /// a pane we recorded) gets its tags back.
    private static var checkedPanes: Set<String> = []

    static func restoreTags(store: SessionStore, remote: Bool) {
        let untagged = store.snapshot.panes.filter { $0.hostID == nil }
        let key: (Pane) -> String = { "\(store.client.endpoint.socketPath)|\($0.paneID)|\($0.terminalID)" }
        let pending = untagged.filter { !checkedPanes.contains(key($0)) }
        guard !pending.isEmpty else { return }
        for pane in pending { checkedPanes.insert(key(pane)) }
        let recorded = Dictionary(shared.states.compactMap { id, state in state.paneID.map { ($0, (id, state)) } }, uniquingKeysWith: { a, _ in a })
        store.perform { client in
            for pane in pending {
                let info = try? await client.call("pane.process_info", ["pane_id": .string(pane.paneID)])
                guard case let .array(processes)? = info?["process_info"]?["foreground_processes"] else { continue }
                for process in processes {
                    guard case let .array(argv)? = process["argv"] else { continue }
                    let args = argv.compactMap(\.stringValue)
                    var tag: (id: String, kind: HostPaneKind)?
                    if let at = args.firstIndex(of: "pane-host"), args.count > at + 2, let kind = HostPaneKind(rawValue: args[at + 1]) {
                        tag = (args[at + 2], kind)
                    } else if remote, args.first.map({ ($0 as NSString).lastPathComponent == "cat" }) == true,
                              let (id, state) = recorded[pane.paneID] {
                        tag = (id, state.kind)
                    }
                    guard let tag else { continue }
                    let state = await MainActor.run { shared[tag.id] } ?? HostPaneState(kind: tag.kind)
                    try await client.reportMetadata(paneID: pane.paneID, title: hostTitle(state),
                                                    tokens: ["ghr_kind": tag.kind.rawValue, "ghr_id": tag.id])
                    break
                }
            }
        }
    }

    static func hostTitle(_ state: HostPaneState) -> String {
        switch state.kind {
        case .browser: "🌐 " + (state.title ?? state.url ?? "Browser")
        case .files, .diff:
            (state.mode == "changes" || (state.mode == nil && state.kind == .diff) ? "± " : "📁 ")
                + ((state.selection ?? state.path).map { ($0 as NSString).lastPathComponent } ?? "Files")
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
