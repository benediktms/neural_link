import birl
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import neural_link/brain/types
import neural_link/cli/sync
import neural_link/domain/id
import neural_link/domain/message
import neural_link/domain/room
import neural_link/persistence/brain
import neural_link/persistence/database
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
  "/tmp/" <> id.generate("sync_cli_test_") <> ".db"
}

fn test_log_path() -> String {
  "/tmp/" <> id.generate("sync_cli_log_") <> ".jsonl"
}

fn with_store_and_log(f: fn(sqlite.SqliteStore, String) -> Nil) {
  let db_path = test_db_path()
  let log_path = test_log_path()
  cleanup(db_path)
  cleanup(log_path)

  let assert Ok(store) = database.open(database.File(db_path))
  f(store, log_path)
  sqlite.close(store)

  cleanup(db_path)
  cleanup(log_path)
}

fn insert_closed_room(
  store: sqlite.SqliteStore,
  room_id: String,
  title: String,
) -> Nil {
  let open_room = room.new(room_id, title)
  let assert Ok(_) = sqlite.insert_room(store, open_room)
  let closed_room = room.close_with_resolution(open_room, room.Completed)
  let assert Ok(_) = sqlite.update_room_close(store, closed_room, 0, 0)
  Nil
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

fn insert_message(
  store: sqlite.SqliteStore,
  room_id: String,
  sequence: Int,
  summary: String,
) -> Nil {
  let message_id = id.generate("msg_")
  let assert Ok(_) =
    sqlite.insert_message(
      store,
      make_message(message_id, room_id, sequence, summary),
    )
  Nil
}

pub fn sync_pushes_unsynced_rooms_test() {
  with_store_and_log(fn(store, log_path) {
    insert_closed_room(store, "room_unsynced", "Unsynced Room")
    insert_message(store, "room_unsynced", 1, "Summary one")

    let assert Ok(started) = brain_client_mock.start_mock_actor()
    let subject = brain_client_mock.mock_actor_subject(started)
    let client = brain_client_mock.new_mock_client(subject)

    let result = sync.sync_rooms(store, log_path, client)

    let calls = brain_client_mock.get_calls(subject)
    list.length(calls) |> should.equal(1)
    sync_log.is_synced(log_path, "room_unsynced") |> should.equal(True)

    result
    |> should.equal(sync.SyncResult(
      total_closed_rooms: 1,
      already_synced: 0,
      synced: 1,
      failed: 0,
    ))
  })
}

pub fn sync_skips_already_synced_test() {
  with_store_and_log(fn(store, log_path) {
    insert_closed_room(store, "room_already", "Already Synced Room")
    insert_message(store, "room_already", 1, "Existing summary")
    let assert Ok(_) = sync_log.mark_synced(log_path, "room_already", "")

    let assert Ok(started) = brain_client_mock.start_mock_actor()
    let subject = brain_client_mock.mock_actor_subject(started)
    let client = brain_client_mock.new_mock_client(subject)

    let result = sync.sync_rooms(store, log_path, client)

    let calls = brain_client_mock.get_calls(subject)
    list.length(calls) |> should.equal(0)

    result
    |> should.equal(sync.SyncResult(
      total_closed_rooms: 1,
      already_synced: 1,
      synced: 0,
      failed: 0,
    ))
  })
}

pub fn sync_handles_errors_gracefully_test() {
  with_store_and_log(fn(store, log_path) {
    insert_closed_room(store, "room_error", "Error Room")
    insert_message(store, "room_error", 1, "Will fail")

    insert_closed_room(store, "room_ok", "Okay Room")
    insert_message(store, "room_ok", 1, "Will succeed")

    let flaky_client =
      brain.BrainClient(
        save_snapshot: fn(_, _, _, _) { Ok("unused") },
        create_artifact: fn(_, title, _, _, _) {
          case title {
            "Room: Error Room" -> Error(types.CommandFailed("boom"))
            _ -> Ok("mock-record-id")
          }
        },
      )

    let result = sync.sync_rooms(store, log_path, flaky_client)

    sync_log.is_synced(log_path, "room_error") |> should.equal(False)
    sync_log.is_synced(log_path, "room_ok") |> should.equal(True)

    result
    |> should.equal(sync.SyncResult(
      total_closed_rooms: 2,
      already_synced: 0,
      synced: 1,
      failed: 1,
    ))
  })
}
