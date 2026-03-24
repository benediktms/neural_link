import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import gleam/otp/actor
import neural_link/domain/id
import neural_link/domain/interaction_mode.{type InteractionMode}
import neural_link/domain/room.{type Room} as domain_room
import neural_link/persistence/config.{type PersistencePluginConfig}
import neural_link/runtime/room.{
  type RoomMessage, Shutdown as RoomShutdown, start as start_room,
}

pub type RegistryMessage {
  CreateRoom(
    title: String,
    purpose: Option(String),
    external_ref: Option(String),
    tags: List(String),
    plugins: List(PersistencePluginConfig),
    interaction_mode: Option(InteractionMode),
    reply: Subject(Result(Room, String)),
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
      reply,
    ) -> {
      let room_id = id.generate("room_")
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
          actor.send(reply, Ok(room_data))
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(reply, Error("Failed to start room actor"))
          actor.continue(state)
        }
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
  actor.call(registry, 5000, fn(reply) {
    CreateRoom(
      title,
      purpose,
      external_ref,
      tags,
      plugins,
      interaction_mode,
      reply,
    )
  })
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
