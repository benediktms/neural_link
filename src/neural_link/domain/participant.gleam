import birl.{type Time}
import neural_link/domain/id.{type ParticipantId, ParticipantId}

pub type ParticipantRole {
  Lead
  Owner
  Member
  Observer
  Custom(String)
}

pub type ParticipantStatus {
  Active
  Draining
  Departed
}

pub type Participant {
  Participant(
    id: ParticipantId,
    display_name: String,
    role: ParticipantRole,
    status: ParticipantStatus,
    joined_at: Time,
  )
}

pub fn new(id: String, name: String, role: ParticipantRole) -> Participant {
  Participant(
    id: ParticipantId(id),
    display_name: name,
    role: role,
    status: Active,
    joined_at: birl.utc_now(),
  )
}

pub fn is_active(p: Participant) -> Bool {
  p.status == Active
}

pub fn is_departed(p: Participant) -> Bool {
  p.status == Departed
}

pub fn is_lead(p: Participant) -> Bool {
  p.role == Lead
}

pub fn set_status(p: Participant, status: ParticipantStatus) -> Participant {
  Participant(..p, status: status)
}

pub fn role_to_string(role: ParticipantRole) -> String {
  case role {
    Lead -> "lead"
    Owner -> "owner"
    Member -> "member"
    Observer -> "observer"
    Custom(s) -> s
  }
}
