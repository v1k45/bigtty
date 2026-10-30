import AppKit
import HerdrKit
import WebKit

/// The methods behind the control socket. Browser commands target a pane by
/// `browser` (host id or herdr pane id); otherwise the browser in the
/// caller's tab (`caller_pane`, from `HERDR_PANE_ID`), then the most
/// recently focused one.
@MainActor
final class ControlAPI {
    typealias Failure = ControlServer.Failure

    private let store: SessionStore
    /// The focused herdr pane of the key window, for `open` outside herdr.
    var focusedPane: () -> String? = { nil }
    /// Needs You and notifications for the store's panes, for `notify.post`.
    var attention: AttentionCenter?

    init(store: SessionStore) {
        self.store = store
    }

    func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "system.ping":
            return ["app": "bigtty", "herdr": .string("\(store.state)")]
        case "browser.list":
            return .array(browserList())
        case "browser.open":
            return try await open(params)
        case "files.open", "files.diff":
            return try openFiles(params, changes: method == "files.diff")
        case "notify.post":
            return try await postNotification(params)
        default:
            break
        }
        guard method.hasPrefix("browser.") else { throw Failure(code: "unknown_method", message: method) }
        let (id, browser) = try resolveBrowser(params)
        let verb = String(method.dropFirst("browser.".count))
        if verb.hasPrefix("tab.") { return try await tabCommand(String(verb.dropFirst(4)), id, browser, params) }
        let page = try resolvePage(browser, params)
        // A restored tab starts loading now; its page script comes with it.
        let waking = !page.hasWebView && !page.isBlank
        let web = page.webView
        page.keepAwake()
        if waking { await page.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30) }
        let target = params["target"]?.stringValue
        if ["navigate", "click", "dblclick", "fill", "type", "press", "select", "check", "uncheck", "scroll", "hover", "back", "forward", "reload", "eval"].contains(verb) {
            let who = callerAgent(params) ?? "An agent"
            page.noteAutomation("\(who) is controlling this page · \(verb)\(target.map { " " + $0 } ?? "")")
        }

        switch method.dropFirst("browser.".count) {
        case "navigate":
            guard let url = params["url"]?.stringValue else { throw Failure(code: "invalid_params", message: "url required") }
            page.load(url)
            await page.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30)
            return pageInfo(id, page)
        case "back":
            web.goBack()
            return await settle(id, page)
        case "forward":
            web.goForward()
            return await settle(id, page)
        case "reload":
            web.reload()
            return await settle(id, page)
        case "snapshot":
            let options: JSONValue = [
                "interactive": .bool(params["interactive"]?.boolValue ?? false),
                "selector": params["selector"] ?? .null,
                "maxLines": params["max_lines"] ?? .null,
            ]
            let tree = try await automation(web, "return __btty.snapshot(options)", ["options": options])
            var info = pageInfo(id, page)
            if case var .object(o) = info {
                o["snapshot"] = tree
                info = .object(o)
            }
            return info
        case "click", "dblclick":
            let count = method.hasSuffix("dblclick") ? 2 : (params["count"]?.intValue ?? 1)
            _ = try await automation(web, "return __btty.click(target, {count})", ["target": .string(try require(target)), "count": .number(Double(count))])
            return await settle(id, page)
        case "fill":
            _ = try await automation(web, "return __btty.fill(target, text)", ["target": .string(try require(target)), "text": params["text"] ?? ""])
            return true
        case "type":
            _ = try await automation(web, "return __btty.type(target, text)", ["target": target.map(JSONValue.string) ?? .null, "text": params["text"] ?? ""])
            return true
        case "press":
            guard let key = params["key"]?.stringValue else { throw Failure(code: "invalid_params", message: "key required") }
            _ = try await automation(web, "return __btty.press(key, target)", ["key": .string(key), "target": target.map(JSONValue.string) ?? .null])
            return await settle(id, page)
        case "hover":
            return try await automation(web, "return __btty.hover(target)", ["target": .string(try require(target))])
        case "highlight":
            return try await automation(web, "return __btty.highlight(target)", ["target": .string(try require(target))])
        case "select":
            return try await automation(web, "return __btty.select(target, values)", ["target": .string(try require(target)), "values": params["values"] ?? []])
        case "check", "uncheck":
            let on = method.hasSuffix(".check")
            return try await automation(web, "return __btty.check(target, on)", ["target": .string(try require(target)), "on": .bool(on)])
        case "scroll":
            let options: JSONValue = [
                "target": target.map(JSONValue.string) ?? .null,
                "direction": params["direction"] ?? .null,
                "amount": params["amount"] ?? .null,
            ]
            return try await automation(web, "return __btty.scroll(options)", ["options": options])
        case "get":
            let what = params["what"]?.stringValue ?? "text"
            switch what {
            case "url": return .string(web.url?.absoluteString ?? "")
            case "title": return .string(web.title ?? "")
            default:
                return try await automation(web, "return __btty.get(what, target, name)", [
                    "what": .string(what), "target": target.map(JSONValue.string) ?? .null, "name": params["name"] ?? .null,
                ])
            }
        case "eval":
            guard let script = params["script"]?.stringValue else { throw Failure(code: "invalid_params", message: "script required") }
            return try await evaluate(web, script)
        case "wait":
            if params["load"]?.boolValue == true || (params["selector"] == nil && params["text"] == nil && params["url"] == nil && params["fn"] == nil) {
                try await Task.sleep(nanoseconds: 50_000_000)
                await page.waitForLoad(timeout: params["timeout"]?.doubleValue ?? 30)
                return pageInfo(id, page)
            }
            let options: JSONValue = [
                "selector": params["selector"] ?? .null, "text": params["text"] ?? .null,
                "url": params["url"] ?? .null, "fn": params["fn"] ?? .null,
                "gone": params["gone"] ?? false,
            ]
            let wanted = ["selector", "text", "url", "fn"].compactMap { key in params[key]?.stringValue.map { "\(key) \($0)" } }.first
            return try await waitUntil(page, options, for: wanted ?? "the page", timeout: params["timeout"]?.doubleValue ?? 10)
        case "screenshot":
            return try await screenshot(id, web, path: params["path"]?.stringValue)
        case "console":
            let entries = page.console.map { entry -> JSONValue in
                ["level": .string(entry.level), "text": .string(entry.text)]
            }
            if params["clear"]?.boolValue == true { page.clearConsole() }
            return .array(entries)
        case "focus":
            browser.select(page)
            if let paneID = paneID(forHost: id) {
                store.perform { try await $0.focusPane(paneID) }
            }
            return true
        case "close":
            guard let paneID = paneID(forHost: id) else { throw Failure(code: "not_found", message: "browser \(id) has no herdr pane") }
            store.perform { try await $0.closePane(paneID) }
            return true
        default:
            throw Failure(code: "unknown_method", message: method)
        }
    }

    // MARK: - Tabs

    private func tabCommand(_ verb: String, _ id: String, _ browser: BrowserPaneView, _ params: JSONValue) async throws -> JSONValue {
        let caller = params["caller_pane"]?.stringValue
        switch verb {
        case "list":
            let own = caller.flatMap(browser.page(forCaller:))
            return .array(browser.pages.enumerated().map { index, page in
                [
                    "index": .number(Double(index + 1)),
                    "tab": .string(page.id),
                    "url": .string(page.address?.absoluteString ?? ""),
                    "title": .string(page.title),
                    "active": .bool(page === browser.activePage),
                    "yours": .bool(page === own),
                ]
            })
        case "new":
            let url = try params["url"]?.stringValue.map(address)
            let background = params["background"]?.boolValue == true || browser.isInUse
            let page = browser.newPage(url: url, select: !background, agent: true)
            if let caller { browser.noteCaller(caller, on: page) }
            page.keepAwake()
            if url != nil { await page.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30) }
            return pageInfo(id, page)
        case "switch":
            let page = try resolvePage(browser, params)
            browser.select(page)
            return pageInfo(id, page)
        case "close":
            browser.close(try resolvePage(browser, params))
            return true
        default:
            throw Failure(code: "unknown_method", message: "browser.tab.\(verb)")
        }
    }

    private func address(_ input: String) throws -> URL {
        guard let url = BrowserAddress.normalize(input) else { throw Failure(code: "invalid_params", message: "not an address: \(input)") }
        return url
    }

    /// `--tab`, else the tab this terminal last used, else the one showing.
    /// Refs from a snapshot belong to one page, so a command stays on the
    /// agent's tab even when someone switches tabs under it.
    private func resolvePage(_ browser: BrowserPaneView, _ params: JSONValue) throws -> BrowserPage {
        let caller = params["caller_pane"]?.stringValue
        let page: BrowserPage
        if let wanted = params["tab"]?.stringValue {
            guard let named = browser.page(matching: wanted) else {
                throw Failure(code: "not_found", message: "no tab \(wanted); see `btty browser tab list`")
            }
            page = named
        } else {
            page = caller.flatMap(browser.page(forCaller:)) ?? browser.activePage
        }
        if let caller { browser.noteCaller(caller, on: page) }
        return page
    }

    // MARK: - Targets

    /// The agent running in the calling pane, for "claude is controlling this page".
    private func callerAgent(_ params: JSONValue) -> String? {
        guard let caller = params["caller_pane"]?.stringValue, let pane = store.pane(caller) else { return nil }
        return pane.displayAgent ?? pane.agent
    }

    private func require(_ target: String?) throws -> String {
        guard let target, !target.isEmpty else {
            throw Failure(code: "invalid_params", message: "target required: a ref from `snapshot` (@e3) or a CSS selector")
        }
        return target
    }

    private func paneID(forHost hostID: String) -> String? {
        store.snapshot.panes.first { $0.hostID == hostID }?.paneID
    }

    private var browserPanes: [Pane] {
        store.snapshot.panes.filter { $0.hostKind == .browser && $0.hostID != nil }
    }

    private func resolveBrowser(_ params: JSONValue) throws -> (String, BrowserPaneView) {
        if let wanted = params["browser"]?.stringValue {
            if let pane = store.pane(wanted), pane.hostKind == .browser, let id = pane.hostID {
                return (id, BrowserRegistry.shared.view(for: id))
            }
            if HostPaneStore.shared[wanted] != nil || BrowserRegistry.shared.existing(wanted) != nil {
                return (wanted, BrowserRegistry.shared.view(for: wanted))
            }
            throw Failure(code: "not_found", message: "no browser \(wanted); see `btty browser list`")
        }
        if let id = callerTabBrowser(params) { return (id, BrowserRegistry.shared.view(for: id)) }
        if let id = BrowserRegistry.shared.lastFocused { return (id, BrowserRegistry.shared.view(for: id)) }
        let all = browserPanes
        if all.count == 1, let id = all[0].hostID { return (id, BrowserRegistry.shared.view(for: id)) }
        throw Failure(
            code: "no_browser",
            message: all.isEmpty ? "no browser pane; open one with `btty browser open <url>`"
                : "several browser panes; pick one with --browser (see `btty browser list`)"
        )
    }

    /// The browser in the same herdr tab as the calling pane.
    private func callerTabBrowser(_ params: JSONValue) -> String? {
        guard let caller = params["caller_pane"]?.stringValue, let tab = store.pane(caller)?.tabID else { return nil }
        let candidates = browserPanes.filter { $0.tabID == tab }.compactMap(\.hostID)
        if let last = BrowserRegistry.shared.lastFocused, candidates.contains(last) { return last }
        return candidates.first
    }

    private func browserList() -> [JSONValue] {
        browserPanes.compactMap { pane -> JSONValue? in
            guard let id = pane.hostID else { return nil }
            let browser = BrowserRegistry.shared.existing(id)
            let state = HostPaneStore.shared[id]
            return [
                "id": .string(id),
                "pane": .string(pane.paneID),
                "workspace": .string(store.workspace(pane.workspaceID)?.label ?? pane.workspaceID),
                "url": .string(browser?.activePage.address?.absoluteString ?? state?.url ?? ""),
                "title": .string(browser?.activePage.title ?? state?.title ?? ""),
                "focused": .bool(BrowserRegistry.shared.lastFocused == id),
                "tabs": .number(Double(browser?.pages.count ?? state?.tabs?.count ?? 1)),
            ]
        }
    }

    // MARK: - Open

    private func open(_ params: JSONValue) async throws -> JSONValue {
        let url = params["url"]?.stringValue ?? ""
        let forceNew = params["new"]?.boolValue ?? false
        if !forceNew, params["browser"] != nil || callerTabBrowser(params) != nil {
            let (id, browser) = try resolveBrowser(params)
            let page = try openInTab(url, browser, params)
            page.keepAwake()
            await page.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30)
            return pageInfo(id, page)
        }
        guard let beside = params["caller_pane"]?.stringValue.flatMap({ store.pane($0)?.paneID }) ?? focusedPane() else {
            throw Failure(code: "no_pane", message: "run inside a herdr pane, or focus one in bigtty")
        }
        let direction: SplitDirection = params["direction"]?.stringValue == "down" ? .down : .right
        let normalized = BrowserAddress.normalize(url)?.absoluteString
        let id = HostPaneStore.open(
            HostPaneState(kind: .browser, url: normalized), beside: beside, direction: direction, store: store
        )
        let browser = BrowserRegistry.shared.view(for: id)
        BrowserRegistry.shared.noteFocus(id)
        let page = browser.activePage
        page.openedByAgent = true
        if let caller = params["caller_pane"]?.stringValue { browser.noteCaller(caller, on: page) }
        await page.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30)
        return pageInfo(id, page)
    }

    /// `btty browser open` in a pane that exists: the agent's own tab if it
    /// has one, a lone blank tab, else a new tab, so a page on screen is
    /// never replaced. It comes to the front unless someone is using the pane.
    private func openInTab(_ url: String, _ browser: BrowserPaneView, _ params: JSONValue) throws -> BrowserPage {
        guard !url.isEmpty else { return try resolvePage(browser, params) }
        let target = try address(url)
        let background = params["background"]?.boolValue == true || browser.isInUse
        let caller = params["caller_pane"]?.stringValue
        let lone = browser.pages.count == 1 && browser.activePage.isBlank ? browser.activePage : nil
        guard let page = try (params["tab"] != nil ? resolvePage(browser, params) : caller.flatMap(browser.page(forCaller:))) ?? lone else {
            let page = browser.newPage(url: target, select: !background, agent: true)
            if let caller { browser.noteCaller(caller, on: page) }
            return page
        }
        page.openedByAgent = true
        page.navigate(to: target)
        if !background { browser.select(page) }
        if let caller { browser.noteCaller(caller, on: page) }
        return page
    }

    // MARK: - Files

    /// Shows a file (or a repo's changes) in the caller's tab: in its files
    /// pane if it has one covering the path, else in a new one beside it.
    private func openFiles(_ params: JSONValue, changes: Bool) throws -> JSONValue {
        guard let path = params["path"]?.stringValue, !path.isEmpty else {
            throw Failure(code: "invalid_params", message: "path required")
        }
        guard FileManager.default.fileExists(atPath: path) else { throw Failure(code: "not_found", message: "\(path) does not exist") }
        let line = params["line"]?.intValue
        let isDirectory = GitClient.isDirectory(path)
        let repo = GitClient.repository(containing: path)
        let root = changes ? (repo?.root ?? path) : (repo?.root ?? (isDirectory ? path : (path as NSString).deletingLastPathComponent))
        let selection: String? = isDirectory ? nil : path
        let mode: FilesPaneView.Mode = changes ? .changes : .files

        if let caller = params["caller_pane"]?.stringValue, let tab = store.pane(caller)?.tabID,
           let existing = store.panes(in: tab).first(where: { ($0.hostKind == .files || $0.hostKind == .diff) }),
           let hostID = existing.hostID
        {
            let view = FilesRegistry.shared.view(for: hostID)
            if path.hasPrefix(view.root) || root == view.root {
                view.setMode(mode)
                if let selection { view.select(path: selection, line: line) }
                return ["id": .string(hostID), "pane": .string(existing.paneID), "root": .string(view.root)]
            }
        }
        guard let beside = params["caller_pane"]?.stringValue.flatMap({ store.pane($0)?.paneID }) ?? focusedPane() else {
            throw Failure(code: "no_pane", message: "run inside a herdr pane, or focus one in bigtty")
        }
        let state = HostPaneState(kind: changes ? .diff : .files, path: root, selection: selection, mode: mode.rawValue, line: line)
        let id = HostPaneStore.open(state, beside: beside, direction: .right, store: store)
        return ["id": .string(id), "root": .string(root)]
    }

    // MARK: - Notify

    /// A message for the user from a pane's program: on Needs You, and a
    /// macOS notification unless the pane is on screen.
    private func postNotification(_ params: JSONValue) async throws -> JSONValue {
        let body = params["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { throw Failure(code: "invalid_params", message: "a message is required") }
        guard let wanted = params["pane"]?.stringValue ?? params["caller_pane"]?.stringValue else {
            throw Failure(code: "no_pane", message: "run inside a herdr pane, or pass --pane <id>")
        }
        guard let pane = store.pane(wanted), let attention else {
            throw Failure(code: "not_found", message: "no pane \(wanted) in this herdr session")
        }
        let title = params["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep it to what a notification shows.
        let (result, banners) = await attention.post(pane.paneID, title: title.map { String($0.prefix(200)) },
                                                     body: String(body.prefix(1000)))
        return ["pane": .string(pane.paneID), "result": .string(result.rawValue), "banners": .bool(banners)]
    }

    // MARK: - Helpers

    private func pageInfo(_ id: String, _ page: BrowserPage) -> JSONValue {
        var info: [String: JSONValue] = [
            "id": .string(id),
            "tab": .string(page.id),
            "url": .string(page.webView.url?.absoluteString ?? ""),
            "title": .string(page.title),
        ]
        if let pane = paneID(forHost: id) { info["pane"] = .string(pane) }
        if let error = page.lastNavigationError { info["error"] = .string(error) }
        return .object(info)
    }

    /// After an action that may navigate, let the navigation start and finish.
    private func settle(_ id: String, _ page: BrowserPage) async -> JSONValue {
        try? await Task.sleep(nanoseconds: 150_000_000)
        await page.waitForLoad(timeout: 15)
        return pageInfo(id, page)
    }

    /// Polls from here, not in the page: a hidden tab's timers barely run,
    /// and a navigation mid-wait would take a page-side loop with it.
    private func waitUntil(_ page: BrowserPage, _ options: JSONValue, for wanted: String, timeout: TimeInterval) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            page.keepAwake()
            let met = try? await automation(page.webView, "return __btty.checkWait(options)", ["options": options])
            if met?.boolValue == true { return true }
            guard Date() < deadline else {
                throw Failure(code: "script_error", message: "timed out waiting for \(wanted)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func automation(_ web: WKWebView, _ body: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        do {
            let result = try await web.callAsyncJavaScript(
                body, arguments: arguments.mapValues(\.anyValue), in: nil, contentWorld: BrowserPage.automationWorld
            )
            return JSONValue(any: result)
        } catch {
            throw Failure(code: "script_error", message: Self.message(for: error))
        }
    }

    /// Runs page code in the page's own world, as an expression when it is one.
    private func evaluate(_ web: WKWebView, _ script: String) async throws -> JSONValue {
        do {
            let result = try await web.callAsyncJavaScript("return (\n\(script)\n)", arguments: [:], in: nil, contentWorld: .page)
            return JSONValue(any: result)
        } catch {
            let message = Self.message(for: error)
            guard message.contains("SyntaxError") else { throw Failure(code: "script_error", message: message) }
        }
        do {
            let result = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            return JSONValue(any: result)
        } catch {
            throw Failure(code: "script_error", message: Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        let info = (error as NSError).userInfo
        if var message = info["WKJavaScriptExceptionMessage"] as? String {
            if message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
            return message
        }
        return error.localizedDescription
    }

    private func screenshot(_ id: String, _ web: WKWebView, path: String?) async throws -> JSONValue {
        let image: NSImage
        do {
            image = try await web.takeSnapshot(configuration: nil)
        } catch {
            throw Failure(code: "screenshot_failed", message: error.localizedDescription)
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw Failure(code: "screenshot_failed", message: "could not encode PNG") }
        let file = path ?? (NSTemporaryDirectory() + "btty-\(id)-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: URL(fileURLWithPath: file))
        } catch {
            throw Failure(code: "screenshot_failed", message: error.localizedDescription)
        }
        return ["path": .string(file), "width": .number(Double(rep.pixelsWide)), "height": .number(Double(rep.pixelsHigh))]
    }
}
