import AppKit
@testable import bigtty
import Foundation
import Testing

@Suite struct BrowserHistoryRulesTests {
    func clean(_ s: String) -> String? { BrowserHistoryRules.clean(URL(string: s)!) }

    @Test func keepsAddressesAsTheyAre() {
        #expect(clean("https://a.example/docs?page=2") == "https://a.example/docs?page=2")
        #expect(clean("http://localhost:3000/") == "http://localhost:3000/")
    }

    @Test func dropsFragmentsAndLogins() {
        #expect(clean("https://me:pw@a.example/x#part") == "https://a.example/x")
    }

    @Test func dropsAQueryHoldingACredential() {
        #expect(clean("https://a.example/cb?code=abc&state=1") == "https://a.example/cb")
        #expect(clean("https://a.example/?access_token=abc") == "https://a.example/")
        #expect(clean("https://a.example/?API_KEY=abc") == "https://a.example/")
        #expect(clean("https://a.example/?client_secret=abc") == "https://a.example/")
    }

    @Test func onlyWebPages() {
        #expect(clean("about:blank") == nil)
        #expect(clean("file:///etc/hosts") == nil)
        #expect(clean("webkit-extension://abc/page.html") == nil)
    }

    func visit(days: Double, count: Int = 1, typed: Int = 0, space: String? = nil, now: Date) -> BrowserVisit {
        BrowserVisit(url: "u", machine: "local", title: "", space: space, lastVisit: now.addingTimeInterval(-days * 86400), visitCount: count, typedCount: typed)
    }

    @Test func recencyFrequencyTypedAndSpaceAllCount() {
        let now = Date()
        func score(_ v: BrowserVisit, space: String? = nil) -> Double { BrowserHistoryRules.score(v, space: space, now: now) }
        #expect(score(visit(days: 0, now: now)) > score(visit(days: 30, now: now)))
        #expect(score(visit(days: 1, count: 20, now: now)) > score(visit(days: 1, now: now)))
        #expect(score(visit(days: 1, count: 2, typed: 2, now: now)) > score(visit(days: 1, count: 2, now: now)))
        #expect(score(visit(days: 1, space: "api", now: now), space: "api") > score(visit(days: 1, space: "web", now: now), space: "api"))
    }

    @Test func onlyYourPagesCount() {
        let now = Date()
        func yours(enabled: Bool = true, agent: Bool = false, acted: TimeInterval? = nil) -> Bool {
            BrowserHistoryRules.isYours(enabled: enabled, openedByAgent: agent, lastAgentAction: acted.map { now.addingTimeInterval(-$0) }, now: now)
        }
        #expect(yours())
        #expect(!yours(enabled: false))
        #expect(!yours(agent: true))
        #expect(!yours(acted: 2))
        #expect(yours(acted: BrowserHistoryRules.agentGrace + 1))
    }

    @Test func likeWildcardsAreLiteral() {
        #expect(BrowserHistoryRules.likePattern("50%_a") == "%50\\%\\_a%")
    }
}

/// A real database, in a temporary folder.
@Suite struct BrowserHistoryTests {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite").path
    let history: BrowserHistory

    init() { history = BrowserHistory(path: path) }

    func urls(_ query: String, machine: String = "local", space: String? = nil) async -> [String] {
        await history.search(query, machine: machine, space: space, limit: 8).map(\.url)
    }

