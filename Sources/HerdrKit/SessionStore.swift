import Foundation

/// The app's view of one herdr server: the latest snapshot plus every tab's
/// split tree. Events are treated as signals to re-read, as herdr's docs
/// recommend, never applied as deltas.
@MainActor
public final class SessionStore {
    public enum ConnectionState: Equatable {
        case connecting
        case connected(version: String)
        case disconnected(String)
    }

    public let client: HerdrClient
    public private(set) var snapshot: Snapshot = .empty
    public private(set) var layouts: [String: TabLayout] = [:]
    public private(set) var state: ConnectionState = .connecting {
        didSet { if state != oldValue { notify() } }
    }

    /// Called on the main actor after every change.
    private var observers: [UUID: @MainActor () -> Void] = [:]
    /// Raw events, for consumers that react to specific ones (notifications).
    private var eventObservers: [UUID: @MainActor (HerdrEvent) -> Void] = [:]

    private var stream: EventStream?
    /// Panes the current stream watches for agent status; a different pane
    /// set means resubscribing.
    private var subscribedPanes: Set<String> = []
    private var resubscribing = false
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var running = false

    public init(endpoint: HerdrEndpoint) {
        client = HerdrClient(endpoint: endpoint)
    }

    // MARK: - Observation

    @discardableResult
    public func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    @discardableResult
    public func observeEvents(_ handler: @escaping @MainActor (HerdrEvent) -> Void) -> UUID {
        let id = UUID()
        eventObservers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        eventObservers.removeValue(forKey: id)
    }

    private func notify() {
        for handler in observers.values { handler() }
    }

    // MARK: - Lookup

    public func workspace(_ id: String?) -> Workspace? {
        snapshot.workspaces.first { $0.workspaceID == id }
    }

    public func tabs(in workspaceID: String) -> [Tab] {
        snapshot.tabs.filter { $0.workspaceID == workspaceID }.sorted { $0.number < $1.number }
    }

    public func tab(_ id: String?) -> Tab? {
        snapshot.tabs.first { $0.tabID == id }
    }

    public func pane(_ id: String?) -> Pane? {
        snapshot.panes.first { $0.paneID == id }
    }

    public func panes(in tabID: String) -> [Pane] {
        snapshot.panes.filter { $0.tabID == tabID }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        Task { await runLoop() }
    }

    public func stop() {
        running = false
        stream?.close()
        stream = nil
    }

    /// Subscribe, snapshot, then re-read on every event. Reconnects with
    /// backoff when the server goes away or drops the stream.
    private func runLoop() async {
        var backoff: UInt64 = 500_000_000
        while running {
            do {
                if case .connected = state {} else { state = .connecting }
                let endpoint = client.endpoint
                // Snapshot first to learn the panes, subscribe, then re-read
                // so nothing between the two is missed.
                let panes = try await client.snapshot().panes.map(\.paneID)
                let stream = try await Task.detached {
                    try EventStream(endpoint: endpoint, agentStatusPanes: panes)
                }.value
                self.stream = stream
                subscribedPanes = Set(panes)
                try await refresh()
                state = .connected(version: snapshot.version)
                backoff = 500_000_000

                let events = AsyncThrowingStream<HerdrEvent, Error> { continuation in
                    Thread.detachNewThread {
                        do {
                            while let event = try stream.next() { continuation.yield(event) }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
                for try await event in events {
                    for handler in eventObservers.values { handler(event) }
                    scheduleRefresh()
                }
                if !resubscribing { state = .disconnected("event stream ended") }
            } catch {
                if !resubscribing { state = .disconnected(String(describing: error)) }
            }
            stream?.close()
            stream = nil
            guard running else { break }
            if resubscribing {
                resubscribing = false
                continue
            }
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, 5_000_000_000)
        }
    }

    /// Coalesces bursts of events (a split fires several) into one re-read.
    public func scheduleRefresh() {
        refreshPending = true
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while refreshPending {
                refreshPending = false
                try? await Task.sleep(nanoseconds: 16_000_000)
                try? await refresh()
            }
            refreshTask = nil
        }
    }

    public func refresh() async throws {
        let snapshot = try await client.snapshot()
        var layouts: [String: TabLayout] = [:]
        try await withThrowingTaskGroup(of: TabLayout?.self) { group in
            for tab in snapshot.tabs {
                let client = client
                group.addTask { try? await client.layout(tabID: tab.tabID) }
            }
            for try await layout in group {
                if let layout { layouts[layout.tabID] = layout }
            }
        }
        let panes = Set(snapshot.panes.map(\.paneID))
        if stream != nil, panes != subscribedPanes, !resubscribing {
            resubscribing = true
            stream?.close()
        }
        guard snapshot != self.snapshot || layouts != self.layouts else { return }
        self.snapshot = snapshot
        self.layouts = layouts
        notify()
    }

    /// Runs an API mutation and reports failures without throwing into UI code.
    public func perform(_ action: @escaping @Sendable (HerdrClient) async throws -> Void) {
        let client = client
        Task {
            do {
                try await action(client)
            } catch {
                NSLog("ghostherdr: herdr call failed: \(error)")
            }
            scheduleRefresh()
        }
    }
}
