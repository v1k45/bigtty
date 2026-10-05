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

## Moving panes

A pane can move to another tab or space, its process still running: agents,
servers and browser panes keep going where they land.

- **Drag** a pane by its top edge onto a space in the sidebar (onto one of its
  tab rows for that tab), or below the cards for a new space of its own.
  **Hold it there** a moment and the space blinks and opens, like a folder in
  Finder: keep dragging to drop the pane exactly where you want it (beside a
  pane, or along an edge of the whole tab).
- **Pane ▸ Move Pane To…** (or **⌘K ▸ Move Pane to…**) picks one of your
  spaces and their tabs, a new tab here or a new space in the palette.
- **⌃⌥⌘1–9** sends the focused pane to space 1–9.

bigtty follows the pane there; hold **⌥** while choosing or dropping to stay
where you are. A tab or space the move leaves empty closes. Panes move within
one machine (herdr can't carry a process to another).

## Pinned panes

**⌥⌘P** (Pane ▸ Pin Pane, or ⌘K) pins a pane: it follows you between spaces,
as a full-height column on the right of whatever you switch to. Pin a dev
server's logs, a `localhost` preview or an agent you're watching, and it stays
in view. Several pins stack in the column; drag its divider to set the width.
A 📌 marks a pinned pane, and pinned panes don't name the tabs they visit.

Pinning is a real move in herdr, so herdr's own terminal UI and your other
Macs see the pane where you last were. **⌥⌘P** again unpins it, back beside
the pane it was next to. Switching quickly moves the pins once, when you
settle; a zoomed tab is left alone.

In herdr's terminal UI, pins stay where you last were, unless you add the
[pins plugin](../herdr-plugin/pins/README.md) (`herdr plugin install
v1k45/bigtty/herdr-plugin/pins`): then they follow you there too, and herdr
gets a **Pin or unpin pane** action for its command palette or a key.

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

The **Window** menu lists every space by the same name: the session on screen
under its own header ("This Mac · hq"), every other session and machine in a
submenu ("orb · main"). A space with several tabs also lists them as
"api › logs" (up to 8), and a badge counts what needs you. So menu search
(Help ▸ Search, or Spotlight's menu actions) finds a space or tab by name, and
picking one only shows it: nothing moves, and herdr's own focus stays put.

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

**Needs You**, at the top of the sidebar, lists everything waiting on you
across every machine and session, most urgent first: a machine whose login
waits on you (a Tailscale approval, a sign-in), then agents asking something
you haven't seen, agents still waiting on an answer (with their question),
machines that can't be reached, and agents that finished while you were
away; within each, whatever has waited longest leads. Click one to go there;
click the header to collapse it (the space cards still quote each question).
**⇧⌘K** opens the whole list as a palette. ⌘⌫ there (or the × on a row)
dismisses an item until its state changes, and ⌘Z brings it back.

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

Machines connected over SSH get the same switcher once they have more than
one session: click the session name on the machine's row to switch, start a
stopped session there, or create one. Their running sessions stay connected
in the background too.

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
time (codes are never stored). A wrong password asks again; cancel, and
bigtty stops asking for that machine until you connect it again yourself,
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
