---
name: remote-room-open
description: Open a coordination room on a remote neural_link MCP server. Use when the user wants to start a cross-machine / cross-session room, says "open a remote room", "start a shared room", or invokes /remote-room-open.
---

# Remote Room — Open

Open a new coordination room on the **remote** neural_link MCP server.
The remote server lets agents on different machines and different
Claude Code sessions exchange messages. The local stdio server is for
solo use; this skill always targets `mcp__neural_link_remote__*`.

## Prerequisites

The user must have `neural_link_remote` registered in their MCP config.
If the tool `mcp__neural_link_remote__room_open` is not available, tell
the user to run:

```bash
claude mcp add -s user -t http neural_link_remote <URL> \
  --header "Authorization: Bearer $NEURAL_LINK_AUTH_TOKEN"
```

…and link them to `docs/REMOTE.md` for setup guidance.

## Usage

```
/remote-room-open <title> [purpose]
```

`<title>` is required — a human-readable label. `[purpose]` is optional
free text describing what the room is for (helps teammates joining
later).

## Steps

1. Read the user's title and optional purpose from the invocation.
2. Generate a `participant_id` for the user — `lead-<username>` is a
   good default if you can infer their handle, otherwise ask. The user
   is opening the room, so they take role `lead` (handled implicitly by
   `room_open`).
3. Call `mcp__neural_link_remote__room_open` with:
   - `title` — from the invocation
   - `participant_id` — the chosen lead id
   - `display_name` — a human-readable name for the lead
   - `purpose` — if provided
4. Report the resulting `room_id` back to the user, plus the join
   command other agents would use:
   ```
   /remote-room-join <room_id> <their-participant-id> <their-display-name>
   ```

## Notes

- The `room_id` returned is what teammates use to join. Share it
  through whatever channel you'd share a link in (Slack, etc.) — there
  is no auto-discovery.
- If the room title or purpose suggests a deterministic id is wanted
  (e.g. "the daily-standup room"), the user can supply
  `--id nlr-<16-hex-chars>` and the same room can be re-opened later
  with the same id (the server returns `already_existed: true` on
  re-open).
- The opener is automatically joined as the room lead. No extra
  `room_join` is needed for them.