    @Test func aRevisitUpdatesTheRow() {
        history.record(url: "https://a.example/", machine: "local", title: "A", space: "api", typed: true)
        history.record(url: "https://a.example/", machine: "local", title: "", space: nil, typed: false)
        let rows = history.recent(machine: "local", limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].visitCount == 2)
        #expect(rows[0].typedCount == 1)
        #expect(rows[0].title == "A")
        #expect(rows[0].space == "api")
    }

    @Test func searchMatchesEveryWordInTheAddressOrTitle() async {
        history.record(url: "https://docs.example/api", machine: "local", title: "Coupon reference", space: nil, typed: false)
        history.record(url: "https://other.example/", machine: "local", title: "Coupon", space: nil, typed: false)
        #expect(await urls("coupon docs") == ["https://docs.example/api"])
        #expect(await urls("nothing").isEmpty)
    }

    @Test func searchTreatsWildcardsAsText() async {
        history.record(url: "https://a.example/x", machine: "local", title: "plain", space: nil, typed: false)
        #expect(await urls("%").isEmpty)
    }

    @Test func machinesKeepTheirOwnHistory() async {
        history.record(url: "http://localhost:3000/", machine: "local", title: "Here", space: nil, typed: false)
        history.record(url: "http://localhost:3000/", machine: "devbox", title: "There", space: nil, typed: false)
        #expect(history.recent(machine: "local", limit: 5).map(\.title) == ["Here"])
        #expect(history.recent(machine: "devbox", limit: 5).map(\.title) == ["There"])
        #expect(await history.search("localhost", machine: "devbox", space: nil, limit: 5).map(\.title) == ["There"])
    }

    @Test func thisSpaceRanksHigher() async {
        let now = Date()
        history.record(url: "https://a.example/one", machine: "local", title: "", space: "web", typed: false, at: now)
        history.record(url: "https://a.example/two", machine: "local", title: "", space: "api", typed: false, at: now)
        #expect(await urls("a.example", space: "api").first == "https://a.example/two")
        #expect(await urls("a.example", space: "web").first == "https://a.example/one")
    }

    @Test func removingForgetsOnePage() {
        history.record(url: "https://a.example/", machine: "local", title: "", space: nil, typed: false)
        history.record(url: "https://b.example/", machine: "local", title: "", space: nil, typed: false)
        history.remove(url: "https://a.example/", machine: "local")
        #expect(history.recent(machine: "local", limit: 5).map(\.url) == ["https://b.example/"])
    }

    @Test func clearingTakesARangeOrEverything() {
        let now = Date()
        history.record(url: "https://old.example/", machine: "local", title: "", space: nil, typed: false, at: now.addingTimeInterval(-7200))
        history.record(url: "https://new.example/", machine: "local", title: "", space: nil, typed: false, at: now)
        history.clear(since: now.addingTimeInterval(-3600))
        #expect(history.recent(machine: "local", limit: 5).map(\.url) == ["https://old.example/"])
        history.clear(since: nil)
        #expect(history.recent(machine: "local", limit: 5).isEmpty)
    }

    @Test func oldPagesAgeOutWhenItOpens() {
        let now = Date()
        history.record(url: "https://old.example/", machine: "local", title: "", space: nil, typed: false, at: now.addingTimeInterval(-BrowserHistoryRules.maximumAge - 60))
        history.record(url: "https://new.example/", machine: "local", title: "", space: nil, typed: false, at: now)
        history.flush()
        let reopened = BrowserHistory(path: path)
        #expect(reopened.recent(machine: "local", limit: 5).map(\.url) == ["https://new.example/"])
    }

    @Test func onlyYouCanReadTheFile() {
        history.flush()
        #expect(history.fileMode == 0o600)
    }

    @Test func tenThousandRowsStayQuick() async {
        for n in 0..<10000 {
            history.record(url: "https://site\(n % 50).example/page/\(n)", machine: "local", title: "Page \(n)", space: nil, typed: false)
        }
        history.flush()
        let start = Date()
        _ = await urls("site7 page")
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}

@Suite struct BrowserSuggestionsTests {
    func visit(_ url: String, _ title: String = "") -> BrowserVisit {
        BrowserVisit(url: url, machine: "local", title: title, space: nil, lastVisit: Date(), visitCount: 1, typedCount: 0)
    }

    func tab(_ url: String, _ title: String = "", here: Bool = true) -> BrowserSuggestionSources.OpenTab {
        .init(pane: "p", tab: "t", url: url, title: title, place: "api", inThisSpace: here)
    }

    @Test func rowOneIsAlwaysWhatReturnDoes() {
        let go = BrowserSuggestions.typing("example.com", sources: .init())
        #expect(go[0].kind == .go)
        #expect(go[0].url.absoluteString == "https://example.com")
        let search = BrowserSuggestions.typing("how to bake", sources: .init())
        #expect(search[0].kind == .search)
        #expect(search[0].title == "Search DuckDuckGo for “how to bake”")
        #expect(search.count == 1)
    }

