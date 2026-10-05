import AppKit
import HerdrKit

/// One herdr server bigtty shows: this Mac's, or one reached over SSH.
/// Owns that server's session store, attention tracking and sidebar info.
@MainActor
final class Machine {
    enum Kind: Equatable {
        case local
        case ssh(target: String, session: String?)
    }

    enum Status: Equatable {
        case connecting
        case connected
        case notRunning
        case herdrMissing
        case signIn(String)
        case failed(String)
        case reconnecting(seconds: Int)
        case disabled
        /// The SSH login waits for approval in a browser (Tailscale SSH's
        /// check mode); it continues by itself once approved.
        case approval(URL)
    }

    let id: String
    let name: String
    let kind: Kind
    private(set) var status: Status = .connecting { didSet { if status != oldValue { notify() } } }
    private(set) var store: SessionStore?
    private(set) var attention: AttentionCenter?
    private(set) var spaceInfo: SpaceInfoCenter?
    /// Round trip of a `ping`, for the sidebar ("● 24 ms").
    private(set) var latency: Int?
    /// herdr version on the machine, when it differs from this Mac's.
    private(set) var versionWarning: String?
    /// SOCKS proxy for this machine's browser panes (remote only).
    var socksPort: Int? { tunnel?.isOpen == true ? tunnel?.socksPort : nil }

    var isLocal: Bool { kind == .local }

    /// A local port reaching `localhost:<port>` on this machine (remote only).
    nonisolated func localPort(forRemote port: Int, tunnel: SSHTunnel?) -> Int? {
        tunnel?.localPort(forRemote: port)
    }

    /// For browser panes: maps the machine's localhost URLs to local forwards.
    var localhostMapper: LocalhostMapper? {
        guard let tunnel, !isLocal else { return nil }
        return LocalhostMapper(tunnel: tunnel)
    }
    var runner: CommandRunner { tunnel.map { CommandRunner(ssh: $0.config) } ?? .local }

    var viewedPanes: () -> Set<String> = { [] }
    /// Set until the app delegate wires `viewedPanes` and `reveal`.
    var viewedPanesUnset = true
    var reveal: (Pane) -> Void = { _ in }

    private var tunnel: SSHTunnel?
    private var probe: SSHTunnel.Probe?
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var pingTimer: Timer?
    private var attempts = 0
    /// Bumped by each `connect()`, so a superseded one's outcome is dropped.
    private var connection = 0

    /// This Mac's server for one herdr session: the default one (or the
    /// one BIGTTY_SESSION names) is "local", other named sessions
    /// "session:<name>".
    init(local endpoint: HerdrEndpoint, id: String = "local") {
        self.id = id
        parentID = nil
        name = "This Mac"
        kind = .local
        session = endpoint.session
        makeStore(endpoint: endpoint)
    }

    /// The herdr session this machine shows; nil is the default one.
    private(set) var session: String?

    /// How the session switcher names it.
    var sessionName: String { session ?? "default" }

    /// What host panes created here are tagged with, so their state is
    /// only pruned while their own server is connected (nil: the default
    /// local session, as before sessions).
    var hostTag: String? { id == "local" ? nil : id }

    /// The saved machine this is another herdr session of (remote only).
    let parentID: String?

