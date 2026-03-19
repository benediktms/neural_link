import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import neural_link/domain/id.{
  MessageId, ParticipantId, ThreadId, message_id_to_string,
  participant_id_to_string,
}
import neural_link/domain/message
import neural_link/domain/participant as participant_domain
import neural_link/domain/room as domain_room
import neural_link/domain/wait
import neural_link/mcp/transport
import neural_link/runtime/registry as registry_mod
import neural_link/runtime/room as room_mod

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn make_handler(
  registry: Subject(registry_mod.RegistryMessage),
) -> transport.ToolCallHandler {
  fn(tool_name: String, arguments: Option(Dynamic)) -> Result(json.Json, String) {
    case tool_name {
      "room_open" -> handle_room_open(registry, arguments)
      "room_join" -> handle_room_join(registry, arguments)
      "message_send" -> handle_message_send(registry, arguments)
      "inbox_read" -> handle_inbox_read(registry, arguments)
      "message_ack" -> handle_message_ack(registry, arguments)
      "wait_for" -> handle_wait_for(registry, arguments)
      "thread_summarize" -> handle_thread_summarize(registry, arguments)
      "room_close" -> handle_room_close(registry, arguments)
      _ -> Error("Unknown tool: " <> tool_name)
    }
  }
}

// ---------------------------------------------------------------------------
// Param extraction helpers
// ---------------------------------------------------------------------------

fn get_string_param(params: Dynamic, field: String) -> Result(String, String) {
  let decoder = decode.field(field, decode.string, decode.success)
  case decode.run(params, decoder) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("Missing required param: " <> field)
  }
}

