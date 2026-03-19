import birl.{type Time}
import gleam/list
import gleam/option.{type Option, None, Some}
import neural_link/domain/id.{
  type ParticipantId, type RoomId, ParticipantId, RoomId,
}
import neural_link/domain/participant.{type Participant}

pub type RoomStatus {
  Open
  Active
  Closing
  Closed
}

pub type RoomResolution {
  Completed
  Cancelled
  Superseded
  Failed
}

pub type Room {
  Room(
    id: RoomId,
    title: String,
    status: RoomStatus,
    created_at: Time,
    participants: List(Participant),
    metadata: Option(String),
    purpose: Option(String),
    external_ref: Option(String),
    tags: List(String),
    resolution: Option(RoomResolution),
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
    purpose: None,
    external_ref: None,
    tags: [],
    resolution: None,
  )
}

pub fn new_with_metadata(
  id: String,
  title: String,
  purpose: Option(String),
  external_ref: Option(String),
  tags: List(String),
) -> Room {
  Room(
    id: RoomId(id),
    title: title,
    status: Open,
    created_at: birl.now(),
    participants: [],
    metadata: None,
    purpose: purpose,
    external_ref: external_ref,
    tags: tags,
    resolution: None,
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

pub fn close_with_resolution(room: Room, resolution: RoomResolution) -> Room {
  Room(..room, status: Closed, resolution: Some(resolution))
}

pub fn add_participant(room: Room, p: Participant) -> Room {
  Room(..room, participants: [p, ..room.participants])
}

pub fn remove_participant(room: Room, id: ParticipantId) -> Room {
  let ParticipantId(target) = id
  Room(
    ..room,
    participants: list.filter(room.participants, fn(p) {
      let ParticipantId(pid) = p.id
      pid != target
    }),
  )
}

pub fn participant_count(room: Room) -> Int {
  list.length(room.participants)
}

pub fn is_closed(room: Room) -> Bool {
  room.status == Closed
}
