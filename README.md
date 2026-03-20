# neural_link

A messaging and coordination system for multi-agent workflows, implemented in Gleam on the BEAM. Provides execution-scoped coordination rooms where deployed subagents communicate in real time via typed messages with participant-scoped receipts. Brain-backed for durable consequences. MCP-exposed for tool integration.

## Architecture

```
src/neural_link/
├── domain/          # Pure types: Room, Message, Participant, Thread, Wait
├── runtime/         # OTP actors: Registry, Room, Inbox, Presence
├── brain/           # Brain integration: client (FFI), bridge (lifecycle + durable)
└── mcp/             # MCP server: protocol, codec, transport, tools, handlers
```

**Domain** — Immutable types defining rooms, messages (12 kinds), participants, threads, receipts, and wait filters. No side effects.

**Runtime** — OTP actor tree. Registry manages room lifecycle. Each Room actor holds live state: messages, receipts, pending waits. Inbox manages cross-room wait registrations. Presence tracks participant leases.

**Brain Bridge** — Persists durable events to brain via CLI subprocess. Room open/close lifecycle events and durable messages (decisions, blockers, handoffs, review results, summaries) are bridged asynchronously.

**MCP Server** — JSON-RPC 2.0 over stdio. 8 tools expose the full coordination surface.

## Setup

Prerequisites:
- [Gleam](https://gleam.run) >= 1.7
- Erlang/OTP >= 27
- [brain](https://github.com/your-org/brain) (optional, for durable persistence)

```bash
gleam deps download
gleam build
gleam test
```

To run as an MCP server:

```bash
gleam run
```

## MCP Tools

| Tool | Description |
|---|---|
| `room_open` | Create a new coordination room |
| `room_join` | Add a participant to a room |
| `message_send` | Send a typed message (12 kinds: question, answer, finding, handoff, blocker, decision, review_request, review_result, artifact_ref, summary, challenge, proposal) |
| `inbox_read` | Read a participant's inbox for a room |
| `message_ack` | Acknowledge messages (participant-scoped) |
| `wait_for` | Block until a matching message arrives |
| `thread_summarize` | Summarize messages in a room or thread |
| `room_close` | Close a room with resolution |

## Participant-Scoped Receipt Model

A message exists once. Each intended recipient receives their own receipt. Acking a message for participant A does **not** affect participant B's receipt.

- **Directed messages** (`to` specified) — receipts created only for listed participants
- **Broadcast messages** (`to` empty) — receipts created for all participants except the sender

## Durability

| Message Kind | Auto-Persisted to Brain |
|---|---|
| Decision | Yes |
| Blocker | Yes |
| Handoff | Yes |
| ReviewResult | Yes |
| Summary | Yes (as artifact) |
| Others | Only if `persist_hint: durable` |

Room open/close events are always persisted.

## Usage Example

```
1. room_open(title: "Debug auth middleware")
   → room_id: "room_a1b2c3..."

2. room_join(room_id, participant_id: "recon-agent", role: "member")
   room_join(room_id, participant_id: "fix-agent", role: "member")

3. message_send(room_id, from: "recon-agent", kind: "finding",
                summary: "Auth token expires before refresh window")

4. inbox_read(room_id, participant_id: "fix-agent")
   → [{ kind: "finding", summary: "Auth token expires..." }]

5. message_send(room_id, from: "fix-agent", to: ["recon-agent"],
                kind: "decision", summary: "Extend token TTL to 2x refresh")

6. message_ack(room_id, participant_id: "recon-agent",
               message_ids: ["msg_..."])

7. room_close(room_id, resolution: "completed")
   → brain records created for room lifecycle + decision
```

## v1 Limitations

- Single-node only (no distributed rooms)
- No authentication/authorization
- No message encryption or editing
- `thread_summarize` returns concatenated summaries (no LLM summarization)
- `wait_for` timeout not enforced at actor level (MCP layer handles client timeouts)
- stdio and HTTP MCP transports (no SSE)

## License

Apache-2.0