    @Test func aMatchCompletesTheFirstRow() {
        let sources = BrowserSuggestionSources(history: [visit("http://localhost:8040/orders", "Orders")])
        let rows = BrowserSuggestions.typing("loc", sources: sources)
        #expect(rows[0].kind == .go)
        #expect(rows[0].url.absoluteString == "http://localhost:8040/orders")
        #expect(rows[0].detail == "Orders")
        #expect(rows.last?.kind == .search)
    }

    @Test func rowsComeInOrder() {
        let sources = BrowserSuggestionSources(
            tabs: [tab("https://docs.example/", "Docs")], ports: [8080],
            history: [visit("https://docs.example/", "Docs"), visit("https://docs.example/api", "API docs"), visit("https://docs.example/b", "Docs B")]
        )
        let kinds = BrowserSuggestions.typing("docs", sources: sources).map(\.kind)
        #expect(kinds.first == .go)
        #expect(kinds.contains(.openTab(pane: "p", tab: "t")))
        #expect(kinds.last == .search)
        // The open page isn't offered a second time from history.
        #expect(kinds.filter { $0 == .history }.count == 1)
    }

    @Test func eightRowsAtMostWithSearchStillThere() {
        let many = (0..<20).map { visit("https://docs.example/\($0)", "Docs \($0)") }
        let rows = BrowserSuggestions.typing("docs", sources: .init(history: many))
        #expect(rows.count == BrowserSuggestions.maximumRows)
        #expect(rows.last?.kind == .search)
    }

    @Test func aBlankFieldShowsThisSpaceFirst() {
        let sources = BrowserSuggestionSources(
            tabs: [tab("https://here.example/", "Here"), tab("https://there.example/", "There", here: false)],
            ports: [3000], history: [visit("https://recent.example/", "Recent")]
        )
        let rows = BrowserSuggestions.blank(sources)
        #expect(rows.map(\.title) == ["localhost:3000", "Here", "Recent"])
    }

    @Test func completionOnlyFinishesWhatWasTyped() {
        let rows = [BrowserSuggestion(kind: .history, title: "", detail: "", url: URL(string: "https://www.docs.example/api")!)]
        #expect(BrowserSuggestions.completion(for: "docs", in: rows) == ".example/api")
        #expect(BrowserSuggestions.completion(for: "api", in: rows) == nil)
        #expect(BrowserSuggestions.completion(for: "docs.example/api", in: rows) == nil)
        #expect(BrowserSuggestions.completion(for: "two words", in: rows) == nil)
    }

    @Test func neverOffersTheSearchRowAsACompletion() {
        let rows = [BrowserSuggestion(kind: .search, title: "", detail: "", url: URL(string: "https://duckduckgo.com/?q=do")!)]
        #expect(BrowserSuggestions.completion(for: "duck", in: rows) == nil)
    }

    @Test func portsCompleteFromThisSpace() {
        let rows = BrowserSuggestions.typing("localh", sources: .init(ports: [3000]))
        #expect(rows[0].url.absoluteString == "http://localhost:3000")
    }
}

/// The address bar in a real window (never shown), through the field editor.
@MainActor @Suite(.serialized) struct AddressSuggestionTests {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    let pane: BrowserPaneView
    let machine = "test-\(UUID().uuidString)"

    init() {
        _ = NSApplication.shared
        var state = HostPaneState(kind: .browser)
        state.tabs = [BrowserTabState(id: BrowserTabRules.newID())]
        pane = BrowserPaneView(hostID: "test-\(UUID().uuidString)", state: state, machineKey: machine)
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView?.addSubview(pane)
        pane.layoutSubtreeIfNeeded()
        pane.focusAddressBar()
    }

    var editor: NSTextView { pane.address.currentEditor() as! NSTextView }

    func type(_ text: String) async {
        editor.insertText(text, replacementRange: editor.selectedRange())
        await settle()
    }

