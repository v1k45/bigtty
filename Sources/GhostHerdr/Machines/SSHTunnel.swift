import Foundation
import HerdrKit

/// Runs a command on this Mac or on a machine over SSH, for small probes
/// (git branch, listening ports).
struct CommandRunner: Sendable {
    /// `nil` runs locally.
    let ssh: SSHTunnel.Config?

    static let local = CommandRunner(ssh: nil)

    func run(_ executable: String, _ args: [String], okStatuses: Set<Int32> = [0]) -> String? {
        if let ssh {
            let command = ([executable] + args).map(SSHTunnel.shellQuote).joined(separator: " ")
            return SSHTunnel.runSSH(ssh, remoteCommand: command, okStatuses: okStatuses)?.output
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? args : [executable] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard okStatuses.contains(process.terminationStatus) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// An SSH connection to a machine running herdr: a probe of what's there,
/// then a long-lived `ssh -N` that forwards the machine's two herdr sockets
/// into a local folder (so the herdr CLI and API work unchanged) and opens a
/// SOCKS proxy so browser panes reach the machine's `localhost`.
final class SSHTunnel: @unchecked Sendable {
    struct Config: Sendable, Equatable {
        /// Anything `ssh` accepts: `user@host`, `host:port`, an ~/.ssh/config alias.
        let target: String
        /// Remote herdr session; `nil` is the default one.
        let session: String?
        /// Local folder holding the forwarded sockets and the control socket.
        let directory: String

        var controlPath: String { directory + "/cm" }
        var localAPISocket: String { directory + "/herdr.sock" }
        var localClientSocket: String { directory + "/herdr-client.sock" }
    }

    struct Probe: Sendable, Equatable {
        let apiSocket: String
        let herdrBinary: String?
        let running: Bool
        let version: String?
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// SSH itself failed: bad key, unknown host, refused.
        case ssh(String)
        case herdrMissing
        case notRunning
        case forwarding(String)

        var description: String {
            switch self {
            case let .ssh(message): message
            case .herdrMissing: "herdr isn’t installed there"
            case .notRunning: "herdr isn’t running there"
            case let .forwarding(message): message
            }
        }

        /// Messages that mean the user must sign in or trust the host.
        var needsSignIn: Bool {
            guard case let .ssh(message) = self else { return false }
            let m = message.lowercased()
            return m.contains("permission denied") || m.contains("host key") || m.contains("authenticity")
                || m.contains("passphrase") || m.contains("password")
        }
    }

    let config: Config
    private var process: Process?
    private(set) var socksPort: Int = 0
    var onExit: (@Sendable (String) -> Void)?

    init(config: Config) {
        self.config = config
        try? FileManager.default.createDirectory(atPath: config.directory, withIntermediateDirectories: true)
    }

    // MARK: - Probe

    /// Finds herdr's socket and binary on the machine and whether it runs.
    func probe() throws -> Probe {
        let sessionPath = config.session.map { "/sessions/\($0)" } ?? ""
        let script = """
        base="${XDG_CONFIG_HOME:-$HOME/.config}/herdr\(sessionPath)"
        sock="$base/herdr.sock"
        bin="$(command -v herdr 2>/dev/null)"
        [ -z "$bin" ] && [ -x "$HOME/.local/bin/herdr" ] && bin="$HOME/.local/bin/herdr"
        [ -z "$bin" ] && [ -x "$HOME/.cargo/bin/herdr" ] && bin="$HOME/.cargo/bin/herdr"
        running=no; [ -S "$sock" ] && running=yes
        version=""; [ -n "$bin" ] && version="$("$bin" --version 2>/dev/null | head -1)"
        printf 'sock=%s\\nbin=%s\\nrunning=%s\\nversion=%s\\n' "$sock" "$bin" "$running" "$version"
        """
        guard let result = Self.runSSH(config, remoteCommand: "sh -s", stdin: script) else {
            throw Failure.ssh("ssh could not start")
        }
        guard result.status == 0 else {
            throw Failure.ssh(result.error.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "ssh failed")
        }
        var values: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] } else if parts.count == 1 { values[parts[0]] = "" }
        }
        let bin = values["bin"].flatMap { $0.isEmpty ? nil : $0 }
        let version = values["version"].flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "herdr ", with: "") }
        return Probe(apiSocket: values["sock"] ?? "", herdrBinary: bin, running: values["running"] == "yes", version: version)
    }

    /// Starts the herdr server on the machine, detached.
    func startServer(binary: String) throws {
        let session = config.session.map { " --session " + Self.shellQuote($0) } ?? ""
        let command = "nohup \(Self.shellQuote(binary))\(session) server >/dev/null 2>&1 &"
        guard let result = Self.runSSH(config, remoteCommand: "sh -c " + Self.shellQuote(command)), result.status == 0 else {
            throw Failure.ssh("could not start herdr")
        }
    }

    // MARK: - Tunnel

    /// Forwards both herdr sockets and opens the SOCKS proxy; returns once
    /// the local sockets exist.
    func open(remoteAPISocket: String) throws {
        close()
        let remoteClient = (remoteAPISocket as NSString).deletingLastPathComponent + "/herdr-client.sock"
        for path in [config.localAPISocket, config.localClientSocket] { unlink(path) }
        socksPort = Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Its own connection: through the shared control connection, ssh
        // would hand the forwards to the master and exit.
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            "-L", "\(config.localAPISocket):\(remoteAPISocket)",
            "-L", "\(config.localClientSocket):\(remoteClient)",
            "-D", "127.0.0.1:\(socksPort)",
            config.target,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let box = ErrorBox()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { box.append(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.onExit?(box.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try process.run()
        self.process = process
        // Wait for the forwarded sockets to appear.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: config.localAPISocket),
               FileManager.default.fileExists(atPath: config.localClientSocket) { return }
            if !process.isRunning {
                throw Failure.forwarding(box.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "ssh exited")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        close()
        throw Failure.forwarding("timed out forwarding herdr’s sockets")
    }

    var isOpen: Bool { process?.isRunning ?? false }

    // MARK: - Port forwards for browser panes

    private var portForwards: [Int: (local: Int, process: Process)] = [:]
    private let forwardLock = NSLock()

    /// A local port that reaches `localhost:<remotePort>` on the machine,
    /// through its own `ssh -N -L`. WebKit won't send localhost through a
    /// proxy, so browser panes use these instead.
    func localPort(forRemote remotePort: Int) -> Int? {
        forwardLock.lock()
        defer { forwardLock.unlock() }
        if let existing = portForwards[remotePort], existing.process.isRunning { return existing.local }
        let local = Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
            "-N", "-L", "127.0.0.1:\(local):localhost:\(remotePort)", config.target,
        ]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Wait until the local end accepts connections.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, process.isRunning {
            if Self.canConnect(port: local) {
                portForwards[remotePort] = (local, process)
                return local
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminate()
        return nil
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    private func closeForwards() {
        forwardLock.lock()
        defer { forwardLock.unlock() }
        for (_, forward) in portForwards where forward.process.isRunning { forward.process.terminate() }
        portForwards.removeAll()
    }

    func close() {
        closeForwards()
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { close() }

    // MARK: - Helpers

    static func baseOptions(_ config: Config) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(config.controlPath)",
            "-o", "ControlPersist=600",
        ]
    }

    struct Result {
        let status: Int32
        let output: String
        let error: String
    }

    /// One command over the shared SSH connection.
    static func runSSH(_ config: Config, remoteCommand: String, stdin: String? = nil, okStatuses: Set<Int32>? = nil) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = baseOptions(config) + [config.target, remoteCommand]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try process.run() } catch { return nil }
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), error: String(decoding: error, as: UTF8.self))
        if let okStatuses, !okStatuses.contains(result.status) { return nil }
        return result
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
