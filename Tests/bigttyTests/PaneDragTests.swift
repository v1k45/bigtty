import AppKit
@testable import bigtty
import Testing

/// The top row of panes sits under the hidden title bar, where AppKit drags
/// the window from every view that doesn't claim its rect.
@MainActor @Suite struct PaneDragTests {
    private typealias OpaqueRect = @convention(c) (AnyObject, Selector) -> NSRect
    private let selector = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")

    /// The rect a view keeps for itself under the title bar.
    private func claimed(by view: NSView) -> NSRect {
        let imp = class_getMethodImplementation(type(of: view), selector)
        return unsafeBitCast(imp, to: OpaqueRect.self)(view, selector)
    }

    @Test func appKitStillAsksViewsAboutTitlebarDrags() {
        // If this fails, macOS dropped the hook: dragging a top-row pane's
        // grip moves the window again.
        #expect(PaneContainerView.claimsTitlebarDrags)
    }

    @Test func panesKeepDragsUnderTheTitleBar() {
        let pane = PaneContainerView(paneID: "p1", content: NSView())
        pane.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        #expect(claimed(by: pane) == pane.bounds)
    }

    @Test func gripStaysOutOfTheKeyboardFocus() {
        let grip = PaneGrip(frame: NSRect(x: 0, y: 0, width: 400, height: PaneGrip.bandHeight))
        #expect(!grip.mouseDownCanMoveWindow)
        #expect(!grip.acceptsFirstResponder)
    }

    @Test func plainViewsStillMoveTheWindow() {
        // The gap above the panes and the sidebar's top keep dragging it.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 8))
        #expect(claimed(by: view) == .zero)
    }

    @Test func gripLetsControlsUnderItKeepTheirClicks() {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let content = NSView(frame: pane.bounds)
        let button = NSButton(frame: NSRect(x: 10, y: 284, width: 40, height: 16))
        content.addSubview(button)
        pane.addSubview(content)
        let grip = PaneGrip(frame: NSRect(x: 0, y: 300 - PaneGrip.bandHeight, width: 400, height: PaneGrip.bandHeight))
        grip.content = content
        pane.addSubview(grip)
        #expect(grip.hitTest(NSPoint(x: 20, y: 292)) == nil)
        #expect(grip.hitTest(NSPoint(x: 200, y: 292)) === grip)
    }
}
