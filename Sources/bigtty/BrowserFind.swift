import AppKit
import WebKit

/// ⌘F in a browser pane, with WebKit's own find, as Safari does: every
/// match highlighted (the page dims around them), the current one bounced,
/// and a match count. Nothing goes into the page, so it can't see what you
/// search for.
///
/// The highlights and count are WebKit SPI (`_findString:options:maxCount:`
/// with `_WKFindDelegate`), the same calls DuckDuckGo's macOS browser makes.
/// Each is checked before use: without them, find falls back to the public
/// `find(_:configuration:)`, which selects matches but can't count them.
@MainActor
final class BrowserFinder: FindDriver {
    private weak var browser: BrowserPaneView?
    var onFindStatus: ((FindStatus) -> Void)?
    var findBarInset: CGFloat { BrowserPaneView.toolbarHeight }
    var findsUpward: Bool { false }
    var findFocusView: NSView { browser?.webView ?? NSView() }

    private var query = ""
    /// A search has found matches: later ones continue from the current one.
    private var active = false
    /// 0-based; WebKit's own match index isn't reliable, so it's tracked here.
    private var index: Int?
    private let callbacks = FindCallbacks()
    /// Answers to older requests are dropped.
    private var generation = 0

    static let maxMatches = 1000

    init(browser: BrowserPaneView) {
        self.browser = browser
    }

    func find(_ query: String) {
        self.query = query
        guard !query.isEmpty else {
            reset()
            onFindStatus?(.idle)
            return
        }
        // Typing more keeps the current match where it can.
        search(active ? [.showOverlay, .noIndexChange] : [.showOverlay], step: .stay)
    }

    func findNext(backwards: Bool) {
        guard !query.isEmpty else { return }
        search(backwards ? [.showOverlay, .backwards] : [.showOverlay], step: backwards ? .back : .forward)
    }

    func endFind() {
        query = ""
        reset()
    }

    /// A new page loaded under the open bar: search it too.
    func pageLoaded() {
        guard !query.isEmpty else { return }
        reset()
        search([.showOverlay], step: .stay)
    }

    func selectionForFind(_ done: @escaping (String?) -> Void) {
        // In the app's world: the page can't swap getSelection out.
        browser?.webView.evaluateJavaScript("String(window.getSelection() || '')", in: nil, in: BrowserPaneView.automationWorld) { result in
            MainActor.assumeIsolated { done((try? result.get() as? String).flatMap { $0.isEmpty ? nil : $0 }) }
        }
    }

    // MARK: - Searching

    private func reset() {
        generation += 1
        active = false
        index = nil
        hideOverlay()
    }

    private func hideOverlay() {
        if let webView = browser?.webView, webView.responds(to: Self.hideFindUI) {
            webView.perform(Self.hideFindUI)
        }
    }

    private func search(_ options: FindOptions, step: FindStep, retried: Bool = false) {
        guard let webView = browser?.webView else { return }
        generation += 1
        let generation = generation
        var options = options.union([.caseInsensitive, .wrapAround, .showFindIndicator])
        // The first search of a run doesn't always draw the overlay; it's
        // repeated once with it (see `answered`), as DuckDuckGo does.
        // (WebKit SPI, so any of this may change: a `WebKitFindTests` canary
        // checks it still counts.)
        if !active { options.remove(.showOverlay) }

        guard Self.hasNativeFind(webView) else {
            return publicFind(webView, backwards: options.contains(.backwards), generation: generation)
        }
        if options.contains(.noIndexChange) {
            // Find starts from the selection: collapsed to its start, the
            // same match is found again.
            webView.evaluateJavaScript("try { window.getSelection().collapseToStart() } catch (_) {}", in: nil, in: BrowserPaneView.automationWorld) { _ in }
        }
        callbacks.attach(to: webView) { [weak self] matches in
            guard let self, generation == self.generation else { return }
            self.answered(matches, step: step, retried: retried)
        }
        Self.findString(webView, query, options: options.rawValue, maxCount: UInt(Self.maxMatches))
    }

    private func answered(_ matches: Int, step: FindStep, retried: Bool) {
        guard matches > 0 else {
            reset()
            onFindStatus?(.matches(current: nil, total: 0))
            return
        }
        index = Self.nextIndex(index, total: matches, step: step)
        if !active, !retried {
            // WebKit counts (and highlights every match) only with the
            // overlay: again, on the same match, with it.
            active = true
            hideOverlay()
            search([.showOverlay, .noIndexChange], step: .stay, retried: true)
            return
        }
        active = true
        onFindStatus?(.matches(current: index, total: matches))
    }

    /// Without the SPI: the match is selected and scrolled to, uncounted.
    private func publicFind(_ webView: WKWebView, backwards: Bool, generation: Int) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation else { return }
                self.onFindStatus?(result.matchFound ? .uncounted : .matches(current: nil, total: 0))
            }
        }
    }

    // MARK: - Index

    enum FindStep { case stay, forward, back }

    /// The current match after a search found `total`: the first on a new
    /// search, kept on a refinement (clamped), one along (wrapping) on
    /// next / previous.
    nonisolated static func nextIndex(_ current: Int?, total: Int, step: FindStep) -> Int? {
        guard total > 0 else { return nil }
        guard let current else { return step == .back ? total - 1 : 0 }
        switch step {
        case .stay: return min(current, total - 1)
        case .forward: return current + 1 < total ? current + 1 : 0
        case .back: return current > 0 ? current - 1 : total - 1
        }
    }

    // MARK: - WebKit SPI

    /// `_WKFindOptions`.
    struct FindOptions: OptionSet {
        let rawValue: UInt
        static let caseInsensitive = Self(rawValue: 1 << 0)
        static let backwards = Self(rawValue: 1 << 3)
        static let wrapAround = Self(rawValue: 1 << 4)
        static let showOverlay = Self(rawValue: 1 << 5)
        static let showFindIndicator = Self(rawValue: 1 << 6)
        static let noIndexChange = Self(rawValue: 1 << 8)
    }

    static let findStringSelector = NSSelectorFromString("_findString:options:maxCount:")
    static let hideFindUI = NSSelectorFromString("_hideFindUI")
    static let setFindDelegate = NSSelectorFromString("_setFindDelegate:")

    static func hasNativeFind(_ webView: WKWebView) -> Bool {
        webView.responds(to: findStringSelector) && webView.responds(to: setFindDelegate)
    }

    static func findString(_ webView: WKWebView, _ string: String, options: UInt, maxCount: UInt) {
        typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        let find = unsafeBitCast(webView.method(for: findStringSelector), to: Find.self)
        find(webView, findStringSelector, string as NSString, options, maxCount)
    }
}

/// `_WKFindDelegate`: how many matches a find found. (The web view holds
/// its find delegate weakly; the finder keeps this alive.)
@MainActor
final class FindCallbacks: NSObject {
    private var completion: ((Int) -> Void)?

    /// Becomes the web view's find delegate for the next answer.
    func attach(to webView: WKWebView, completion: @escaping (Int) -> Void) {
        self.completion = completion
        webView.perform(BrowserFinder.setFindDelegate, with: self)
    }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_: WKWebView, didFindMatches matches: UInt, forString _: String, withMatchIndex _: Int) {
        finish(Int(matches))
    }

    @objc(_webView:didFailToFindString:)
    func webView(_: WKWebView, didFailToFindString _: String) {
        finish(0)
    }

    private func finish(_ matches: Int) {
        let completion = completion
        self.completion = nil
        completion?(matches)
    }
}
