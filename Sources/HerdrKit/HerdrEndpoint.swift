import Foundation

/// Where a herdr server lives: its session name, API socket and CLI binary.
public struct HerdrEndpoint: Sendable, Equatable {
    /// `nil` is the default session.
    public let session: String?
    public let socketPath: String
    /// The herdr CLI: the one asked for, else wherever it is installed now
    /// (looked up each time, so installing herdr needs no relaunch).
    public var herdrBinary: String { binaryOverride ?? Self.locateHerdr() ?? "herdr" }
    private let binaryOverride: String?
    /// Set for a forwarded (remote) server: the herdr CLI finds both sockets
    /// through `HERDR_SOCKET_PATH`, deriving `herdr-client.sock` beside it.
    public let forwarded: Bool

    public init(session: String? = nil, socketPath: String? = nil, herdrBinary: String? = nil) {
        self.session = session
        self.socketPath = socketPath ?? Self.defaultSocketPath(session: session)
        binaryOverride = herdrBinary
        forwarded = false
    }

    /// A server reached through local copies of its sockets (SSH forwarding).
    public init(forwardedSocket path: String, herdrBinary: String? = nil) {
        session = nil
        socketPath = path
        binaryOverride = herdrBinary
        forwarded = true
    }

    /// Environment for herdr CLI processes talking to this endpoint.
    public var cliEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "HERDR_SESSION")
        env.removeValue(forKey: "HERDR_CLIENT_SOCKET_PATH")
        // Named local sessions go by `--session`; everything else by path.
        if session == nil {
            env["HERDR_SOCKET_PATH"] = socketPath
        } else {
            env.removeValue(forKey: "HERDR_SOCKET_PATH")
        }
        return env
    }

    /// Mirrors herdr's own resolution: `HERDR_SOCKET_PATH`, then the named
    /// session's socket, then the default one.
    public static func defaultSocketPath(session: String?) -> String {
        let env = ProcessInfo.processInfo.environment
        if session == nil, let path = env["HERDR_SOCKET_PATH"], !path.isEmpty { return path }
        let base = (env["XDG_CONFIG_HOME"].map { $0 + "/herdr" })
            ?? (NSHomeDirectory() + "/.config/herdr")
        if let session { return "\(base)/sessions/\(session)/herdr.sock" }
        return "\(base)/herdr.sock"
    }

    /// An app launched from Finder gets a minimal PATH, so look in the usual
    /// install locations as well.
    public static func locateHerdr() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"]
        for dir in dirs {
            let path = "\(dir)/herdr"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Whether a server answers on `path`: a connect, nothing sent.
    public static func isServing(_ path: String) -> Bool {
        (try? UnixSocket(path: path, timeout: 0.5)).map { _ in true } ?? false
    }

    /// herdr's sessions on this Mac from its config folder, no CLI: nil
    /// name for the default one.
    public static func localSessions() -> [(name: String?, running: Bool)] {
        let base = (defaultSocketPath(session: nil) as NSString).deletingLastPathComponent
        var result: [(String?, Bool)] = [(nil, isServing(defaultSocketPath(session: nil)))]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base + "/sessions")) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base + "/sessions/" + name, isDirectory: &isDir), isDir.boolValue else { continue }
            result.append((name, isServing(defaultSocketPath(session: name))))
        }
        return result
    }

    /// Arguments that select this endpoint's session on the herdr CLI.
    public var sessionArguments: [String] {
        forwarded ? [] : (session.map { ["--session", $0] } ?? [])
    }
}
