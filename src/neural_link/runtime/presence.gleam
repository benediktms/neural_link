import birl
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import neural_link/domain/id.{type ParticipantId, participant_id_to_string}

pub type PresenceEntry {
  PresenceEntry(rooms: List(String), last_seen: Int, lease_ms: Int)
}

type PresenceState {
  PresenceState(entries: Dict(String, PresenceEntry))
}

pub type PresenceMessage {
  Register(participant_id: ParticipantId, room_id: String, lease_ms: Int)
  Heartbeat(participant_id: ParticipantId)
  Unregister(participant_id: ParticipantId, room_id: String)
  QueryRoom(room_id: String, reply: Subject(List(String)))
  QueryParticipant(
    participant_id: ParticipantId,
    reply: Subject(Result(PresenceEntry, String)),
  )
  CheckExpired(reply: Subject(List(String)))
  Shutdown
}

pub fn start() -> actor.StartResult(Subject(PresenceMessage)) {
  actor.new(PresenceState(entries: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: PresenceState,
  msg: PresenceMessage,
) -> actor.Next(PresenceState, PresenceMessage) {
  case msg {
    Register(participant_id, room_id, lease_ms) -> {
      let key = participant_id_to_string(participant_id)
      let now = birl.to_unix_milli(birl.utc_now())
      let existing = dict.get(state.entries, key)
      let entry = case existing {
        Ok(e) -> e
        Error(_) -> PresenceEntry(rooms: [], last_seen: now, lease_ms: lease_ms)
      }
      let rooms = case list.contains(entry.rooms, room_id) {
        True -> entry.rooms
        False -> [room_id, ..entry.rooms]
      }
      let updated =
        PresenceEntry(rooms: rooms, last_seen: now, lease_ms: lease_ms)
      let entries = dict.insert(state.entries, key, updated)
      actor.continue(PresenceState(entries: entries))
    }

    Heartbeat(participant_id) -> {
      let key = participant_id_to_string(participant_id)
      let now = birl.to_unix_milli(birl.utc_now())
      let entries = case dict.get(state.entries, key) {
        Ok(entry) -> {
          let updated =
            PresenceEntry(
              rooms: entry.rooms,
              last_seen: now,
              lease_ms: entry.lease_ms,
            )
          dict.insert(state.entries, key, updated)
        }
        Error(_) -> state.entries
      }
      actor.continue(PresenceState(entries: entries))
    }

    Unregister(participant_id, room_id) -> {
      let key = participant_id_to_string(participant_id)
      let entries = case dict.get(state.entries, key) {
        Ok(entry) -> {
          let rooms = list.filter(entry.rooms, fn(r) { r != room_id })
          case rooms {
            [] -> dict.delete(state.entries, key)
            _ -> {
              let updated =
                PresenceEntry(
                  rooms: rooms,
                  last_seen: entry.last_seen,
                  lease_ms: entry.lease_ms,
                )
              dict.insert(state.entries, key, updated)
            }
          }
        }
        Error(_) -> state.entries
      }
      actor.continue(PresenceState(entries: entries))
    }

    QueryRoom(room_id, reply) -> {
      let participants =
        dict.fold(state.entries, [], fn(acc, key, entry) {
          case list.contains(entry.rooms, room_id) {
            True -> [key, ..acc]
            False -> acc
          }
        })
      process.send(reply, participants)
      actor.continue(state)
    }

    QueryParticipant(participant_id, reply) -> {
      let key = participant_id_to_string(participant_id)
      let result = case dict.get(state.entries, key) {
        Ok(entry) -> Ok(entry)
        Error(_) -> Error("Participant not found")
      }
      process.send(reply, result)
      actor.continue(state)
    }

    CheckExpired(reply) -> {
      let now = birl.to_unix_milli(birl.utc_now())
      let #(expired, remaining) =
        dict.fold(state.entries, #([], dict.new()), fn(acc, key, entry) {
          let #(exp_acc, rem_acc) = acc
          case now - entry.last_seen > entry.lease_ms {
            True -> #([key, ..exp_acc], rem_acc)
            False -> #(exp_acc, dict.insert(rem_acc, key, entry))
          }
        })
      process.send(reply, expired)
      actor.continue(PresenceState(entries: remaining))
    }

    Shutdown -> actor.stop()
  }
}

pub fn register(
  presence: Subject(PresenceMessage),
  participant_id: ParticipantId,
  room_id: String,
  lease_ms: Int,
) -> Nil {
  actor.send(presence, Register(participant_id, room_id, lease_ms))
}

pub fn heartbeat(
  presence: Subject(PresenceMessage),
  participant_id: ParticipantId,
) -> Nil {
  actor.send(presence, Heartbeat(participant_id))
}

pub fn unregister(
  presence: Subject(PresenceMessage),
  participant_id: ParticipantId,
  room_id: String,
) -> Nil {
  actor.send(presence, Unregister(participant_id, room_id))
}

pub fn query_room(
  presence: Subject(PresenceMessage),
  room_id: String,
) -> List(String) {
  actor.call(presence, 5000, QueryRoom(room_id, _))
}

pub fn query_participant(
  presence: Subject(PresenceMessage),
  participant_id: ParticipantId,
) -> Result(PresenceEntry, String) {
  actor.call(presence, 5000, QueryParticipant(participant_id, _))
}

pub fn check_expired(presence: Subject(PresenceMessage)) -> List(String) {
  actor.call(presence, 5000, CheckExpired)
}
