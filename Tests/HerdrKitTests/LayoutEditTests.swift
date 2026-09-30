import Testing
@testable import HerdrKit

struct LayoutEditTests {
    private func p(_ id: String) -> LayoutNode { .pane(id: id) }
    private func row(_ a: LayoutNode, _ b: LayoutNode) -> LayoutNode { .split(direction: .right, ratio: 0.5, first: a, second: b) }
    private func column(_ a: LayoutNode, _ b: LayoutNode) -> LayoutNode { .split(direction: .down, ratio: 0.5, first: a, second: b) }

    @Test func threeAcrossBecomesTwoOverOne() {
        let across = row(row(p("a"), p("b")), p("c"))
        let result = across.dropping("c", on: .tabEdge(.bottom))
        #expect(result.sameArrangement(as: column(row(p("a"), p("b")), p("c"))))
    }

    @Test func dropBesideAPane() {
        let across = row(row(p("a"), p("b")), p("c"))
        #expect(across.dropping("c", on: .pane("b", .bottom)).sameArrangement(as: row(p("a"), column(p("b"), p("c")))))
        #expect(across.dropping("a", on: .pane("c", .left)).sameArrangement(as: row(p("b"), row(p("a"), p("c")))))
    }

    @Test func centerSwaps() {
        let across = row(p("a"), p("b"))
        #expect(across.dropping("a", on: .pane("b", .center)).sameArrangement(as: row(p("b"), p("a"))))
    }

    @Test func tabEdgeTopAndLeft() {
        let stack = column(p("a"), column(p("b"), p("c")))
        #expect(stack.dropping("c", on: .tabEdge(.left)).sameArrangement(as: row(p("c"), column(p("a"), p("b")))))
        #expect(stack.dropping("a", on: .tabEdge(.top)).sameArrangement(as: column(p("a"), column(p("b"), p("c")))))
    }

    @Test func removingCollapsesParent() {
        #expect(row(p("a"), column(p("b"), p("c"))).removing("b")!.sameArrangement(as: row(p("a"), p("c"))))
        #expect(p("a").removing("a") == nil)
    }

    @Test func splitPaths() {
        let tree = row(p("a"), column(p("b"), p("c")))
        #expect(tree.splits.map(\.path) == [[], [true]])
    }
}
