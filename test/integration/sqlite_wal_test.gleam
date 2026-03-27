import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import neural_link/mcp/handlers
import neural_link/mcp/tools
import neural_link/mcp/transport/http as http_transport
import neural_link/persistence/database
import neural_link/persistence/sqlite
import neural_link/runtime/supervisor
import sqlight

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

fn room_open(url: String, sid: String, title: String) -> Result(String, String) {
  let h = [#("mcp-session-id", sid)]
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"room_open\",\"arguments\":{\"title\":\""
    <> title
    <> "\",\"participant_id\":\"lead\",\"display_name\":\"Lead\"}}}"

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

pub fn full_room_lifecycle_sqlite_test() {
  let port = 31_000 + erlang_abs(erlang_unique_integer()) % 1000
  let assert Ok(services) = supervisor.start_with_database(database.Memory)

  let handler =
    handlers.make_handler(handlers.HandlerConfig(
      registry: services.registry,
      inbox: services.inbox,
      presence: services.presence,
      store: services.store,
    ))

  let assert Ok(_) =
    http_transport.start_server(
      tools.all_tools(),
      handler,
      port,
      services.registry,
      services.presence,
    )
  process.sleep(100)

  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"
  let sid = make_session(url)
  let title =
    "SQLite Lifecycle Test "
    <> int.to_string(erlang_abs(erlang_unique_integer()))

  let assert Ok(room_id) = room_open(url, sid, title)
  let assert Ok(Nil) = room_join(url, sid, room_id, "agent-a", "Agent A")

  let durable_summary = "durable decision"
  let nondurable_summary = "ephemeral question"
  let assert Ok(_decision_message_id) =
    message_send(url, sid, room_id, "agent-a", "decision", durable_summary)
  let assert Ok(_question_message_id) =
    message_send(url, sid, room_id, "agent-a", "question", nondurable_summary)

  let assert Ok(_close_resp) = room_close(url, sid, room_id, "completed")

  let store = services.store

  let assert Ok(closed_rooms) = sqlite.query_closed_rooms(store)
  let matching_rooms =
    list.filter(closed_rooms, fn(room) {
      let sqlite.ClosedRoom(id:, title: room_title, closed_at: _) = room
      id == room_id && room_title == title
    })
  list.length(matching_rooms) |> should.equal(1)

  let assert Ok(stored_messages) = sqlite.query_room_messages(store, room_id)
  list.length(stored_messages) |> should.equal(1)
  let assert [sqlite.StoredMessage(kind:, summary:, ..)] = stored_messages
  kind |> should.equal("decision")
  summary |> should.equal(durable_summary)

  let sqlite.SqliteStore(connection: conn) = store

  let assert Ok(artifact_counts) =
    sqlight.query(
      "SELECT COUNT(*) FROM conversation_artifacts WHERE room_id = ?",
      on: conn,
      with: [sqlight.text(room_id)],
      expecting: decode.at([0], decode.int),
    )
  artifact_counts |> should.equal([1])

  let assert Ok(participant_counts) =
    sqlight.query(
      "SELECT COUNT(*) FROM participants WHERE room_id = ?",
      on: conn,
      with: [sqlight.text(room_id)],
      expecting: decode.at([0], decode.int),
    )
  participant_counts |> should.equal([2])

  sqlite.close(store)
}
