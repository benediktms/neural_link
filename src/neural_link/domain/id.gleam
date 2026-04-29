import gleam/bit_array
import gleam/crypto
import gleam/list
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

/// Errors returned by ID parsers/validators.
pub type IdError {
  InvalidFormat(detail: String)
}

/// Parse a string as a `RoomId`, validating it matches the same shape that
/// `new_room_id` produces: `room_` prefix followed by exactly 16 lowercase
/// hex characters (21 chars total). This is the canonical format check —
/// callers MUST use it to reject malformed caller-supplied ids before they
/// reach the registry or persistence layer.
pub fn room_id_from_string(s: String) -> Result(RoomId, IdError) {
  case is_valid_room_id_format(s) {
    True -> Ok(RoomId(s))
    False ->
      Error(InvalidFormat("room_id must match ^room_[a-f0-9]{16}$, got: " <> s))
  }
}

fn is_valid_room_id_format(s: String) -> Bool {
  case string.starts_with(s, "room_") {
    False -> False
    True -> {
      let suffix = string.drop_start(s, 5)
      string.length(suffix) == 16
      && list.all(string.to_graphemes(suffix), is_lowercase_hex_char)
    }
  }
}

fn is_lowercase_hex_char(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "a" | "b" | "c" | "d" | "e" | "f" -> True
    _ -> False
  }
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
