import AppKit
import WebKit

/// Clearing what the browser keeps.
@MainActor
enum BrowserData {
    /// Deletes history since `date`, or all of it. The saved back/forward
    /// lists and the reopen lists hold URLs too, and can't be cut by date,
    /// so they go in full.
    static func clearHistory(since date: Date?, history: BrowserHistory = .shared) {
        history.clear(since: date)
        for (_, view) in BrowserRegistry.shared.all { view.forgetSavedHistory() }
        BrowserPageState.removeAll()
    }

    static func confirmClearHistory(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Clear history?"
        alert.informativeText = "This also deletes saved back/forward lists and the list of closed tabs. Open tabs stay open."
        alert.addButton(withTitle: "Last Hour")
        alert.addButton(withTitle: "Last Day")
        alert.addButton(withTitle: "Everything")
        alert.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: clearHistory(since: Date().addingTimeInterval(-3600))
            case .alertSecondButtonReturn: clearHistory(since: Date().addingTimeInterval(-86400))
            case .alertThirdButtonReturn: clearHistory(since: nil)
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    static func clearWebsiteData() {
        for store in [BrowserPage.sharedDataStore] + BrowserProxy.allStores {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
    }

    static func confirmClearWebsiteData(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Clear cookies and site data?"
        alert.informativeText = "This signs you out of websites in every browser pane, on this Mac and remote machines."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { clearWebsiteData() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }
}

/// Safari's Web Inspector, for the page showing, in a window of its own: a
/// pane is too small for it, and docked it would share the pane's layout.
/// WebKit only offers it through private API, so each piece is checked first.
@MainActor
enum BrowserInspector {
    private static let getter = NSSelectorFromString("_inspector")
    private static let showSelector = NSSelectorFromString("show")
    private static let detachSelector = NSSelectorFromString("detach")

    static var isAvailable: Bool { WKWebView.instancesRespond(to: getter) }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: getter), let inspector = webView.perform(getter)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: showSelector), inspector.responds(to: detachSelector) else { return nil }
        return inspector
    }

    static func show(_ webView: WKWebView) {
        guard let inspector = inspector(of: webView) else { return }
        inspector.perform(showSelector)
        inspector.perform(detachSelector)
    }

    /// Its own dock button puts it in the pane. Back out it goes.
    static func keepDetached(_ webView: WKWebView, in pane: NSView) {
        guard pane.subviews.contains(where: { String(describing: type(of: $0)).contains("Inspector") }) else { return }
        DispatchQueue.main.async { inspector(of: webView)?.perform(detachSelector) }
    }
}
