# Features in depth

## Terminals

Every pane is a Ghostty surface. Your Ghostty config
(`~/.config/ghostty/config.ghostty` or Ghostty's other usual places) applies
as is, and saved edits take effect immediately. On top, **Settings ▸ Terminal**
picks a theme (curated light/dark pairs or any of Ghostty's collection,
bundled from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)),
font, size, background translucency, contrast boost and copy on select.
`theme = Name` and `theme = light:A,dark:B` in your config just work.
`BIGTTY_GHOSTTY_CONFIG=/path` keeps a separate config for bigtty.

Clicks, hover, scrolling and pastes reach apps like Claude Code, vim and htop
the way they do in Ghostty. ⌘V with a screenshot on the clipboard pastes it as
a file (uploaded first for a pane on another machine), so Claude Code attaches it.

## Spaces

The sidebar lists every space with its branch, folder, listening ports and
agents, and its tabs by name: a label you gave it, a title the agent reports,
the agent's own conversation title (Claude Code, Codex) or the terminal title.
A space with several tabs shows the first two and "+N more".

Spaces go by what they're doing, too: one herdr named after its folder shows
its first tab's title instead ("Fix checkout totals" rather than
"checkout-api"), with the folder on the line below. A name you gave the space
(Rename Space…) always wins, a plain shell keeps the folder name, and herdr's
own name for the space is never changed.

⌘1–9 are fixed: space 1 is whatever sits at the top. Drag cards in the
sidebar, or right-click one and choose Move Up / Move Down, to put the spaces
you use most on the keys you want. ⌃⌘⇥ goes back to the last space you were
in; hold ⌃⌘ and keep tapping ⇥ to go further back.

Each card says how long its space has been quiet ("claude · idle · 3h"), and
spaces with nothing for 12 hours fade until you hover or select them, so the
ones worth your attention stand out. The window and sidebar remember their
size; the buttons beside the traffic lights hide the sidebar (⌃⌘S) and the
file viewer (⇧⌘E).

## Attention and notifications

herdr reports each agent's state; bigtty turns it into a breathing dot while
an agent works, and when one needs you: a ring on the pane, a highlighted
space with the agent's own question, a Dock badge, and a notification for
panes you aren't looking at. **Settings ▸ General** picks the sound (or none);
the Dock icon bounces when an agent needs you while bigtty is in the
background. Once you've seen it, it goes quiet until the agent needs you
again.

## Browser panes

A browser pane is a real herdr pane (tagged, running a small placeholder), so
splitting, zooming, moving and closing work like any pane, and layouts survive
restarts. It identifies as Safari, plays media with a speaker on its tab, and
video full screen fills the pane (or the display, if you prefer). Terminal
links open in the tab's browser pane or in your default browser (a setting).

**Extensions.** Browser panes run Safari/Chrome MV3 web extensions (macOS
15.4+). **Settings ▸ General ▸ Get uBlock Origin Lite** installs it; any other
unpacked extension goes in `~/Library/Application Support/bigtty/Extensions`.

## Files and changes

⌘-click a path, `btty open path:line`, or **⌥⌘F**: the file opens at the line,
highlighted, with images and PDFs previewed; the tree is a click away. The
Changes pane (**⌥⌘G**, `btty diff`) lists what git sees as changed with each
diff, refreshed live. Right-click a file to insert its path into the terminal.

## Sessions

herdr sessions are independent servers, each with its own spaces. The
*This Mac* row in the sidebar shows the current one; click it (or ⇧⌘S) to
switch, start a stopped session, create one, or stop and delete them. ⌘K
lists sessions too, and finds spaces in all of them. Every running session
stays connected in the background: its agents' questions badge the
switcher, notify you and count in the Dock badge. `btty` commands from an
agent act in the agent's own session.

## Remote machines

**File ▸ Connect Machine…** takes any SSH target (`user@host`, `host:port`, an
`~/.ssh/config` alias). bigtty checks it, can start herdr there, and keeps
one SSH connection forwarding herdr's sockets, so everything works as it does
locally: terminals, agents, attention, ⌘K, files panes, and browser panes that
reach the machine's `localhost` (the address bar still says `localhost:3000`).
It uses your SSH keys and agent; machines saved with `herdr machine add`
appear on their own.

**Passwords.** When keys aren't enough, bigtty asks in a dialog: a password,
a key's passphrase, a one-time code, or whether to trust a machine's new host
key. You're asked once per connection to a machine, not for each thing it
opens, and **Remember in Keychain** keeps a password or passphrase for next
time (codes are never stored). Cancel, or a password that doesn't work twice,
and bigtty stops asking for that machine until you connect it again yourself,
so it never piles up dialogs while it retries in the background.

## How it works

- **HerdrKit** speaks herdr's NDJSON socket API (`session.snapshot`,
  `layout.export`, `events.subscribe`, `pane.*`). Events trigger a re-read,
  never a delta.
- Each visible pane runs `herdr terminal session control` and feeds its frames
  into a Ghostty surface with a host-managed backend; keys, clicks, scrolls and
  pastes go back as herdr terminal commands.
- Browser and files panes are herdr panes tagged `btty_kind`, so herdr's layout
  stays the single source of truth for every pane.
- Remote machines are herdr sockets forwarded over SSH; the rest of the app
  doesn't know the difference.
