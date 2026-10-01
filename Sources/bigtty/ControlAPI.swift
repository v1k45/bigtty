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
        default:
            break
        }
        guard method.hasPrefix("browser.") else { throw Failure(code: "unknown_method", message: method) }
        let (id, browser) = try resolveBrowser(params)
        let web = browser.webView
        let target = params["target"]?.stringValue
        let verb = String(method.dropFirst("browser.".count))
        if ["navigate", "click", "dblclick", "fill", "type", "press", "select", "check", "uncheck", "scroll", "hover", "back", "forward", "reload", "eval"].contains(verb) {
            let who = callerAgent(params) ?? "An agent"
            browser.noteAutomation("\(who) is controlling this page · \(verb)\(target.map { " " + $0 } ?? "")")
        }

        switch method.dropFirst("browser.".count) {
        case "navigate":
            guard let url = params["url"]?.stringValue else { throw Failure(code: "invalid_params", message: "url required") }
            browser.load(url)
            await browser.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30)
            return pageInfo(id, browser)
        case "back":
            web.goBack()
            return await settle(id, browser)
        case "forward":
            web.goForward()
            return await settle(id, browser)
        case "reload":
            web.reload()
            return await settle(id, browser)
        case "snapshot":
            let options: JSONValue = [
                "interactive": .bool(params["interactive"]?.boolValue ?? false),
                "selector": params["selector"] ?? .null,
                "maxLines": params["max_lines"] ?? .null,
            ]
            let tree = try await automation(web, "return __ghr.snapshot(options)", ["options": options])
            var info = pageInfo(id, browser)
            if case var .object(o) = info {
                o["snapshot"] = tree
                info = .object(o)
            }
            return info
        case "click", "dblclick":
            let count = method.hasSuffix("dblclick") ? 2 : (params["count"]?.intValue ?? 1)
            _ = try await automation(web, "return __ghr.click(target, {count})", ["target": .string(try require(target)), "count": .number(Double(count))])
            return await settle(id, browser)
        case "fill":
            _ = try await automation(web, "return __ghr.fill(target, text)", ["target": .string(try require(target)), "text": params["text"] ?? ""])
            return true
        case "type":
            _ = try await automation(web, "return __ghr.type(target, text)", ["target": target.map(JSONValue.string) ?? .null, "text": params["text"] ?? ""])
            return true
        case "press":
            guard let key = params["key"]?.stringValue else { throw Failure(code: "invalid_params", message: "key required") }
            _ = try await automation(web, "return __ghr.press(key, target)", ["key": .string(key), "target": target.map(JSONValue.string) ?? .null])
            return await settle(id, browser)
        case "hover":
            return try await automation(web, "return __ghr.hover(target)", ["target": .string(try require(target))])
        case "highlight":
            return try await automation(web, "return __ghr.highlight(target)", ["target": .string(try require(target))])
        case "select":
            return try await automation(web, "return __ghr.select(target, values)", ["target": .string(try require(target)), "values": params["values"] ?? []])
        case "check", "uncheck":
            let on = method.hasSuffix(".check")
            return try await automation(web, "return __ghr.check(target, on)", ["target": .string(try require(target)), "on": .bool(on)])
        case "scroll":
            let options: JSONValue = [
                "target": target.map(JSONValue.string) ?? .null,
                "direction": params["direction"] ?? .null,
                "amount": params["amount"] ?? .null,
            ]
            return try await automation(web, "return __ghr.scroll(options)", ["options": options])
        case "get":
            let what = params["what"]?.stringValue ?? "text"
            switch what {
            case "url": return .string(web.url?.absoluteString ?? "")
            case "title": return .string(web.title ?? "")
            default:
                return try await automation(web, "return __ghr.get(what, target, name)", [
                    "what": .string(what), "target": target.map(JSONValue.string) ?? .null, "name": params["name"] ?? .null,
                ])
            }
        case "eval":
            guard let script = params["script"]?.stringValue else { throw Failure(code: "invalid_params", message: "script required") }
            return try await evaluate(web, script)
        case "wait":
            if params["load"]?.boolValue == true || (params["selector"] == nil && params["text"] == nil && params["url"] == nil && params["fn"] == nil) {
                try await Task.sleep(nanoseconds: 50_000_000)
                await browser.waitForLoad(timeout: params["timeout"]?.doubleValue ?? 30)
                return pageInfo(id, browser)
            }
            let options: JSONValue = [
                "selector": params["selector"] ?? .null, "text": params["text"] ?? .null,
                "url": params["url"] ?? .null, "fn": params["fn"] ?? .null,
                "gone": params["gone"] ?? false,
                "timeout": .number((params["timeout"]?.doubleValue ?? 10) * 1000),
            ]
            return try await automation(web, "return await __ghr.waitFor(options)", ["options": options])
        case "screenshot":
            return try await screenshot(id, web, path: params["path"]?.stringValue)
        case "console":
            let entries = browser.console.map { entry -> JSONValue in
                ["level": .string(entry.level), "text": .string(entry.text)]
            }
            if params["clear"]?.boolValue == true { browser.clearConsole() }
            return .array(entries)
        case "focus":
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
            throw Failure(code: "not_found", message: "no browser \(wanted); see `ghr browser list`")
        }
        if let id = callerTabBrowser(params) { return (id, BrowserRegistry.shared.view(for: id)) }
        if let id = BrowserRegistry.shared.lastFocused { return (id, BrowserRegistry.shared.view(for: id)) }
        let all = browserPanes
        if all.count == 1, let id = all[0].hostID { return (id, BrowserRegistry.shared.view(for: id)) }
        throw Failure(
            code: "no_browser",
            message: all.isEmpty ? "no browser pane; open one with `ghr browser open <url>`"
                : "several browser panes; pick one with --browser (see `ghr browser list`)"
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
            let web = BrowserRegistry.shared.existing(id)?.webView
            let state = HostPaneStore.shared[id]
            return [
                "id": .string(id),
                "pane": .string(pane.paneID),
                "workspace": .string(store.workspace(pane.workspaceID)?.label ?? pane.workspaceID),
                "url": .string(web?.url?.absoluteString ?? state?.url ?? ""),
                "title": .string(web?.title ?? state?.title ?? ""),
                "focused": .bool(BrowserRegistry.shared.lastFocused == id),
            ]
        }
    }

    // MARK: - Open

    private func open(_ params: JSONValue) async throws -> JSONValue {
        let url = params["url"]?.stringValue ?? ""
        let forceNew = params["new"]?.boolValue ?? false
        if !forceNew, params["browser"] != nil || callerTabBrowser(params) != nil {
            let (id, browser) = try resolveBrowser(params)
            if !url.isEmpty { browser.load(url) }
            await browser.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30)
            return pageInfo(id, browser)
        }
        guard let beside = params["caller_pane"]?.stringValue.flatMap({ store.pane($0)?.paneID }) ?? focusedPane() else {
            throw Failure(code: "no_pane", message: "run inside a herdr pane, or focus one in bigtty")
        }
        let direction: SplitDirection = params["direction"]?.stringValue == "down" ? .down : .right
        let normalized = BrowserPaneView.normalize(url)?.absoluteString
        let id = HostPaneStore.open(
            HostPaneState(kind: .browser, url: normalized), beside: beside, direction: direction, store: store
        )
        let browser = BrowserRegistry.shared.view(for: id)
        BrowserRegistry.shared.noteFocus(id)
        await browser.waitForNavigation(timeout: params["timeout"]?.doubleValue ?? 30)
        return pageInfo(id, browser)
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

    // MARK: - Helpers

    private func pageInfo(_ id: String, _ browser: BrowserPaneView) -> JSONValue {
        var info: [String: JSONValue] = [
            "id": .string(id),
            "url": .string(browser.webView.url?.absoluteString ?? ""),
            "title": .string(browser.webView.title ?? ""),
        ]
        if let pane = paneID(forHost: id) { info["pane"] = .string(pane) }
        if let error = browser.lastNavigationError { info["error"] = .string(error) }
        return .object(info)
    }

    /// After an action that may navigate, let the navigation start and finish.
    private func settle(_ id: String, _ browser: BrowserPaneView) async -> JSONValue {
        try? await Task.sleep(nanoseconds: 150_000_000)
        await browser.waitForLoad(timeout: 15)
        return pageInfo(id, browser)
    }

    private func automation(_ web: WKWebView, _ body: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        do {
            let result = try await web.callAsyncJavaScript(
                body, arguments: arguments.mapValues(\.anyValue), in: nil, contentWorld: BrowserPaneView.automationWorld
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
        let file = path ?? (NSTemporaryDirectory() + "ghr-\(id)-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: URL(fileURLWithPath: file))
        } catch {
            throw Failure(code: "screenshot_failed", message: error.localizedDescription)
        }
        return ["path": .string(file), "width": .number(Double(rep.pixelsWide)), "height": .number(Double(rep.pixelsHigh))]
    }
}
