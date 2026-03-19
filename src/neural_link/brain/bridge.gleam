import birl
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import neural_link/brain/client
import neural_link/brain/types.{
  type BrainConfig, type BrainResult, CommandFailed,
}
import neural_link/domain/id
import neural_link/domain/message.{
  type Message, Blocker, Decision, Durable, Handoff, ReviewResult, Summary,
  is_durable,
}
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

// ---------------------------------------------------------------------------
// Message bridge
// ---------------------------------------------------------------------------

/// Persist a durable message to brain.
/// Returns Ok(record_id) if persisted, or Error if the message is not durable.
/// Caller is responsible for async dispatch.
pub fn on_message(config: BrainConfig, msg: Message) -> BrainResult(String) {
  let should_persist = is_durable(msg.kind) || msg.persist_hint == Durable
  case should_persist {
    False -> Error(CommandFailed("Message not durable — skipped"))
    True -> persist_message(config, msg)
  }
}

fn persist_message(config: BrainConfig, msg: Message) -> BrainResult(String) {
  let room_id = id.room_id_to_string(msg.room_id)
  let kind_str = message.kind_to_string(msg.kind)
  let title = "[" <> kind_str <> "] " <> msg.summary
  let text = build_message_text(room_id, kind_str, msg)
  case msg.kind {
    Summary -> {
      let tags = ["neural-link", "summary", room_id]
      client.create_artifact(config, title, text, "summary", tags)
    }
    _ -> {
      let tag = case msg.kind {
        Decision -> "decision"
        Blocker -> "blocker"
        Handoff -> "handoff"
        ReviewResult -> "review-result"
        _ -> "message"
      }
      let tags = ["neural-link", tag, room_id]
      client.create_record(config, title, text, tags)
    }
  }
}

fn build_message_text(room_id: String, kind_str: String, msg: Message) -> String {
  let msg_id = id.message_id_to_string(msg.message_id)
  let from_str = id.participant_id_to_string(msg.from)
  let body_str = option_to_string(msg.body, "none")
  string.join(
    [
      "Message ID: " <> msg_id,
      "Room: " <> room_id,
      "From: " <> from_str,
      "Kind: " <> kind_str,
      "Sequence: " <> int.to_string(msg.sequence),
      "Summary: " <> msg.summary,
      "Body: " <> body_str,
    ],
    "\n",
  )
}
