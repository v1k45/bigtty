import AppKit
@testable import bigtty
import Foundation
import Testing

@Suite struct BrowserTabRulesTests {
    @Test func tabsShareTheRowUpToAMaximum() {
        #expect(BrowserTabRules.tabWidth(count: 2, available: 1000).width == BrowserTabRules.tabMaximumWidth)
        #expect(BrowserTabRules.tabWidth(count: 4, available: 400) == (100, false))
    }

    @Test func tabsStopShrinkingAndScroll() {
        let (width, overflows) = BrowserTabRules.tabWidth(count: 10, available: 400)
        #expect(width == BrowserTabRules.tabMinimumWidth)
        #expect(overflows)
    }

    @Test func closingPicksTheTabToTheRightThenTheNewLast() {
        #expect(BrowserTabRules.indexAfterClosing(0, count: 3) == 0)
        #expect(BrowserTabRules.indexAfterClosing(1, count: 3) == 1)
        #expect(BrowserTabRules.indexAfterClosing(2, count: 3) == 1)
    }

    @Test func nineIsAlwaysTheLast() {
        #expect(BrowserTabRules.index(forNumber: 1, count: 3) == 0)
        #expect(BrowserTabRules.index(forNumber: 4, count: 3) == nil)
        #expect(BrowserTabRules.index(forNumber: 9, count: 3) == 2)
        #expect(BrowserTabRules.index(forNumber: 9, count: 12) == 11)
        #expect(BrowserTabRules.index(forNumber: 0, count: 3) == nil)
    }

    @Test func tabsAreFoundByIDOrNumber() {
        let ids = ["t1a", "t2b", "t3c"]
        #expect(BrowserTabRules.index(matching: "t2b", ids: ids) == 1)
        #expect(BrowserTabRules.index(matching: "3", ids: ids) == 2)
        #expect(BrowserTabRules.index(matching: "4", ids: ids) == nil)
        #expect(BrowserTabRules.index(matching: "0", ids: ids) == nil)
        #expect(BrowserTabRules.index(matching: "nope", ids: ids) == nil)
        // An id wins over a number that looks the same.
        #expect(BrowserTabRules.index(matching: "2", ids: ["2", "b"]) == 0)
    }

    @Test func aLinkMatchesItsPageLoosely() {
        func url(_ s: String) -> URL? { URL(string: s) }
        #expect(BrowserTabRules.samePage(url("http://localhost:3000/"), url("http://localhost:3000")))
        #expect(BrowserTabRules.samePage(url("https://a.dev/x#top"), url("https://a.dev/x")))
        #expect(!BrowserTabRules.samePage(url("https://a.dev/x"), url("https://a.dev/y")))
        #expect(!BrowserTabRules.samePage(url("https://a.dev/?q=1"), url("https://a.dev/?q=2")))
        #expect(!BrowserTabRules.samePage(nil, nil))
    }

    @Test func tileIsTheFirstLetter() {
        #expect(BrowserTabRules.tile(title: "bigtty docs", url: nil) == "B")
        #expect(BrowserTabRules.tile(title: "", url: URL(string: "https://www.example.com")) == "E")
        #expect(BrowserTabRules.tile(title: "1234", url: nil) == "•")
    }

    @Test func savedPanesWithoutTabsStillDecode() throws {
        let old = #"{"kind":"browser","url":"https://example.com"}"#
        let state = try JSONDecoder().decode(HostPaneState.self, from: Data(old.utf8))
        #expect(state.tabs == nil)
        #expect(state.url == "https://example.com")
    }

    @Test func tabStateSurvivesSaving() throws {
        var state = HostPaneState(kind: .browser, url: "https://b.dev")
        state.tabs = [BrowserTabState(id: "t1", url: "https://a.dev", title: "A"), BrowserTabState(id: "t2", url: "https://b.dev", agent: true)]
        state.activeTab = "t2"
        let back = try JSONDecoder().decode(HostPaneState.self, from: JSONEncoder().encode(state))
        #expect(back.tabs == state.tabs)
        #expect(back.activeTab == "t2")
    }

    @Test func pageStateFilesStayInTheirFolder() {
        BrowserPageState.save(Data("x".utf8), for: "tabc123")
        #expect(BrowserPageState.load("tabc123") == Data("x".utf8))
        BrowserPageState.remove("tabc123")
        #expect(BrowserPageState.load("tabc123") == nil)
        // An id out of panes.json can't name a path elsewhere.
        BrowserPageState.save(Data("x".utf8), for: "../escape")
        #expect(BrowserPageState.load("../escape") == nil)
        #expect(!FileManager.default.fileExists(atPath: BrowserPageState.folder.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    @Test func oversizedPageStateIsNotKept() {
        BrowserPageState.save(Data("x".utf8), for: "tbig")
        BrowserPageState.save(Data(count: BrowserPageState.sizeLimit + 1), for: "tbig")
        #expect(BrowserPageState.load("tbig") == nil)
    }
}

/// The real pane, on tabs that never load anything.
@MainActor @Suite struct BrowserPaneTabsTests {
    func pane(_ tabs: [String?] = [nil], active: Int = 0) -> BrowserPaneView {
        var state = HostPaneState(kind: .browser)
        let run = BrowserTabRules.newID()
        let saved = tabs.enumerated().map { BrowserTabState(id: "\(run)x\($0.offset)", url: $0.element) }
        state.tabs = saved
        state.activeTab = saved[active].id
        return BrowserPaneView(hostID: "test-\(UUID().uuidString)", state: state)
    }

