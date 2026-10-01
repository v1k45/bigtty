<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.png">
  <img src="docs/banner-light.png" alt="bigtty: a native Mac home for your terminal agents">
</picture>

<p align="center">
  <a href="https://github.com/v1k45/bigtty/releases/latest"><b>Download for macOS</b></a> ·
  <a href="#install">Install</a> ·
  <a href="docs/features.md">Features</a> ·
  <a href="docs/shortcuts.md">Shortcuts</a> ·
  <a href="docs/btty.md">btty</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/herdr-0.9.2%2B-5CF29A?labelColor=111" alt="herdr 0.9.2+">
  <img src="https://img.shields.io/badge/Swift-AppKit-F05138?logo=swift&logoColor=white" alt="Swift and AppKit">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license">
</p>

![bigtty: spaces in the sidebar, tests, a live dashboard, server logs and code side by side](docs/screenshots/workspace.png)

Claude Code, Codex and friends run in [herdr](https://herdr.dev) because it
keeps them alive. **bigtty** gives that herd a proper Mac app: every space in a
sidebar, every agent's state at a glance, real Ghostty terminals, and a
browser and your code right next to the agent that needs them. Quit it and
nothing stops; herdr keeps running everything.

<br>

## Know which agent needs you

Each space shows its branch, ports, what its agents are doing and how long
it's been quiet. When one stops to ask something, its space quotes the
question, its pane gets a ring and a notification finds you. **⇧⌘U** jumps
there.

![An agent's question shown on its space, its pane ringed](docs/screenshots/attention.png)

## The diff next to the decision

**⌘-click** any path an agent prints and it opens right there, at the line.
**⌥⌘G** shows what changed, live, beside the agent asking whether to keep it.

![A git diff beside an agent waiting on an answer](docs/screenshots/changes-and-agents.png)

## ⌘K to anywhere

Fuzzy search over spaces, agents, panes and actions, and through everything
your terminals printed.

![The ⌘K palette finding "coupon" in spaces and terminal output](docs/screenshots/jump-palette.png)

## A browser in the layout

Browser panes split, zoom and move like terminals. Open `localhost` beside the
dev server, block ads with uBlock Origin Lite, let agents drive it with
[`btty browser`](docs/btty.md), or keep a Short playing while the agents grind.

![Two agents working beside a YouTube Short filling a tall browser pane](docs/screenshots/brainrot.png)

## Keyboard first

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/shortcut-hints.png" alt="Shortcut badges on spaces, tabs and panes while ⌘ is held"></td>
    <td width="50%"><img src="docs/screenshots/shortcuts-sheet.png" alt="The ⌘/ shortcuts sheet"></td>
  </tr>
  <tr>
    <td align="center">Hold <b>⌘</b>: every space, tab and pane shows its key.</td>
    <td align="center"><b>⌘/</b> lists them all.</td>
  </tr>
</table>

## Made to fit your Mac

Your Ghostty config as is, hundreds of themes built in, translucency, fonts,
notification sounds, and SSH machines whose spaces sit right under yours.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/settings-terminal.png" alt="Terminal settings"></td>
    <td width="50%"><img src="docs/screenshots/settings-browser.png" alt="Browser settings"></td>
  </tr>
</table>

<br>

## Install

Needs **macOS 14+** and **[herdr](https://herdr.dev) 0.9.2+**. Universal
(Apple Silicon and Intel).

```sh
gh release download -R v1k45/bigtty -p 'bigtty-*.dmg' && open bigtty-*.dmg
```

Drag bigtty to Applications and open it; it finds herdr and connects to your
default session. Downloaded in a browser instead? The app is ad-hoc signed, so
clear the quarantine flag once:
`xattr -dr com.apple.quarantine /Applications/bigtty.app`.

## Quick start

| | |
|---|---|
| **⌘N** · **⌘T** · **⌘D** | New space · tab · split |
| **⌥⌘B** · **⌥⌘F** · **⌥⌘G** | Browser · files · git changes beside you |
| **⌘K** · **⇧⌘U** | Jump anywhere · next agent that needs you |
| **⌘1–9** · **⌃⌘⇥** | Your spaces · back to the last one |
| **⌥⌘K** · **⇧⌘S** | Connect a machine · switch session |

Drag a pane by its top edge to rearrange. Everything else:
[shortcuts](docs/shortcuts.md).

## Learn more

- [Features in depth](docs/features.md): terminals, spaces, attention, browser
  panes and extensions, files, sessions, remote machines, how it works
- [btty](docs/btty.md): the command agents use to drive bigtty's browser and
  open files
- [Building and development](docs/development.md)

Built on [herdr](https://herdr.dev), [Ghostty](https://ghostty.org) via
[libghostty-spm](https://github.com/Lakr233/libghostty-spm), and themes from
[iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes).
MIT licensed.