    /// Lets a search come back.
    func settle() async {
        BrowserHistory.shared.flush()
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Waits for a result that should arrive, however busy the machine is.
    func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func seed(_ url: String, _ title: String = "") {
        BrowserHistory.shared.record(url: url, machine: machine, title: title, space: nil, typed: false)
    }

    @Test func typingCompletesInlineWithTheRestSelected() async {
        seed("http://localhost:8040/orders", "Orders")
        await type("loc")
        await until { editor.string.count > 3 }
        #expect(editor.string == "localhost:8040/orders")
        #expect(editor.selectedRange() == NSRange(location: 3, length: 18))
    }

    @Test func deletingTheCompletionDoesntBringItBack() async {
        seed("http://localhost:8040/orders")
        await type("loc")
        await until { editor.string.count > 3 }
        editor.deleteBackward(nil)
        await settle()
        #expect(editor.string == "loc")
    }

    @Test func typingOverACompletionReplacesIt() async {
        seed("http://localhost:8040/orders")
        seed("http://localhost:9000/admin")
        await type("loc")
        await type("alhost:9")
        await until { editor.string.count > 11 }
        #expect(editor.string == "localhost:9000/admin")
    }

    @Test func returnGoesToTheTextInTheField() async {
        seed("http://localhost:8040/orders")
        await type("loc")
        await until { editor.string.count > 3 }
        pane.address.sendAction(pane.address.action, to: pane.address.target)
        #expect(pane.activePage.address?.absoluteString == "http://localhost:8040/orders")
    }

    /// A result still on its way can't change what Return does.
    @Test func aLateResultLeavesNewerTextAlone() async {
        seed("http://localhost:8040/orders")
        editor.insertText("loc", replacementRange: editor.selectedRange())
        editor.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        await settle()
        #expect(editor.string == "locx")
    }

    @Test func midCompositionNothingCompletes() async {
        seed("http://localhost:8040/orders")
        editor.setMarkedText("lo", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        await settle()
        #expect(editor.string == "lo")
        #expect(editor.hasMarkedText())
    }

    @Test func arrowsChooseARowForReturn() async {
        seed("https://docs.example/a", "Docs A")
        seed("https://docs.example/b", "Docs B")
        await type("docs guide")
        await until { !pane.suggestions.isEmpty }
        _ = pane.control(pane.address, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        // Row one is the search; nothing else matched two words.
        #expect(pane.control(pane.address, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(pane.activePage.address?.host == "duckduckgo.com")
    }

    @Test func escapeClosesTheListAndPutsTheAddressBack() async {
        seed("https://docs.example/a")
        await type("docs")
        _ = pane.control(pane.address, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.string == "")
    }

    @Test func commandDeleteForgetsAChosenHistoryRow() async {
        seed("https://docs.example/a", "Docs A")
        seed("https://docs.example/b", "Docs B")
        await type("docs")
        await until { pane.suggestions.count > 2 }
        for _ in 0..<2 { _ = pane.control(pane.address, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))) }
        #expect(pane.control(pane.address, textView: editor, doCommandBy: #selector(NSResponder.deleteToBeginningOfLine(_:))))
        #expect(BrowserHistory.shared.recent(machine: machine, limit: 5).count == 1)
    }

    @Test func clearingAlsoTakesSavedStateAndTheReopenList() {
        let history = BrowserHistory(path: FileManager.default.temporaryDirectory.appendingPathComponent("clear-\(UUID().uuidString).sqlite").path)
        history.record(url: "https://a.example/", machine: machine, title: "", space: nil, typed: false)
        var state = HostPaneState(kind: .browser)
        state.tabs = ["https://a.invalid", "https://b.invalid"].map { BrowserTabState(id: BrowserTabRules.newID(), url: $0) }
        let id = "test-\(UUID().uuidString)"
        HostPaneStore.shared[id] = state
        let tabs = BrowserRegistry.shared.view(for: id)
        tabs.close(tabs.pages[1])
        BrowserPageState.save(Data("x".utf8), for: tabs.pages[0].id)
        BrowserData.clearHistory(since: nil, history: history)
        #expect(history.recent(machine: machine, limit: 5).isEmpty)
        #expect(tabs.closed.isEmpty)
        #expect(BrowserPageState.load(tabs.pages[0].id) == nil)
        tabs.pages[0].saveHistory()
        #expect(BrowserPageState.load(tabs.pages[0].id) == nil)
    }

    @Test func aBlankFieldListsThisMachinesPagesOnly() async {
        BrowserHistory.shared.record(url: "http://localhost:1/", machine: "elsewhere", title: "Theirs", space: nil, typed: false)
        seed("https://mine.example/", "Mine")
        BrowserHistory.shared.flush()
        let found = await BrowserHistory.shared.search("", machine: machine, space: nil, limit: 8)
        #expect(found.map(\.title) == ["Mine"])
    }
}