    /// A machine over SSH; `connect()` brings it up. `parent`: the saved
    /// machine whose other herdr session this is; it shares that one's SSH
    /// login and gets a folder of its own for the forwarded sockets.
    init(id: String, name: String, target: String, session: String?, parent: String? = nil) {
        self.id = id
        self.name = name
        self.session = session
        parentID = parent
        kind = .ssh(target: target, session: session)
        // No spaces allowed: ssh splits ControlPath on them. Short, too, for
        // the 104-byte Unix socket path limit.
        let machines = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.bigtty/m")
        let own = parent.map { String($0.prefix(8)) } ?? String(id.prefix(8))
        let control = machines.appendingPathComponent(own).path
        let dir = parent == nil ? control : control + "/s" + Self.shortHash(session ?? "")
        let tunnel = SSHTunnel(config: .init(target: target, session: session, directory: dir, controlDirectory: control))
        self.tunnel = tunnel
        // This connection's login waits for approval in the browser: say
        // so, with its link (another session's link wouldn't let it in).
        tunnel.logins.onWait = { [weak self] url in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.loginWaits(url) } }
        }
        approvedObserver = NotificationCenter.default.addObserver(forName: .bigttyLoginApproved, object: nil, queue: .main) { [weak self] note in
            guard note.object as? String == target else { return }
            MainActor.assumeIsolated { self?.loginApprovedElsewhere() }
        }
    }

    private var approvedObserver: NSObjectProtocol?

    private func loginWaits(_ url: URL) {
        switch status {
        case .connected, .disabled: return
        default: status = .approval(url)
        }
    }

    /// Another login to this host was approved while ours still waits on
    /// its own link: start over, and the approval lets the new one in.
    private func loginApprovedElsewhere() {
        guard case .approval = status, let tunnel, tunnel.logins.isWaiting else { return }
        tunnel.logins.cancelAll()
        connect(byUser: false)
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func notify() {
        for handler in observers.values { handler() }
    }

    // MARK: - Store

    private func makeStore(endpoint: HerdrEndpoint) {
        let store = SessionStore(endpoint: endpoint)
        // Notifications say where: a remote machine, or a session here other than the default.
        let attention = AttentionCenter(store: store, machineName: isLocal ? session.map { "\($0) session" }
            : parentID != nil ? "\(name) · \(sessionName) session" : name)
        attention.viewedPanes = { [weak self] in self?.viewedPanes() ?? [] }
        attention.reveal = { [weak self] pane in self?.reveal(pane) }
        let spaceInfo = SpaceInfoCenter(store: store, attention: attention, runner: { [weak self] in self?.runner ?? .local })
        self.store = store
        self.attention = attention
        self.spaceInfo = spaceInfo
        store.observe { [weak self] in self?.storeChanged() }
        attention.observe { [weak self] in self?.notify() }
        spaceInfo.observe { [weak self] in self?.notify() }
        store.start()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measureLatency() }
        }
        measureLatency()
    }

    private func storeChanged() {
        guard let store else { return }
        switch store.state {
        case .connected:
            if status != .connected { status = .connected }
        case .connecting:
            if status == .connected, !isLocal { status = .connecting }
        case .disconnected:
            // Locally that means no server; remotely the tunnel handles it.
            if isLocal { status = .notRunning }
        }
        notify()
    }

    private func measureLatency() {
        guard let client = store?.client, case .connected = store?.state else { return }
        Task {
            let start = Date()
            if (try? await client.ping()) != nil {
                latency = Int(Date().timeIntervalSince(start) * 1000)
                notify()
            }
        }
    }

    // MARK: - Remote connection

    /// Probes the machine, forwards its sockets and starts the store.
    /// `byUser`: you asked for it, so ssh may ask for a password again even
    /// if you cancelled one before; background retries never re-ask.
    func connect(byUser: Bool = true) {
        guard let tunnel, !isLocal else { return }
        if byUser { SSHAskpass.shared.allow(tunnel.config.target) }
        reconnectTask?.cancel()
        connection += 1
        let connection = connection
        status = .connecting
        let local = HerdrEndpoint.locateHerdr().flatMap { Self.version(of: $0) }
        Task.detached { [tunnel] in
            do {
                let probe = try tunnel.probe()
                guard probe.herdrBinary != nil else { throw SSHTunnel.Failure.herdrMissing }
                guard probe.running else {
                    await MainActor.run { self.probe = probe }
                    throw SSHTunnel.Failure.notRunning
                }
                try tunnel.open(remoteAPISocket: probe.apiSocket)
                await MainActor.run {
                    guard connection == self.connection else { return }
                    self.tunnelOpened(probe: probe, localVersion: local)
                }
            } catch {
                let failure = error as? SSHTunnel.Failure ?? .ssh(String(describing: error))
                await MainActor.run {
                    guard connection == self.connection else { return }
                    self.failed(failure)
                }
            }
        }
    }

    private func tunnelOpened(probe: SSHTunnel.Probe, localVersion: String?) {
        self.probe = probe
        attempts = 0
        lastError = nil
        if let remote = probe.version, let localVersion, remote != localVersion {
            versionWarning = "herdr \(remote) there, \(localVersion) here"
        } else {
            versionWarning = nil
        }
        tunnel?.onExit = { [weak self] message in
            Task { @MainActor in self?.tunnelClosed(message) }
        }
        if let store {
            store.scheduleRefresh()
        } else if let tunnel {
            makeStore(endpoint: HerdrEndpoint(forwardedSocket: tunnel.config.localAPISocket))
        }
        if case .connected = store?.state { status = .connected } else { status = .connecting }
    }

    private func tunnelClosed(_ message: String) {
        guard status != .disabled else { return }
        scheduleReconnect(after: message)
    }

    /// Start herdr for this session if the first connect finds it stopped.
    var startsWhenStopped = false

    /// The last connection error, for the problem sheet and debugging.
    private(set) var lastError: String?

    private func failed(_ failure: SSHTunnel.Failure) {
        lastError = failure.description
        switch failure {
        case .herdrMissing: status = .herdrMissing
        case .notRunning:
            status = .notRunning
            // A session you asked to start: start it now that it's probed.
            if startsWhenStopped {
                startsWhenStopped = false
                startServer()
            }
        case _ where failure.needsSignIn: status = .signIn(failure.description)
        default: scheduleReconnect(after: failure.description)
        }
    }

    /// Retries with backoff: 5s, 10s, 30s, then every 60s.
    private func scheduleReconnect(after message: String) {
        attempts += 1
        let delay = [5, 10, 30][safe: attempts - 1] ?? 60
        status = attempts > 3 ? .failed(message) : .reconnecting(seconds: delay)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            for remaining in stride(from: delay, to: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if case .reconnecting = self?.status { self?.status = .reconnecting(seconds: remaining - 1) }
            }
            guard !Task.isCancelled else { return }
            self?.connect(byUser: false)
        }
    }

    /// Starts herdr on the machine (it was installed but not running).
    func startServer() {
        guard let tunnel, let binary = probe?.herdrBinary else { return }
        status = .connecting
        Task.detached { [tunnel] in
            do {
                try tunnel.startServer(binary: binary)
                try await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run { self.connect() }
            } catch {
                await MainActor.run { self.failed(.ssh("could not start herdr")) }
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        connection += 1
        tunnel?.logins.cancelAll()
        status = .disabled
        tunnel?.close()
        store?.stop()
    }

    // MARK: - Display

    /// The right-hand text in the sidebar's machine header.
    var statusText: String {
        switch status {
        case .connecting: return "connecting…"
        case .connected:
            return isLocal ? "" : latency.map { "● \($0) ms" } ?? "●"
        case .notRunning: return "not running"
        case .herdrMissing: return "herdr not installed"
        case .signIn: return "! sign in"
        case .approval: return "! approve login"
        case .failed: return "! error"
        case let .reconnecting(seconds): return seconds > 0 ? "reconnecting in \(seconds)s" : "reconnecting…"
        case .disabled: return "off"
        }
    }

    var statusIsProblem: Bool {
        switch status {
        case .signIn, .failed, .herdrMissing, .approval: true
        default: false
        }
    }

    /// Hover text for the header: details too long or too minor for it.
    var statusTip: String? {
        guard case .connected = status else { return lastError }
        return versionWarning.map { $0 + " (works; update to match if something looks off)" }
    }

    /// The login's home here, for resolving ~ in clicked paths.
    var homeDirectory: String? { isLocal ? NSHomeDirectory() : probe?.home }

    /// A path on this machine as the sidebar shows it: home as ~.
    func displayPath(_ path: String) -> String {
        if isLocal { return (path as NSString).abbreviatingWithTildeInPath }
        guard let home = probe?.home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var target: String? {
        if case let .ssh(target, _) = kind { return target }
        return nil
    }

    /// Six hex digits naming a session's socket folder (FNV-1a).
    private static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%06x", hash & 0xFFFFFF)
    }

    static func version(of binary: String) -> String? {
        let result = CommandRunner.local.run(binary, ["--version"])
        return result?.split(separator: "\n").first.map { $0.replacingOccurrences(of: "herdr ", with: "") }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Rewrites `http://localhost:3000/x` to `http://127.0.0.1:<forward>/x` for a
/// remote machine's browser panes, and back again for the address bar.
final class LocalhostMapper: @unchecked Sendable {
    private let tunnel: SSHTunnel
    private let lock = NSLock()
    private var remoteByLocal: [Int: Int] = [:]

    init(tunnel: SSHTunnel) {
        self.tunnel = tunnel
    }

    static func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host)
    }

    /// The URL to actually load, or nil if it can't be forwarded. Blocks
    /// while the forward starts, so call it off the main thread.
    func rewrite(_ url: URL) -> URL? {
        guard Self.isLocalhost(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let remotePort = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard let local = tunnel.localPort(forRemote: remotePort) else { return nil }
        lock.withLock { remoteByLocal[local] = remotePort }
        components.host = "127.0.0.1"
        components.port = local
        return components.url
    }

    /// Whether this URL is already one of our forwards.
    func isForwarded(_ url: URL) -> Bool {
        guard url.host == "127.0.0.1", let port = url.port else { return false }
        return lock.withLock { remoteByLocal[port] != nil }
    }

    /// What to show the user for a forwarded URL.
    func display(_ url: URL) -> URL {
        guard url.host == "127.0.0.1", let port = url.port,
              let remote = lock.withLock({ remoteByLocal[port] }),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = "localhost"
        components.port = remote
        return components.url ?? url
    }
}
