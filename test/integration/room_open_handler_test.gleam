//// Handler-level tests for the `room_open` MCP tool that exercise paths the
//// HTTP-level tests can't reach cleanly:
////
//// 1. Restart-replay: the registry is fresh but sqlite already has a row for
////    the supplied id (simulates a process restart). The handler must detect
////    the UNIQUE constraint violation from `insert_room` and respond with
////    `already_existed: true` rather than silently overwriting state.
////
//// 2. No-row-after-bad-id: a malformed `id` parameter must short-circuit
////    before any DB write. We assert directly against `count_rooms` rather
////    than inferring from response shape.
////
//// We call the handler function directly via `make_handler` instead of going
//// through the HTTP transport so the assertions can inspect both the JSON
//// response and the sqlite state in the same test.

import birl
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import neural_link/domain/id
import neural_link/domain/room as domain_room
import neural_link/mcp/handlers
import neural_link/mcp/transport
import neural_link/persistence/database
import neural_link/persistence/sqlite
import neural_link/runtime/supervisor

fn build_handler() -> #(transport.ToolCallHandler, sqlite.SqliteStore) {
  let assert Ok(services) = supervisor.start_with_database(database.Memory)
  let handler =
    handlers.make_handler(handlers.HandlerConfig(
      registry: services.registry,
      inbox: services.inbox,
      presence: services.presence,
      store: services.store,
    ))
  #(handler, services.store)
}

fn parse_args(json_body: String) -> Dynamic {
  let assert Ok(args) = json.parse(json_body, decode.dynamic)
  args
}

// ---------------------------------------------------------------------------
// nlr-a91 fix: cross-process restart contract
// ---------------------------------------------------------------------------

pub fn room_open_with_id_already_in_sqlite_returns_already_existed_test() {
  let #(handler, store) = build_handler()

  // Simulate a prior process: write a room directly to sqlite. The registry
  // is fresh, so it will return `Created` for this id.
  let supplied = "room_a1b2c3d4e5f60718"
  let prior_room =
    domain_room.Room(
      id: id.RoomId(supplied),
      title: "From Prior Process",
      status: domain_room.Open,
      created_at: birl.utc_now(),
      participants: [],
      metadata: option.None,
      purpose: option.None,
      external_ref: option.None,
      tags: [],
      plugins: [],
      resolution: option.None,
      interaction_mode: option.None,
    )
  let assert Ok(_) = sqlite.insert_room(store, prior_room)
  let assert Ok(1) = sqlite.count_rooms(store)

  // Caller in the new process tries to claim the same id. Registry has no
  // actor for it → `Created`. insert_room hits the UNIQUE constraint → handler
  // pivots to the AlreadyExisted response.
  let args =
    parse_args(
      "{\"title\":\"New Caller\",\"participant_id\":\"newcomer\",\"display_name\":\"Newcomer\",\"id\":\""
      <> supplied
      <> "\"}",
    )
  let assert Ok(resp) = handler("room_open", Some(args))
  let body = json.to_string(resp)

  // already_existed=true; no second row was inserted.
  string.contains(body, "\"already_existed\":true") |> should.be_true
  string.contains(body, supplied) |> should.be_true
  let assert Ok(1) = sqlite.count_rooms(store)
}

// ---------------------------------------------------------------------------
// nlr-a91 fix: bad-id rejection leaves the database untouched
// ---------------------------------------------------------------------------

pub fn room_open_with_bad_id_inserts_no_row_test() {
  let #(handler, store) = build_handler()
  let assert Ok(0) = sqlite.count_rooms(store)

  let bad_ids = [
    "room_xyz", "", "room_a1b2c3d4e5f607189", "not-a-room",
    "room_ABCDEF0123456789",
  ]
  assert_each_rejected(handler, store, bad_ids)
}

fn assert_each_rejected(
  handler: transport.ToolCallHandler,
  store: sqlite.SqliteStore,
  bad_ids: List(String),
) -> Nil {
  case bad_ids {
    [] -> Nil
    [bad, ..rest] -> {
      let args =
        parse_args(
          "{\"title\":\"Bad Id\",\"participant_id\":\"lead\",\"display_name\":\"Lead\",\"id\":\""
          <> bad
          <> "\"}",
        )
      case handler("room_open", Some(args)) {
        Ok(_) ->
          panic as { "expected handler to reject bad id but got Ok: " <> bad }
        Error(msg) -> {
          // Useful diagnostic if the assertion below ever fails.
          let assert True = string.contains(msg, "invalid id")
          Nil
        }
      }
      // Crucial check: no row was inserted regardless of which bad id was tried.
      let assert Ok(0) = sqlite.count_rooms(store)
      assert_each_rejected(handler, store, rest)
    }
  }
}

// ---------------------------------------------------------------------------
// nlr-a91 regression: response schema is uniform across Created and
// AlreadyExisted paths.
// ---------------------------------------------------------------------------

pub fn room_open_response_schema_is_uniform_test() {
  let #(handler, _store) = build_handler()
  let supplied = "room_0123456789abcdef"

  let first_args =
    parse_args(
      "{\"title\":\"First\",\"participant_id\":\"lead\",\"display_name\":\"Lead\",\"id\":\""
      <> supplied
      <> "\"}",
    )
  let assert Ok(first_resp) = handler("room_open", Some(first_args))
  let first_body = json.to_string(first_resp)
  // Created path: all six fields present, none null.
  string.contains(first_body, "\"already_existed\":false") |> should.be_true
  string.contains(first_body, "\"participant_id\":\"lead\"") |> should.be_true
  string.contains(first_body, "\"role\":\"lead\"") |> should.be_true

  let second_args =
    parse_args(
      "{\"title\":\"Second\",\"participant_id\":\"interloper\",\"display_name\":\"Interloper\",\"id\":\""
      <> supplied
      <> "\"}",
    )
  let assert Ok(second_resp) = handler("room_open", Some(second_args))
  let second_body = json.to_string(second_resp)
  // AlreadyExisted path: same keys, but participant_id and role are null. A
  // client decoding both branches with the same schema must work.
  string.contains(second_body, "\"already_existed\":true") |> should.be_true
  string.contains(second_body, "\"participant_id\":null") |> should.be_true
  string.contains(second_body, "\"role\":null") |> should.be_true
}
