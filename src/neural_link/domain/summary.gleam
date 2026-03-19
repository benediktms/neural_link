import birl
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import neural_link/domain/id.{
  type RoomId, type ThreadId, participant_id_to_string, room_id_to_string,
  thread_id_to_string,
}
import neural_link/domain/message.{
  type Message, Answer, Blocker, Decision, Question,
}
import neural_link/domain/room.{
  type Room, Cancelled, Completed, Failed, Superseded,
}

pub type ConversationExtraction {
  ConversationExtraction(
    room_id: RoomId,
    thread_id: Option(ThreadId),
    content: String,
    decisions: List(String),
    open_questions: List(String),
    unresolved_blockers: List(String),
    message_count: Int,
    participant_ids: List(String),
    artifact_record_id: Option(String),
  )
}

/// Extract structured data from a list of messages.
/// Messages should be in chronological order (ascending sequence).
pub fn extract(
  room: Room,
  thread_id: Option(ThreadId),
  messages: List(Message),
) -> ConversationExtraction {
  let sorted =
    list.sort(messages, fn(a, b) { int.compare(a.sequence, b.sequence) })
  let content = serialize_conversation(room, sorted)
  let decisions = extract_by_kind(sorted, Decision)
  let open_questions = extract_open_questions(sorted)
  let unresolved_blockers = extract_unresolved_blockers(sorted)
  let participant_ids =
    list.map(room.participants, fn(p) { participant_id_to_string(p.id) })

  ConversationExtraction(
    room_id: room.id,
    thread_id: thread_id,
    content: content,
    decisions: decisions,
    open_questions: open_questions,
    unresolved_blockers: unresolved_blockers,
    message_count: list.length(sorted),
    participant_ids: participant_ids,
    artifact_record_id: None,
  )
}

pub fn set_artifact_id(
  extraction: ConversationExtraction,
  record_id: String,
) -> ConversationExtraction {
  ConversationExtraction(..extraction, artifact_record_id: Some(record_id))
}

pub fn encode(extraction: ConversationExtraction) -> json.Json {
  let artifact = case extraction.artifact_record_id {
    Some(id) -> json.string(id)
    None -> json.null()
  }
  let thread = case extraction.thread_id {
    Some(tid) -> json.string(thread_id_to_string(tid))
    None -> json.null()
  }
  json.object([
    #("room_id", json.string(room_id_to_string(extraction.room_id))),
    #("thread_id", thread),
    #("message_count", json.int(extraction.message_count)),
    #("participant_ids", json.array(extraction.participant_ids, json.string)),
    #("decisions", json.array(extraction.decisions, json.string)),
    #("open_questions", json.array(extraction.open_questions, json.string)),
    #(
      "unresolved_blockers",
      json.array(extraction.unresolved_blockers, json.string),
    ),
    #("content", json.string(extraction.content)),
    #("artifact_record_id", artifact),
  ])
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

fn serialize_conversation(room: Room, messages: List(Message)) -> String {
  let room_id = room_id_to_string(room.id)
  let created = birl.to_iso8601(room.created_at)
  let resolution_str = case room.resolution {
    Some(Completed) -> "completed"
    Some(Cancelled) -> "cancelled"
    Some(Superseded) -> "superseded"
    Some(Failed) -> "failed"
    None -> "open"
  }
  let participants_str =
    list.map(room.participants, fn(p) {
      p.display_name <> " (" <> participant_id_to_string(p.id) <> ")"
    })
    |> string.join(", ")

  let header =
    string.join(
      [
        "# Room: " <> room.title,
        "# Room ID: " <> room_id,
        "# Opened: " <> created,
        "# Participants: " <> participants_str,
        "# Resolution: " <> resolution_str,
        "",
        "---",
        "",
      ],
      "\n",
    )

  let body =
    list.map(messages, serialize_message)
    |> string.join("\n\n")

  header <> body
}

fn serialize_message(msg: Message) -> String {
  let from = participant_id_to_string(msg.from)
  let kind_str = message.kind_to_string(msg.kind)
  let ts = birl.to_iso8601(msg.created_at)
  let seq = int.to_string(msg.sequence)
  let header = "[" <> seq <> "] " <> from <> " (" <> kind_str <> ") " <> ts
  case msg.body {
    Some(body) -> header <> "\n" <> msg.summary <> "\n" <> body
    None -> header <> "\n" <> msg.summary
  }
}

// ---------------------------------------------------------------------------
// Extraction helpers
// ---------------------------------------------------------------------------

fn extract_by_kind(
  messages: List(Message),
  kind: message.MessageKind,
) -> List(String) {
  list.filter_map(messages, fn(m) {
    case m.kind == kind {
      True -> Ok(m.summary)
      False -> Error(Nil)
    }
  })
}

fn extract_open_questions(messages: List(Message)) -> List(String) {
  // Threaded questions: resolved if any Answer/Decision follows in same thread.
  // Unthreaded questions: resolved 1:1 in sequence order by unthreaded
  // Answer/Decision messages. Each resolver consumes one question.
  let resolvers =
    list.filter(messages, fn(m) { m.kind == Answer || m.kind == Decision })
  let questions = list.filter(messages, fn(m) { m.kind == Question })
  find_unresolved(questions, resolvers)
}

fn extract_unresolved_blockers(messages: List(Message)) -> List(String) {
  // Same resolution rules as questions.
  let resolvers =
    list.filter(messages, fn(m) { m.kind == Decision || m.kind == Answer })
  let blockers = list.filter(messages, fn(m) { m.kind == Blocker })
  find_unresolved(blockers, resolvers)
}

/// Find messages that have no resolver.
/// Threaded: any resolver in the same thread after it.
/// Unthreaded: 1:1 consumption in sequence order.
fn find_unresolved(
  targets: List(Message),
  resolvers: List(Message),
) -> List(String) {
  // Split into threaded and unthreaded
  let threaded_targets =
    list.filter(targets, fn(m) { option.is_some(m.thread_id) })
  let unthreaded_targets = list.filter(targets, fn(m) { m.thread_id == None })
  let unthreaded_resolvers =
    list.filter(resolvers, fn(r) { r.thread_id == None })

  // Threaded: any resolver in same thread after the target
  let open_threaded =
    list.filter_map(threaded_targets, fn(t) {
      let resolved =
        list.any(resolvers, fn(r) {
          r.sequence > t.sequence && r.thread_id == t.thread_id
        })
      case resolved {
        True -> Error(Nil)
        False -> Ok(t.summary)
      }
    })

  // Unthreaded: walk both lists in sequence order, consuming 1:1
  let open_unthreaded =
    consume_unthreaded(unthreaded_targets, unthreaded_resolvers)

  list.append(open_threaded, open_unthreaded)
}

/// Walk unthreaded targets and resolvers in sequence order.
/// Each resolver consumes the first unresolved target before it.
fn consume_unthreaded(
  targets: List(Message),
  resolvers: List(Message),
) -> List(String) {
  case targets {
    [] -> []
    [target, ..rest_targets] -> {
      // Find a resolver after this target
      case list.find(resolvers, fn(r) { r.sequence > target.sequence }) {
        Ok(resolver) -> {
          // This target is resolved. Remove the used resolver and continue.
          let remaining_resolvers =
            list.filter(resolvers, fn(r) { r.sequence != resolver.sequence })
          consume_unthreaded(rest_targets, remaining_resolvers)
        }
        Error(_) -> {
          // No resolver available — this and all remaining are unresolved
          list.map([target, ..rest_targets], fn(t) { t.summary })
        }
      }
    }
  }
}
