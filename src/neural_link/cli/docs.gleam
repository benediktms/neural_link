import gleam/bit_array
import gleam/crypto
import gleam/io
import gleam/list
import gleam/string

const marker_prefix = "neural_link"

const default_file = "AGENTS.md"

pub fn run(args: List(String)) -> Nil {
  let target_path = case args {
    [path, ..] -> path
    [] -> default_file
  }

  let content = generate_docs_content()
  let hash = content_hash(content)
  let start_marker = "<!-- " <> marker_prefix <> ":start:" <> hash <> " -->"
  let end_marker = "<!-- " <> marker_prefix <> ":end -->"
  let block = start_marker <> "\n" <> content <> "\n" <> end_marker

  case read_file(target_path) {
    Error(_) -> {
      // File doesn't exist — create it with the block
      case write_file(target_path, block <> "\n") {
        Ok(_) -> io.println("Created " <> target_path)
        Error(e) -> io.println_error("Failed to create file: " <> e)
      }
    }
    Ok(existing) -> {
      // Check if marker already exists with same hash (idempotent)
      case string.contains(existing, start_marker) {
        True -> {
          io.println("Already up to date")
        }
        False -> {
          // Check if any neural_link marker exists (needs replacement)
          let updated = case
            find_marker_range(
              existing,
              "<!-- " <> marker_prefix <> ":start:",
              end_marker,
            )
          {
            Ok(#(before, _, after)) -> before <> block <> after
            Error(_) ->
              // No existing marker — append
              existing <> "\n" <> block <> "\n"
          }
          case write_file(target_path, updated) {
            Ok(_) -> io.println("Updated " <> target_path)
            Error(e) -> io.println_error("Failed to update file: " <> e)
          }
        }
      }
    }
  }
}

fn content_hash(content: String) -> String {
  let hash_bytes = crypto.hash(crypto.Sha256, bit_array.from_string(content))
  bit_array.base16_encode(hash_bytes)
  |> string.lowercase
  |> string.slice(0, 8)
}

fn find_marker_range(
  text: String,
  start_prefix: String,
  end_marker: String,
) -> Result(#(String, String, String), Nil) {
  case string.split_once(text, start_prefix) {
    Error(_) -> Error(Nil)
    Ok(#(before, rest_with_start)) -> {
      // rest_with_start starts after the start_prefix, find the end of the start marker line
      case string.split_once(rest_with_start, "\n") {
        Error(_) -> Error(Nil)
        Ok(#(_, after_start_line)) -> {
          case string.split_once(after_start_line, end_marker) {
            Error(_) -> Error(Nil)
            Ok(#(middle_content, after_end)) -> {
              Ok(#(before, middle_content, after_end))
            }
          }
        }
      }
    }
  }
}

fn generate_docs_content() -> String {
  string.join(
    [
      "## neural_link — Multi-Agent Coordination",
      "",
      "neural_link provides real-time coordination between agents via an MCP server.",
      "All tools below are MCP tool calls prefixed with `neural_link` (e.g., `mcp__neural_link__room_open`).",
      "",
      "### When to use neural_link",
      "",
      "**Always use neural_link when 2 or more subagents are dispatched.** No exceptions.",
      "The lead opens a room before dispatching, every subagent joins the room, and the lead participates alongside them.",
      "",
      "### Roles",
      "",
      "| Role | Who | Responsibilities |",
      "|------|-----|------------------|",
      "| **Lead** | The session that dispatches subagents | Opens the room (auto-joined as lead). Monitors messages, acknowledges inbox items, answers questions, responds to escalations, unblocks agents, and closes the room. |",
      "| **Subagent** | Each dispatched agent | Joins the room on activation. Communicates findings, blockers, and questions. Checks inbox after meaningful work or when nudged. Sends `handoff`, then calls `room_leave` before returning. |",
      "",
      "### Happy path",
      "",
      "Use this sequence unless the task requires something more specialized.",
      "",
      "**Lead**",
      "1. `room_open`",
      "2. Dispatch subagents with `room_id`, participant identity, and instruction to join",
      "3. After each meaningful work unit or inbox nudge: `inbox_read` -> process -> `message_ack`",
      "4. Send `decision` or `answer` messages when agents need direction",
      "5. After all subagents send `handoff` and leave: `room_close`",
      "",
      "**Subagent**",
      "1. `room_join`",
      "2. Perform assigned work",
      "3. Send `message_send` updates for findings, questions, blockers, review requests, or artifacts",
      "4. After each meaningful work unit or inbox nudge: `inbox_read` -> process -> `message_ack`",
      "5. If fully blocked with nothing else to do: `wait_for`",
      "6. When complete: send `handoff`, then call `room_leave`",
      "",
      "### Coordination flow",
      "",
      "#### Lead (dispatcher)",
      "",
      "1. **Open a room** — call `room_open` with `title`, `purpose`, `participant_id`, and `display_name`. The opener is auto-joined as the room's lead. No separate `room_join` needed. The `brains` parameter configures persistence plugins for this room.",
      "2. **Dispatch subagents** — include the `room_id` in every subagent's prompt along with the instruction to join the room and communicate.",
      "3. **Monitor and participate** — after each meaningful work unit, explicit inbox nudge, or state transition, call `inbox_read`, process messages, and immediately `message_ack` them. Answer questions from subagents. Send `decision` messages to resolve ambiguities. Unblock agents that report `blocker` messages. Respond to `escalation` messages when subagents depart while others depend on them.",
      "4. **Close the room** — once all subagents have sent `handoff` and called `room_leave`, call `room_close` with a resolution. The server persists the full conversation via registered persistence plugins (if brains were declared) and returns structured extraction data: decisions, open questions, blockers, participant list, and message count.",
      "5. **Persist and present** — use the structured extraction from `room_close` to compose a narrative summary for the user. The artifact record ID links to the full conversation for future reference.",
      "",
      "#### Subagent (participant)",
      "",
      "1. **Join** — on activation, if a `room_id` was provided in your prompt, call `room_join` with the room_id, your designation as `participant_id` and `display_name`, and role `member`. If your context includes a Claude Code `agent_id` (injected by the SubagentStart hook), pass it as the `agent_id` parameter — this enables automatic inbox notifications via the PostToolUse hook.",
      "2. **Communicate** — send typed messages via `message_send` as you work. Share findings, flag blockers, ask questions. Use the appropriate message `kind` (see below).",
      "3. **Read inbox** — call `inbox_read` after completing a logical unit of work, after sending an important message, or after an inbox nudge indicates pending messages. Process and `message_ack` all messages promptly. If the lead or another subagent asks a question, answer it. If a blocker is raised that you can resolve, respond.",
      "4. **Wait when blocked** — if you cannot proceed until another agent provides something and you have no other useful work, use `wait_for` to block until the matching message arrives. Do not poll `inbox_read` in a loop.",
      "5. **Handoff and leave** — when your work is complete, send a `handoff` message summarizing what you accomplished and any open items, then call `room_leave`. The system drains any pending outbound obligations before departing. If you have unacked outbound messages, the call blocks until recipients ack or the timeout expires. Do NOT skip `room_leave`. Silent departure can strand agents waiting on your messages.",
      "",
      "### Persistence",
      "",
      "neural_link persists room events to a local SQLite database (`neural_link.db`) as they happen. Rooms, participants, durable messages, and conversation artifacts are written on every lifecycle event. SQLite writes are best-effort (fire-and-forget) — errors are logged but never fail MCP responses. Actors remain the source of truth at runtime; SQLite provides durability.",
      "",
      "When `brains` is passed to `room_open`, events are also dispatched to registered persistence plugins. BrainPlugin replicates room lifecycle and durable messages to brain in real-time. Plugin failures are logged but do not block the primary coordination flow.",
      "",
      "### Syncing to brain",
      "",
      "The `sync` CLI command pushes closed room transcripts from SQLite to brain as artifacts:",
      "",
      "```",
      "nlk sync [--db neural_link.db] [--log .neural_link/sync.jsonl] [--brain name]",
      "```",
      "",
      "Sync reads closed rooms from SQLite, builds a conversation transcript, and calls `brain artifacts create` for each unsynced room. Progress is tracked in a JSONL log (decoupled from SQLite). Re-running is idempotent — already-synced rooms are skipped.",
      "",
      "### Message kinds",
      "",
      "Every message has a `kind` that signals its intent. Use the right kind — other agents filter on it.",
      "",
      "| Kind | When to use |",
      "|------|-------------|",
      "| `finding` | You discovered something another agent needs to know |",
      "| `handoff` | Your part is done — summarize results and hand over |",
      "| `blocker` | You cannot proceed until something is resolved |",
      "| `decision` | Recording a choice that affects other agents |",
      "| `question` | Asking another agent (or the lead) for information |",
      "| `answer` | Responding to a question |",
      "| `review_request` | Asking another agent to review your work |",
      "| `review_result` | Delivering review feedback |",
      "| `artifact_ref` | Pointing to a file, commit, or output another agent should consume |",
      "| `summary` | Summarizing progress or conclusions |",
      "| `challenge` | Disputing or questioning a prior finding or proposal. Use in adversarial/deliberative modes to contest claims. Distinct from `question` — challenge is adversarial, question is neutral. |",
      "| `proposal` | Putting forward a concrete option or approach. Distinct from `finding` — a finding is an observation, a proposal is a recommended action that invites a decision. |",
      "| `escalation` | System-generated. Sent to the lead when a subagent departs while another agent has a pending `wait_for` targeting that subagent. The lead must respond to unblock the waiting agent. |",
      "",
      "### Waiting for other agents",
      "",
      "`wait_for` is a blocking call. Your tool call is held open on the server until a matching message arrives or the timeout expires (default: 30s, max: 120s). You are effectively paused.",
      "",
      "- **Use `wait_for` when you have nothing else to do** until a specific message arrives (e.g., waiting for a handoff, a review result, or an answer to your question)",
      "- **Do not use `wait_for` if you have other work to do** — continue working and check `inbox_read` after the next meaningful work unit or inbox nudge",
      "- **Filter precisely** — use the `kinds` and `from` params to match only what you need, avoiding false wakeups",
      "- **Set reasonable timeouts** — a stuck `wait_for` blocks you for up to 120 seconds",
      "",
      "### Departure and drain",
      "",
      "When a subagent's work is done, it calls `room_leave`. The system checks for outbound obligations — messages sent by the leaving agent that recipients haven't acked yet. If obligations exist, the agent enters a `Draining` state:",
      "",
      "- No new messages can be broadcast to a draining agent",
      "- The `room_leave` call blocks until all recipients ack the agent's messages, or the drain timeout expires",
      "- On timeout, the agent departs forcibly",
      "",
      "**Lead escalation:** If an agent departs while another agent has a `wait_for` targeting them (via the `from` filter), the system sends an `escalation` message to the lead. The lead's response can satisfy the waiting agent's filter — the lead effectively stands in for the departed agent. This override only activates when ALL agents in the `from` filter have departed.",
      "",
      "**The lead cannot leave.** The lead is auto-joined on `room_open` and can only exit via `room_close`. This guarantees a fallback recipient always exists.",
      "",
      "### Interaction modes",
      "",
      "Rooms can be opened with an `interaction_mode` that declares how participants are expected to communicate. The mode is advisory — messages are never rejected — but compliance is tracked at room close.",
      "",
      "| Mode | Use case | Expected message flow |",
      "|------|----------|----------------------|",
      "| `adversarial` | Review, diagnosis, architecture evaluation | Finding → Challenge → Decision. Every substantive claim should be challenged by a different participant. |",
      "| `informative` | Implementation coordination (default) | Finding → Handoff. One-directional updates. Questions answered, no obligation to challenge. |",
      "| `deliberative` | Architecture decisions, trade-off analysis, collaborative design | Question/Proposal → Finding/Challenge → Decision. Multiple perspectives before resolution. |",
      "| `supervisory` | Lead monitoring adjuncts | Finding → Question (from lead) → Decision. Status reporting with lead oversight. |",
      "",
      "**How to use:**",
      "1. The lead passes `interaction_mode` when calling `room_open` (e.g., `interaction_mode: \"adversarial\"`)",
      "2. The mode is returned in `room_join` responses so joining agents can discover it",
      "3. On `room_close`, if a mode was set, the response includes `compliance` data: expectations checked, expectations fulfilled, and unchallenged findings (adversarial mode)",
      "",
      "**Compliance tracking:** At room close, the server evaluates whether the expected response patterns were followed. Thread-aware — threaded triggers are matched against same-thread responses only. The compliance score is informational, not enforced.",
      "",
      "### Persistence",
      "",
      "neural_link uses a plugin system for persistence. When `brains` is passed to `room_open`, events are dispatched to registered persistence plugins.",
      "BrainPlugin replicates room lifecycle and durable messages to brain. Plugin failures are logged but do not block the primary coordination flow.",
      "",
      "### Tools reference",
      "",
      generate_tools_doc(),
      "",
      "### Inbox nudge system",
      "",
      "Two layers ensure agents see pending messages:",
      "",
      "| Layer | Covers | Config |",
      "|-------|--------|--------|",
      "| **Server-side piggyback** | neural_link tool calls | None — automatic. `_inbox_pending` field on tool responses. |",
      "| **PostToolUse hook** | ALL tool calls (Read, Write, Bash, Grep, etc.) | Requires hook scripts in `settings.json`. Run `just install-hooks`. |",
      "",
      "**How it works:**",
      "",
      "1. **SubagentStart hook** fires when a subagent spawns. It reads the `agent_id` from Claude Code's hook payload and injects it into the subagent's context via `additionalContext`.",
      "2. The subagent passes `agent_id` to `room_join`. The server maps `agent_id → participant_id`.",
      "3. **PostToolUse hook** fires after every tool call. It reads `agent_id` from the hook payload and queries `GET /agent/:agent_id/inbox/count`. If messages are pending, it injects a nudge into the model's context.",
      "",
      "No filesystem state. No environment variables. The server owns all mappings. Concurrency-safe — each subagent has a unique `agent_id` assigned by Claude Code.",
      "",
      "**Timing note:** The PostToolUse hook may fire before the subagent has called `room_join` (e.g., during initial tool calls). This is harmless — unknown agents receive a 404 response and the hook exits silently.",
      "",
      "**Setup:** Run `just install-hooks` to install the hook scripts into `~/.claude/settings.json`. The PostToolUse hook defaults to port 9961 (override via `NEURAL_LINK_PORT` env var).",
      "",
      "### REST endpoints",
      "",
      "- `GET /inbox/:participant_id/count` — Pending message count by participant. Returns `{\"total\": N, \"rooms\": {\"room_id\": count}}`. Returns 404 if participant not found.",
      "- `GET /agent/:agent_id/inbox/count` — Pending message count by Claude Code agent_id (used by PostToolUse hook). Resolves agent_id → participant_id via server-side mapping. Same response format. Returns 404 if agent not registered.",
      "- `GET /health` — Health check. Returns `{\"status\": \"ok\"}`.",
      "",
      "### Rules",
      "",
      "1. **Always acknowledge messages you have read.** Call `message_ack` after processing inbox messages. Unacknowledged messages reappear in your inbox.",
      "2. **One room per coordination concern.** Do not multiplex unrelated work into a single room.",
      "3. **Close rooms when done.** Always call `room_close` with a resolution (`completed`, `cancelled`, `superseded`, `failed`). Unclosed rooms leak state.",
      "4. **Send `handoff` then `room_leave` before returning.** Silent completion causes deadlocks.",
      "5. **Never ignore a `blocker`.** If you receive a blocker message, respond to it or escalate. Dropping blockers stalls the entire coordination.",
      "6. **Use `thread_id` in multi-topic rooms.** If a room covers multiple sub-topics, tag messages with a thread ID to keep conversations separable.",
      "7. **Do not use neural_link as a logging system.** Rooms are for agent-to-agent communication. Use brain records for persistence.",
      "8. **Do not send messages to yourself.** Use the appropriate persistence tool instead.",
      "9. **Do not poll `inbox_read` in a loop.** Read inbox after meaningful work or inbox nudges. Use `wait_for` only when fully blocked.",
      "10. **The lead persists the summary.** After `room_close`, the lead uses the structured extraction (decisions, open questions, blockers, artifact record ID) to compose and present a summary to the user.",
      "11. **Respond to `escalation` messages immediately.** The lead receives escalations when departing agents leave behind unresolved waits. Ignoring escalations deadlocks waiting agents.",
    ],
    "\n",
  )
}

fn generate_tools_doc() -> String {
  let tools = [
    #(
      "room_open",
      "Create a coordination room. The opener is auto-joined as the room's lead. The `brains` param configures persistence plugins for this room.",
      "title (required), participant_id (required), display_name (required), purpose, external_ref, tags, brains, interaction_mode",
    ),
    #(
      "room_join",
      "Join a room as a participant. Returns room_id, participant_id, joined, and interaction_mode (if set)",
      "room_id (required), participant_id (required), display_name (required), role, agent_id (enables PostToolUse inbox nudge)",
    ),
    #(
      "room_leave",
      "Leave a room with drain semantics. Blocks until outbound obligations clear or timeout. Lead cannot leave (use room_close)",
      "room_id (required), participant_id (required), timeout_ms",
    ),
    #(
      "message_send",
      "Send a typed message to a room",
      "room_id (required), from (required), kind (required: question|answer|finding|handoff|blocker|decision|review_request|review_result|artifact_ref|summary|challenge|proposal|escalation), summary (required), to, body, thread_id, persist_hint",
    ),
    #(
      "inbox_read",
      "Read your pending messages in a room",
      "room_id (required), participant_id (required)",
    ),
    #(
      "message_ack",
      "Acknowledge messages you have processed",
      "room_id (required), participant_id (required), message_ids (required)",
    ),
    #(
      "wait_for",
      "Block until a matching message arrives (long-poll)",
      "room_id (required), participant_id (required), since_sequence, kinds, from, timeout_ms",
    ),
    #(
      "thread_summarize",
      "Get structured coordination status (decisions, open questions, blockers) — read-only, no persistence",
      "room_id (required), thread_id",
    ),
    #(
      "room_close",
      "Close a room. Persists conversation via registered persistence plugins and returns structured extraction. If interaction_mode was set, also returns compliance data (expectations_checked, expectations_fulfilled, unchallenged_findings)",
      "room_id (required), resolution (required: completed|cancelled|superseded|failed)",
    ),
  ]

  list.map(tools, fn(tool) {
    let #(name, desc, params) = tool
    "- **`" <> name <> "`** — " <> desc <> ". Params: " <> params
  })
  |> string.join("\n")
}

@external(erlang, "neural_link_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "neural_link_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
