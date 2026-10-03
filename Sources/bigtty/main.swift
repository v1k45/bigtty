import AppKit

MainActor.assumeIsolated {
    // Already running from another copy: show that one instead.
    if let peer = SingleInstance.runningPeer() {
        SingleInstance.reopen(peer)
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
