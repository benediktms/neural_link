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
  // TODO: replace this hash with something that makes sense
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
      "| **Lead** | The session that dispatches subagents | Opens the room before dispatch. Joins the room after dispatch. Monitors messages, answers questions, asks questions, unblocks agents. Closes the room when all work is done. Persists the summary. |",
      "| **Subagent** | Each dispatched agent | Joins the room on activation. Communicates findings, blockers, and questions. Reads inbox periodically. Sends `handoff` before returning. |",
      "",
      "### Coordination flow",
      "",
      "#### Lead (dispatcher)",
      "",
      "1. **Open a room** — call `room_open` with a descriptive `title` and `purpose` BEFORE dispatching any subagents. If working with brain-tracked projects, pass `brains` to enable artifact persistence on close.",
      "2. **Dispatch subagents** — include the `room_id` in every subagent's prompt along with the instruction to join the room and communicate.",
      "3. **Join the room** — after dispatching, the lead calls `room_join` to become a participant (use a stable identifier like `lead` or your session designation as `participant_id`).",
      "4. **Monitor and participate** — while subagents work, the lead periodically reads the room via `inbox_read`. Answer questions from subagents. Ask questions if something is unclear. Send `decision` messages to resolve ambiguities. Unblock agents that report `blocker` messages.",
      "5. **Close the room** — once all subagents have sent `handoff` and their work is complete, call `room_close` with a resolution. The server persists the full conversation as a brain artifact (if brains were declared) and returns structured extraction data: decisions, open questions, blockers, participant list, message count, and artifact record ID.",
      "6. **Persist and present** — use the structured extraction from `room_close` to compose a narrative summary for the user. The artifact record ID links to the full conversation for future reference.",
      "",
      "#### Subagent (participant)",
      "",
      "1. **Join** — on activation, if a `room_id` was provided in your prompt, call `room_join` with the room_id, your designation as `participant_id` and `display_name`, and role `member`.",
      "2. **Communicate** — send typed messages via `message_send` as you work. Share findings, flag blockers, ask questions. Use the appropriate message `kind` (see below).",
      "3. **Read inbox** — call `inbox_read` periodically (after completing logical units of work). Process and `message_ack` all messages promptly. If the lead or another subagent asks a question, answer it. If a blocker is raised that you can resolve, respond.",
      "4. **Wait when blocked** — if you cannot proceed until another agent provides something, use `wait_for` to block until the matching message arrives. Do not poll.",
      "5. **Handoff** — when your work is complete, send a `handoff` message summarizing what you accomplished and any open items. This is mandatory — silent completion causes deadlocks.",
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
      "",
      "### Waiting for other agents",
      "",
      "`wait_for` is a blocking call. Your tool call is held open on the server until a matching message arrives or the timeout expires (default: 30s, max: 120s). You are effectively paused.",
      "",
      "- **Use `wait_for` when you have nothing else to do** until a specific message arrives (e.g., waiting for a handoff, a review result, or an answer to your question)",
      "- **Do not use `wait_for` if you have other work to do** — use `inbox_read` periodically instead",
      "- **Filter precisely** — use the `kinds` and `from` params to match only what you need, avoiding false wakeups",
      "- **Set reasonable timeouts** — a stuck `wait_for` blocks you for up to 120 seconds",
      "",
      "### Tools reference",
      "",
      generate_tools_doc(),
      "",
      "### Rules",
      "",
      "1. **Always acknowledge messages you have read.** Call `message_ack` after processing inbox messages. Unacknowledged messages reappear in your inbox.",
      "2. **One room per coordination concern.** Do not multiplex unrelated work into a single room.",
      "3. **Close rooms when done.** Always call `room_close` with a resolution (`completed`, `cancelled`, `superseded`, `failed`). Unclosed rooms leak state.",
      "4. **Send `handoff` before returning.** If you are a subagent and your work is done, send a handoff message. Silent completion causes deadlocks.",
      "5. **Never ignore a `blocker`.** If you receive a blocker message, respond to it or escalate. Dropping blockers stalls the entire coordination.",
      "6. **Use `thread_id` in multi-topic rooms.** If a room covers multiple sub-topics, tag messages with a thread ID to keep conversations separable.",
      "7. **Do not use neural_link as a logging system.** Rooms are for agent-to-agent communication. Use brain records for persistence.",
      "8. **Do not send messages to yourself.** Use the appropriate persistence tool instead.",
      "9. **Do not poll `inbox_read` in a loop.** Use `wait_for` to block until a message arrives. Polling wastes resources.",
      "10. **The lead persists the summary.** After `room_close`, the lead uses the structured extraction (decisions, open questions, blockers, artifact record ID) to compose and present a summary to the user.",
    ],
    "\n",
  )
}

fn generate_tools_doc() -> String {
  let tools = [
    #(
      "room_open",
      "Create a coordination room",
      "title (required), purpose, external_ref, tags, brains",
    ),
    #(
      "room_join",
      "Join a room as a participant",
      "room_id (required), participant_id (required), display_name (required), role",
    ),
    #(
      "message_send",
      "Send a typed message to a room",
      "room_id (required), from (required), kind (required), summary (required), to, body, thread_id, persist_hint",
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
      "Close a room. Persists full conversation as brain artifact, returns structured extraction",
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
