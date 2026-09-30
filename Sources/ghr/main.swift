import Foundation
import HerdrKit

// The full CLI (browser automation, open, diff) arrives with the control
// server in milestone 6.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      ghr pane-host <kind> <id> [title]   placeholder process for a GhostHerdr pane
      ghr version

    """.utf8))
    exit(64)
}

/// Runs in a herdr pane that GhostHerdr draws as a browser or file view.
/// Other herdr clients (the TUI, remote viewers) see this text instead.
func paneHost(kind: String, id: String, title: String?) -> Never {
    let icon = switch kind {
    case "browser": "🌐"
    case "files": "📁"
    case "diff": "±"
    default: "▢"
    }
    var banner = "\u{1b}[2J\u{1b}[H\n  \(icon)  GhostHerdr \(kind) pane"
    if let title, !title.isEmpty { banner += "\n     \(title)" }
    banner += "\n\n  \u{1b}[2mOpen this workspace in GhostHerdr to see it. (\(id))\u{1b}[0m\n"
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

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "version", "--version":
    print("ghr 0.1.0")
case "pane-host":
    guard args.count >= 3 else { usage() }
    paneHost(kind: args[1], id: args[2], title: args.count > 3 ? args[3] : nil)
default:
    usage()
}
