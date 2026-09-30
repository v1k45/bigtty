import AppKit
import HerdrKit
import UserNotifications

/// Tracks which panes need the user, posts notifications for new ones, and
/// keeps the Dock badge current.
@MainActor
final class AttentionCenter: NSObject {
    private let store: SessionStore
    private(set) var attention = Attention()
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var notificationsAvailable = false

    /// Panes the user is looking at: focused in the key window of the active app.
    var viewedPanes: () -> Set<String> = { [] }
    /// Bring a pane on screen (notification click, jump-to-unread).
    var reveal: (Pane) -> Void = { _ in }

    /// Shown in notifications for remote machines ("api-server · workbox").
    private let machineName: String?

    init(store: SessionStore, machineName: String? = nil) {
        self.store = store
        self.machineName = machineName
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
        Self.all.append(WeakAttention(self))
        center.delegate = NotificationRouter.shared
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
        content.subtitle = machineName.map { "\(workspace) · \($0)" } ?? workspace
        content.body = pane.title ?? pane.terminalTitle ?? pane.displayName
        content.userInfo = ["pane_id": pane.paneID, "machine": machineName ?? "local"]
        content.threadIdentifier = pane.workspaceID
        let request = UNNotificationRequest(identifier: "\(pane.paneID)-\(transition.reason)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Every attention center, so notification clicks reach the right machine.
    static var all: [WeakAttention] = []

    /// A notification for one of this center's panes was clicked.
    func handleClick(userInfo: [String: String]) -> Bool {
        guard (userInfo["machine"] ?? "local") == (machineName ?? "local"),
              let paneID = userInfo["pane_id"], let pane = store.pane(paneID) else { return false }
        NSApp.activate(ignoringOtherApps: true)
        reveal(pane)
        return true
    }
}

final class WeakAttention {
    weak var value: AttentionCenter?
    init(_ value: AttentionCenter) { self.value = value }
}

/// The one UNUserNotificationCenter delegate, routing clicks to the machine
/// whose pane it was.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo
        let info: [String: String] = ["pane_id": raw["pane_id"] as? String ?? "", "machine": raw["machine"] as? String ?? "local"]
        await MainActor.run {
            for center in AttentionCenter.all.compactMap(\.value) where center.handleClick(userInfo: info) { break }
        }
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
