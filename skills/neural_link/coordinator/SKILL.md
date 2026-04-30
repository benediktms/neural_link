---
name: coordinator
description: Spawn a teammate that bridges a remote neural_link room into the parent session via a local notification room. Use when the user wants to be notified of remote-room messages without manually polling. Triggers on /coordinator or "watch the remote room".
---

# Coordinator

Spin up a coordinator teammate that watches a remote neural_link room
and forwards new messages into a local room shared with the parent
session. The parent receives standard PostToolUse inbox nudges
whenever a remote teammate sends a message — no manual polling.

This is the headline workflow for cross-machine coordination.

## Prerequisites

- `neural_link` (local stdio) AND `neural_link_remote` (HTTP) both
  registered. See `docs/REMOTE.md`.
- `agents/remote-room-coordinator.md` accessible to Claude Code
  (typically symlinked into `~/.claude/agents/` via `just install-skills`).
- The PostToolUse inbox-nudge hook installed (`just install-hooks`).

## Usage

```
/coordinator <remote_room_id> [<remote_participant_id>]
```

- `<remote_room_id>` — the remote room to watch (provided by whoever
  opened it)
- `<remote_participant_id>` — optional; defaults to
  `coordinator-<your-handle>`

## Steps

1. **Open a local notification room.** Call
   `mcp__neural_link__room_open` with:
   - `title: "Coordinator bridge for <remote_room_id>"`
   - `participant_id: "parent"`
   - `display_name: "<user's name>"` (use a reasonable default if
     unknown)
   - `interaction_mode: "informative"` (this is a one-way feed)

   Capture the returned `room_id` as `LOCAL_ROOM_ID`.

2. **Spawn the coordinator teammate** using the Agent tool with
   `subagent_type: "remote-room-coordinator"` (the agent definition
   in `agents/remote-room-coordinator.md`). Pass these as the prompt's
   inputs:

   - `LOCAL_ROOM_ID` — from step 1
   - `LOCAL_PARTICIPANT_ID: "coordinator"`
   - `REMOTE_ROOM_ID` — from the user's invocation
   - `REMOTE_PARTICIPANT_ID` — from invocation or default

   Run the agent in the **background** (`run_in_background: true`) so
   it can long-poll without blocking the parent.

3. **Confirm to the user**: "Coordinator deployed. Watching remote
   room <id>. You will be nudged when teammates send messages — use
   `/reply` to respond, or `/send-message` for ad-hoc broadcasts."

4. **Tell the user how to stop the coordinator.** The clean shutdown
   is for the user to invoke `/coordinator-stop` (a future skill) or
   send a `handoff` message to `coordinator` in the local room with
   `summary: "shutdown"`. Until that lands, killing the parent
   session terminates the agent.

## Notes

- The coordinator only forwards. It does not reply on the parent's
  behalf. The parent uses `/reply` or `/send-message` to interact
  with the remote room directly.
- The coordinator long-polls via `wait_for` (60s windows). Idle cost
  is one HTTP request per minute — negligible.
- If the parent wants to send to multiple remote rooms, run multiple
  `/coordinator` invocations with different remote room ids. Each
  spawns its own teammate and its own local room, and you'll see
  nudges from all of them.
- This pattern reuses the existing PostToolUse inbox-nudge hook —
  there's no separate notification channel to set up. The hook fires
  on any local-room inbox count change.
