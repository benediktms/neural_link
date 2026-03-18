import birl.{type Time}

pub type ParticipantId {
  ParticipantId(String)
}

pub type ParticipantRole {
  Owner
  Member
  Observer
}

pub type Participant {
  Participant(
    id: ParticipantId,
    display_name: String,
    role: ParticipantRole,
    joined_at: Time,
  )
}

pub fn new(id: String, name: String, role: ParticipantRole) -> Participant {
  Participant(
    id: ParticipantId(id),
    display_name: name,
    role: role,
    joined_at: birl.now(),
  )
}