    @Test func aPaneSavedBeforeTabsHasOnePage() {
        let view = BrowserPaneView(hostID: "test-\(UUID().uuidString)", state: HostPaneState(kind: .browser, url: "about:blank", title: "Old"))
        #expect(view.pages.count == 1)
        #expect(view.activePage.title == "Old")
    }

    @Test func onlyTheActiveTabGetsAWebView() {
        let view = pane(["about:blank", "about:blank", "about:blank"], active: 1)
        #expect(view.pages.map(\.hasWebView) == [false, true, false])
        view.select(view.pages[2])
        #expect(view.pages[2].hasWebView)
        #expect(view.webView.superview === view)
    }

    @Test func aHiddenTabLeavesTheViewTree() {
        let view = pane(["about:blank", "about:blank"])
        let first = view.activePage.webView
        view.select(view.pages[1])
        #expect(first.superview == nil)
        #expect(view.pages[0].hasWebView)
    }

    @Test func newTabsGoLastAndLinksBesideTheirPage() {
        let view = pane([nil, nil, nil], active: 0)
        let new = view.newPage()
        #expect(view.pages.last === new)
        #expect(view.activePage === new)
        let link = view.newPage(after: view.pages[0])
        #expect(view.pages[1] === link)
    }

    @Test func aBackgroundTabStaysOutOfTheWay() {
        let view = pane([nil])
        let shown = view.activePage
        let new = view.newPage(url: URL(string: "about:blank"), select: false)
        #expect(view.activePage === shown)
        #expect(new.hasWebView)
        #expect(new.webView.superview == nil)
    }

    @Test func closingTheActiveTabShowsItsRightNeighbour() {
        let view = pane([nil, nil, nil], active: 1)
        let right = view.pages[2]
        view.close(view.activePage)
        #expect(view.activePage === right)
        #expect(view.pages.count == 2)
    }

    @Test func closingTheLastTabClosesThePane() {
        let view = pane([nil])
        var closed = false
        view.onClose = { closed = true }
        view.close(view.activePage)
        #expect(closed)
        #expect(view.pages.count == 1)
    }

    @Test func reopeningPutsATabBackWhereItWas() {
        let view = pane(["https://a.dev", "https://b.dev", "https://c.dev"], active: 0)
        view.close(view.pages[1])
        #expect(view.closed.count == 1)
        view.reopenClosed()
        #expect(view.pages.map(\.address?.host) == ["a.dev", "b.dev", "c.dev"])
        #expect(view.activePage.address?.host == "b.dev")
        #expect(view.closed.isEmpty)
    }

    @Test func blankTabsAreNotWorthReopening() {
        let view = pane([nil, nil])
        view.close(view.pages[1])
        #expect(view.closed.isEmpty)
    }

    @Test func aCallerKeepsItsTabUntilItCloses() {
        let view = pane([nil, nil])
        let mine = view.pages[1]
        view.noteCaller("w1", on: mine)
        view.select(view.pages[0])
        #expect(view.page(forCaller: "w1") === mine)
        #expect(view.page(forCaller: "w2") == nil)
        view.close(mine)
        #expect(view.page(forCaller: "w1") == nil)
    }

    @Test func aLinkReusesTheTabOnItsPage() {
        let view = pane(["https://a.dev/", "https://b.dev/"], active: 0)
        view.showLink(URL(string: "https://b.dev")!)
        #expect(view.activePage.address?.host == "b.dev")
        #expect(view.pages.count == 2)
    }

    @Test func aLinkFillsABlankTab() {
        let view = pane([nil])
        view.showLink(URL(string: "https://a.dev")!)
        #expect(view.pages.count == 1)
        #expect(view.activePage.address?.host == "a.dev")
    }

    @Test func aLinkToANewPageOpensATab() {
        let view = pane(["https://a.dev/"])
        view.showLink(URL(string: "https://b.dev")!)
        #expect(view.pages.count == 2)
        #expect(view.activePage.address?.host == "b.dev")
    }

    @Test func theStripNeedsTwoTabsAndRoom() {
        let view = pane([nil, nil])
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        #expect(view.chromeHeight == BrowserPaneView.toolbarHeight + BrowserPaneView.stripHeight)
        view.frame.size.width = BrowserTabRules.stripMinimumPaneWidth - 1
        #expect(view.chromeHeight == BrowserPaneView.toolbarHeight)
        let lone = pane([nil])
        lone.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        #expect(lone.chromeHeight == BrowserPaneView.toolbarHeight)
    }

    @Test func theOptionsListTabActions() {
        let titles = pane([nil]).optionsMenu().items.map(\.title)
        #expect(titles.contains("New Tab"))
        #expect(titles.contains("Reopen Closed Tab"))
    }

    @Test func theCountButtonListsEveryTab() {
        let view = pane(["https://a.dev", "https://b.dev"])
        view.frame = NSRect(x: 0, y: 0, width: 250, height: 300)
        #expect(view.tabsMenu().items.prefix(2).map(\.title) == ["a.dev", "b.dev"])
        #expect(view.tabsMenu().items.contains { $0.title == "New Tab" })
    }

    @Test func theTightestCountButtonHoldsTheOptionsToo() {
        let view = pane(["https://a.dev", "https://b.dev"])
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 300)
        #expect(view.tabsMenu().items.contains { $0.title == "Copy Address" })
    }

    @Test func stateMirrorsTheActiveTab() {
        let view = pane(["https://a.dev/", "https://b.dev/"], active: 0)
        view.select(view.pages[1])
        let state = HostPaneStore.shared[view.hostID]
        #expect(state?.url == "https://b.dev/")
        #expect(state?.activeTab == view.pages[1].id)
        #expect(state?.tabs?.map(\.id) == view.pages.map(\.id))
    }
}
