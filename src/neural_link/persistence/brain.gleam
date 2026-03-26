import birl
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import neural_link/brain/client
import neural_link/brain/types as brain_types
import neural_link/domain/id
import neural_link/domain/message.{type Message, is_durable, kind_to_string}
import neural_link/domain/room.{type Room}
import neural_link/persistence/plugin
import neural_link/persistence/types

// ---------------------------------------------------------------------------
// BrainClient — injectable interface for brain CLI operations
// ---------------------------------------------------------------------------

pub type BrainClient {
  BrainClient(
    save_snapshot: fn(brain_types.BrainConfig, String, String, List(String)) ->
      brain_types.BrainResult(String),
    create_artifact: fn(
      brain_types.BrainConfig,
      String,
      String,
      String,
      List(String),
    ) ->
      brain_types.BrainResult(String),
  )
}

// ---------------------------------------------------------------------------
// BrainPlugin — replication to brain for memory graph indexing
// ---------------------------------------------------------------------------

pub fn brain_plugin(name: String) -> plugin.PersistencePlugin {
  brain_plugin_with_client(
    name,
    BrainClient(
      save_snapshot: client.save_snapshot,
      create_artifact: client.create_artifact,
    ),
  )
}

pub fn brain_plugin_with_client(
  name: String,
  client: BrainClient,
) -> plugin.PersistencePlugin {
  plugin.PersistencePlugin(
    name: "brain:" <> name,
    on_init: fn() { Ok(Nil) },
    on_room_open: on_room_open(name, client),
    on_room_close: on_room_close(name, client),
    on_conversation_artifact: on_conversation_artifact(name, client),
    on_message: on_message(name, client),
  )
}

fn on_room_open(
  name: String,
  client: BrainClient,
) -> fn(Room) -> Result(Nil, types.PersistenceError) {
  fn(room: Room) {
    let brain_cfg = brain_types.BrainConfig(brain_name: name)
    let title = "Room opened: " <> room.title
    let content = build_room_open_text(room)
    case
      client.save_snapshot(brain_cfg, title, content, [
        "neural-link",
        "room-open",
      ])
    {
      Ok(_) -> Ok(Nil)
      Error(err) -> Error(map_brain_error(err))
    }
  }
}

fn on_room_close(
  name: String,
  client: BrainClient,
) -> fn(Room, Int, Int) -> Result(Nil, types.PersistenceError) {
  fn(room: Room, message_count: Int, duration_ms: Int) {
    let brain_cfg = brain_types.BrainConfig(brain_name: name)
    let title = "Room closed: " <> room.title
    let content = build_room_close_text(room, message_count, duration_ms)
    case
      client.save_snapshot(brain_cfg, title, content, [
        "neural-link",
        "room-close",
      ])
    {
      Ok(_) -> Ok(Nil)
      Error(err) -> Error(map_brain_error(err))
    }
  }
}

fn on_conversation_artifact(
  name: String,
  client: BrainClient,
) -> fn(Room, String) -> Result(String, types.PersistenceError) {
  fn(room: Room, content: String) {
    let brain_cfg = brain_types.BrainConfig(brain_name: name)
    let title = "Conversation: " <> room.title
    let room_id = id.room_id_to_string(room.id)
    let room_tags = room.tags
    let base_tags = ["neural-link", "conversation", room_id]
    let tags = list.append(base_tags, room_tags)
    case
      client.create_artifact(brain_cfg, title, content, "conversation", tags)
    {
      Ok(record_id) -> Ok(record_id)
      Error(err) -> Error(map_brain_error(err))
    }
  }
}

fn on_message(
  name: String,
  client: BrainClient,
) -> fn(Message) -> Result(Nil, types.PersistenceError) {
  fn(msg: Message) {
    let brain_cfg = brain_types.BrainConfig(brain_name: name)
    persist_message(brain_cfg, msg, client)
  }
}

fn persist_message(
  brain_cfg: brain_types.BrainConfig,
  msg: Message,
  client: BrainClient,
) -> Result(Nil, types.PersistenceError) {
  let room_id = id.room_id_to_string(msg.room_id)
  let kind_str = kind_to_string(msg.kind)
  let title = "[" <> kind_str <> "] " <> msg.summary
  let content = build_message_text(room_id, kind_str, msg)
  case is_durable(msg.kind) || msg.persist_hint == message.Durable {
    False -> Ok(Nil)
    True -> {
      case msg.kind {
        message.Summary -> {
          let tags = ["neural-link", "summary", room_id]
          case
            client.create_artifact(brain_cfg, title, content, "summary", tags)
          {
            Ok(_) -> Ok(Nil)
            Error(err) -> Error(map_brain_error(err))
          }
        }
        _ -> {
          let tag = case msg.kind {
            message.Decision -> "decision"
            message.Blocker -> "blocker"
            message.Handoff -> "handoff"
            message.ReviewResult -> "review-result"
            _ -> "message"
          }
          let tags = ["neural-link", tag, room_id]
          case client.save_snapshot(brain_cfg, title, content, tags) {
            Ok(_) -> Ok(Nil)
            Error(err) -> Error(map_brain_error(err))
          }
        }
      }
    }
  }
}

fn map_brain_error(err: brain_types.BrainError) -> types.PersistenceError {
  case err {
    brain_types.Timeout -> types.Timeout
    brain_types.CommandFailed(output) ->
      types.AdapterError(backend: "brain", detail: "command_failed: " <> output)
    brain_types.ParseError(detail) ->
      types.AdapterError(backend: "brain", detail: "parse_error: " <> detail)
  }
}

// ---------------------------------------------------------------------------
// Content builders (copied from bridge.gleam)
// ---------------------------------------------------------------------------

pub fn build_room_open_text(room: Room) -> String {
  let room_id = id.room_id_to_string(room.id)
  let purpose = option.unwrap(room.purpose, "none")
  let external_ref = option.unwrap(room.external_ref, "none")
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

pub fn build_room_close_text(
  room: Room,
  message_count: Int,
  duration_ms: Int,
) -> String {
  let room_id = id.room_id_to_string(room.id)
  let resolution = case room.resolution {
    option.Some(room.Completed) -> "completed"
    option.Some(room.Cancelled) -> "cancelled"
    option.Some(room.Superseded) -> "superseded"
    option.Some(room.Failed) -> "failed"
    option.None -> "none"
  }
  let participant_count = int.to_string(room.participant_count(room))
  let purpose = option.unwrap(room.purpose, "none")
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

pub fn build_message_text(
  room_id: String,
  kind_str: String,
  msg: Message,
) -> String {
  let msg_id = id.message_id_to_string(msg.message_id)
  let from_str = id.participant_id_to_string(msg.from)
  let body_str = option.unwrap(msg.body, "none")
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
