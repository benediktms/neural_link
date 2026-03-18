import gleam/crypto
import gleam/bit_array
import gleam/string

/// All domain ID types — every domain module imports from here
pub type RoomId {
  RoomId(String)
}

pub type ParticipantId {
  ParticipantId(String)
}

pub type MessageId {
  MessageId(String)
}

pub type ThreadId {
  ThreadId(String)
}

pub type SummaryId {
  SummaryId(String)
}

pub type WaitId {
  WaitId(String)
}

/// Generate a unique ID with the given prefix.
/// Format: prefix + 16 random hex characters (lowercase)
/// Example: "room_a1b2c3d4e5f6g7h8"
pub fn generate(prefix: String) -> String {
  let bytes = crypto.strong_random_bytes(8)
  let hex = bit_array.base16_encode(bytes) |> string.lowercase
  prefix <> hex
}

pub fn new_room_id() -> RoomId {
  RoomId(generate("room_"))
}

pub fn new_participant_id() -> ParticipantId {
  ParticipantId(generate("participant_"))
}

pub fn new_message_id() -> MessageId {
  MessageId(generate("msg_"))
}

pub fn new_thread_id() -> ThreadId {
  ThreadId(generate("thread_"))
}

pub fn new_summary_id() -> SummaryId {
  SummaryId(generate("summary_"))
}

pub fn new_wait_id() -> WaitId {
  WaitId(generate("wait_"))
}

/// Extract the raw string from any ID type
pub fn room_id_to_string(id: RoomId) -> String {
  let RoomId(s) = id
  s
}

pub fn participant_id_to_string(id: ParticipantId) -> String {
  let ParticipantId(s) = id
  s
}

pub fn message_id_to_string(id: MessageId) -> String {
  let MessageId(s) = id
  s
}

pub fn thread_id_to_string(id: ThreadId) -> String {
  let ThreadId(s) = id
  s
}

pub fn summary_id_to_string(id: SummaryId) -> String {
  let SummaryId(s) = id
  s
}

pub fn wait_id_to_string(id: WaitId) -> String {
  let WaitId(s) = id
  s
}
