import AppKit
import HerdrKit
import Network

/// Retries unreachable machines when the network comes back or moves to
/// other interfaces, and on wake, rather than leaving them to their
/// backoff (up to five minutes). Debounced by `NetworkChange`.
@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()
    private var change = NetworkChange()
    private var pending: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private let retry: @MainActor () -> Void

    /// Start after `NetworkWarmup.run()`, which must create Network's
    /// context first.
    init(retry: @escaping @MainActor () -> Void) {
        self.retry = retry
        monitor.pathUpdateHandler = { [weak self] path in
            let state = NetworkChange.Path(satisfied: path.status == .satisfied,
                                           interfaces: path.availableInterfaces.map(\.name))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.change.pathChanged(state) else { return }
                    self.schedule()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.bigtty.network-watch", qos: .utility))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    private func schedule() {
        pending?.cancel()
        let now = Date()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.change.retried(at: Date())
                self.retry()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + change.retryAt(now: now).timeIntervalSince(now), execute: item)
    }
}
