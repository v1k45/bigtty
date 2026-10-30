import AppKit
@testable import bigtty
import Testing
import WebKit

@Suite struct BrowserAddressNormalizeTests {
    func normalized(_ text: String) -> String? { BrowserAddress.normalize(text)?.absoluteString }

    @Test func fullURLsStayAsTheyAre() {
        #expect(normalized("https://example.com/a?b=1") == "https://example.com/a?b=1")
        #expect(normalized("  http://localhost:3000/  ") == "http://localhost:3000/")
        #expect(normalized("about:blank") == "about:blank")
        #expect(normalized("webkit-extension://abc/dashboard.html") == "webkit-extension://abc/dashboard.html")
    }

    @Test func aLonePortIsLocalhost() {
        #expect(normalized(":8040") == "http://localhost:8040")
        #expect(normalized(":8040/orders?id=1") == "http://localhost:8040/orders?id=1")
        #expect(normalized(":http")?.hasPrefix("https://duckduckgo.com/") == true)
    }

    @Test func bareHosts() {
        #expect(normalized("example.com") == "https://example.com")
        #expect(normalized("example.com/a") == "https://example.com/a")
        #expect(normalized("localhost:3000") == "http://localhost:3000")
        #expect(normalized("localhost") == "http://localhost")
        #expect(normalized("127.0.0.1:8080/x") == "http://127.0.0.1:8080/x")
        #expect(normalized("0.0.0.0:5000") == "http://0.0.0.0:5000")
        #expect(normalized("[::1]:3000") == "http://[::1]:3000")
        #expect(normalized("api.localhost:3000") == "http://api.localhost:3000")
        #expect(normalized("devbox:9000") == "https://devbox:9000")
    }

    @Test func everythingElseSearches() {
        for text in ["what is a port", "swift", "foo:bar", "a b.c", "readme/notes"] {
            #expect(normalized(text)?.hasPrefix("https://duckduckgo.com/?q=") == true, "\(text)")
        }
        #expect(BrowserAddress.normalize("   ") == nil)
    }
}

@Suite struct BrowserAddressShownTests {
    func shown(_ text: String) -> BrowserAddress.Shown { BrowserAddress.shown(URL(string: text)!) }

    @Test func dropsTheSchemeAndKeepsThePath() {
        #expect(shown("https://docs.acme.dev/api/coupons?version=2") == .init(site: "docs.acme.dev", rest: "/api/coupons?version=2"))
        #expect(shown("http://example.test/login") == .init(site: "example.test", rest: "/login"))
    }

    @Test func aPortBelongsToTheSite() {
        #expect(shown("http://localhost:8040/orders") == .init(site: "localhost:8040", rest: "/orders"))
        #expect(shown("http://[::1]:3000/a") == .init(site: "[::1]:3000", rest: "/a"))
    }

    @Test func aBareRootHasNoRest() {
        #expect(shown("https://example.com/") == .init(site: "example.com", rest: ""))
        #expect(shown("https://example.com") == .init(site: "example.com", rest: ""))
        #expect(shown("https://example.com?q=1") == .init(site: "example.com", rest: "?q=1"))
    }

    @Test func aUserNameCantPoseAsTheSite() {
        #expect(shown("https://bank.com@evil.example/x").site == "evil.example")
    }

    @Test func otherSchemesShowWhole() {
        #expect(shown("file:///tmp/a.html") == .init(site: "", rest: "file:///tmp/a.html"))
        #expect(shown("about:blank") == .init(site: "", rest: "about:blank"))
    }
}

@Suite struct BrowserAddressFitTests {
    /// Every character is one point wide.
    func fit(_ site: String, _ rest: String, _ width: CGFloat) -> BrowserAddress.Shown {
        BrowserAddress.fit(.init(site: site, rest: rest), width: width) { CGFloat($0.count) }
    }

    @Test func leavesWhatFits() {
        #expect(fit("acme.dev", "/orders", 15) == .init(site: "acme.dev", rest: "/orders"))
    }

