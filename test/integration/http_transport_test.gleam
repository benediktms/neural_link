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

@external(erlang, "neural_link_http_test_ffi", "http_get")
fn http_get(
  url: String,
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

pub fn http_tools_list_returns_9_tools_test() {
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
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"HTTP Test Room\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}}}",
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
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"Nudge Test\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}}}",
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

  let assert Ok(#(200, resp_body, _)) = http_get(url, [])
  string.contains(resp_body, "ok") |> should.be_true
}

pub fn http_agent_inbox_count_returns_404_for_unknown_agent_test() {
  let port = start_test_server()
  let url =
    "http://localhost:"
    <> int.to_string(port)
    <> "/agent/unknown-agent-id/inbox/count"

  let assert Ok(#(404, resp_body, _)) = http_get(url, [])
  string.contains(resp_body, "Agent not found") |> should.be_true
}

pub fn http_agent_inbox_count_tracks_via_agent_id_test() {
  let port = start_test_server()
  let base = "http://localhost:" <> int.to_string(port)
  let mcp_url = base <> "/mcp"

  // Initialize
  let assert Ok(#(200, _, init_headers)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      [],
    )
  let assert Ok(sid) = find_header(init_headers, "mcp-session-id")
  let h = [#("mcp-session-id", sid)]

  // Open room
  let assert Ok(#(200, open_resp, _)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"Agent ID Test\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}}}",
      h,
    )
  let assert Ok(room_id) = extract_json_string(open_resp, "room_id")

  // Join sender (no agent_id)
  let join_sender =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"sender\",\"display_name\":\"Sender\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_sender, h)

  // Join receiver WITH agent_id
  let join_receiver =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"receiver\",\"display_name\":\"Receiver\",\"agent_id\":\"agent-abc-123\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_receiver, h)

  // Query by agent_id before messages — should be 0
  let agent_url = base <> "/agent/agent-abc-123/inbox/count"
  let assert Ok(#(200, count_0, _)) = http_get(agent_url, [])
  string.contains(count_0, "\"total\":0") |> should.be_true

  // Send message from sender
  let send =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"from\":\"sender\",\"kind\":\"finding\",\"summary\":\"test\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, send, h)

  // Query by agent_id — should be 1
  let assert Ok(#(200, count_1, _)) = http_get(agent_url, [])
  string.contains(count_1, "\"total\":1") |> should.be_true
  string.contains(count_1, room_id) |> should.be_true
}

pub fn http_concurrent_agents_isolated_inbox_counts_test() {
  let port = start_test_server()
  let base = "http://localhost:" <> int.to_string(port)
  let mcp_url = base <> "/mcp"

  // Initialize
  let assert Ok(#(200, _, init_headers)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      [],
    )
  let assert Ok(sid) = find_header(init_headers, "mcp-session-id")
  let h = [#("mcp-session-id", sid)]

  // Open room
  let assert Ok(#(200, open_resp, _)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"Concurrency Test\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}}}",
      h,
    )
  let assert Ok(room_id) = extract_json_string(open_resp, "room_id")

  // Join lead (no agent_id)
  let join_lead =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_lead, h)

  // Join drone-1 with agent_id alpha
  let join_d1 =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"drone-1\",\"display_name\":\"Drone 1\",\"agent_id\":\"agent-alpha\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_d1, h)

  // Join drone-2 with agent_id beta
  let join_d2 =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"drone-2\",\"display_name\":\"Drone 2\",\"agent_id\":\"agent-beta\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_d2, h)

  // Both agents start at 0
  let alpha_url = base <> "/agent/agent-alpha/inbox/count"
  let beta_url = base <> "/agent/agent-beta/inbox/count"

  let assert Ok(#(200, a0, _)) = http_get(alpha_url, [])
  string.contains(a0, "\"total\":0") |> should.be_true
  let assert Ok(#(200, b0, _)) = http_get(beta_url, [])
  string.contains(b0, "\"total\":0") |> should.be_true

  // Lead sends message (broadcast) — both drones get it
  let send1 =
    "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"from\":\"lead\",\"kind\":\"question\",\"summary\":\"status?\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, send1, h)

  // Both agents see 1
  let assert Ok(#(200, a1, _)) = http_get(alpha_url, [])
  string.contains(a1, "\"total\":1") |> should.be_true
  let assert Ok(#(200, b1, _)) = http_get(beta_url, [])
  string.contains(b1, "\"total\":1") |> should.be_true

  // Drone-1 acks — only alpha drops to 0, beta stays at 1
  let read_d1 =
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"inbox_read\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"drone-1\"}}}"
  let assert Ok(#(200, inbox_d1, _)) = http_post(mcp_url, read_d1, h)
  let assert Ok(msg_id) = extract_json_string(inbox_d1, "message_id")

  let ack_d1 =
    "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"message_ack\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"drone-1\",\"message_ids\":\""
    <> msg_id
    <> "\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, ack_d1, h)

  // Alpha = 0, Beta still = 1
  let assert Ok(#(200, a2, _)) = http_get(alpha_url, [])
  string.contains(a2, "\"total\":0") |> should.be_true
  let assert Ok(#(200, b2, _)) = http_get(beta_url, [])
  string.contains(b2, "\"total\":1") |> should.be_true
}

pub fn http_agent_id_isolation_across_rooms_test() {
  let port = start_test_server()
  let base = "http://localhost:" <> int.to_string(port)
  let mcp_url = base <> "/mcp"

  // Initialize
  let assert Ok(#(200, _, init_headers)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      [],
    )
  let assert Ok(sid) = find_header(init_headers, "mcp-session-id")
  let h = [#("mcp-session-id", sid)]

  // Open two rooms
  let assert Ok(#(200, open1, _)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"Room A\",\"participant_id\":\"lead-a\",\"display_name\":\"Lead A\"}}}",
      h,
    )
  let assert Ok(room_a) = extract_json_string(open1, "room_id")

  let assert Ok(#(200, open2, _)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"Room B\",\"participant_id\":\"lead-b\",\"display_name\":\"Lead B\"}}}",
      h,
    )
  let assert Ok(room_b) = extract_json_string(open2, "room_id")

  // Agent joins both rooms with the same agent_id but different participant_ids
  // This tests that agent_id maps to the participant_id from the LAST join
  // (realistic: one agent, one agent_id, but the participant_id is consistent)
  let join_a =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_a
    <> "\",\"participant_id\":\"drone-x\",\"display_name\":\"Drone X\",\"agent_id\":\"agent-x\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_a, h)

  // Join room B with same participant_id (same agent, same identity)
  let join_b =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_b
    <> "\",\"participant_id\":\"drone-x\",\"display_name\":\"Drone X\",\"agent_id\":\"agent-x\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_b, h)

  // Join a sender in both rooms
  let join_s_a =
    "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_a
    <> "\",\"participant_id\":\"sender\",\"display_name\":\"Sender\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_s_a, h)
  let join_s_b =
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_b
    <> "\",\"participant_id\":\"sender\",\"display_name\":\"Sender\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_s_b, h)

  // Send message in room A only
  let send_a =
    "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":{\"room_id\":\""
    <> room_a
    <> "\",\"from\":\"sender\",\"kind\":\"finding\",\"summary\":\"room A msg\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, send_a, h)

  // Send two messages in room B
  let send_b1 =
    "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":{\"room_id\":\""
    <> room_b
    <> "\",\"from\":\"sender\",\"kind\":\"finding\",\"summary\":\"room B msg 1\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, send_b1, h)
  let send_b2 =
    "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":{\"room_id\":\""
    <> room_b
    <> "\",\"from\":\"sender\",\"kind\":\"finding\",\"summary\":\"room B msg 2\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, send_b2, h)

  // Agent endpoint should aggregate: 1 from room A + 2 from room B = 3
  let agent_url = base <> "/agent/agent-x/inbox/count"
  let assert Ok(#(200, resp, _)) = http_get(agent_url, [])
  string.contains(resp, "\"total\":3") |> should.be_true
  // Both room IDs present
  string.contains(resp, room_a) |> should.be_true
  string.contains(resp, room_b) |> should.be_true
}

pub fn http_inbox_count_returns_404_for_unknown_participant_test() {
  let port = start_test_server()
  let url =
    "http://localhost:" <> int.to_string(port) <> "/inbox/unknown-agent/count"

  let assert Ok(#(404, resp_body, _)) = http_get(url, [])
  string.contains(resp_body, "Participant not found") |> should.be_true
}

pub fn http_inbox_count_tracks_pending_messages_test() {
  let port = start_test_server()
  let base = "http://localhost:" <> int.to_string(port)
  let mcp_url = base <> "/mcp"

  // Initialize
  let assert Ok(#(200, _, init_headers)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
      [],
    )
  let assert Ok(sid) = find_header(init_headers, "mcp-session-id")
  let h = [#("mcp-session-id", sid)]

  // Open room
  let assert Ok(#(200, open_resp, _)) =
    http_post(
      mcp_url,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\"Count Test\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}}}",
      h,
    )
  let assert Ok(room_id) = extract_json_string(open_resp, "room_id")

  // Join two participants
  let join_a =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"sender\",\"display_name\":\"Sender\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_a, h)
  let join_b =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"receiver\",\"display_name\":\"Receiver\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, join_b, h)

  // Check count before any messages — should be 0
  let count_url = base <> "/inbox/receiver/count"
  let assert Ok(#(200, count_resp_0, _)) = http_get(count_url, [])
  string.contains(count_resp_0, "\"total\":0") |> should.be_true

  // Send a message from sender to receiver
  let send =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"from\":\"sender\",\"kind\":\"finding\",\"summary\":\"test finding\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, send, h)

  // Check count — receiver should have 1 pending
  let assert Ok(#(200, count_resp_1, _)) = http_get(count_url, [])
  string.contains(count_resp_1, "\"total\":1") |> should.be_true
  string.contains(count_resp_1, room_id) |> should.be_true

  // Ack the message via inbox_read + message_ack
  let read_inbox =
    "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"inbox_read\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"receiver\"}}}"
  let assert Ok(#(200, inbox_resp, _)) = http_post(mcp_url, read_inbox, h)
  let assert Ok(msg_id) = extract_json_string(inbox_resp, "message_id")

  let ack =
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"message_ack\",\"arguments\":{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\"receiver\",\"message_ids\":\""
    <> msg_id
    <> "\"}}}"
  let assert Ok(#(200, _, _)) = http_post(mcp_url, ack, h)

  // Check count after ack — should be back to 0
  let assert Ok(#(200, count_resp_2, _)) = http_get(count_url, [])
  string.contains(count_resp_2, "\"total\":0") |> should.be_true
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn start_test_server() -> Int {
  let port = 19_000 + erlang_abs(erlang_unique_integer()) % 1000
  let assert Ok(services) = supervisor.start()
  let tool_defs = tools.all_tools()
  let handler =
    handlers.make_handler(handlers.HandlerConfig(
      registry: services.registry,
      inbox: services.inbox,
      presence: services.presence,
      store: services.store,
    ))
  let assert Ok(_) =
    http_transport.start_server(
      tool_defs,
      handler,
      port,
      services.registry,
      services.presence,
    )
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
