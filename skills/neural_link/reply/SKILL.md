---
name: reply
description: Reply to the most recent unread message in a remote neural_link room. Auto-acks the original message, creates a threaded reply. Triggers on /reply or "reply to the room".
---

# Reply

Reply to the most recent unread inbox message in a remote room. The
original message is acked; the reply is threaded onto the same
conversation.

This is the ad-hoc counterpart to `/send-message` — convenient when
the user just received a nudge ("you have N pending messages") and
wants to respond without thinking about thread ids.

## Prerequisites

- `neural_link_remote` registered (see `docs/REMOTE.md`).
- The user is joined to the target room.
- There is at least one unacked message in the user's inbox for that
  room.

## Usage

```
/reply <room_id> <participant_id> [--kind <kind>] <body>
```

- `<room_id>` — the room
- `<participant_id>` — your participant id in that room
- `--kind` — defaults to `answer` (you're replying); see the
  send-message skill for the full kind table
- `<body>` — your reply text. First line = summary, rest = body.

## Steps

1. Call `mcp__neural_link_remote__inbox_read` with the room and
   participant id. This returns pending messages.
2. If empty: tell the user "No pending messages to reply to" and
   stop.
3. Pick the **most recent** message — typically the last in the
   returned list. Capture its `message_id`, `from`, and `thread_id`
   (or `message_id` if `thread_id` is null — replies to top-level
   messages create a new thread named after the original message).
4. Show the user the message you're replying to (summary + body, the
   sender, the kind) and confirm before proceeding. The user may want
   to redirect to a different message — handle that gracefully.
5. Call `mcp__neural_link_remote__message_send` with:
   - `room_id`, `from` (the user's participant_id)
   - `kind` — `answer` by default (or whatever the user passed)
   - `to` — the original sender's `participant_id`
   - `thread_id` — the original's `thread_id` (or `message_id` if no
     thread existed)
   - `summary` and `body` — split from the user's reply text
6. Call `mcp__neural_link_remote__message_ack` with the original
   `message_id` to mark it processed.
7. Confirm to the user: "Replied to <sender> in thread <thread_id>.
   Original message acked."

## Notes

- Acking happens *after* the reply send succeeds. If the send fails,
  don't ack — the user can retry.
- If multiple messages are pending, the user often wants to reply to
  the most recent one but may want a different one. Always show what
  you're about to reply to and let them redirect.
- Replies inherit the thread id, which keeps the conversation
  coherent for `thread_summarize` later.
