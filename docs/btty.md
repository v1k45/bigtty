# btty: agents driving bigtty

**bigtty ▸ Install btty and Agent Skill…** puts `btty` on your `PATH` and
teaches your agents to use it:

```sh
btty browser open localhost:3000     # beside the agent, or a tab of this tab's browser
btty browser snapshot -i             # - textbox "Email" [ref=e3] …
btty browser fill @e3 me@example.com
btty browser click @e5
btty browser wait --text "Welcome"
btty browser screenshot out.png --open
btty open src/app.py:42              # show a file beside the agent
btty diff                            # show the repo's changes
```

Also `type`, `press`, `select`, `check`, `scroll`, `hover`, `get`, `eval`,
`console`, `navigate`, `back`, `forward`, `reload`, `list`, `close`, and
`--json`. Commands go over a user-only socket; the page script runs in an
isolated JavaScript world.

### Page tabs

`btty browser open` never replaces the page on screen: it uses the agent's own
tab if it has one, else opens a new one, and leaves the pane alone while you're
using it (`--background` always does; `--new` splits a new pane).

```sh
btty browser tab list                # number, id, url, title
btty browser tab new localhost:3000 --background
btty browser tab switch 2            # show it
btty browser tab close t3f09a1c2
btty browser get title --tab 2       # any command, any tab
```

Each terminal keeps to the tab it last used, so an agent's refs stay valid when
you switch tabs under it. A hidden tab keeps running, slowly, and at full speed
for 30 seconds after each command.

## Notifications

```sh
btty notify "Deploy finished"                  # from a script or agent in a pane
btty notify --title "CI" "tests passed"
```

The message goes on **Needs You** for the calling pane (`HERDR_PANE_ID`, or
`--pane <id>`) and, unless you're looking at that pane, a macOS notification.
If macOS notifications are off for bigtty, it still lands on Needs You and
`btty` says so. The agent skill tells agents about it, and to use it only when
they're blocked, need a decision, or have finished a long task.

### Claude Code

Claude Code only sends terminal notifications to terminals it recognises,
and herdr panes aren't one, so its notifications (the PushNotification tool)
never reach bigtty on their own. A Claude Code hook sends them:

```sh
btty hooks install claude     # adds a Notification hook to ~/.claude/settings.json
btty hooks status claude
btty hooks uninstall claude
```

`install` merges into the settings file (or `$CLAUDE_CONFIG_DIR/settings.json`,
or `--settings <path>`): your other hooks and settings stay, a copy of the
previous file is kept beside it, and running it again changes nothing. The hook
only handles `push_notification`; permission prompts and finished turns already
reach Needs You through herdr. Outside herdr, or when bigtty isn't running, it
does nothing. New Claude Code sessions pick it up.
