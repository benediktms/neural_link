import birl
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import neural_link/brain/client
import neural_link/brain/types.{type BrainConfig, type BrainResult}
import neural_link/domain/id
import neural_link/domain/room.{
  type Room, Cancelled, Completed, Failed, Superseded,
}

pub fn on_room_open(config: BrainConfig, room: Room) -> BrainResult(String) {
  let room_id = id.room_id_to_string(room.id)
  let title = "Room opened: " <> room.title
  let text = build_open_text(room_id, room)
  client.create_record(config, title, text, ["neural-link", "room-open"])
}

pub fn on_room_close(
  config: BrainConfig,
  room: Room,
  message_count: Int,
  duration_ms: Int,
) -> BrainResult(String) {
  let room_id = id.room_id_to_string(room.id)
  let title = "Room closed: " <> room.title
  let text = build_close_text(room_id, room, message_count, duration_ms)
  client.create_record(config, title, text, ["neural-link", "room-close"])
}

fn build_open_text(room_id: String, room: Room) -> String {
  let purpose = option_to_string(room.purpose, "none")
  let external_ref = option_to_string(room.external_ref, "none")
  let participant_count = int.to_string(room.participant_count(room))
  let created_at = birl.to_iso8601(room.created_at)
  let tags = case room.tags {
    [] -> "none"
    ts -> string.join(ts, ", ")
  }
  string.join(
    [
      "Room ID: " <> room_id,
      "Title: " <> room.title,
      "Purpose: " <> purpose,
      "External ref: " <> external_ref,
      "Participants: " <> participant_count,
      "Created at: " <> created_at,
      "Tags: " <> tags,
    ],
    "\n",
  )
}

fn build_close_text(
  room_id: String,
  room: Room,
  message_count: Int,
  duration_ms: Int,
) -> String {
  let resolution = case room.resolution {
    Some(Completed) -> "completed"
    Some(Cancelled) -> "cancelled"
    Some(Superseded) -> "superseded"
    Some(Failed) -> "failed"
    None -> "none"
  }
  let participant_count = int.to_string(room.participant_count(room))
  let purpose = option_to_string(room.purpose, "none")
  let tags = case room.tags {
    [] -> "none"
    ts -> string.join(ts, ", ")
  }
  string.join(
    [
      "Room ID: " <> room_id,
      "Title: " <> room.title,
      "Resolution: " <> resolution,
      "Participants: " <> participant_count,
      "Messages: " <> int.to_string(message_count),
      "Duration: " <> int.to_string(duration_ms) <> "ms",
      "Purpose: " <> purpose,
      "Tags: " <> tags,
    ],
    "\n",
  )
}

fn option_to_string(opt: Option(String), default: String) -> String {
  option.unwrap(opt, default)
}
