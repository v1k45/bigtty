import Testing
@testable import HerdrKit

struct ClickedPathTests {
    @Test func absolute() {
        #expect(ClickedPath("/Users/me/shot.png") == .init(path: "/Users/me/shot.png", line: nil))
    }

    @Test func lineAndColumn() {
        #expect(ClickedPath("Sources/app.swift:42") == .init(path: "Sources/app.swift", line: 42))
        #expect(ClickedPath("Sources/app.swift:42:7") == .init(path: "Sources/app.swift", line: 42))
    }

    @Test func fileURL() {
        #expect(ClickedPath("file:///tmp/a%20b.png") == .init(path: "/tmp/a b.png", line: nil))
        #expect(ClickedPath("file:///tmp/x.swift#L12") == .init(path: "/tmp/x.swift", line: 12))
    }

    @Test func surroundingPunctuation() {
        #expect(ClickedPath("(/tmp/x.png).") == .init(path: "/tmp/x.png", line: nil))
        #expect(ClickedPath("`src/a.py`,") == .init(path: "src/a.py", line: nil))
    }

    @Test func otherSchemesAreNotPaths() {
        #expect(ClickedPath("mailto:me@example.com") == nil)
        #expect(ClickedPath("ssh://host/x") == nil)
    }

    @Test func resolving() {
        #expect(ClickedPath("src/a.py")!.resolved(cwd: "/home/v/proj", home: "/home/v") == "/home/v/proj/src/a.py")
        #expect(ClickedPath("~/notes.md")!.resolved(cwd: "/x", home: "/home/v") == "/home/v/notes.md")
        #expect(ClickedPath("../b.txt")!.resolved(cwd: "/home/v/proj", home: nil) == "/home/v/b.txt")
        #expect(ClickedPath("/abs/c")!.resolved(cwd: "/x", home: nil) == "/abs/c")
    }
}
