# Upstream notes

Changes bigtty would like from herdr. Not filed yet: we're finishing the
app first.

## Inline images in terminal panes (kitty graphics)

herdr already sends kitty-graphics images to terminal clients as raw bytes
(`ServerMessage::Graphics { bytes }`, "to write directly to the host
terminal"), and Ghostty draws them natively. Two things stop them reaching
bigtty:

1. `herdr terminal session control` drops them:
   `src/client/terminal_sessions.rs`, `write_terminal_session_output`:
   `Ok(ServerMessage::Graphics { .. }) => {}`.
   Proposed: emit `{"type":"terminal.graphics","bytes":"<base64>"}` in order
   with `terminal.frame` records.
2. The session client says hello with a 0×0 cell size, so herdr can't place
   images. Proposed: take cell pixels from `terminal.resize`
   (`cell_width_px` / `cell_height_px`, which bigtty already sends) or a
   `--cell-size WxH` flag.

bigtty side, once available: feed `terminal.graphics` bytes into the
surface (`InMemoryTerminalSession.receive`) in stream order.

## Other gaps noticed

- `pane.read` caps at 1000 lines (`src/app/api_helpers.rs`), which limits a
  history view for long shell output.
- `pane.agent_status_changed` needs a `pane_id` per subscription, so clients
  resubscribe whenever panes change.
- Pane `tokens` from `pane.report_metadata` don't survive a server restart.

## Sticky (pinned) panes

bigtty pins a pane by moving it into every tab you switch to (`pane.move`,
then a rebuild by moves for a full-height column). It works, but each switch
reflows the destination tab, and two clients on different spaces pull the
pane back and forth. Native support would be: a pane flagged sticky that
herdr's layout keeps in every tab's right column (one process, one size),
with an API to set it and its width, and an event when it changes. bigtty
would then just draw herdr's layout.

Found while building it (herdr 0.9.3):
- A cross-space `pane.move` keeps the process and terminal id (and tokens)
  but gives the pane a new pane id; a control stream on the terminal
  survives.
- `layout.apply` with existing `pane_id`s replaces those panes with new ones
  (their processes end), so it can't rearrange a tab in place.
- A move into or out of a zoomed tab is a no-op (`zoomed_tab`).

