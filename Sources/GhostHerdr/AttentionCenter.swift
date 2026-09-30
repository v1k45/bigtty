import AppKit
import HerdrKit
import UserNotifications

/// Tracks which panes need the user, posts notifications for new ones, and
/// keeps the Dock badge current.
@MainActor
final class AttentionCenter: NSObject, UNUserNotificationCenterDelegate {
    private let store: SessionStore
    private(set) var attention = Attention()
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var notificationsAvailable = false

    /// Panes the user is looking at: focused in the key window of the active app.
    var viewedPanes: () -> Set<String> = { [] }
    /// Bring a pane on screen (notification click, jump-to-unread).
    var reveal: (Pane) -> Void = { _ in }

    init(store: SessionStore) {
        self.store = store
        super.init()
        store.observe { [weak self] in self?.snapshotChanged() }
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewChanged() }
            }
        }
        setUpNotifications()
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    // MARK: - State

    private func snapshotChanged() {
        let transitions = attention.update(panes: store.snapshot.panes, viewed: currentlyViewed)
        for transition in transitions { notify(transition) }
        publish()
    }

    /// Focus or key window moved: whatever is now on screen counts as seen.
    func viewChanged() {
        let before = attention
        attention.markViewed(currentlyViewed)
        if attention != before { publish() }
    }

    private var currentlyViewed: Set<String> {
        NSApp.isActive ? viewedPanes() : []
    }

    private func publish() {
        let count = attention.needingAttention.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        for handler in observers.values { handler() }
    }

    func reason(for paneID: String) -> Attention.Reason? { attention.reason(for: paneID) }

    func count(inTab tabID: String) -> Int { attention.count(inTab: tabID, panes: store.snapshot.panes) }

    func count(inWorkspace id: String) -> Int { attention.count(inWorkspace: id, panes: store.snapshot.panes) }

    /// Reveals the next pane needing attention after `current`, wrapping.
    func jumpToNext(after current: String?) {
        let queue = attention.queue(in: store.snapshot)
        guard !queue.isEmpty else { NSSound.beep(); return }
        let index = queue.firstIndex { $0.paneID == current }.map { ($0 + 1) % queue.count } ?? 0
        reveal(queue[index])
    }

    // MARK: - Notifications

    private func setUpNotifications() {
        // UNUserNotificationCenter needs a real app bundle; `swift run`
        // binaries have none and would crash on access.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("ghostherdr: notifications unavailable: \(error)") }
            Task { @MainActor [weak self] in self?.notificationsAvailable = granted }
        }
    }

    private func notify(_ transition: Attention.Transition) {
        guard notificationsAvailable, let pane = store.pane(transition.paneID) else { return }
        switch Settings.notify {
        case .never: return
        case .needsYou: if transition.reason == .done { return }
        case .needsYouOrFinishes: break
        }
        let workspace = store.workspace(pane.workspaceID)?.label ?? pane.workspaceID
        let agent = pane.displayAgent ?? pane.agent ?? "Agent"
        let content = UNMutableNotificationContent()
        switch transition.reason {
        case .blocked:
            content.title = "\(agent) needs you"
            content.sound = .default
        case .done:
            content.title = "\(agent) finished"
        }
        content.subtitle = workspace
        content.body = pane.title ?? pane.terminalTitle ?? pane.displayName
        content.userInfo = ["pane_id": pane.paneID]
        content.threadIdentifier = pane.workspaceID
        let request = UNNotificationRequest(identifier: "\(pane.paneID)-\(transition.reason)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let paneID = response.notification.request.content.userInfo["pane_id"] as? String else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let pane = store.pane(paneID) { reveal(pane) }
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
