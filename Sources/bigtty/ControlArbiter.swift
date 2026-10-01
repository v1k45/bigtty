import AppKit

/// herdr lets one client control a pane and any number observe it. When the
/// same pane is on screen in several windows, the one the user last focused
/// controls and the others observe, so our own windows never fight over it.
@MainActor
final class ControlArbiter {
    static let shared = ControlArbiter()

    private var views: [String: [WeakTerminal]] = [:]
    private var controller: [String: ObjectIdentifier] = [:]

    private struct WeakTerminal {
        weak var view: HerdrTerminalView?
    }

    private func live(_ paneID: String) -> [HerdrTerminalView] {
        let alive = (views[paneID] ?? []).compactMap(\.view)
        views[paneID] = alive.map(WeakTerminal.init)
        return alive
    }

    /// The mode a view should attach with right now.
    func register(_ view: HerdrTerminalView) -> HerdrTerminalView.Mode {
        var list = live(view.paneID)
        if !list.contains(where: { $0 === view }) { list.append(view) }
        views[view.paneID] = list.map(WeakTerminal.init)
        if let id = controller[view.paneID], list.contains(where: { ObjectIdentifier($0) == id }),
           id != ObjectIdentifier(view)
        {
            return .observe
        }
        controller[view.paneID] = ObjectIdentifier(view)
        return .control
    }

    /// Hands control to `view`; every other view of the pane observes.
    func claim(_ view: HerdrTerminalView) {
        _ = register(view)
        controller[view.paneID] = ObjectIdentifier(view)
        for other in live(view.paneID) where other !== view {
            other.setMode(.observe)
        }
        view.setMode(.control)
    }

    /// A view left the screen; if it held control, pass it on.
    func release(_ view: HerdrTerminalView) {
        let remaining = live(view.paneID).filter { $0 !== view && $0.window != nil }
        views[view.paneID] = remaining.map(WeakTerminal.init)
        guard controller[view.paneID] == ObjectIdentifier(view) else { return }
        controller[view.paneID] = nil
        let next = remaining.first { $0.window?.isKeyWindow == true } ?? remaining.first
        if let next { claim(next) }
    }
}
