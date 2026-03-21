# neural_link

`neural_link` is a coordination layer for multi-agent workflows, implemented in Gleam on the BEAM. It provides execution-scoped rooms where agents exchange typed messages, wait on specific responses, and track delivery per recipient instead of per message. Brain integration adds durable persistence for room lifecycle events and selected message kinds, while the MCP surface makes the system available to external tools and agents.

## What It Does

- Opens coordination rooms for a single work session or execution scope
- Tracks participants, inbox state, receipts, and wait conditions in real time
- Supports typed coordination messages such as findings, blockers, decisions, handoffs, and reviews
- Persists durable consequences to `brain` without turning every message into a permanent record
- Exposes the coordination model through MCP over stdio and HTTP

## Architecture

```text
src/neural_link/
├── domain/          # Pure types: Room, Message, Participant, Thread, Wait
├── runtime/         # OTP actors: Registry, Room, Inbox, Presence
├── brain/           # Brain integration: client (FFI), bridge (lifecycle + durable)
└── mcp/             # MCP server: protocol, codec, transport, tools, handlers
```

- `domain`: immutable types for rooms, messages, participants, threads, receipts, and wait filters
- `runtime`: OTP supervisor and actors for room lifecycle, inbox state, wait registration, and participant presence
- `brain`: asynchronous persistence bridge for room open/close events and durable messages
- `mcp`: tool definitions, handlers, and stdio/HTTP transport layers

### Runtime responsibilities

- `Registry`: creates rooms, tracks room processes, and routes room-level operations
- `Room`: owns live room state such as participants, messages, receipts, and thread data
- `Inbox`: manages cross-room waits and wakes blocked callers when matching messages arrive
- `Presence`: tracks participant leases and agent-to-participant mapping for inbox nudges

### Request flow

Most tool calls follow the same path:

```text
MCP transport
  -> tool handler
  -> runtime actor(s)
  -> optional brain bridge
  -> MCP response
```

In practice:

- `room_open` and `room_close` pass through MCP handlers into the runtime, then trigger asynchronous `brain` lifecycle persistence
- `message_send` mutates room state first, then notifies inbox waiters, then optionally persists durable messages
- `wait_for` registers a filter with `Inbox` and resumes only when a matching message is observed
- `thread_summarize` reads existing room state; it does not invoke an external summarizer

## Core Model

### Participant-scoped receipts

A message exists once, but every intended recipient gets an independent receipt. Acknowledging a message for one participant does not acknowledge it for any other participant.

- Directed message: receipts are created only for the listed recipients
- Broadcast message: receipts are created for every participant except the sender

### Durability

Room open and close events are always persisted when `brain` integration is configured.

The following message kinds are persisted automatically:

| Message kind | Persisted automatically |
|---|---|
| `decision` | Yes |
| `blocker` | Yes |
| `handoff` | Yes |
| `review_result` | Yes |
| `summary` | Yes, as an artifact |
| all others | Only when `persist_hint: durable` is set |

## MCP Surface

The MCP server exposes the full coordination workflow:

| Tool | Purpose |
|---|---|
| `room_open` | Create a room and auto-join the lead participant |
| `room_join` | Join an existing room as a participant |
| `message_send` | Send a typed message |
| `inbox_read` | Read pending messages for a participant in a room |
| `message_ack` | Acknowledge processed messages |
| `wait_for` | Block until a matching message arrives |
| `thread_summarize` | Return a structured summary for a room or thread |
| `room_close` | Close a room and persist the outcome |

Supported message kinds:
`question`, `answer`, `finding`, `handoff`, `blocker`, `decision`, `review_request`, `review_result`, `artifact_ref`, `summary`, `challenge`, `proposal`, `escalation`

## Quick Start

### Prerequisites

- [Gleam](https://gleam.run) 1.7 or newer
- Erlang/OTP 27 or newer
- [`brain`](https://github.com/benediktms/brain), optional, for durable persistence

### Build and test

```bash
just build
just test
```

### Run the server

For local development:

```bash
just run
```

To install the local binary wrapper and register the MCP endpoint with Claude:

```bash
just install
```

## Example Flow

```text
1. room_open(title: "Debug auth middleware", participant_id: "lead", display_name: "Lead")
   -> room_id: "room_a1b2c3..."

2. room_join(room_id, participant_id: "recon-agent", display_name: "Recon", role: "member")
   room_join(room_id, participant_id: "fix-agent", display_name: "Fix", role: "member")

3. message_send(room_id, from: "recon-agent", kind: "finding",
                summary: "Auth token expires before refresh window")

4. inbox_read(room_id, participant_id: "fix-agent")
   -> [{ kind: "finding", summary: "Auth token expires before refresh window" }]

5. message_send(room_id, from: "fix-agent", to: ["recon-agent"],
                kind: "decision", summary: "Extend token TTL to 2x refresh")

6. message_ack(room_id, participant_id: "recon-agent", message_ids: ["msg_..."])

7. room_close(room_id, resolution: "completed")
   -> durable room records plus any durable message artifacts
```

## Current Limits

- Single-node runtime only; distributed rooms are not implemented
- No authentication or authorization layer
- No message editing or encryption
- `thread_summarize` is extractive, not LLM-generated
- `wait_for` timeout handling is enforced at the MCP layer, not inside the room actor
- SSE transport is not implemented

## License

Apache-2.0
