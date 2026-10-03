import AppKit

/// One bigtty per bundle id. Several copies can share it (/Applications
/// plus dev builds), and Spotlight may launch any of them; a second copy
/// would open its own windows next to the first one's.
enum SingleInstance {
    /// The copy that was already running, when this one should step aside.
    /// Instances on their own socket (`BIGTTY_SOCKET`, as tests use) and
    /// `swift run` binaries (no bundle id) always run.
    static func runningPeer() -> NSRunningApplication? {
        let env = ProcessInfo.processInfo.environment
        guard env["BIGTTY_SOCKET"].map(\.isEmpty) ?? true,
              let id = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current
        // The oldest copy wins, so two launched together don't both quit.
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != me && !$0.isTerminated && isOlder($0, than: me) }
            .min { isOlder($0, than: $1) }
    }

    /// Shows the running copy as if its Dock icon was clicked: in front, and
    /// with a window even if all were closed.
    static func reopen(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let done = DispatchSemaphore(value: 0)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if error != nil { app.activate() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    private static func isOlder(_ a: NSRunningApplication, than b: NSRunningApplication) -> Bool {
        switch (a.launchDate, b.launchDate) {
        case let (x?, y?) where x != y: x < y
        default: a.processIdentifier < b.processIdentifier
        }
    }
}
