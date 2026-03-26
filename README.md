# neural_link

`neural_link` is a coordination layer for multi-agent workflows, implemented in Gleam on the BEAM. It provides execution-scoped rooms where agents exchange typed messages, wait on specific responses, and track delivery per recipient instead of per message. A generic persistence plugin architecture adds durable persistence for room lifecycle events and selected message kinds, while the MCP surface makes the system available to external tools and agents.

## What It Does

- Opens coordination rooms for a single work session or execution scope
- Tracks participants, inbox state, receipts, and wait conditions in real time
- Supports typed coordination messages such as findings, blockers, decisions, handoffs, and reviews
- Persists durable consequences via plugins without turning every message into a permanent record
- Exposes the coordination model through MCP over stdio and HTTP

## Architecture

```text
src/neural_link/
├── domain/          # Pure types: Room, Message, Participant, Thread, Wait
├── runtime/         # OTP actors: Registry, Room, Inbox, Presence
├── persistence/     # Persistence plugin system: generic interface, BrainPlugin, SqlitePlugin stub
├── brain/           # Brain CLI client (FFI) and types — used by BrainPlugin
└── mcp/             # MCP server: protocol, codec, transport, tools, handlers
```

- `domain`: immutable types for rooms, messages, participants, threads, receipts, and wait filters
- `runtime`: OTP supervisor and actors for room lifecycle, inbox state, wait registration, and participant presence
- `persistence`: generic plugin interface and replication dispatch for room events
- `brain`: Brain CLI client (FFI) and types — used by BrainPlugin
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
  -> optional persistence plugins
  -> MCP response
```

In practice:

- `room_open` and `room_close` pass through MCP handlers into the runtime, then trigger asynchronous persistence plugin dispatch
- `message_send` mutates room state first, then notifies inbox waiters, then optionally persists durable messages via plugins
- `wait_for` registers a filter with `Inbox` and resumes only when a matching message is observed
- `thread_summarize` reads existing room state; it does not invoke an external summarizer

## Core Model

### Participant-scoped receipts

A message exists once, but every intended recipient gets an independent receipt. Acknowledging a message for one participant does not acknowledge it for any other participant.

- Directed message: receipts are created only for the listed recipients
- Broadcast message: receipts are created for every participant except the sender

### Durability

Room open and close events are always persisted when persistence plugins are configured (via the `brains` parameter on `room_open`).

Persistence is handled by a plugin system. The `BrainPlugin` replicates events to `brain` for memory graph indexing. Plugin failures are logged but do not block the primary coordination flow.

The following message kinds are persisted automatically:

| Message kind | Persisted automatically |
|---|---|
| `decision` | Yes |
| `blocker` | Yes |
| `handoff` | Yes |
| `review_result` | Yes |
| `summary` | Yes, as an artifact |
| all others | Only when `persist_hint: durable` is set |

## Persistence Plugin Architecture

`neural_link` uses a plugin system for replication and durable persistence. While the primary coordination state lives in the runtime actors, room lifecycle events and durable messages are dispatched to registered persistence plugins.

### Dispatch flow

1.  **Registration**: A room declares its persistence plugins via the `brains` parameter on `room_open`.
2.  **Resolution**: The MCP handler resolves these configuration strings into `PersistencePlugin` instances.
3.  **Execution**: When a room event occurs (open, close, durable message), the system dispatches the event to all registered plugins.

### Primary vs. Plugin write

Plugins receive events after the primary write succeeds. They are intended for replication to external systems (like `brain`). Plugin failures are logged by the server but do not roll back or block the primary coordination flow.

### Current plugins

- **BrainPlugin**: The working reference implementation. It replicates room events and durable messages to the `brain` CLI for memory graph indexing.
- **SqlitePlugin**: A stub implementation (not yet implemented). It always returns `Unavailable` and serves as a template for future SQLite-based replication.

## Writing a Persistence Plugin

Adding a new persistence backend involves three steps:

1.  **Implement the interface**: Create a new module in `src/neural_link/persistence/` that returns a `PersistencePlugin` record (defined in `plugin.gleam`). You must implement all five handlers:
    - `on_init`: Called when the plugin is registered.
    - `on_room_open`: Called after a room is opened.
    - `on_room_close`: Called after a room is closed.
    - `on_conversation_artifact`: Called with the full conversation text on room close.
    - `on_message`: Called for each durable message.
2.  **Add configuration**: Add a new variant to the `PersistencePluginConfig` type in `src/neural_link/persistence/config.gleam`.
3.  **Register the resolver**: Add a case to `resolve_plugin_config_real` in `src/neural_link/mcp/handlers.gleam` to map your config variant to your plugin implementation.

For a complete example, see `src/neural_link/persistence/brain.gleam`. For a minimal stub, see `src/neural_link/persistence/sqlite_plugin.gleam`.

> **Note for testing**: The `make_handler_for_testing` function in `handlers.gleam` allows injecting a custom plugin resolver, which is useful for verifying plugin dispatch in integration tests without external dependencies.

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
| `room_close` | Close a room and persist the outcome via registered persistence plugins |

Supported message kinds:
`question`, `answer`, `finding`, `handoff`, `blocker`, `decision`, `review_request`, `review_result`, `artifact_ref`, `summary`, `challenge`, `proposal`, `escalation`

## Quick Start

### Prerequisites

- [Gleam](https://gleam.run) 1.7 or newer
- Erlang/OTP 27 or newer
- [`brain`](https://github.com/benediktms/brain), optional, for durable persistence via `BrainPlugin`

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
   -> durable room records plus any durable message artifacts via registered persistence plugins
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
