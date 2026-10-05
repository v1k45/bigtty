import Foundation
@testable import HerdrKit
import Testing

@Suite struct NetworkChangeTests {
    let wifi = NetworkChange.Path(satisfied: true, interfaces: ["en0"])
    let down = NetworkChange.Path(satisfied: false, interfaces: [])
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func theNetworkAtLaunchIsNotAChange() {
        var change = NetworkChange()
        let changed = change.pathChanged(wifi)
        #expect(!changed)
    }

    @Test func comingBackRetries() {
        var change = NetworkChange()
        _ = change.pathChanged(wifi)
        let lost = change.pathChanged(down)
        let back = change.pathChanged(wifi)
        #expect(!lost && back)
    }

    @Test func movingToOtherInterfacesRetries() {
        var change = NetworkChange()
        _ = change.pathChanged(wifi)
        let vpn = change.pathChanged(.init(satisfied: true, interfaces: ["en0", "utun4"]))
        #expect(vpn)
    }

    @Test func repeatsOfTheSamePathAreIgnored() {
        var change = NetworkChange()
        _ = change.pathChanged(wifi)
        let again = change.pathChanged(wifi)
        let andAgain = change.pathChanged(wifi)
        #expect(!again && !andAgain)
    }

    @Test func retriesOnceSettled() {
        let change = NetworkChange(settle: 2, spacing: 15)
        #expect(change.retryAt(now: t0) == t0 + 2)
    }

    @Test func aFlappingNetworkRetriesAtMostEverySpacing() {
        var change = NetworkChange(settle: 2, spacing: 15)
        change.retried(at: t0)
        // Back again a second later: waits out the spacing, not just the settle.
        #expect(change.retryAt(now: t0 + 1) == t0 + 15)
        // Long after: just the settle.
        #expect(change.retryAt(now: t0 + 60) == t0 + 62)
    }
}
