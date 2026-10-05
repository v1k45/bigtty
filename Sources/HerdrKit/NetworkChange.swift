import Foundation

/// Decides when the network coming back (or the Mac waking) should retry
/// unreachable machines: once things settle, and not too often, so a
/// flapping network doesn't storm ssh.
public struct NetworkChange: Sendable {
    /// What the network looks like: usable, and over which interfaces.
    public struct Path: Sendable, Equatable {
        public let satisfied: Bool
        public let interfaces: [String]

        public init(satisfied: Bool, interfaces: [String]) {
            self.satisfied = satisfied
            self.interfaces = interfaces
        }
    }

    /// Quiet time after the last change before retrying.
    public let settle: TimeInterval
    /// Least time between two retries.
    public let spacing: TimeInterval

    private var last: Path?
    private var lastRetry: Date?

    public init(settle: TimeInterval = 2, spacing: TimeInterval = 15) {
        self.settle = settle
        self.spacing = spacing
    }

    /// A new path. True when it's worth a retry: the network became usable,
    /// or it moved to other interfaces (Wi-Fi to Ethernet, a VPN). The first
    /// one is the network as it was at launch, not a change.
    public mutating func pathChanged(_ path: Path) -> Bool {
        defer { last = path }
        guard let last else { return false }
        guard path.satisfied else { return false }
        return !last.satisfied || last.interfaces != path.interfaces
    }

    /// When to retry, for a change (or wake) at `now`: after it settles,
    /// and no sooner than `spacing` after the last retry. Each new change
    /// pushes it back, so a flap ends in one retry.
    public func retryAt(now: Date) -> Date {
        max(now + settle, (lastRetry ?? .distantPast) + spacing)
    }

    public mutating func retried(at date: Date) { lastRetry = date }
}
