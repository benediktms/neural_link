import birl.{type Time}
import gleam/list
import neural_link/domain/id.{
  type ParticipantId, type RoomId, type WaitId, new_wait_id,
}
import neural_link/domain/message.{type MessageKind}

pub type WaitFilter {
  WaitFilter(kinds: List(MessageKind), from: List(ParticipantId))
}

pub type Wait {
  Wait(
    wait_id: WaitId,
    participant_id: ParticipantId,
    room_id: RoomId,
    filter: WaitFilter,
    since_sequence: Int,
    timeout_ms: Int,
    created_at: Time,
  )
}

pub fn new_wait(
  participant_id: ParticipantId,
  room_id: RoomId,
  filter: WaitFilter,
  since_sequence: Int,
  timeout_ms: Int,
) -> Wait {
  Wait(
    wait_id: new_wait_id(),
    participant_id: participant_id,
    room_id: room_id,
    filter: filter,
    since_sequence: since_sequence,
    timeout_ms: timeout_ms,
    created_at: birl.utc_now(),
  )
}

pub fn empty_filter() -> WaitFilter {
  WaitFilter(kinds: [], from: [])
}

pub fn matches_filter(
  filter: WaitFilter,
  kind: MessageKind,
  sender: ParticipantId,
) -> Bool {
  let kind_matches = case filter.kinds {
    [] -> True
    kinds -> list.contains(kinds, kind)
  }
  let sender_matches = case filter.from {
    [] -> True
    froms -> list.contains(froms, sender)
  }
  kind_matches && sender_matches
}
