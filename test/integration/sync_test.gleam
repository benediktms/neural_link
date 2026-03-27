import birl
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import neural_link/cli/sync
import neural_link/domain/id
import neural_link/domain/message
import neural_link/domain/room
import neural_link/persistence/sqlite
import neural_link/persistence/sync_log
import persistence/brain_client_mock
import simplifile

fn cleanup(path: String) {
  case simplifile.delete(file_or_dir_at: path) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

fn test_db_path() -> String {
  "/tmp/" <> id.generate("sync_e2e_test_") <> ".db"
}

fn test_log_path() -> String {
  "/tmp/" <> id.generate("sync_e2e_test_") <> ".jsonl"
}

fn with_store_and_log(f: fn(sqlite.SqliteStore, String) -> Nil) {
  let db_path = test_db_path()
  let log_path = test_log_path()
  cleanup(db_path)
  cleanup(log_path)

  let assert Ok(store) = sqlite.open(db_path)
  f(store, log_path)
  sqlite.close(store)

  cleanup(db_path)
  cleanup(log_path)
}

fn make_message(
  message_id: String,
  room_id: String,
  sequence: Int,
  summary: String,
) -> message.Message {
  message.Message(
    message_id: id.MessageId(message_id),
    room_id: id.RoomId(room_id),
    thread_id: None,
    from: id.ParticipantId("participant-1"),
    to: [],
    kind: message.Summary,
    created_at: birl.utc_now(),
    sequence: sequence,
    requires_ack: False,
    persist_hint: message.Durable,
    references: [],
    summary: summary,
    body: Some("Body " <> int.to_string(sequence)),
  )
}

fn insert_test_closed_room(
  store: sqlite.SqliteStore,
  room_id: String,
  title: String,
) -> Nil {
  let open_room = room.new(room_id, title)
  let assert Ok(_) = sqlite.insert_room(store, open_room)

  let assert Ok(_) =
    sqlite.insert_participant(
      store,
      room_id,
      "participant-1",
      "Participant 1",
      "member",
      birl.to_iso8601(birl.utc_now()),
    )

  let assert Ok(_) =
    sqlite.insert_message(
      store,
      make_message(id.generate("msg_"), room_id, 1, "First summary"),
    )
  let assert Ok(_) =
    sqlite.insert_message(
      store,
      make_message(id.generate("msg_"), room_id, 2, "Second summary"),
    )

  let closed_room = room.close_with_resolution(open_room, room.Completed)
  let assert Ok(_) = sqlite.update_room_close(store, closed_room, 2, 0)
  Nil
}

pub fn sync_pushes_closed_room_test() {
  with_store_and_log(fn(store, log_path) {
    let room_id = "room_sync_pushes"
    let title = "Sync E2E Room"
    insert_test_closed_room(store, room_id, title)

    let assert Ok(started) = brain_client_mock.start_mock_actor()
    let subject = brain_client_mock.mock_actor_subject(started)
    let client = brain_client_mock.new_mock_client(subject)

    let result = sync.sync_rooms(store, log_path, client)
    result
    |> should.equal(sync.SyncResult(
      total_closed_rooms: 1,
      already_synced: 0,
      synced: 1,
      failed: 0,
    ))

    let calls = brain_client_mock.get_calls(subject)
    list.length(calls) |> should.equal(1)

    case calls {
      [brain_client_mock.CreateArtifactCall(_, call_title, content, kind, tags)] -> {
        call_title |> should.equal("Room: " <> title)
        kind |> should.equal("conversation")
        list.contains(tags, room_id) |> should.be_true
        string.contains(content, "# Room: " <> title) |> should.be_true
        string.contains(content, "First summary") |> should.be_true
        string.contains(content, "Second summary") |> should.be_true
      }
      _ -> panic as "expected exactly one CreateArtifactCall"
    }

    sync_log.is_synced(log_path, room_id) |> should.be_true
    let entries = sync_log.list_synced(log_path)
    list.length(entries) |> should.equal(1)

    case simplifile.read(from: log_path) {
      Ok(contents) -> string.contains(contents, room_id) |> should.be_true
      Error(_) -> panic as "expected sync log file to exist"
    }
  })
}

pub fn sync_idempotent_test() {
  with_store_and_log(fn(store, log_path) {
    let room_id = "room_sync_idempotent"
    let title = "Sync Idempotent Room"
    insert_test_closed_room(store, room_id, title)

    let assert Ok(started) = brain_client_mock.start_mock_actor()
    let subject = brain_client_mock.mock_actor_subject(started)
    let client = brain_client_mock.new_mock_client(subject)

    let first_result = sync.sync_rooms(store, log_path, client)
    first_result
    |> should.equal(sync.SyncResult(
      total_closed_rooms: 1,
      already_synced: 0,
      synced: 1,
      failed: 0,
    ))

    let second_result = sync.sync_rooms(store, log_path, client)
    second_result
    |> should.equal(sync.SyncResult(
      total_closed_rooms: 1,
      already_synced: 1,
      synced: 0,
      failed: 0,
    ))

    let calls = brain_client_mock.get_calls(subject)
    list.length(calls) |> should.equal(1)

    let entries = sync_log.list_synced(log_path)
    list.length(entries) |> should.equal(1)
    sync_log.is_synced(log_path, room_id) |> should.be_true
  })
}
