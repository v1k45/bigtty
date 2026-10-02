# bigtty pins (herdr plugin)

Panes you pin in [bigtty](https://github.com/v1k45/bigtty) (⌥⌘P) follow you
between spaces there. With this plugin they follow you in herdr's own terminal
UI too: switch space or tab in herdr and the pinned panes move in as a column
on the right, the same as in bigtty.

```sh
herdr plugin install v1k45/bigtty/herdr-plugin/pins
```

You can pin from herdr too, without bigtty: run **Pin or unpin pane** from
herdr's command palette, or bind it to a key in herdr's config:

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "bigtty.pins.toggle"
```

Unpinning puts the pane back where it was pinned from (beside the same pane,
or in its old tab or space if that pane is gone). Pins made in herdr and in
bigtty are the same thing, so either can unpin them.

Install it where herdr runs (your Mac, or a server you connect to). herdr
fetches plugins with `git`, and this one runs on `python3`; most Linux systems
and macOS (with the developer tools) have both.

How it works: bigtty tags pinned panes (`btty_pin`, `btty_pin_width` pane
tokens). On every `workspace.focused` and `tab.focused` event the plugin moves
the tagged panes into herdr's focused tab: the first beside the pane along the
right edge (a full-height column when there is one), the rest stacked below.
Quick switching settles first and moves them once. bigtty only moves pins when
you switch in bigtty, so the two don't pull them back and forth.
