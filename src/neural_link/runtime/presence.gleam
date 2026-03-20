import birl
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import neural_link/domain/id.{type ParticipantId, participant_id_to_string}

pub type PresenceEntry {
  PresenceEntry(rooms: List(String), last_seen: Int, lease_ms: Int)
}

type PresenceState {
  PresenceState(
    entries: Dict(String, PresenceEntry),
    /// Maps Claude Code agent_id → participant_id string
    agent_map: Dict(String, String),
  )
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
  RegisterAgent(agent_id: String, participant_id: ParticipantId)
  QueryAgent(agent_id: String, reply: Subject(Result(String, String)))
  Shutdown
}

pub fn start() -> actor.StartResult(Subject(PresenceMessage)) {
  actor.new(PresenceState(entries: dict.new(), agent_map: dict.new()))
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
      let entry = case dict.get(state.entries, key) {
        Ok(e) -> e
        Error(_) -> PresenceEntry(rooms: [], last_seen: now, lease_ms: lease_ms)
      }
      let rooms = case list.contains(entry.rooms, room_id) {
        True -> entry.rooms
        False -> [room_id, ..entry.rooms]
      }
      let updated = PresenceEntry(..entry, rooms: rooms, last_seen: now)
      let entries = dict.insert(state.entries, key, updated)
      actor.continue(PresenceState(..state, entries: entries))
    }

    Heartbeat(participant_id) -> {
      let key = participant_id_to_string(participant_id)
      let now = birl.to_unix_milli(birl.utc_now())
      let entries = case dict.get(state.entries, key) {
        Ok(entry) ->
          dict.insert(
            state.entries,
            key,
            PresenceEntry(..entry, last_seen: now),
          )
        Error(_) -> state.entries
      }
      actor.continue(PresenceState(..state, entries: entries))
    }

    Unregister(participant_id, room_id) -> {
      let key = participant_id_to_string(participant_id)
      case dict.get(state.entries, key) {
        Error(_) -> actor.continue(state)
        Ok(entry) -> {
          let rooms = list.filter(entry.rooms, fn(r) { r != room_id })
          case rooms {
            [] -> {
              // Participant has no rooms left — clean up entries and agent_map
              let entries = dict.delete(state.entries, key)
              let agent_map = purge_agent_entries(state.agent_map, key)
              actor.continue(PresenceState(
                entries: entries,
                agent_map: agent_map,
              ))
            }
            _ -> {
              let entries =
                dict.insert(
                  state.entries,
                  key,
                  PresenceEntry(..entry, rooms: rooms),
                )
              actor.continue(PresenceState(..state, entries: entries))
            }
          }
        }
      }
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
      let result =
        dict.get(state.entries, key)
        |> result.map_error(fn(_) { "Participant not found" })
      process.send(reply, result)
      actor.continue(state)
    }

    RegisterAgent(agent_id, participant_id) -> {
      let pid_str = participant_id_to_string(participant_id)
      let agent_map = dict.insert(state.agent_map, agent_id, pid_str)
      actor.continue(PresenceState(..state, agent_map: agent_map))
    }

    QueryAgent(agent_id, reply) -> {
      let result =
        dict.get(state.agent_map, agent_id)
        |> result.map_error(fn(_) { "Agent not found" })
      process.send(reply, result)
      actor.continue(state)
    }

    // TODO: v2 — add periodic timer to call CheckExpired and remove stale participants
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
      // Clean agent_map for expired participants
      let cleaned_agent_map =
        list.fold(expired, state.agent_map, fn(am, pid) {
          purge_agent_entries(am, pid)
        })
      process.send(reply, expired)
      actor.continue(PresenceState(
        entries: remaining,
        agent_map: cleaned_agent_map,
      ))
    }

    Shutdown -> actor.stop()
  }
}

/// Remove all agent_map entries pointing to the given participant_id
fn purge_agent_entries(
  agent_map: Dict(String, String),
  participant_id: String,
) -> Dict(String, String) {
  dict.filter(agent_map, fn(_agent_id, pid) { pid != participant_id })
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

pub fn register_agent(
  presence: Subject(PresenceMessage),
  agent_id: String,
  participant_id: ParticipantId,
) -> Nil {
  actor.send(presence, RegisterAgent(agent_id, participant_id))
}

pub fn query_agent(
  presence: Subject(PresenceMessage),
  agent_id: String,
) -> Result(String, String) {
  actor.call(presence, 5000, QueryAgent(agent_id, _))
}

pub fn check_expired(presence: Subject(PresenceMessage)) -> List(String) {
  actor.call(presence, 5000, CheckExpired)
}
