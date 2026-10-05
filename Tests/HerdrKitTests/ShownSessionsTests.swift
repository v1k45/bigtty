import Testing
@testable import HerdrKit

@Suite struct ShownSessionsTests {
    @Test func showingTheShownSessionIsNoChange() {
        var shown = ShownSessions()
        let own = shown.show("default", on: "box", own: "default")
        let other = shown.show("work", on: "box", own: "default")
        let again = shown.show("work", on: "box", own: "default")
        #expect(!own)
        #expect(other)
        #expect(!again)
        #expect(shown.shown(on: "box", own: "default") == "work")
        let back = shown.show("default", on: "box", own: "default")
        #expect(back)
        #expect(shown.shown(on: "other", own: "default") == "default")
    }

    /// The 0.6.3 crash: a remote's session list dropped the session a window
    /// showed; the window fell back to the remote's own session, showing it
    /// announced a change, and the window (still on the gone session while
    /// the change was announced) fell back again, 12,000 levels deep.
    @Test func fallingBackFromAGoneSessionSettles() {
        final class Model {
            var shown = ShownSessions(["box": "work"])
            var live: Set<String> = ["box/default", "box/work"]
            var window = "box/work"
            var depth = 0
            var maxDepth = 0

            /// MachineManager.changed() → the window's observer.
            func changed() {
                depth += 1
                maxDepth = max(maxDepth, depth)
                defer { depth -= 1 }
                guard depth < 50 else { return }
                if !live.contains(window) { switchTo("default") }
            }

            /// The window's switchMachine at the time of the crash: it tells
            /// the manager first and moves itself after.
            func switchTo(_ session: String) {
                if shown.show(session, on: "box", own: "default") { changed() }
                window = "box/" + session
            }
        }
        let model = Model()
        model.live.remove("box/work")
        model.changed()
        #expect(model.window == "box/default")
        #expect(model.maxDepth <= 2)
    }
}
