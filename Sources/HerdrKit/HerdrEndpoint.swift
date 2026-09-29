import Foundation

/// Where a herdr server lives: its session name, API socket and CLI binary.
public struct HerdrEndpoint: Sendable, Equatable {
    /// `nil` is the default session.
    public let session: String?
    public let socketPath: String
    public let herdrBinary: String

    public init(session: String? = nil, socketPath: String? = nil, herdrBinary: String? = nil) {
        self.session = session
        self.socketPath = socketPath ?? Self.defaultSocketPath(session: session)
        self.herdrBinary = herdrBinary ?? Self.locateHerdr() ?? "herdr"
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

    /// Arguments that select this endpoint's session on the herdr CLI.
    public var sessionArguments: [String] {
        session.map { ["--session", $0] } ?? []
    }
}