fn get_optional_string_param(params: Dynamic, field: String) -> Option(String) {
  let decoder = decode.field(field, decode.string, decode.success)
  case decode.run(params, decoder) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn require_params(arguments: Option(Dynamic)) -> Result(Dynamic, String) {
  case arguments {
    None -> Error("Missing arguments")
    Some(params) -> Ok(params)
  }
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

fn parse_kind(s: String) -> Result(message.MessageKind, String) {
  case string.lowercase(s) {
    "question" -> Ok(message.Question)
    "answer" -> Ok(message.Answer)
    "finding" -> Ok(message.Finding)
    "handoff" -> Ok(message.Handoff)
    "blocker" -> Ok(message.Blocker)
    "decision" -> Ok(message.Decision)
    "review_request" -> Ok(message.ReviewRequest)
    "review_result" -> Ok(message.ReviewResult)
    "artifact_ref" -> Ok(message.ArtifactRef)
    "summary" -> Ok(message.Summary)
    _ -> Error("Unknown message kind: " <> s)
  }
}

fn parse_resolution(s: String) -> Result(domain_room.RoomResolution, String) {
  case string.lowercase(s) {
    "completed" -> Ok(domain_room.Completed)
    "cancelled" -> Ok(domain_room.Cancelled)
    "superseded" -> Ok(domain_room.Superseded)
    "failed" -> Ok(domain_room.Failed)
    _ -> Error("Unknown resolution: " <> s)
  }
}

fn parse_role(s: String) -> participant_domain.ParticipantRole {
  case string.lowercase(s) {
    "owner" -> participant_domain.Owner
    "observer" -> participant_domain.Observer
    _ -> participant_domain.Member
  }
}

fn split_comma(s: String) -> List(String) {
  string.split(s, ",")
  |> list.map(string.trim)
  |> list.filter(fn(x) { x != "" })
}

// ---------------------------------------------------------------------------
// Encode message to JSON
// ---------------------------------------------------------------------------

fn encode_message(msg: message.Message) -> json.Json {
  let mid = message_id_to_string(msg.message_id)
  let from = participant_id_to_string(msg.from)
  let kind_str = kind_to_string(msg.kind)
  json.object([
    #("message_id", json.string(mid)),
    #("from", json.string(from)),
    #("kind", json.string(kind_str)),
    #("summary", json.string(msg.summary)),
    #("sequence", json.int(msg.sequence)),
  ])
}

fn kind_to_string(kind: message.MessageKind) -> String {
  case kind {
    message.Question -> "question"
    message.Answer -> "answer"
    message.Finding -> "finding"
    message.Handoff -> "handoff"
    message.Blocker -> "blocker"
    message.Decision -> "decision"
    message.ReviewRequest -> "review_request"
    message.ReviewResult -> "review_result"
    message.ArtifactRef -> "artifact_ref"
    message.Summary -> "summary"
  }
}

// ---------------------------------------------------------------------------
// Handler: room_open
// ---------------------------------------------------------------------------

fn handle_room_open(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use title <- result_then(get_string_param(params, "title"))
  use room <- result_then(registry_mod.create_room(registry, title))
  let id.RoomId(room_id_str) = room.id
  Ok(
    json.object([
      #("room_id", json.string(room_id_str)),
      #("title", json.string(room.title)),
      #("status", json.string("open")),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Handler: room_join
// ---------------------------------------------------------------------------

fn handle_room_join(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use room_id <- result_then(get_string_param(params, "room_id"))
  use participant_id <- result_then(get_string_param(params, "participant_id"))
  use display_name <- result_then(get_string_param(params, "display_name"))
  let role_str =
    get_optional_string_param(params, "role")
    |> option.unwrap("member")
  let role = parse_role(role_str)
  let p = participant_domain.new(participant_id, display_name, role)
  use room_subject <- result_then(registry_mod.get_room(registry, room_id))
  use _ <- result_then(room_mod.join(room_subject, p))
  Ok(
    json.object([
      #("room_id", json.string(room_id)),
      #("participant_id", json.string(participant_id)),
      #("joined", json.bool(True)),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Handler: message_send
// ---------------------------------------------------------------------------

fn handle_message_send(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use room_id <- result_then(get_string_param(params, "room_id"))
  use from_str <- result_then(get_string_param(params, "from"))
  use kind_str <- result_then(get_string_param(params, "kind"))
  use summary <- result_then(get_string_param(params, "summary"))
  use kind <- result_then(parse_kind(kind_str))
  let from_id = ParticipantId(from_str)
  let to_ids =
    get_optional_string_param(params, "to")
    |> option.map(fn(to_str) {
      split_comma(to_str)
      |> list.map(ParticipantId)
    })
    |> option.unwrap([])
  use room_subject <- result_then(registry_mod.get_room(registry, room_id))
  use msg <- result_then(room_mod.send_msg(
    room_subject,
    from_id,
    to_ids,
    kind,
    summary,
  ))
  let mid = message_id_to_string(msg.message_id)
  let id.RoomId(rid) = msg.room_id
  Ok(
    json.object([
      #("message_id", json.string(mid)),
      #("room_id", json.string(rid)),
      #("sequence", json.int(msg.sequence)),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Handler: inbox_read
// ---------------------------------------------------------------------------

fn handle_inbox_read(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use room_id <- result_then(get_string_param(params, "room_id"))
  use participant_id_str <- result_then(get_string_param(
    params,
    "participant_id",
  ))
  let pid = ParticipantId(participant_id_str)
  use room_subject <- result_then(registry_mod.get_room(registry, room_id))
  let messages = room_mod.read_inbox(room_subject, pid)
  Ok(json.array(messages, encode_message))
}

// ---------------------------------------------------------------------------
// Handler: message_ack
// ---------------------------------------------------------------------------

fn handle_message_ack(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use room_id <- result_then(get_string_param(params, "room_id"))
  use participant_id_str <- result_then(get_string_param(
    params,
    "participant_id",
  ))
  use message_ids_str <- result_then(get_string_param(params, "message_ids"))
  let pid = ParticipantId(participant_id_str)
  let mids =
    split_comma(message_ids_str)
    |> list.map(MessageId)
  use room_subject <- result_then(registry_mod.get_room(registry, room_id))
  use _ <- result_then(room_mod.ack_messages(room_subject, pid, mids))
  Ok(json.object([#("acked", json.bool(True))]))
}

// ---------------------------------------------------------------------------
// Handler: wait_for
// ---------------------------------------------------------------------------

fn handle_wait_for(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use room_id <- result_then(get_string_param(params, "room_id"))
  use participant_id_str <- result_then(get_string_param(
    params,
    "participant_id",
  ))
  let pid = ParticipantId(participant_id_str)

  let since_seq =
    get_optional_string_param(params, "since_sequence")
    |> option.then(fn(s) {
      case int.parse(s) {
        Ok(n) -> Some(n)
        Error(_) -> None
      }
    })
    |> option.unwrap(0)

  let timeout_ms =
    get_optional_string_param(params, "timeout_ms")
    |> option.then(fn(s) {
      case int.parse(s) {
        Ok(n) -> Some(n)
        Error(_) -> None
      }
    })
    |> option.unwrap(30_000)

  let kinds =
    get_optional_string_param(params, "kinds")
    |> option.map(fn(s) {
      split_comma(s)
      |> list.filter_map(fn(k) { parse_kind(k) })
    })
    |> option.unwrap([])

  let froms =
    get_optional_string_param(params, "from")
    |> option.map(fn(s) {
      split_comma(s)
      |> list.map(ParticipantId)
    })
    |> option.unwrap([])

  let filter = wait.WaitFilter(kinds: kinds, from: froms)

  use room_subject <- result_then(registry_mod.get_room(registry, room_id))

  let call_timeout = timeout_ms + 5000
  let wait_result =
    actor.call(room_subject, call_timeout, fn(reply) {
      room_mod.RegisterWait(
        participant_id: pid,
        filter: filter,
        since_sequence: since_seq,
        timeout_ms: timeout_ms,
        reply: reply,
      )
    })

  case wait_result {
    Ok(msg) -> Ok(encode_message(msg))
    Error(e) -> Error(e)
  }
}

// ---------------------------------------------------------------------------
// Handler: thread_summarize
// ---------------------------------------------------------------------------

fn handle_thread_summarize(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use room_id <- result_then(get_string_param(params, "room_id"))
  let thread_id_opt =
    get_optional_string_param(params, "thread_id")
    |> option.map(ThreadId)
  use room_subject <- result_then(registry_mod.get_room(registry, room_id))
  let messages = room_mod.get_messages(room_subject, thread_id_opt)
  let count = list.length(messages)
  let summary =
    messages
    |> list.map(fn(m) { m.summary })
    |> string.join(" | ")
  Ok(
    json.object([
      #("summary", json.string(summary)),
      #("message_count", json.int(count)),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Handler: room_close
// ---------------------------------------------------------------------------

fn handle_room_close(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result_then(require_params(arguments))
  use room_id <- result_then(get_string_param(params, "room_id"))
  use resolution_str <- result_then(get_string_param(params, "resolution"))
  use resolution <- result_then(parse_resolution(resolution_str))
  use room_subject <- result_then(registry_mod.get_room(registry, room_id))
  use _ <- result_then(room_mod.close_room(room_subject, resolution))
  Ok(
    json.object([
      #("room_id", json.string(room_id)),
      #("status", json.string("closed")),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Utility: monadic result chaining
// ---------------------------------------------------------------------------

fn result_then(result: Result(a, e), f: fn(a) -> Result(b, e)) -> Result(b, e) {
  case result {
    Ok(value) -> f(value)
    Error(e) -> Error(e)
  }
}
