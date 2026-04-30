---
name: remote-room-close
description: Close a coordination room on the remote neural_link server with a resolution. Use when the work in the room is done, the user says "close the remote room" / "wrap up", or invokes /remote-room-close.
---

# Remote Room — Close

Close an existing remote room with a resolution. Closing persists the
final transcript via configured plugins (e.g. brain) and frees the
room id.

## Prerequisites

`neural_link_remote` registered (see `docs/REMOTE.md`). Only the room
**lead** can close the room — if the user joined as a member, this
skill will fail.

## Usage

```
/remote-room-close <room_id> [resolution]
```

- `<room_id>` — the room to close
- `[resolution]` — one of `completed` (default), `cancelled`,
  `superseded`, `failed`

## Steps

1. Confirm with the user before closing — closing is irreversible.
   Show the room's current state first (`thread_summarize` is cheap
   and gives a useful preview).
2. Call `mcp__neural_link_remote__room_close` with `room_id` and
   `resolution`.
3. The response includes structured extraction (decisions, blockers,
   open questions, compliance summary if interaction_mode was set).
   Surface this to the user — it's the artifact you came for.
4. If a `brains` plugin was configured at open time, the conversation
   is also persisted to brain memory automatically; mention this so
   the user knows where to find it later.

## Choosing a resolution

| Resolution | When to use |
|---|---|
| `completed` | The work concluded successfully — most common case |
| `cancelled` | The user is abandoning the room without completing the work |
| `superseded` | A new room is replacing this one |
| `failed` | The work was attempted but couldn't be completed |

The resolution is recorded in the persisted artifact and is
informational — it doesn't change what gets saved.
