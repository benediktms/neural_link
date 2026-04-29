import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import neural_link/domain/id
import neural_link/domain/interaction_mode.{type InteractionMode}
import neural_link/domain/room.{type Room} as domain_room
import neural_link/persistence/config.{type PersistencePluginConfig}
import neural_link/runtime/room.{
  type RoomMessage, Shutdown as RoomShutdown, get_state as get_room_state,
  start as start_room,
}

/// Outcome of a `CreateRoom` request. `AlreadyExisted` is only ever returned
/// when the caller supplied an `id` and a room with that id is already live in
/// the registry — the existing room is returned unchanged, no new actor is
/// spawned, and no participants are added.
pub type CreateRoomResult {
  Created(room: Room)
  AlreadyExisted(room: Room)
}

pub type RegistryMessage {
  CreateRoom(
    title: String,
    purpose: Option(String),
    external_ref: Option(String),
    tags: List(String),
    plugins: List(PersistencePluginConfig),
    interaction_mode: Option(InteractionMode),
    id: Option(String),
    reply: Subject(Result(CreateRoomResult, String)),
  )
  GetRoom(room_id: String, reply: Subject(Result(Subject(RoomMessage), String)))
  ListRoomIds(reply: Subject(List(String)))
  RemoveRoom(room_id: String, reply: Subject(Result(Nil, String)))
  Shutdown
}

type State =
  Dict(String, Subject(RoomMessage))

pub fn start() -> actor.StartResult(Subject(RegistryMessage)) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: State,
  msg: RegistryMessage,
) -> actor.Next(State, RegistryMessage) {
  case msg {
    CreateRoom(
      title,
      purpose,
      external_ref,
      tags,
      plugins,
      interaction_mode,
      supplied_id,
      reply,
    ) -> {
      // Idempotent path: if caller supplied an id that's already live, return
      // the existing room unchanged. This makes retries safe and lets two
      // processes converge on the same row without a registration round-trip.
      case supplied_id {
        Some(id_str) ->
          case dict.get(state, id_str) {
            Ok(existing_subject) -> {
              let existing_room = get_room_state(existing_subject)
              actor.send(reply, Ok(AlreadyExisted(existing_room)))
              actor.continue(state)
            }
            Error(_) ->
              spawn_room(
                state,
                id_str,
                title,
                purpose,
                external_ref,
                tags,
                plugins,
                interaction_mode,
                reply,
              )
          }
        None ->
          spawn_room(
            state,
            id.generate("room_"),
            title,
            purpose,
            external_ref,
            tags,
            plugins,
            interaction_mode,
            reply,
          )
      }
    }

    GetRoom(room_id, reply) -> {
      case dict.get(state, room_id) {
        Ok(subject) -> {
          actor.send(reply, Ok(subject))
        }
        Error(_) -> {
          actor.send(reply, Error("Room not found: " <> room_id))
        }
      }
      actor.continue(state)
    }

    ListRoomIds(reply) -> {
      actor.send(reply, dict.keys(state))
      actor.continue(state)
    }

    RemoveRoom(room_id, reply) -> {
      case dict.get(state, room_id) {
        Ok(room_subject) -> {
          actor.send(room_subject, RoomShutdown)
          let new_state = dict.delete(state, room_id)
          actor.send(reply, Ok(Nil))
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(reply, Error("Room not found: " <> room_id))
          actor.continue(state)
        }
      }
    }

    Shutdown -> actor.stop()
  }
}

pub fn create_room(
  registry: Subject(RegistryMessage),
  title: String,
  purpose: Option(String),
  external_ref: Option(String),
  tags: List(String),
  plugins: List(PersistencePluginConfig),
  interaction_mode: Option(InteractionMode),
) -> Result(Room, String) {
  case
    create_room_with_id(
      registry,
      title,
      purpose,
      external_ref,
      tags,
      plugins,
      interaction_mode,
      None,
    )
  {
    Ok(Created(room)) -> Ok(room)
    Ok(AlreadyExisted(room)) -> Ok(room)
    Error(e) -> Error(e)
  }
}

/// Create a room with an optional caller-supplied id. When `id` is `Some`,
/// the registry uses it verbatim if free, or returns `AlreadyExisted` with the
/// existing room if a room with that id is already live. When `id` is `None`,
/// behaviour is unchanged: the registry generates a fresh id and always
/// returns `Created`. Caller-supplied ids MUST be pre-validated via
/// `id.room_id_from_string` — the registry does not re-validate.
pub fn create_room_with_id(
  registry: Subject(RegistryMessage),
  title: String,
  purpose: Option(String),
  external_ref: Option(String),
  tags: List(String),
  plugins: List(PersistencePluginConfig),
  interaction_mode: Option(InteractionMode),
  id: Option(String),
) -> Result(CreateRoomResult, String) {
  actor.call(registry, 5000, fn(reply) {
    CreateRoom(
      title,
      purpose,
      external_ref,
      tags,
      plugins,
      interaction_mode,
      id,
      reply,
    )
  })
}

fn spawn_room(
  state: State,
  room_id: String,
  title: String,
  purpose: Option(String),
  external_ref: Option(String),
  tags: List(String),
  plugins: List(PersistencePluginConfig),
  interaction_mode: Option(InteractionMode),
  reply: Subject(Result(CreateRoomResult, String)),
) -> actor.Next(State, RegistryMessage) {
  let room_data =
    domain_room.new_with_metadata(
      room_id,
      title,
      purpose,
      external_ref,
      tags,
      plugins,
      interaction_mode,
    )
  case start_room(room_data) {
    Ok(started) -> {
      let new_state = dict.insert(state, room_id, started.data)
      actor.send(reply, Ok(Created(room_data)))
      actor.continue(new_state)
    }
    Error(_) -> {
      actor.send(reply, Error("Failed to start room actor"))
      actor.continue(state)
    }
  }
}

pub fn get_room(
  registry: Subject(RegistryMessage),
  room_id: String,
) -> Result(Subject(RoomMessage), String) {
  actor.call(registry, 5000, fn(reply) { GetRoom(room_id, reply) })
}

pub fn list_room_ids(registry: Subject(RegistryMessage)) -> List(String) {
  actor.call(registry, 5000, fn(reply) { ListRoomIds(reply) })
}

pub fn remove_room(
  registry: Subject(RegistryMessage),
  room_id: String,
) -> Result(Nil, String) {
  actor.call(registry, 5000, fn(reply) { RemoveRoom(room_id, reply) })
}
