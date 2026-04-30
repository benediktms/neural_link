---
name: send-message
description: Send a message to a remote neural_link room. Use for ad-hoc broadcasts or directed messages to teammates in a shared room. Triggers on /send-message or "send a message to the room".
---

# Send Message

Send a typed message to a room on the **remote** neural_link server.
Use for ad-hoc messaging when you don't want to spawn a coordinator
teammate.

## Prerequisites

- `neural_link_remote` registered (see `docs/REMOTE.md`).
- The user has already joined the target room (via
  `/remote-room-open` or `/remote-room-join`).

## Usage

```
/send-message <room_id> <participant_id> [--kind <kind>] [--to <ids>] [--thread <thread_id>] <body>
```

- `<room_id>` — the target room
- `<participant_id>` — who you are *in this room*
- `--kind` — one of: `question`, `answer`, `finding`, `blocker`,
  `decision`, `handoff`, `review_request`, `review_result`,
  `artifact_ref`, `summary`, `challenge`, `proposal`, `escalation`.
  Default `finding` (general broadcast).
- `--to` — comma-separated list of participant_ids to direct the
  message to. Omit for room-wide broadcast.
- `--thread` — thread id to attach this message to (creates a
  conversation thread). Omit for a top-level message.
- `<body>` — the message body. The first line is used as the summary;
  the rest is the body.

## Steps

1. Parse args. The body is everything after the flags.
2. Split body into `summary` (first line, ≤120 chars) and `body`
   (the rest, may be empty).
3. Call `mcp__neural_link_remote__message_send` with:
   - `room_id`, `from` (participant_id), `kind`, `summary`, `body`
   - `to` (if provided)
   - `thread_id` (if provided)
   - `persist_hint: durable` if the kind is one a future agent might
     want to recall (decisions, findings of substance) — otherwise
     omit
4. The response includes `message_id` and per-recipient delivery
   info. Confirm to the user: "Sent. Pending recipients: N".

## Choosing a kind

| Kind | Use for |
|---|---|
| `question` | Asking another agent for information |
| `answer` | Replying to a question |
| `finding` | Informational broadcast — "I noticed X" |
| `blocker` | "I'm stuck on Y, can someone unblock?" |
| `decision` | "We're going with approach A" — auto-persisted |
| `handoff` | Passing work to another agent — auto-persisted |
| `review_request` | Asking for review of work |
| `review_result` | Verdict on a review request — auto-persisted |
| `proposal` | Proposing a direction — open for challenge |
| `challenge` | Adversarial pushback on a finding/proposal |
| `summary` | Periodic recap — auto-persisted |
| `escalation` | Raising priority / asking for human attention |
| `artifact_ref` | Pointing to a saved artifact (snapshot, doc) |

`decision`, `blocker`, `handoff`, `review_result`, `summary` are
auto-persisted to the conversation artifact. Other kinds need
`persist_hint: durable` to be saved.
