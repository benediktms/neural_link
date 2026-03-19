import birl.{type Time}
import gleam/option.{type Option, None}
import neural_link/domain/id.{
  type RoomId, type SummaryId, type ThreadId, new_summary_id,
}

pub type Summary {
  Summary(
    summary_id: SummaryId,
    room_id: RoomId,
    thread_id: Option(ThreadId),
    content: String,
    open_questions: List(String),
    decisions: List(String),
    message_range: #(Int, Int),
    created_at: Time,
    persisted_to_brain: Bool,
  )
}

pub fn new_summary(
  room_id: RoomId,
  content: String,
  message_range: #(Int, Int),
) -> Summary {
  Summary(
    summary_id: new_summary_id(),
    room_id: room_id,
    thread_id: None,
    content: content,
    open_questions: [],
    decisions: [],
    message_range: message_range,
    created_at: birl.utc_now(),
    persisted_to_brain: False,
  )
}

pub fn mark_persisted(summary: Summary) -> Summary {
  Summary(..summary, persisted_to_brain: True)
}
