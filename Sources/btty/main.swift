import Foundation
import HerdrKit

let usageText = """
btty — drive bigtty from a shell or an agent

usage:
  btty open <path>[:line]                show a file or folder in a files pane beside you
  btty diff [path]                       show the repository's changes (git diff vs HEAD)
  btty browser <command> [args] [--browser <id|pane>] [--json]
  btty pane-host <kind> <id> [title]     placeholder process for a bigtty pane
  btty version

browser commands (targets are refs from `snapshot`, like @e3, or CSS selectors):
  open [url] [--new] [--down]   open in this tab's browser pane, or split a new one
  list                          browser panes: id, pane, url, title
  snapshot [-i] [--selector S]  page structure with refs (-i: interactive only)
  click <target>                also: dblclick, hover, highlight
  fill <target> <text>          replace a field's value
  type <target> <text>          type key by key ("-" as target: focused element)
  press <key> [target]          Enter, Tab, Escape, ArrowDown, a, …
  select <target> <value>...    choose <select> options by value or label
  check <target>                also: uncheck
  scroll [up|down|left|right] [px] | scroll --target <target>
  get <text|html|value|attr|count|box|visible|enabled|checked|url|title> [target] [attr]
  eval <js>                     run JavaScript in the page ("-" reads stdin)
  wait [--selector S | --text T | --url U | --fn JS | --load] [--gone] [--timeout secs]
  screenshot [path] [--open]    PNG of the page; prints the path (--open: preview it beside you)
  console [--clear]             captured console output and page errors
  navigate <url> | back | forward | reload | focus | close

Inside a herdr pane, commands go to the browser in the same tab.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("btty: \(message)\n".utf8))
    exit(code)
}

// MARK: - pane-host

/// Runs in a herdr pane that bigtty draws as a browser or file view.
/// Other herdr clients (the TUI, remote viewers) see this text instead.
func paneHost(kind: String, id: String, title: String?) -> Never {
    let icon = switch kind {
    case "browser": "🌐"
    case "files": "📁"
    case "diff": "±"
    default: "▢"
    }
    var banner = "\u{1b}[2J\u{1b}[H\n  \(icon)  bigtty \(kind) pane"
    if let title, !title.isEmpty { banner += "\n     \(title)" }
    banner += "\n\n  \u{1b}[2mOpen this workspace in bigtty to see it. (\(id))\u{1b}[0m\n"
    FileHandle.standardOutput.write(Data(banner.utf8))

    // Swallow keystrokes quietly: turn off echo and canonical mode.
    var term = termios()
    if tcgetattr(STDIN_FILENO, &term) == 0 {
        term.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &term)
    }
    for sig in [SIGINT, SIGQUIT, SIGTSTP] { signal(sig, SIG_IGN) }
    var buffer = [UInt8](repeating: 0, count: 256)
    while read(STDIN_FILENO, &buffer, buffer.count) > 0 {}
    exit(0)
}

// MARK: - Argument parsing

struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    static let valued: Set<String> = ["browser", "selector", "text", "url", "fn", "timeout", "target", "max-lines"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-i" {
                switches.insert("interactive")
            } else if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    flags[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if Self.valued.contains(name), i + 1 < args.count {
                    flags[name] = args[i + 1]
                    i += 1
                } else {
                    switches.insert(name)
                }
            } else {
                positional.append(arg)
            }
            i += 1
        }
    }

    func arg(_ index: Int, _ name: String) -> String {
        guard index < positional.count else { fail("missing <\(name)>; see `btty browser --help`", code: 64) }
        return positional[index]
    }

    func rest(from index: Int) -> String {
        positional.count > index ? positional[index...].joined(separator: " ") : ""
    }
}

// MARK: - Output

func printResult(_ command: String, _ result: JSONValue, json: Bool) {
    if json {
        print(result.jsonString)
        return
    }
    switch command {
    case "snapshot":
        let title = result["title"]?.stringValue ?? ""
        let url = result["url"]?.stringValue ?? ""
        print("# \(title) — \(url)")
        print(result["snapshot"]?.stringValue ?? "")
    case "list":
        guard case let .array(items) = result, !items.isEmpty else {
            print("no browser panes")
            return
        }
        for item in items {
            let focused = item["focused"]?.boolValue == true ? "*" : " "
            let fields = ["id", "pane", "workspace", "url", "title"].map { item[$0]?.stringValue ?? "" }
            print("\(focused) " + fields.joined(separator: "\t"))
        }
    case "console":
        guard case let .array(entries) = result else { return }
        for entry in entries {
            print("[\(entry["level"]?.stringValue ?? "log")] \(entry["text"]?.stringValue ?? "")")
        }
    case "screenshot":
        print(result["path"]?.stringValue ?? result.jsonString)
    default:
        switch result {
        case let .string(s): print(s)
        case .bool(true): break
        case .null: break
        case let .object(o) where o["url"] != nil && o["id"] != nil:
            var line = "\(o["id"]?.stringValue ?? "")\t\(o["url"]?.stringValue ?? "")\t\(o["title"]?.stringValue ?? "")"
            if let error = o["error"]?.stringValue { line += "\t(error: \(error))" }
            print(line)
        default: print(result.jsonString)
        }
    }
}

// MARK: - browser

func browser(_ args: [String]) {
    let parsed = Arguments(args)
    guard let command = parsed.positional.first, !parsed.switches.contains("help") else {
        print(usageText)
        exit(command(args) == nil ? 64 : 0)
    }
    var params: [String: JSONValue] = [:]
    if let pane = ProcessInfo.processInfo.environment["HERDR_PANE_ID"] { params["caller_pane"] = .string(pane) }
    // Which herdr session the caller runs in, for bigtty to pick its store.
    if let socket = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"] { params["caller_socket"] = .string(socket) }
    if let browser = parsed.flags["browser"] { params["browser"] = .string(browser) }
    if let timeout = parsed.flags["timeout"].flatMap(Double.init) { params["timeout"] = .number(timeout) }
    let method: String
    switch command {
    case "open":
        method = "browser.open"
        params["url"] = .string(parsed.rest(from: 1))
        if parsed.switches.contains("new") { params["new"] = true }
        if parsed.switches.contains("down") { params["direction"] = "down" }
    case "list", "back", "forward", "reload", "focus", "close":
        method = "browser.\(command)"
    case "navigate", "goto":
        method = "browser.navigate"
        params["url"] = .string(parsed.arg(1, "url"))
    case "snapshot":
        method = "browser.snapshot"
        if parsed.switches.contains("interactive") { params["interactive"] = true }
        if let selector = parsed.flags["selector"] { params["selector"] = .string(selector) }
        if let max = parsed.flags["max-lines"].flatMap(Double.init) { params["max_lines"] = .number(max) }
    case "click", "dblclick", "hover", "highlight", "check", "uncheck":
        method = "browser.\(command)"
        params["target"] = .string(parsed.arg(1, "target"))
    case "fill":
        method = "browser.fill"
        params["target"] = .string(parsed.arg(1, "target"))
        params["text"] = .string(parsed.rest(from: 2))
    case "type":
        method = "browser.type"
        let target = parsed.arg(1, "target")
        if target != "-" { params["target"] = .string(target) }
        params["text"] = .string(parsed.rest(from: 2))
    case "press":
        method = "browser.press"
        params["key"] = .string(parsed.arg(1, "key"))
        if parsed.positional.count > 2 { params["target"] = .string(parsed.positional[2]) }
    case "select":
        method = "browser.select"
        params["target"] = .string(parsed.arg(1, "target"))
        params["values"] = .array(parsed.positional.dropFirst(2).map(JSONValue.string))
    case "scroll":
        method = "browser.scroll"
        if let target = parsed.flags["target"] { params["target"] = .string(target) }
        if parsed.positional.count > 1 { params["direction"] = .string(parsed.positional[1]) }
        if parsed.positional.count > 2, let amount = Double(parsed.positional[2]) { params["amount"] = .number(amount) }
    case "get":
        method = "browser.get"
        params["what"] = .string(parsed.arg(1, "property"))
        if parsed.positional.count > 2 { params["target"] = .string(parsed.positional[2]) }
        if parsed.positional.count > 3 { params["name"] = .string(parsed.positional[3]) }
    case "eval":
        method = "browser.eval"
        var script = parsed.rest(from: 1)
        if script == "-" || script.isEmpty {
            script = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        params["script"] = .string(script)
    case "wait":
        method = "browser.wait"
        for key in ["selector", "text", "url", "fn"] {
            if let value = parsed.flags[key] { params[key] = .string(value) }
        }
        if parsed.positional.count > 1, params["selector"] == nil { params["selector"] = .string(parsed.positional[1]) }
        if parsed.switches.contains("gone") { params["gone"] = true }
        if parsed.switches.contains("load") { params["load"] = true }
    case "screenshot":
        method = "browser.screenshot"
        if parsed.positional.count > 1 {
            let path = parsed.positional[1]
            params["path"] = .string(path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path)
        }
    case "console":
        method = "browser.console"
        if parsed.switches.contains("clear") { params["clear"] = true }
    default:
        fail("unknown browser command \(command); see `btty browser --help`", code: 64)
    }

    do {
        let result = try ControlClient().call(method, params)
        printResult(command, result, json: parsed.switches.contains("json"))
        // `screenshot --open`: show it in a preview pane beside the caller.
        if command == "screenshot", parsed.switches.contains("open"), let path = result["path"]?.stringValue {
            var open: [String: JSONValue] = ["path": .string(path)]
            if let caller = params["caller_pane"] { open["caller_pane"] = caller }
            if let socket = params["caller_socket"] { open["caller_socket"] = socket }
            _ = try ControlClient().call("files.open", open)
        }
    } catch HerdrError.connect {
        fail("bigtty is not running (no socket at \(BigttyControl.socketPath))", code: 3)
    } catch let HerdrError.server(code, message) {
        fail("\(message) [\(code)]")
    } catch {
        fail("\(error)")
    }
}

// MARK: - files

func files(command: String, _ args: [String]) {
    let parsed = Arguments(args)
    var target = parsed.positional.first ?? "."
    var line: Int?
    // path:line, as compilers and agents print them.
    if let colon = target.lastIndex(of: ":"), let n = Int(target[target.index(after: colon)...]),
       !FileManager.default.fileExists(atPath: target)
    {
        line = n
        target = String(target[..<colon])
    }
    let cwd = FileManager.default.currentDirectoryPath
    let absolute = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
    var params: [String: JSONValue] = ["path": .string(absolute)]
    if let line { params["line"] = .number(Double(line)) }
    if let pane = ProcessInfo.processInfo.environment["HERDR_PANE_ID"] { params["caller_pane"] = .string(pane) }
    // Which herdr session the caller runs in, for bigtty to pick its store.
    if let socket = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"] { params["caller_socket"] = .string(socket) }
    do {
        let result = try ControlClient().call(command == "diff" ? "files.diff" : "files.open", params)
        if parsed.switches.contains("json") { print(result.jsonString) }
    } catch HerdrError.connect {
        fail("bigtty is not running (no socket at \(BigttyControl.socketPath))", code: 3)
    } catch let HerdrError.server(code, message) {
        fail("\(message) [\(code)]")
    } catch {
        fail("\(error)")
    }
}

/// `nil` when no command was given at all.
func command(_ args: [String]) -> String? { Arguments(args).positional.first }

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "version", "--version":
    // The app it ships in (bigtty.app/Contents/MacOS/btty) holds the version.
    print("btty \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
case "pane-host":
    guard args.count >= 3 else { fail("usage: btty pane-host <kind> <id> [title]", code: 64) }
    paneHost(kind: args[1], id: args[2], title: args.count > 3 ? args[3] : nil)
case "browser":
    browser(Array(args.dropFirst()))
case "open", "diff":
    files(command: args[0], Array(args.dropFirst()))
case "help", "--help", "-h", nil:
    print(usageText)
default:
    fail("unknown command \(args[0]); see `btty help`", code: 64)
}
