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
  let tools_doc = generate_tools_doc()
  string.join(
    [
      "## neural_link",
      "",
      "Multi-agent coordination service. Provides rooms, messaging, inbox, and wait semantics for AI agent coordination via MCP.",
      "",
      "### Connection",
      "",
      "neural_link exposes an MCP server. Connect via:",
      "- **HTTP**: `POST http://localhost:8080/mcp` (default, multi-session)",
      "- **stdio**: Set `NEURAL_LINK_TRANSPORT=stdio` (single-session, for testing)",
      "",
      "All requests use JSON-RPC 2.0. After `initialize`, include the `Mcp-Session-Id` header from the response.",
      "",
      "### Commands",
      "",
      "```bash",
      "nlk start              # Start server (daemonized, port 8080)",
      "nlk start --foreground # Start in foreground",
      "nlk stop               # Stop the server",
      "nlk docs [path]        # Upsert this section into AGENTS.md",
      "nlk version            # Print version",
      "```",
      "",
      "### Environment Variables",
      "",
      "| Variable | Default | Description |",
      "|----------|---------|-------------|",
      "| `NEURAL_LINK_PORT` | `8080` | HTTP server port |",
      "| `NEURAL_LINK_TRANSPORT` | `http` | Transport: `http` or `stdio` |",
      "",
      "### MCP Tools",
      "",
      tools_doc,
      "",
      "### Workflow",
      "",
      "1. `room_open` — create a coordination room",
      "2. `room_join` — add participants (agents) to the room",
      "3. `message_send` — send typed messages (question, answer, finding, handoff, blocker, decision, review_request, review_result, artifact_ref, summary)",
      "4. `inbox_read` — read pending messages for a participant",
      "5. `message_ack` — acknowledge received messages",
      "6. `wait_for` — block until a matching message arrives (supports filtering by kind and sender)",
      "7. `thread_summarize` — get a summary of messages in a room or thread",
      "8. `room_close` — close the room with a resolution (completed, cancelled, superseded, failed)",
    ],
    "\n",
  )
}

fn generate_tools_doc() -> String {
  let tools = [
    #(
      "room_open",
      "Create a coordination room",
      "title (required), purpose, external_ref, tags",
    ),
    #(
      "room_join",
      "Add a participant to a room",
      "room_id (required), participant_id (required), display_name (required), role",
    ),
    #(
      "message_send",
      "Send a typed message",
      "room_id (required), from (required), kind (required), summary (required), to, body, thread_id",
    ),
    #(
      "inbox_read",
      "Read a participant's inbox",
      "room_id (required), participant_id (required)",
    ),
    #(
      "message_ack",
      "Acknowledge messages",
      "room_id (required), participant_id (required), message_ids (required)",
    ),
    #(
      "wait_for",
      "Block until matching message arrives",
      "room_id (required), participant_id (required), since_sequence, kinds, from, timeout_ms",
    ),
    #(
      "thread_summarize",
      "Summarize messages in a room/thread",
      "room_id (required), thread_id",
    ),
    #("room_close", "Close a room", "room_id (required), resolution (required)"),
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
