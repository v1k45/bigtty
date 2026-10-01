# Building and development

## Build from source

Needs Xcode 26 (Swift 6.2+).

```sh
scripts/bundle.sh                 # dev build → build/bigtty.app
open build/bigtty.app
scripts/release.sh 0.3.0          # universal release → build/release/bigtty-0.3.0.{dmg,zip}
```

`BIGTTY_SESSION=<name>` connects to a named herdr session.

## Development

```sh
swift test                                  # unit tests
herdr --session bttytest server &            # isolated server for live tests
BTTY_TEST_SESSION=bttytest swift test         # + live socket/terminal tests
```

Debug hooks on a running app: `kill -USR1 <pid>` writes window, pane and
on-screen terminal text to `$TMPDIR/bigtty-debug.txt` (plus a window
render); `kill -USR2 <pid>` pastes `$TMPDIR/bigtty-type.txt` into the
focused pane, or, starting with `!`, sends a menu action
(`!@<space> newBrowserPane:`). Quit the app with `pkill -x bigtty`
(`pkill -f bigtty.app` also kills the placeholders inside herdr panes).
