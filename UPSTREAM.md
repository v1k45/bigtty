# Upstream notes

Changes GhostHerdr would like from herdr. Not filed yet: we're finishing the
app first.

## Inline images in terminal panes (kitty graphics)

herdr already sends kitty-graphics images to terminal clients as raw bytes
(`ServerMessage::Graphics { bytes }`, "to write directly to the host
terminal"), and Ghostty draws them natively. Two things stop them reaching
GhostHerdr:

1. `herdr terminal session control` drops them:
   `src/client/terminal_sessions.rs`, `write_terminal_session_output`:
   `Ok(ServerMessage::Graphics { .. }) => {}`.
   Proposed: emit `{"type":"terminal.graphics","bytes":"<base64>"}` in order
   with `terminal.frame` records.
2. The session client says hello with a 0×0 cell size, so herdr can't place
   images. Proposed: take cell pixels from `terminal.resize`
   (`cell_width_px` / `cell_height_px`, which GhostHerdr already sends) or a
   `--cell-size WxH` flag.

GhostHerdr side, once available: feed `terminal.graphics` bytes into the
surface (`InMemoryTerminalSession.receive`) in stream order.

## Other gaps noticed

- `pane.read` caps at 1000 lines (`src/app/api_helpers.rs`), which limits a
  history view for long shell output.
- `pane.agent_status_changed` needs a `pane_id` per subscription, so clients
  resubscribe whenever panes change.
- Pane `tokens` from `pane.report_metadata` don't survive a server restart.
