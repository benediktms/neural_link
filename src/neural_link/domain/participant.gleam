import birl.{type Time}
import neural_link/domain/id.{type ParticipantId, ParticipantId}

pub type ParticipantRole {
  Owner
  Member
  Observer
  Custom(String)
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
    joined_at: birl.utc_now(),
  )
}
