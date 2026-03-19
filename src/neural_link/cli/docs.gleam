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
      "neural_link provides coordination between agents working on related tasks.",
      "It is available as an MCP server — all tools below are MCP tool calls.",
      "",
      "### When to use neural_link",
      "",
      "Use neural_link when multiple agents are dispatched and their work is related or overlapping:",
      "",
      "- **Partitioned work on shared files** — agents analyzing, reviewing, or modifying files that may affect each other",
      "- **Sequential handoffs** — one agent's output is another agent's input",
      "- **Parallel work with shared context** — agents need to share findings, flag blockers, or agree on decisions",
      "- **Review workflows** — an agent requests review from another agent",
      "",
      "Do NOT use neural_link for fully independent parallel tasks where agents have no interaction.",
      "",
      "### Coordination flow",
      "",
      "1. **Open a room** — one agent creates a room for the coordination concern (`room_open`)",
      "2. **Join** — each participating agent joins the room (`room_join`)",
      "3. **Communicate** — agents exchange typed messages (`message_send`)",
      "4. **Read and acknowledge** — agents read their inbox (`inbox_read`) and acknowledge messages (`message_ack`)",
      "5. **Wait when blocked** — if an agent needs another agent's output before continuing, it blocks with `wait_for`",
      "6. **Check status mid-flight** — use `thread_summarize` to see decisions, open questions, and blockers without closing the room",
      "7. **Close** — when coordination is complete, close the room with a resolution (`room_close`). If brains were declared on `room_open`, the server persists the full conversation as a brain artifact. Returns structured extraction data (decisions, open questions, blockers, participant list, message count, artifact record ID).",
      "8. **Present the summary** — the orchestrating agent uses the structured extraction from `room_close` (decisions, open questions, blockers, artifact record ID) to compose a narrative summary for the user.",
      "",
      "### Message kinds",
      "",
      "Every message has a `kind` that signals its intent. Use the right kind — other agents filter on it.",
      "",
      "| Kind | When to use |",
      "|------|-------------|",
      "| `finding` | You discovered something another agent needs to know |",
      "| `handoff` | Your part is done — another agent should take over |",
      "| `blocker` | You cannot proceed until something is resolved |",
      "| `decision` | Recording a choice that affects other agents |",
      "| `question` | Asking another agent for information |",
      "| `answer` | Responding to a question |",
      "| `review_request` | Asking another agent to review your work |",
      "| `review_result` | Delivering review feedback |",
      "| `artifact_ref` | Pointing to a file, commit, or output another agent should consume |",
      "| `summary` | Summarizing progress or conclusions |",
      "",
      "### Waiting for other agents",
      "",
      "`wait_for` is a blocking call. When you call it, your tool call is held open on the server until a matching message arrives or the timeout expires (default: 30s, max: 120s). You are effectively paused.",
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
      "1. **Always acknowledge messages you have read.** Call `message_ack` after processing inbox messages. This prevents your inbox from growing unbounded and signals to the sender that you received the message.",
      "2. **One room per coordination concern.** Do not multiplex unrelated work into a single room.",
      "3. **Close rooms when done.** Always call `room_close` with a resolution (`completed`, `cancelled`, `superseded`, `failed`). Unclosed rooms leak state.",
      "4. **Send `handoff` before going idle.** If you are done with your part and another agent is waiting, send a handoff message. Silent completion causes deadlocks.",
      "5. **Never ignore a `blocker`.** If you receive a blocker message, respond to it or escalate. Dropping blockers stalls the coordination.",
      "6. **Use `thread_id` in multi-topic rooms.** If a room covers multiple sub-topics, tag messages with a thread ID to keep conversations separable.",
      "7. **Do not use neural_link as a logging system.** Rooms are for agent-to-agent communication. Use brain records for persisting artifacts and findings.",
      "8. **Do not send messages to yourself.** If you need to record something, use the appropriate persistence tool, not a self-addressed message.",
      "9. **Do not poll `inbox_read` in a loop.** Use `wait_for` to block until a message arrives. Polling wastes resources.",
      "10. **The orchestrator presents the summary.** `room_close` returns structured extraction data (decisions, open questions, blockers, artifact record ID). The lead agent composes a narrative summary for the user from this data. The server does not generate the summary text.",
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
