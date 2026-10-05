import Foundation
import Testing
@testable import HerdrKit

@Suite struct LoginApprovalTests {
    private final class Login {}

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    @Test func findsTheLink() {
        let text = "# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/l1b2c3d4\n"
        #expect(LoginApproval.url(in: text)?.absoluteString == "https://login.tailscale.com/a/l1b2c3d4")
        #expect(LoginApproval.url(in: "Permission denied (publickey).") == nil)
    }

    @Test func eachLinkReportedOncePerLogin() {
        let logins = PendingLogins()
        let calls = Calls()
        logins.onWait = { calls.add($0.absoluteString) }
        let login = Login()
        let url = URL(string: "https://login.tailscale.com/a/one")!
        logins.wait(login, url: url) {}
        logins.wait(login, url: url) {}
        #expect(calls.all == [url.absoluteString])
        #expect(logins.isWaiting)
        #expect(logins.finished(login) == url)
        #expect(!logins.isWaiting)
        #expect(logins.finished(login) == nil)
    }

    @Test func cancelEndsEveryWaitingLogin() {
        let logins = PendingLogins()
        let calls = Calls()
        let first = Login(), second = Login()
        logins.wait(first, url: URL(string: "https://login.tailscale.com/a/one")!) { calls.add("first") }
        logins.wait(second, url: URL(string: "https://login.tailscale.com/a/two")!) { calls.add("second") }
        logins.cancelAll()
        #expect(Set(calls.all) == ["first", "second"])
        #expect(!logins.isWaiting)
        logins.cancelAll()
        #expect(calls.all.count == 2)
    }

    @Test func separateConnectionsKeepTheirOwnLinks() {
        // Two sessions on one host: each shows only its own link.
        let parent = PendingLogins(), session = PendingLogins()
        let parentCalls = Calls(), sessionCalls = Calls()
        parent.onWait = { parentCalls.add($0.lastPathComponent) }
        session.onWait = { sessionCalls.add($0.lastPathComponent) }
        parent.wait(Login(), url: URL(string: "https://login.tailscale.com/a/p")!) {}
        session.wait(Login(), url: URL(string: "https://login.tailscale.com/a/s")!) {}
        #expect(parentCalls.all == ["p"])
        #expect(sessionCalls.all == ["s"])
    }
}
