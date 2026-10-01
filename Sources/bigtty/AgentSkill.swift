import AppKit

/// Teaches coding agents about `btty`: installs the command on PATH and a
/// skill file for Claude Code and other agents that read `~/.agents/skills`.
@MainActor
enum AgentSkill {
    static func markdown(btty: String) -> String {
        """
        ---
        name: bigtty-browser
        description: Open, read and drive web pages in a bigtty browser pane next to your terminal (the user sees it live). Use to check a dev server, verify a UI change, fill forms, read docs, or capture screenshots.
        ---

        # bigtty browser

        You run inside a herdr pane shown by bigtty. `btty browser` controls a real
        WebKit browser pane in the same tab, visible to the user. The binary is
        `btty` (or `\(btty)`).

        ## Loop

        1. `btty browser open http://localhost:3000` — opens a browser pane beside you
           (or reuses this tab's browser). Prints `id  url  title`.
        2. `btty browser snapshot -i` — interactive elements with refs:
           `- textbox "Email" [ref=e3]`, `- button "Sign in" [ref=e5]`.
           Drop `-i` for the full page structure and text.
        3. Act with refs (or CSS selectors): `btty browser fill @e3 me@example.com`,
           `btty browser click @e5`, `btty browser press Enter`.
        4. Refs go stale after the page changes: snapshot again before the next action.

        ## Commands

        - `open [url] [--new]`, `navigate <url>`, `back`, `forward`, `reload`, `list`
        - `snapshot [-i] [--selector S]`
        - `click|dblclick|hover|highlight <target>`, `check|uncheck <target>`
        - `fill <target> <text>`, `type <target> <text>`, `press <key> [target]`
        - `select <target> <value>...`, `scroll [up|down] [px]`, `scroll --target <t>`
        - `get text|html|value|attr|count|visible|url|title [target] [attr]`
        - `eval '<js>'` (expressions or statements with `return`; `await` works)
        - `wait --text T | --selector S | --url U | --load [--gone] [--timeout s]`
        - `screenshot [path]` → PNG path; read it to see the page
        - `console [--clear]` — console output and page errors since load

        Add `--json` for machine-readable output and `--browser <id>` to pick a
        pane from `list`. Exit code 3 means bigtty isn't running.
        """
    }

    /// Links `btty` into ~/.local/bin and writes the skill for every agent
    /// home that exists. Returns what was done, for the confirmation alert.
    static func install() -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let btty = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("btty").path
        var done: [String] = []

        let bin = home + "/.local/bin"
        try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let link = bin + "/btty"
        try? fm.removeItem(atPath: link)
        if (try? fm.createSymbolicLink(atPath: link, withDestinationPath: btty)) != nil {
            done.append("Linked \(link) → bigtty's btty")
        }

        for base in [home + "/.claude", home + "/.agents"] where fm.fileExists(atPath: base) {
            let dir = base + "/skills/bigtty-browser"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if (try? markdown(btty: link).write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)) != nil {
                done.append("Wrote \((dir as NSString).abbreviatingWithTildeInPath)/SKILL.md")
            }
        }
        return done
    }
}