    @Test func cutsThePathFirst() {
        #expect(fit("acme.dev", "/orders/1234", 13) == .init(site: "acme.dev", rest: "/ord…"))
        #expect(fit("acme.dev", "/orders/1234", 9) == .init(site: "acme.dev", rest: "…"))
        #expect(fit("acme.dev", "/orders/1234", 8) == .init(site: "acme.dev", rest: ""))
    }

    @Test func thenTheStartOfTheHost() {
        #expect(fit("docs.acme.dev", "/api", 9).site == "…acme.dev")
        #expect(fit("docs.acme.dev", "/api", 9).rest.isEmpty)
    }

    /// The real site always shows, however deep the lookalike goes.
    @Test func aLookalikeEndsAsTheRealSite() {
        let host = "accounts.bank.com.evil.example"
        #expect(fit(host, "/login", 13).site == "…evil.example")
        #expect(fit(host, "/login", 20).site == "…com.evil.example")
        #expect(fit(host, "/login", 20).site.hasSuffix("evil.example"))
    }

    @Test func aPortSurvivesTheCut() {
        #expect(fit("very.long.preview.acme.dev:8040", "/x", 15).site.hasSuffix(":8040"))
    }

    @Test func nothingFitsNothingBreaks() {
        #expect(fit("acme.dev", "/x", 0).site == "…")
    }
}

@Suite struct BrowserSecurityTests {
    func security(_ text: String?, secure: Bool = true) -> BrowserAddress.Security {
        BrowserAddress.security(of: text.flatMap(URL.init(string:)), onlySecureContent: secure)
    }

    @Test func httpsIsQuietLockUnlessMixed() {
        #expect(security("https://acme.dev") == .secure)
        #expect(security("https://acme.dev", secure: false) == .mixed)
        #expect(security("https://localhost:8443", secure: false) == .mixed)
    }

    @Test func plainHTTPWarnsExceptLocally() {
        #expect(security("http://example.test/login") == .insecure)
        for url in ["http://localhost:8040", "http://127.0.0.1:3000", "http://0.0.0.0:80", "http://[::1]:3000", "http://app.localhost/"] {
            #expect(security(url) == .quiet, "\(url)")
        }
    }

    /// A subdomain of someone else's site isn't local.
    @Test func lookalikesOfLocalhostWarn() {
        #expect(security("http://localhost.evil.example") == .insecure)
        #expect(security("http://127.evil.example") == .insecure)
    }

    @Test func nothingToSayElsewhere() {
        #expect(security(nil) == .quiet)
        #expect(security("about:blank") == .quiet)
        #expect(security("file:///tmp/a.html") == .quiet)
    }

    @Test func onlySecurityWarningsCount() {
        #expect(BrowserAddress.Security.mixed.isWarning)
        #expect(BrowserAddress.Security.insecure.isWarning)
        #expect(!BrowserAddress.Security.secure.isWarning)
    }
}

/// The real field in a real window (never shown), through the field editor.
@MainActor @Suite struct AddressFieldTests {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    let pane: BrowserPaneView

    init() {
        _ = NSApplication.shared
        pane = BrowserPaneView(hostID: "test-\(UUID().uuidString)", state: HostPaneState(kind: .browser))
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView?.addSubview(pane)
        pane.layoutSubtreeIfNeeded()
    }

    func onPage(_ url: String) {
        pane.navigate(to: URL(string: url)!)
        pane.webView.stopLoading()
    }

