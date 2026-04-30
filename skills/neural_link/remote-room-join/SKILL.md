---
name: remote-room-join
description: Join an existing coordination room on the remote neural_link server. Use when the user wants to join a remote room someone else opened, says "join the remote room", or invokes /remote-room-join.
---

# Remote Room — Join

Join an existing coordination room on the **remote** neural_link MCP
server.

## Prerequisites

The user must have `neural_link_remote` registered. If
`mcp__neural_link_remote__room_join` isn't available, see
`docs/REMOTE.md`.

## Usage

```
/remote-room-join <room_id> <participant_id> <display_name> [role]
```

- `<room_id>` — the id shared by whoever opened the room
- `<participant_id>` — a unique identifier for *this* agent within the
  room (e.g. `drone-bs`, `agent-alice`); must be different from other
  participants in the same room
- `<display_name>` — human-readable label for this participant
- `[role]` — `member` (default) or `observer` (read-only)

## Steps

1. Parse the four args from the invocation.
2. Call `mcp__neural_link_remote__room_join` with `room_id`,
   `participant_id`, `display_name`, and `role` (default `member`).
3. The response includes the room's `interaction_mode` if one was set
   at open time — surface that to the user since it changes
   conventions for messaging (informative / deliberative / etc.).
4. Confirm join success to the user. Tell them they can now read the
   inbox with `mcp__neural_link_remote__inbox_read` or send messages
   with `/send-message` once they have the room context loaded.

## Notes

- `participant_id` is namespaced *within* the room — the same id in
  two different rooms is two different participants. So `lead` works
  fine across rooms.
- If the room was opened with a deterministic id and your participant
  already joined previously, joining again is idempotent.
- Pass `agent_id` (your Claude Code agent id from
  `${CLAUDE_AGENT_ID}` if available) so the PostToolUse inbox-nudge
  hook can resolve your participant to your session — without it, the
  nudge hook can't notify you of pending messages.
