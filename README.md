# GhostHerdr

A native macOS client for [herdr](https://herdr.dev): Ghostty-rendered terminals
(via [libghostty-spm](https://github.com/Lakr233/libghostty-spm)), cmux-style
splits, windows and tabs, with a scriptable browser and file viewer on the way.
herdr owns every session, workspace, tab, pane and agent; GhostHerdr is a view
onto it, so closing the app leaves everything running.

MIT licensed.

## Status

| Milestone | State |
|---|---|
| 1. Skeleton, libghostty embedding | done |
| 2. HerdrKit: socket API, events, sidebar + tabs | done |
| 3. Terminal bridge, split tree, split keymap | done (drag-and-drop pane moves pending) |
| 4. Window per space, control handoff, attention rings, notifications | done |
| 5. Host panes + browser | done |
| 6. Control socket, `ghr` CLI, browser automation | done |
| 7. File viewer + diffs | – |

## Build and run

Requires macOS 14+, Xcode 26 / Swift 6.2+, and herdr 0.9+ on `PATH` or in
`~/.local/bin`.

```sh
scripts/bundle.sh            # → build/GhostHerdr.app
open build/GhostHerdr.app    # connects to your default herdr session
```

`GHOSTHERDR_SESSION=<name>` connects to a named herdr session instead. The
terminal uses your Ghostty config (`config.ghostty` or `config` under
`~/.config/ghostty` or `~/Library/Application Support/com.mitchellh.ghostty`).

By default every herdr workspace ("space") gets its own window, with its tabs
in the title bar. **View ▸ One Window per Space** switches to sidebar windows
that flip between spaces instead. When two windows show the same pane, the one
you last focused or typed in controls it and the other mirrors it read-only.

Panes whose agent is blocked get an orange ring, finished ones you haven't
looked at a blue one; tabs, spaces and the Dock icon carry counts, and a
notification fires for panes you aren't looking at.

## Keys

| | |
|---|---|
| ⌘D / ⌘⇧D | split right / down |
| ⌘⌥ arrows | focus neighbour pane |
| ⌃⌘ arrows | resize pane |
| ⌘⇧↩ | zoom pane |
| ⌘W / ⌘⌥W | close pane / tab |
| ⌘T, ⌘1…9, ⌘⇧[ ] | new tab, select tab, cycle tabs |
| ⌘N | new space in the current folder (new window in sidebar mode) |
| ⌘⇧N | new space from a folder picker |
| ⌃⌘1…9 | show space |
| ⌘⇧U | jump to next pane needing attention |
| ⌃⌘S | toggle sidebar |
| ⌘⌥B / ⌘L | new browser pane / address bar |

## How it works

- `HerdrKit` speaks herdr's NDJSON socket API (`session.snapshot`,
  `layout.export`, `events.subscribe`, `pane.*`, …). Events trigger a
  re-read; they are never applied as deltas.
- Each visible pane runs `herdr terminal session control <terminal> --takeover`
  and pipes its ANSI frames into a Ghostty surface with a host-managed
  (non-PTY) backend. Keystrokes go back as `terminal.input`, wheel scrolling as
  `terminal.scroll` (herdr owns scrollback).

## Browser panes

A browser pane is a real herdr pane: GhostHerdr splits a pane, tags it with
`tokens.ghr_kind=browser`, and runs `ghr pane-host` in it, then draws a
WebKit view in its place. So every herdr layout operation (split, zoom,
resize, move, close) works on it, layouts survive restarts, and other herdr
clients see a placeholder. URLs and titles are kept in
`~/Library/Application Support/GhostHerdr/panes.json`. ⌘-clicking a link in a
terminal opens it in the tab's browser pane, or a new one to the right.

## Agents: `ghr browser`

Agents in herdr panes drive the browser in their own tab through `ghr`
(**GhostHerdr ▸ Install ghr and Agent Skill…** links it into `~/.local/bin`
and writes a skill to `~/.claude/skills` / `~/.agents/skills`):

```sh
ghr browser open localhost:3000     # beside you, or this tab's browser
ghr browser snapshot -i             # - textbox "Email" [ref=e3] …
ghr browser fill @e3 me@example.com
ghr browser click @e5
ghr browser wait --text "Welcome"
ghr browser screenshot out.png
```

Also: `type`, `press`, `select`, `check`, `scroll`, `hover`, `get`, `eval`,
`console`, `navigate`/`back`/`forward`/`reload`, `list`, `close`; `--json` for
raw output. Commands go over `~/Library/Application Support/GhostHerdr/control.sock`
(user-only). The in-page script runs in an isolated JavaScript world.

## Development

```sh
swift test                                   # model tests
herdr --session ghrtest server &             # isolated server for live tests
GHR_TEST_SESSION=ghrtest swift test          # + live socket/terminal tests
# (quit any GhostHerdr attached to that session: it takes control of new panes)
```

Debug hooks on a running app: `kill -USR1 <pid>` writes window, pane and
on-screen terminal text to `$TMPDIR/ghostherdr-debug.txt`;
the key window is also rendered to `ghostherdr-debug.png` beside it (no
screen-recording permission needed); `kill -USR2 <pid>` pastes `$TMPDIR/ghostherdr-type.txt` into the focused pane,
or, if it starts with `!`, sends a menu action (`!@<space> newBrowserPane:`).
Kill the app with `pkill -x GhostHerdr`: `pkill -f GhostHerdr.app` also
matches the `ghr pane-host` processes inside herdr panes.
