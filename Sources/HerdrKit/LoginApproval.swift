import Foundation

/// Logins that wait for a person: Tailscale SSH in check mode prints
///   # Tailscale SSH requires an additional check.
///   # To authenticate, visit: https://login.tailscale.com/a/…
/// and holds the connection until that link is approved in a browser.
public enum LoginApproval {
    public static func url(in text: String) -> URL? {
        guard let range = text.range(of: #"https://login\.tailscale\.com/a/[A-Za-z0-9]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    public static func isPending(_ text: String) -> Bool { url(in: text) != nil }
}

/// One connection's ssh logins that wait for approval. Each ssh waits on
/// its own link: approving another one's (a second session on the same
/// machine, say) doesn't let it in, so a machine shows only its own links,
/// and once another login to the host is approved it starts over, which
/// the approval then covers.
public final class PendingLogins: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [ObjectIdentifier: (url: URL, cancel: @Sendable () -> Void)] = [:]
    private var handler: (@Sendable (URL) -> Void)?

    public init() {}

    /// Called (on any thread) with each new link to approve.
    public var onWait: (@Sendable (URL) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// `login` (its ssh process) waits for `url`; `cancel` ends it.
    public func wait(_ login: AnyObject, url: URL, cancel: @escaping @Sendable () -> Void) {
        let key = ObjectIdentifier(login)
        let fresh: (@Sendable (URL) -> Void)?? = lock.withLock {
            if waiting[key]?.url == url { return .none }
            waiting[key] = (url, cancel)
            return .some(handler)
        }
        if case let .some(handler) = fresh { handler?(url) }
    }

    /// The login is through or gave up; returns the link it waited on.
    @discardableResult
    public func finished(_ login: AnyObject) -> URL? {
        lock.withLock { waiting.removeValue(forKey: ObjectIdentifier(login))?.url }
    }

    public var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }

    /// Ends every login still waiting.
    public func cancelAll() {
        let cancels = lock.withLock {
            defer { waiting.removeAll() }
            return waiting.values.map(\.cancel)
        }
        for cancel in cancels { cancel() }
    }
}
