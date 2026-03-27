import gleam/list
import gleeunit/should
import neural_link/persistence/sync_log
import simplifile

fn cleanup(path: String) {
  case simplifile.delete(file_or_dir_at: path) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

pub fn empty_log_not_synced_test() {
  let path = "/tmp/sync_log_test_1.jsonl"
  cleanup(path)

  sync_log.is_synced(path, "room_a")
  |> should.equal(False)

  cleanup(path)
}

pub fn mark_and_verify_test() {
  let path = "/tmp/sync_log_test_2.jsonl"
  cleanup(path)

  let assert Ok(Nil) = sync_log.mark_synced(path, "room_a", "brain_a")
  sync_log.is_synced(path, "room_a")
  |> should.equal(True)

  cleanup(path)
}

pub fn different_room_not_synced_test() {
  let path = "/tmp/sync_log_test_3.jsonl"
  cleanup(path)

  let assert Ok(Nil) = sync_log.mark_synced(path, "room_a", "brain_a")
  sync_log.is_synced(path, "room_b")
  |> should.equal(False)

  cleanup(path)
}

pub fn list_synced_entries_test() {
  let path = "/tmp/sync_log_test_4.jsonl"
  cleanup(path)

  let assert Ok(Nil) = sync_log.mark_synced(path, "room_a", "brain_a")
  let assert Ok(Nil) = sync_log.mark_synced(path, "room_b", "brain_a")

  let entries = sync_log.list_synced(path)
  list.map(entries, fn(entry) {
    case entry {
      sync_log.SyncEntry(room_id, _, _) -> room_id
    }
  })
  |> should.equal(["room_a", "room_b"])

  cleanup(path)
}

pub fn missing_file_returns_empty_list_test() {
  let path = "/tmp/sync_log_test_5.jsonl"
  cleanup(path)

  sync_log.list_synced(path)
  |> should.equal([])

  cleanup(path)
}