    func escape() {
        guard let editor = pane.address.currentEditor() as? NSTextView else {
            Issue.record("not editing")
            return
        }
        _ = pane.control(pane.address, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    @Test func atRestShowsTheShortAddress() {
        onPage("https://docs.acme.dev/api?x=1")
        #expect(pane.address.stringValue == "docs.acme.dev/api?x=1")
        #expect(!pane.isEditingAddress)
    }

    @Test func focusShowsTheExactURLSelected() {
        onPage("https://docs.acme.dev/api?x=1")
        pane.focusAddressBar()
        #expect(pane.isEditingAddress)
        let editor = pane.address.currentEditor() as? NSTextView
        #expect(editor?.string == "https://docs.acme.dev/api?x=1")
        #expect(editor?.selectedRange() == NSRange(location: 0, length: 29))
    }

    @Test func leavingWithoutReturnPutsTheAddressBack() {
        onPage("https://docs.acme.dev/api")
        pane.focusAddressBar()
        (pane.address.currentEditor() as? NSTextView)?.string = "half typed"
        window.makeFirstResponder(pane.webView)
        #expect(!pane.isEditingAddress)
        #expect(pane.address.stringValue == "docs.acme.dev/api")
    }

    @Test func aFocusedFieldThatWasNeverEditedStillGoesBack() {
        onPage("https://docs.acme.dev/api")
        pane.focusAddressBar()
        window.makeFirstResponder(pane.webView)
        #expect(pane.address.stringValue == "docs.acme.dev/api")
    }

    @Test func navigationNeverTouchesWhatsBeingTyped() {
        onPage("https://docs.acme.dev/api")
        pane.focusAddressBar()
        let editor = pane.address.currentEditor() as? NSTextView
        editor?.string = "half typed"
        onPage("https://other.example/agent-went-here")
        #expect(editor?.string == "half typed")
        window.makeFirstResponder(pane.webView)
        #expect(pane.address.stringValue == "other.example/agent-went-here")
    }

    @Test func escapeRestoresThenLeaves() {
        onPage("https://docs.acme.dev/api")
        pane.focusAddressBar()
        let editor = pane.address.currentEditor() as? NSTextView
        editor?.string = "half typed"
        escape()
        #expect(pane.isEditingAddress)
        #expect(editor?.string == "https://docs.acme.dev/api")
        escape()
        #expect(!pane.isEditingAddress)
        #expect(window.firstResponder === pane.webView)
    }

    @Test func escapeWithNothingToUndoGoesStraightToThePage() {
        onPage("https://docs.acme.dev/api")
        pane.focusAddressBar()
        escape()
        #expect(!pane.isEditingAddress)
        #expect(window.firstResponder === pane.webView)
    }

    @Test func withNoPageTypedTextStaysAfterLeaving() {
        pane.focusAddressBar()
        (pane.address.currentEditor() as? NSTextView)?.string = "localhost:3000"
        pane.address.stringValue = "localhost:3000"
        window.makeFirstResponder(pane.webView)
        #expect(pane.address.stringValue == "localhost:3000")
    }

    @Test func optionsMenuHoldsPageActionsAndSettings() {
        onPage("https://docs.acme.dev/api")
        let titles = pane.optionsMenu().items.map(\.title)
        #expect(titles.contains("Open in Default Browser"))
        #expect(titles.contains("Copy Address"))
        #expect(titles.contains("Reload Without Cache"))
        #expect(titles.contains("Find in Page…"))
        #expect(titles.last == "Browser Settings…")
        #expect(!titles.contains("Reload Page"))
        #expect(pane.optionsMenu().items.contains { $0.view is ZoomMenuRow })
        let open = pane.optionsMenu().items.first { $0.title == "Open in Default Browser" }
        #expect(open?.keyEquivalent == "o")
        #expect(open?.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test func tightPanesGetReloadInTheMenu() {
        pane.frame.size.width = 180
        pane.layoutSubtreeIfNeeded()
        #expect(pane.optionsMenu().items.first?.title == "Reload Page")
    }

    @Test func noPageNoPageActions() {
        let menu = pane.optionsMenu()
        #expect(menu.items.first { $0.title == "Copy Address" }?.isEnabled == false)
        #expect(menu.items.first { $0.title == "Browser Settings…" }?.isEnabled == true)
    }

    @Test func zoomStepsAndResets() {
        pane.zoom(by: 1)
        #expect(abs(pane.webView.pageZoom - 1.1) < 0.001)
        pane.zoom(by: 0)
        #expect(pane.webView.pageZoom == 1)
        for _ in 0..<40 { pane.zoom(by: -1) }
        #expect(pane.webView.pageZoom == 0.5)
    }

    @Test func aRemotePaneNamesItsMachine() {
        let remote = BrowserPaneView(hostID: "test-\(UUID().uuidString)", state: HostPaneState(kind: .browser), machineName: "devbox")
        remote.frame = pane.bounds
        remote.layoutSubtreeIfNeeded()
        #expect(remote.machineName.stringValue == "devbox")
        #expect(!remote.machineName.isHidden)
        #expect(pane.machineName.isHidden)
    }
}
