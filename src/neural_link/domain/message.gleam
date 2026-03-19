import birl.{type Time}
import gleam/list
import gleam/option.{type Option, None, Some}
import neural_link/domain/id.{
  type MessageId, type ParticipantId, type RoomId, type ThreadId, new_message_id,
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

pub type MessageKind {
  Question
  Answer
  Finding
  Handoff
  Blocker
  Decision
  ReviewRequest
  ReviewResult
  ArtifactRef
  Summary
}

pub type PersistHint {
  Durable
  Ephemeral
}

pub type ReceiptStatus {
  Pending
  Acked
}

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

pub type Reference {
  Reference(ref_type: String, ref_id: String)
}

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

pub type Message {
  Message(
    message_id: MessageId,
    room_id: RoomId,
    thread_id: Option(ThreadId),
    from: ParticipantId,
    to: List(ParticipantId),
    kind: MessageKind,
    created_at: Time,
    sequence: Int,
    requires_ack: Bool,
    persist_hint: PersistHint,
    references: List(Reference),
    summary: String,
    body: Option(String),
  )
}

pub type Receipt {
  Receipt(
    message_id: MessageId,
    participant_id: ParticipantId,
    status: ReceiptStatus,
    created_at: Time,
    acked_at: Option(Time),
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convert a MessageKind to its string representation.
pub fn kind_to_string(kind: MessageKind) -> String {
  case kind {
    Question -> "question"
    Answer -> "answer"
    Finding -> "finding"
    Handoff -> "handoff"
    Blocker -> "blocker"
    Decision -> "decision"
    ReviewRequest -> "review_request"
    ReviewResult -> "review_result"
    ArtifactRef -> "artifact_ref"
    Summary -> "summary"
  }
}

/// True for message kinds that carry durable collective memory.
pub fn is_durable(kind: MessageKind) -> Bool {
  case kind {
    Decision | Blocker | Handoff | ReviewResult | Summary -> True
    _ -> False
  }
}

/// Construct a new Message with sensible defaults.
pub fn new_message(
  room_id: RoomId,
  from: ParticipantId,
  to: List(ParticipantId),
  kind: MessageKind,
  summary: String,
) -> Message {
  Message(
    message_id: new_message_id(),
    room_id: room_id,
    thread_id: None,
    from: from,
    to: to,
    kind: kind,
    created_at: birl.utc_now(),
    sequence: 0,
    requires_ack: False,
    persist_hint: Ephemeral,
    references: [],
    summary: summary,
    body: None,
  )
}

/// Construct a new Receipt in Pending state.
pub fn new_receipt(
  message_id: MessageId,
  participant_id: ParticipantId,
) -> Receipt {
  Receipt(
    message_id: message_id,
    participant_id: participant_id,
    status: Pending,
    created_at: birl.utc_now(),
    acked_at: None,
  )
}

/// Transition a Receipt from Pending to Acked. Idempotent.
pub fn ack_receipt(receipt: Receipt) -> Receipt {
  case receipt.status {
    Acked -> receipt
    Pending -> Receipt(..receipt, status: Acked, acked_at: Some(birl.utc_now()))
  }
}

/// Create one Receipt per participant in the provided list.
/// The caller determines the audience (directed or broadcast slice).
pub fn expand_receipts(
  message: Message,
  participants: List(ParticipantId),
) -> List(Receipt) {
  list.map(participants, fn(pid) { new_receipt(message.message_id, pid) })
}
