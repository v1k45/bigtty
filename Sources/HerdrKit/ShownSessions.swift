/// Which herdr session each remote shows in the sidebar, by the remote's
/// id: its own session unless another one was switched to.
public struct ShownSessions: Equatable, Sendable {
    public private(set) var names: [String: String]

    public init(_ names: [String: String] = [:]) {
        self.names = names
    }

    /// The session a remote shows: one switched to, else its own.
    public func shown(on remote: String, own: String) -> String {
        names[remote] ?? own
    }

    /// Shows a session on a remote. False when it already was: callers
    /// announce only real changes, since a window falling back from a
    /// stopped session calls this from inside the change it's handling.
    @discardableResult
    public mutating func show(_ session: String, on remote: String, own: String) -> Bool {
        guard shown(on: remote, own: own) != session else { return false }
        names[remote] = session
        return true
    }
}
