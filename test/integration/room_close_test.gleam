import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import neural_link/mcp/handlers
import neural_link/mcp/tools
import neural_link/mcp/transport/http as http_transport
import neural_link/persistence/brain
import neural_link/persistence/config
import neural_link/persistence/database
import neural_link/persistence/plugin
import neural_link/runtime/supervisor
import persistence/brain_client_mock

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@external(erlang, "neural_link_http_test_ffi", "http_post")
fn http_post(
  url: String,
  body: String,
  headers: List(#(String, String)),
) -> Result(#(Int, String, List(#(String, String))), String)

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

fn erlang_abs(n: Int) -> Int {
  case n < 0 {
    True -> -n
    False -> n
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

fn extract_json_string(body: String, key: String) -> Result(String, String) {
  let pattern = "\\\"" <> key <> "\\\":\\\""
  case string.split(body, pattern) {
    [_, rest, ..] ->
      case string.split(rest, "\\\"") {
        [value, ..] -> Ok(value)
        _ -> Error("key not found")
      }
    _ -> Error("key not found")
  }
}

// ---------------------------------------------------------------------------
// Test server with mock BrainClient
// ---------------------------------------------------------------------------

fn start_test_server_with_mock() -> #(
  Int,
  Subject(brain_client_mock.MockMessage),
) {
  let port = 30_000 + erlang_abs(erlang_unique_integer()) % 1000
  let assert Ok(services) = supervisor.start_with_database(database.Memory)
  let assert Ok(mock_started) = brain_client_mock.start_mock_actor()
  let mock_subject = brain_client_mock.mock_actor_subject(mock_started)

  let plugin_resolver = fn(cfg: config.PersistencePluginConfig) -> option.Option(
    plugin.PersistencePlugin,
  ) {
    case cfg {
      config.BrainPlugin(brain_name: _) -> {
        option.Some(brain.brain_plugin_with_client(
          "test-brain",
          brain_client_mock.new_mock_client(mock_subject),
        ))
      }
      _ -> option.None
    }
  }

  let handler =
    handlers.make_handler_for_testing(
      handlers.HandlerConfig(
        registry: services.registry,
        inbox: services.inbox,
        presence: services.presence,
        store: services.store,
      ),
      plugin_resolver,
    )

  let assert Ok(_) =
    http_transport.start_server(
      tools.all_tools(),
      handler,
      port,
      services.registry,
      services.presence,
    )
  process.sleep(1000)
  #(port, mock_subject)
}

fn make_session(url: String) -> String {
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  case retry_session_http(url, body, [], 5) {
    Ok(#(200, _, headers)) -> {
      let assert Ok(sid) = find_header(headers, "mcp-session-id")
      sid
    }
    Ok(#(code, resp, _)) -> {
      let message = "make_session HTTP " <> int.to_string(code) <> ": " <> resp
      panic as message
    }
    Error(e) -> {
      let message = "make_session connection error: " <> e
      panic as message
    }
  }
}

fn retry_session_http(
  url: String,
  body: String,
  headers: List(#(String, String)),
  attempts: Int,
) -> Result(#(Int, String, List(#(String, String))), String) {
  case http_post(url, body, headers) {
    Ok(#(200, _, _)) as r -> r
    Ok(#(0, _, _)) -> {
      case attempts {
        0 -> http_post(url, body, headers)
        _ -> {
          process.sleep(200)
          retry_session_http(url, body, headers, attempts - 1)
        }
      }
    }
    other -> other
  }
}

fn room_open(
  url: String,
  sid: String,
  title: String,
  brains: String,
) -> Result(String, String) {
  let h = [#("mcp-session-id", sid)]
  let args = case brains {
    "" ->
      "{\"title\":\""
      <> title
      <> "\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}"
    _ ->
      "{\"title\":\""
      <> title
      <> "\",\"participant_id\":\"lead\",\"display_name\":\"Lead\",\"brains\":\""
      <> brains
      <> "\"}"
  }
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":"
    <> args
    <> "}}"
  case http_post(url, body, h) {
    Ok(#(200, resp, _)) -> extract_json_string(resp, "room_id")
    Ok(#(code, resp, _)) ->
      Error("room_open failed: " <> int.to_string(code) <> " " <> resp)
    Error(e) -> Error(e)
  }
}

fn room_join(
  url: String,
  sid: String,
  room_id: String,
  participant_id: String,
  display_name: String,
) -> Result(Nil, String) {
  let h = [#("mcp-session-id", sid)]
  let args =
    "{\"room_id\":\""
    <> room_id
    <> "\",\"participant_id\":\""
    <> participant_id
    <> "\",\"display_name\":\""
    <> display_name
    <> "\"}"
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"room_join\",\"arguments\":"
    <> args
    <> "}}"
  case http_post(url, body, h) {
    Ok(#(200, _, _)) -> Ok(Nil)
    Ok(#(code, resp, _)) ->
      Error("room_join failed: " <> int.to_string(code) <> " " <> resp)
    Error(e) -> Error(e)
  }
}

fn message_send(
  url: String,
  sid: String,
  room_id: String,
  from: String,
  kind: String,
  summary: String,
) -> Result(String, String) {
  let h = [#("mcp-session-id", sid)]
  let args =
    "{\"room_id\":\""
    <> room_id
    <> "\",\"from\":\""
    <> from
    <> "\",\"kind\":\""
    <> kind
    <> "\",\"summary\":\""
    <> summary
    <> "\"}"
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"message_send\",\"arguments\":"
    <> args
    <> "}}"
  case http_post(url, body, h) {
    Ok(#(200, resp, _)) -> extract_json_string(resp, "message_id")
    Ok(#(code, resp, _)) ->
      Error("message_send failed: " <> int.to_string(code) <> " " <> resp)
    Error(e) -> Error(e)
  }
}

fn room_close(
  url: String,
  sid: String,
  room_id: String,
  resolution: String,
) -> Result(String, String) {
  let h = [#("mcp-session-id", sid)]
  let args =
    "{\"room_id\":\""
    <> room_id
    <> "\",\"resolution\":\""
    <> resolution
    <> "\"}"
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"room_close\",\"arguments\":"
    <> args
    <> "}}"
  case http_post(url, body, h) {
    Ok(#(200, resp, _)) -> Ok(resp)
    Ok(#(code, resp, _)) ->
      Error("room_close failed: " <> int.to_string(code) <> " " <> resp)
    Error(e) -> Error(e)
  }
}

// ---------------------------------------------------------------------------
// Tests: room_close with mock BrainPlugin
// ---------------------------------------------------------------------------

pub fn room_close_with_brain_plugin_calls_notify_room_open_test() {
  let #(port, mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(_room_id) = room_open(url, sid, "Test Room", "test-brain")
  process.sleep(100)

  let calls = brain_client_mock.get_calls(mock_subject)
  let found =
    list.any(calls, fn(c) {
      case c {
        brain_client_mock.SaveSnapshotCall(_, title, _, tags) ->
          title == "Room opened: Test Room" && list.contains(tags, "room-open")
        _ -> False
      }
    })
  found |> should.be_true
}

pub fn room_close_with_brain_plugin_calls_notify_message_for_durable_kind_test() {
  let #(port, mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "Msg Room", "test-brain")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(url, sid, room_id, "agent-a", "decision", "We should do X")
  process.sleep(100)

  let calls = brain_client_mock.get_calls(mock_subject)
  let found =
    list.any(calls, fn(c) {
      case c {
        brain_client_mock.SaveSnapshotCall(_, title, _, tags) ->
          title == "[decision] We should do X"
          && list.contains(tags, "decision")
        _ -> False
      }
    })
  found |> should.be_true
}

pub fn room_close_with_brain_plugin_skips_non_durable_kind_test() {
  let #(port, mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "Ephemeral Room", "test-brain")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(url, sid, room_id, "agent-a", "question", "What's the status?")
  process.sleep(100)

  let calls = brain_client_mock.get_calls(mock_subject)
  let found =
    list.any(calls, fn(c) {
      case c {
        brain_client_mock.SaveSnapshotCall(_, title, _, _) ->
          string.contains(title, "question")
        _ -> False
      }
    })
  found |> should.be_false
}

pub fn room_close_with_brain_plugin_returns_artifact_record_id_test() {
  let #(port, _mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "Artifact Room", "test-brain")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(url, sid, room_id, "agent-a", "decision", "Final decision")
  let assert Ok(resp) = room_close(url, sid, room_id, "completed")

  let assert Ok(record_id) = extract_json_string(resp, "artifact_record_id")
  record_id |> should.equal("")
}

pub fn room_close_with_brain_plugin_calls_notify_conversation_artifact_test() {
  let #(port, mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "Conv Room", "test-brain")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(url, sid, room_id, "agent-a", "finding", "Found an issue")
  brain_client_mock.reset_mock(mock_subject)
  let assert Ok(_) = room_close(url, sid, room_id, "completed")
  process.sleep(100)

  let calls = brain_client_mock.get_calls(mock_subject)
  let found =
    list.any(calls, fn(c) {
      case c {
        brain_client_mock.CreateArtifactCall(_, title, _, "conversation", _) ->
          title == "Conversation: Conv Room"
        _ -> False
      }
    })
  found |> should.be_true
}

pub fn room_close_with_brain_plugin_calls_notify_room_close_metadata_test() {
  let #(port, mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "Meta Room", "test-brain")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(url, sid, room_id, "agent-a", "decision", "A decision")
  brain_client_mock.reset_mock(mock_subject)
  let assert Ok(_) = room_close(url, sid, room_id, "completed")
  process.sleep(100)

  let calls = brain_client_mock.get_calls(mock_subject)
  let found =
    list.any(calls, fn(c) {
      case c {
        brain_client_mock.SaveSnapshotCall(_, title, _, tags) ->
          title == "Room closed: Meta Room" && list.contains(tags, "room-close")
        _ -> False
      }
    })
  found |> should.be_true
}

pub fn room_close_with_brain_plugin_summary_kind_creates_artifact_test() {
  let #(port, mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "Summary Room", "test-brain")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(url, sid, room_id, "agent-a", "summary", "Weekly summary here")
  process.sleep(100)

  let calls = brain_client_mock.get_calls(mock_subject)
  let found =
    list.any(calls, fn(c) {
      case c {
        brain_client_mock.CreateArtifactCall(_, title, _, "summary", _) ->
          title == "[summary] Weekly summary here"
        _ -> False
      }
    })
  found |> should.be_true
}

pub fn room_close_cancelled_resolution_stored_correctly_test() {
  let #(port, _mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "Cancel Room", "test-brain")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(url, sid, room_id, "agent-a", "decision", "Going nowhere")
  let assert Ok(resp) = room_close(url, sid, room_id, "cancelled")

  extract_json_string(resp, "status") |> should.equal(Ok("closed"))
}

pub fn room_close_no_brains_param_no_plugin_calls_test() {
  let #(port, mock_subject) = start_test_server_with_mock()
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)

  let assert Ok(room_id) = room_open(url, sid, "No Brain Room", "")
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")
  let assert Ok(_) =
    message_send(
      url,
      sid,
      room_id,
      "agent-a",
      "decision",
      "Decision without brain",
    )
  brain_client_mock.reset_mock(mock_subject)
  let assert Ok(_) = room_close(url, sid, room_id, "completed")
  process.sleep(100)

  let calls = brain_client_mock.get_calls(mock_subject)
  calls |> should.equal([])
}

pub fn debug_mock_actor_alone_test() {
  let assert Ok(mock_started) = brain_client_mock.start_mock_actor()
  let mock_subject = brain_client_mock.mock_actor_subject(mock_started)
  let calls = brain_client_mock.get_calls(mock_subject)
  // Just verify the mock actor works
  list.length(calls) |> should.equal(0)
}

pub fn debug_http_with_mock_actor_test() {
  let port = 30_000 + erlang_abs(erlang_unique_integer()) % 1000
  let assert Ok(services) = supervisor.start_with_database(database.Memory)
  let assert Ok(mock_started) = brain_client_mock.start_mock_actor()
  let mock_subject = brain_client_mock.mock_actor_subject(mock_started)

  let plugin_resolver = fn(cfg: config.PersistencePluginConfig) -> option.Option(
    plugin.PersistencePlugin,
  ) {
    case cfg {
      config.BrainPlugin(brain_name: _) -> {
        option.Some(brain.brain_plugin_with_client(
          "test-brain",
          brain_client_mock.new_mock_client(mock_subject),
        ))
      }
      _ -> option.None
    }
  }

  let handler =
    handlers.make_handler_for_testing(
      handlers.HandlerConfig(
        registry: services.registry,
        inbox: services.inbox,
        presence: services.presence,
        store: services.store,
      ),
      plugin_resolver,
    )
  let assert Ok(_) =
    http_transport.start_server(
      tools.all_tools(),
      handler,
      port,
      services.registry,
      services.presence,
    )
  process.sleep(1000)

  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  case http_post(url, body, []) {
    Ok(#(code, resp, hdrs)) -> {
      let has_body = string.length(resp) > 0
      let has_headers = hdrs != []
      code |> should.equal(200)
      has_body |> should.be_true
      has_headers |> should.be_true
    }
    Error(e) -> {
      let message = "Connection error: " <> e
      panic as message
    }
  }
}
