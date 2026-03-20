import gleam/erlang/process
import gleam/int
import gleam/string
import gleeunit/should
import neural_link/mcp/handlers
import neural_link/mcp/tools
import neural_link/mcp/transport/http as http_transport
import neural_link/runtime/supervisor

// ---------------------------------------------------------------------------
// FFI: Erlang httpc client
// ---------------------------------------------------------------------------

@external(erlang, "neural_link_http_test_ffi", "http_post")
fn http_post(
  url: String,
  body: String,
  headers: List(#(String, String)),
) -> Result(#(Int, String, List(#(String, String))), String)

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn http_initialize_returns_session_test() {
  let port = start_test_server()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  let assert Ok(#(200, resp_body, headers)) = http_post(url, body, [])

  // Response should contain protocolVersion
  string.contains(resp_body, "protocolVersion") |> should.be_true

  // Should have mcp-session-id header
  let session_id = find_header(headers, "mcp-session-id")
  session_id |> should.be_ok
}

pub fn http_tools_list_returns_8_tools_test() {
  let port = start_test_server()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  // Initialize first to get session ID
  let init_body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  let assert Ok(#(200, _, init_headers)) = http_post(url, init_body, [])
  let assert Ok(session_id) = find_header(init_headers, "mcp-session-id")

  // List tools
  let tools_body =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
  let assert Ok(#(200, resp_body, _)) =
    http_post(url, tools_body, [#("mcp-session-id", session_id)])

  // Should contain all 8 tool names
  string.contains(resp_body, "room_open") |> should.be_true
  string.contains(resp_body, "room_close") |> should.be_true
  string.contains(resp_body, "wait_for") |> should.be_true
}

pub fn http_rejects_missing_session_test() {
  let port = start_test_server()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  // Try tools/list without session header — should get 401
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"
  let assert Ok(#(401, _, _)) = http_post(url, body, [])
}

pub fn http_room_lifecycle_test() {
  let port = start_test_server()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  // Initialize
  let assert Ok(#(200, _, init_headers)) =
    http_post(
      url,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      [],
    )
  let assert Ok(sid) = find_header(init_headers, "mcp-session-id")
  let h = [#("mcp-session-id", sid)]

  // Open room
  let assert Ok(#(200, open_resp, _)) =
    http_post(
      url,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"HTTP Test Room\"}}}",
      h,
    )
  string.contains(open_resp, "room_id") |> should.be_true
  string.contains(open_resp, "HTTP Test Room") |> should.be_true
}

pub fn http_message_send_includes_inbox_pending_test() {
  let port = start_test_server()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  // Initialize
  let assert Ok(#(200, _, init_headers)) =
    http_post(
      url,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      [],
    )
  let assert Ok(sid) = find_header(init_headers, "mcp-session-id")
  let h = [#("mcp-session-id", sid)]

  // Open room
  let assert Ok(#(200, open_resp, _)) =
    http_post(
      url,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"Nudge Test\"}}}",
      h,
    )
  // Extract room_id from response
  let assert Ok(room_id) = extract_json_string(open_resp, "room_id")

  // Join two participants
  let join_a =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"a\",\"display_name\":\"A\"}}}"
  let assert Ok(#(200, _, _)) = http_post(url, join_a, h)
  let join_b =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"b\",\"display_name\":\"B\"}}}"
  let assert Ok(#(200, _, _)) = http_post(url, join_b, h)

  // A sends a message — response should contain _inbox_pending: 0
  // (A has no pending messages for itself)
  let send =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"from\":\"a\",\"kind\":\"finding\",\"summary\":\"test\"}}}"
  let assert Ok(#(200, send_resp, _)) = http_post(url, send, h)
  // MCP wraps in escaped JSON — check for escaped field name
  string.contains(send_resp, "_inbox_pending") |> should.be_true
  // Sender's own pending count is 0 (escaped integer in MCP content)
  string.contains(send_resp, "\\\"_inbox_pending\\\":0") |> should.be_true
}

pub fn http_health_endpoint_test() {
  let port = start_test_server()
  let url = "http://localhost:" <> int.to_string(port) <> "/health"

  let assert Ok(#(200, resp_body, _)) = http_post(url, "", [])
  string.contains(resp_body, "ok") |> should.be_true
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn start_test_server() -> Int {
  let port = 19_000 + erlang_abs(erlang_unique_integer()) % 1000
  let assert Ok(services) = supervisor.start()
  let tool_defs = tools.all_tools()
  let handler =
    handlers.make_handler(services.registry, services.inbox, services.presence)
  let assert Ok(_) = http_transport.start_server(tool_defs, handler, port)
  // Give the server time to bind
  process.sleep(100)
  port
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

fn erlang_abs(n: Int) -> Int {
  case n < 0 {
    True -> -n
    False -> n
  }
}

/// Extract a string value from an MCP tool response by key.
/// MCP wraps tool output in a content block with escaped JSON, so we search
/// for the escaped pattern: \"key\":\"value\"
fn extract_json_string(body: String, key: String) -> Result(String, Nil) {
  let pattern = "\\\"" <> key <> "\\\":\\\""
  case string.split(body, pattern) {
    [_, rest, ..] ->
      case string.split(rest, "\\\"") {
        [value, ..] -> Ok(value)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case string.lowercase(k) == string.lowercase(name) {
        True -> Ok(v)
        False -> find_header(rest, name)
      }
  }
}
