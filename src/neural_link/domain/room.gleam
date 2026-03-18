import gleam/option.{type Option, None}
import gleam/list
import birl.{type Time}
import neural_link/domain/participant.{type Participant, type ParticipantId, ParticipantId}

pub type RoomId {
  RoomId(String)
}

pub type RoomStatus {
  Open
  Active
  Closing
  Closed
}

pub type Room {
  Room(
    id: RoomId,
    title: String,
    status: RoomStatus,
    created_at: Time,
    participants: List(Participant),
    metadata: Option(String),
  )
}

pub fn new(id: String, title: String) -> Room {
  Room(
    id: RoomId(id),
    title: title,
    status: Open,
    created_at: birl.now(),
    participants: [],
    metadata: None,
  )
}

pub fn activate(room: Room) -> Room {
  Room(..room, status: Active)
}

pub fn begin_close(room: Room) -> Room {
  Room(..room, status: Closing)
}

pub fn close(room: Room) -> Room {
  Room(..room, status: Closed)
}

pub fn add_participant(room: Room, p: Participant) -> Room {
  Room(..room, participants: [p, ..room.participants])
}

pub fn remove_participant(room: Room, id: ParticipantId) -> Room {
  let ParticipantId(target) = id
  Room(..room, participants: list.filter(room.participants, fn(p) {
    let ParticipantId(pid) = p.id
    pid != target
  }))
}

pub fn participant_count(room: Room) -> Int {
  list.length(room.participants)
}

pub fn is_closed(room: Room) -> Bool {
  room.status == Closed
}
