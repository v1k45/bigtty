import Network

/// Works around a macOS 26 Network framework crash: when network settings
/// change (waking up, a VPN connecting), Network can create its default
/// context for the first time while holding its settings lock, and that
/// takes the lock again: "Trying to recursively lock an os_unfair_lock".
/// bigtty reads Network settings (browser proxies for remote machines)
/// without otherwise using that context, so it was exposed. Creating the
/// context once at launch, by starting a path monitor, takes that path off
/// the table.
enum NetworkWarmup {
    private static let monitor = NWPathMonitor()

    static func run() {
        let queue = DispatchQueue(label: "dev.bigtty.network-warmup", qos: .utility)
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1) { monitor.cancel() }
    }
}
