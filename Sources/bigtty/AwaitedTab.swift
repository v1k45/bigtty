import Foundation
import HerdrKit

/// A tab (or space) a window just created with ⌘T, ⌥⌘T, ⌘N or ⌥⌘N, to
/// show once herdr's snapshot has it.
///
/// The window can render several times between asking herdr and seeing
/// the result: every snapshot change does it, and a busy pane changes
/// one many times a second (an agent's spinner in its title), more so
/// across the round trips to a remote Mac. Meanwhile the window keeps
/// showing what it showed; it never falls back to herdr's focus, which
/// is still on the old tab then.
struct AwaitedTab: Equatable {
    let workspaceID: String
    let tabID: String
    let paneID: String
    let since: Date

    /// A tab that never shows up (closed at once by someone else) is
    /// forgotten after this.
    static let patience: TimeInterval = 10

    enum Step: Equatable {
        /// Not in the snapshot yet: keep showing what's shown.
        case wait
        /// Arrived: show it.
        case show
        /// Gave up on it.
        case forget
    }

    init(_ pane: Pane, since: Date = Date()) {
        workspaceID = pane.workspaceID
        tabID = pane.tabID
        paneID = pane.paneID
        self.since = since
    }

    func step(in snapshot: Snapshot, now: Date = Date()) -> Step {
        if snapshot.tabs.contains(where: { $0.tabID == tabID && $0.workspaceID == workspaceID }) { return .show }
        return now.timeIntervalSince(since) > Self.patience ? .forget : .wait
    }
}
