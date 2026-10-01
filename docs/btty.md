# btty: agents driving bigtty

**bigtty ▸ Install btty and Agent Skill…** puts `btty` on your `PATH` and
teaches your agents to use it:

```sh
btty browser open localhost:3000     # beside the agent, or this tab's browser
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
