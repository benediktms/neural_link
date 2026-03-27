import birl
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import simplifile

pub type SyncEntry {
  SyncEntry(room_id: String, brain_name: String, synced_at: String)
}

pub fn is_synced(log_path: String, room_id: String) -> Bool {
  case simplifile.read(from: log_path) {
    Ok(contents) ->
      contents
      |> lines()
      |> list.any(fn(line) {
        case decode_entry(line) {
          Ok(entry) ->
            case entry {
              SyncEntry(entry_room_id, _, _) -> entry_room_id == room_id
            }
          Error(_) -> False
        }
      })
    Error(_) -> False
  }
}

pub fn mark_synced(
  log_path: String,
  room_id: String,
  brain_name: String,
) -> Result(Nil, String) {
  let synced_at = birl.to_iso8601(birl.now())
  let line =
    json.object([
      #("room_id", json.string(room_id)),
      #("brain_name", json.string(brain_name)),
      #("synced_at", json.string(synced_at)),
    ])
    |> json.to_string

  case simplifile.append(to: log_path, contents: line <> "\n") {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

pub fn list_synced(log_path: String) -> List(SyncEntry) {
  case simplifile.read(from: log_path) {
    Ok(contents) ->
      contents
      |> lines()
      |> list.filter_map(fn(line) { decode_entry(line) })
    Error(_) -> []
  }
}

fn decode_entry(line: String) -> Result(SyncEntry, json.DecodeError) {
  let decoder = {
    use room_id <- decode.field("room_id", decode.string)
    use brain_name <- decode.field("brain_name", decode.string)
    use synced_at <- decode.field("synced_at", decode.string)
    decode.success(SyncEntry(room_id:, brain_name:, synced_at:))
  }

  json.parse(from: line, using: decoder)
}

fn lines(contents: String) -> List(String) {
  contents
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
}
