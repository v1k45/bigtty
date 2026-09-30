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
    /// File or folder for file/diff panes.
    var path: String?
    /// The herdr pane last seen hosting it, to re-tag after a server restart.
    var paneID: String?
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
    func prune(keeping liveIDs: Set<String>) {
        let before = states.count
        states = states.filter { liveIDs.contains($0.key) || $0.value.paneID == nil }
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
        store: SessionStore, onPane: (@MainActor (String) -> Void)? = nil
    ) -> String {
        let id = newID(state.kind)
        shared[id] = state
        let title = hostTitle(state)
        store.perform { client in
            let pane = try await client.split(paneID: target, direction: direction)
            try await tag(pane: pane.paneID, id: id, kind: state.kind, title: title, client: client)
            await MainActor.run { onPane?(pane.paneID) }
        }
        return id
    }

    static func tag(pane: String, id: String, kind: HostPaneKind, title: String, client: HerdrClient) async throws {
        try await client.reportMetadata(
            paneID: pane, title: title, tokens: ["ghr_kind": kind.rawValue, "ghr_id": id]
        )
        let command = [ghrPath, "pane-host", kind.rawValue, id, title].map(shellQuote).joined(separator: " ")
        try await client.sendText(paneID: pane, text: "exec \(command)\r")
    }

    static func hostTitle(_ state: HostPaneState) -> String {
        switch state.kind {
        case .browser: "🌐 " + (state.title ?? state.url ?? "Browser")
        case .files: "📁 " + ((state.path as NSString?)?.lastPathComponent ?? "Files")
        case .diff: "± " + ((state.path as NSString?)?.lastPathComponent ?? "Changes")
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
