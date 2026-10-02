import Testing
@testable import HerdrKit

@Suite struct PinLayoutTests {
    let pair = LayoutNode.split(direction: .down, ratio: 0.5, first: .pane(id: "a"), second: .pane(id: "b"))

    @Test func columnWrapsTheTab() {
        let root = PinLayout.column(others: pair, pins: ["p1", "p2"], width: 0.3)
        guard case let .split(.right, ratio, first, second) = root else { Issue.record("not a right split"); return }
        #expect(abs(ratio - 0.7) < 0.0001)
        #expect(first == pair)
        #expect(second.paneIDs == ["p1", "p2"])
        #expect(PinLayout.isColumn(root, pins: ["p1", "p2"]))
        #expect(!PinLayout.isColumn(root, pins: ["p2", "p1"]))
        #expect(!PinLayout.isColumn(pair, pins: ["a"]))
    }

    @Test func rightEdgeLeafFollowsRightSplits() {
        let three = LayoutNode.split(direction: .right, ratio: 0.5, first: .pane(id: "a"),
                                     second: .split(direction: .right, ratio: 0.5, first: .pane(id: "b"), second: .pane(id: "c")))
        let edge = PinLayout.rightEdgeLeaf(three)
        #expect(edge?.id == "c")
        #expect(abs((edge?.share ?? 0) - 0.25) < 0.0001)
        // A down split at the edge spans no single full-height pane.
        #expect(PinLayout.rightEdgeLeaf(pair) == nil)
        #expect(PinLayout.rightEdgeLeaf(.pane(id: "solo"))?.id == "solo")
    }

    @Test func splitRatioGivesTheColumnItsWidth() {
        #expect(abs(PinLayout.splitRatio(share: 1, width: 0.3) - 0.7) < 0.0001)
        #expect(abs(PinLayout.splitRatio(share: 0.5, width: 0.3) - 0.4) < 0.0001)
        #expect(PinLayout.splitRatio(share: 0.1, width: 0.3) == 0.1)
    }
}
