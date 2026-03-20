import birl
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import neural_link/brain/bridge
import neural_link/brain/types.{type BrainConfig, BrainConfig}
import neural_link/domain/id.{
  MessageId, ParticipantId, ThreadId, message_id_to_string,
  participant_id_to_string,
}
import neural_link/domain/interaction_mode
import neural_link/domain/message
import neural_link/domain/participant as participant_domain
import neural_link/domain/room as domain_room
import neural_link/domain/summary as extraction
import neural_link/domain/wait
import neural_link/mcp/transport
import neural_link/runtime/inbox as inbox_mod
import neural_link/runtime/presence as presence_mod
import neural_link/runtime/registry as registry_mod
import neural_link/runtime/room as room_mod

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn make_handler(
  registry: Subject(registry_mod.RegistryMessage),
  inbox: Subject(inbox_mod.InboxMessage),
  presence: Subject(presence_mod.PresenceMessage),
) -> transport.ToolCallHandler {
  fn(tool_name: String, arguments: Option(Dynamic)) -> Result(json.Json, String) {
    case tool_name {
      "room_open" -> handle_room_open(registry, arguments)
      "room_join" -> handle_room_join(registry, presence, arguments)
      "message_send" -> handle_message_send(registry, inbox, arguments)
      "inbox_read" -> handle_inbox_read(registry, arguments)
      "message_ack" -> handle_message_ack(registry, arguments)
      "wait_for" -> handle_wait_for(registry, inbox, arguments)
      "thread_summarize" -> handle_thread_summarize(registry, arguments)
      "room_close" -> handle_room_close(registry, presence, arguments)
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
    "challenge" -> Ok(message.Challenge)
    "proposal" -> Ok(message.Proposal)
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

fn message_fields(msg: message.Message) -> List(#(String, json.Json)) {
  let mid = message_id_to_string(msg.message_id)
  let from = participant_id_to_string(msg.from)
  let kind_str = message.kind_to_string(msg.kind)
  [
    #("message_id", json.string(mid)),
    #("from", json.string(from)),
    #("kind", json.string(kind_str)),
    #("summary", json.string(msg.summary)),
    #("sequence", json.int(msg.sequence)),
  ]
}

fn encode_message(msg: message.Message) -> json.Json {
  json.object(message_fields(msg))
}

// ---------------------------------------------------------------------------
// Inbox nudge helper
// ---------------------------------------------------------------------------

/// Query pending inbox count for a participant in a room and append
/// `_inbox_pending` to the response fields.
fn with_inbox_nudge(
  room_subject: Subject(room_mod.RoomMessage),
  participant_id: String,
  fields: List(#(String, json.Json)),
) -> json.Json {
  let count = room_mod.inbox_count(room_subject, ParticipantId(participant_id))
  json.object(list.append(fields, [#("_inbox_pending", json.int(count))]))
}

// ---------------------------------------------------------------------------
// Handler: room_open
// ---------------------------------------------------------------------------

fn handle_room_open(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use title <- result.try(get_string_param(params, "title"))
  let purpose = get_optional_string_param(params, "purpose")
  let external_ref = get_optional_string_param(params, "external_ref")
  let tags =
    get_optional_string_param(params, "tags")
    |> option.map(split_comma)
    |> option.unwrap([])
  let brains =
    get_optional_string_param(params, "brains")
    |> option.map(split_comma)
    |> option.unwrap([])
  let mode =
    get_optional_string_param(params, "interaction_mode")
    |> option.then(fn(s) {
      case interaction_mode.mode_from_string(s) {
        Ok(m) -> Some(m)
        Error(_) -> None
      }
    })
  use room <- result.try(registry_mod.create_room(
    registry,
    title,
    purpose,
    external_ref,
    tags,
    brains,
    mode,
  ))
  // Fire-and-forget brain bridge per declared brain
  fire_brain_bridge(room.brains, fn(cfg) { bridge.on_room_open(cfg, room) })
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
  presence: Subject(presence_mod.PresenceMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  use participant_id <- result.try(get_string_param(params, "participant_id"))
  use display_name <- result.try(get_string_param(params, "display_name"))
  let role_str =
    get_optional_string_param(params, "role")
    |> option.unwrap("member")
  let role = parse_role(role_str)
  let p = participant_domain.new(participant_id, display_name, role)
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
  use _ <- result.try(room_mod.join(room_subject, p))
  // Register in presence tracker
  presence_mod.register(
    presence,
    ParticipantId(participant_id),
    room_id,
    300_000,
  )
  let room_state = room_mod.get_state(room_subject)
  let mode_field = case room_state.interaction_mode {
    Some(m) -> json.string(interaction_mode.mode_to_string(m))
    None -> json.null()
  }
  Ok(
    json.object([
      #("room_id", json.string(room_id)),
      #("participant_id", json.string(participant_id)),
      #("joined", json.bool(True)),
      #("interaction_mode", mode_field),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Handler: message_send
// ---------------------------------------------------------------------------

fn handle_message_send(
  registry: Subject(registry_mod.RegistryMessage),
  inbox: Subject(inbox_mod.InboxMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  use from_str <- result.try(get_string_param(params, "from"))
  use kind_str <- result.try(get_string_param(params, "kind"))
  use summary <- result.try(get_string_param(params, "summary"))
  use kind <- result.try(parse_kind(kind_str))
  let from_id = ParticipantId(from_str)
  let to_ids =
    get_optional_string_param(params, "to")
    |> option.map(fn(to_str) {
      split_comma(to_str)
      |> list.map(ParticipantId)
    })
    |> option.unwrap([])
  let body = get_optional_string_param(params, "body")
  let thread_id =
    get_optional_string_param(params, "thread_id")
    |> option.map(ThreadId)
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
  use msg <- result.try(room_mod.send_msg_full(
    room_subject,
    from_id,
    to_ids,
    kind,
    summary,
    body,
    thread_id,
  ))
  // Notify inbox of new message
  inbox_mod.notify_message(inbox, msg)
  // Fire-and-forget brain bridge using per-room brains
  let room_state = room_mod.get_state(room_subject)
  fire_brain_bridge(room_state.brains, fn(cfg) { bridge.on_message(cfg, msg) })
  let mid = message_id_to_string(msg.message_id)
  let id.RoomId(rid) = msg.room_id
  Ok(
    with_inbox_nudge(room_subject, from_str, [
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
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  use participant_id_str <- result.try(get_string_param(
    params,
    "participant_id",
  ))
  let pid = ParticipantId(participant_id_str)
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
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
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  use participant_id_str <- result.try(get_string_param(
    params,
    "participant_id",
  ))
  use message_ids_str <- result.try(get_string_param(params, "message_ids"))
  let pid = ParticipantId(participant_id_str)
  let mids =
    split_comma(message_ids_str)
    |> list.map(MessageId)
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
  use _ <- result.try(room_mod.ack_messages(room_subject, pid, mids))
  Ok(
    with_inbox_nudge(room_subject, participant_id_str, [
      #("acked", json.bool(True)),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Handler: wait_for
// ---------------------------------------------------------------------------

fn handle_wait_for(
  registry: Subject(registry_mod.RegistryMessage),
  inbox: Subject(inbox_mod.InboxMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  use participant_id_str <- result.try(get_string_param(
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

  let timeout_ms = {
    let raw =
      get_optional_string_param(params, "timeout_ms")
      |> option.then(fn(s) {
        case int.parse(s) {
          Ok(n) -> Some(n)
          Error(_) -> None
        }
      })
      |> option.unwrap(30_000)
    int.min(raw, 120_000)
  }

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

  use room_subject <- result.try(registry_mod.get_room(registry, room_id))

  // Query room messages in the handler layer (not inside inbox actor) to avoid deadlock
  let messages = room_mod.get_messages(room_subject, None)
  let existing_match =
    list.find(list.reverse(messages), fn(m) {
      m.sequence > since_seq && wait.matches_filter(filter, m.kind, m.from)
    })
  let nudge = fn(msg) {
    with_inbox_nudge(room_subject, participant_id_str, message_fields(msg))
  }
  case existing_match {
    Ok(msg) -> Ok(nudge(msg))
    Error(_) -> {
      // No immediate match — register wait with inbox (non-blocking for inbox)
      let wait_result =
        inbox_mod.register_wait(inbox, pid, filter, since_seq, timeout_ms)
      case wait_result {
        Ok(msg) -> Ok(nudge(msg))
        Error(e) -> Error(e)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Handler: thread_summarize
// ---------------------------------------------------------------------------

fn handle_thread_summarize(
  registry: Subject(registry_mod.RegistryMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  let thread_id_opt =
    get_optional_string_param(params, "thread_id")
    |> option.map(ThreadId)
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
  let room_state = room_mod.get_state(room_subject)
  let messages = room_mod.get_messages(room_subject, thread_id_opt)
  let result = extraction.extract(room_state, thread_id_opt, messages)
  Ok(extraction.encode(result))
}

// ---------------------------------------------------------------------------
// Handler: room_close
// ---------------------------------------------------------------------------

fn handle_room_close(
  registry: Subject(registry_mod.RegistryMessage),
  presence: Subject(presence_mod.PresenceMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  use resolution_str <- result.try(get_string_param(params, "resolution"))
  use resolution <- result.try(parse_resolution(resolution_str))
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
  // Get state and messages before close for brain bridge
  let room_state = room_mod.get_state(room_subject)
  let messages = room_mod.get_messages(room_subject, None)
  use _ <- result.try(room_mod.close_room(room_subject, resolution))
  // Unregister all participants from presence
  list.each(room_state.participants, fn(p) {
    presence_mod.unregister(presence, p.id, room_id)
  })
  let closed_room = domain_room.close_with_resolution(room_state, resolution)
  // Extract structured conversation data
  let conv = extraction.extract(closed_room, None, messages)
  // Persist conversation artifact synchronously (need the record ID)
  let conv = persist_conversation_artifact(room_state.brains, closed_room, conv)
  // Fire-and-forget metadata record (lightweight index)
  let message_count = list.length(messages)
  let duration_ms =
    birl.to_unix_milli(birl.utc_now())
    - birl.to_unix_milli(room_state.created_at)
  fire_brain_bridge(room_state.brains, fn(cfg) {
    bridge.on_room_close(cfg, closed_room, message_count, duration_ms)
  })
  // Compute compliance if interaction mode is set
  let compliance_fields = case room_state.interaction_mode {
    Some(mode) -> {
      let sorted_messages =
        list.sort(messages, fn(a, b) { int.compare(a.sequence, b.sequence) })
      let report =
        interaction_mode.compute_compliance(
          sorted_messages,
          room_state.participants,
          mode,
        )
      [
        #(
          "interaction_mode",
          json.string(interaction_mode.mode_to_string(mode)),
        ),
        #(
          "compliance",
          json.object([
            #("expectations_checked", json.int(report.expectations_checked)),
            #("expectations_fulfilled", json.int(report.expectations_fulfilled)),
            #(
              "unchallenged_findings",
              json.array(report.unchallenged_findings, json.int),
            ),
          ]),
        ),
      ]
    }
    None -> []
  }
  Ok(
    json.object([
      #("room_id", json.string(room_id)),
      #("status", json.string("closed")),
      ..list.append(extraction_fields(conv), compliance_fields)
    ]),
  )
}

fn persist_conversation_artifact(
  brains: List(String),
  room: domain_room.Room,
  conv: extraction.ConversationExtraction,
) -> extraction.ConversationExtraction {
  // Try each brain synchronously until one succeeds
  case brains {
    [] -> conv
    [brain_name, ..rest] -> {
      let cfg = types.BrainConfig(brain_name: brain_name)
      case bridge.on_room_close_with_artifact(cfg, room, conv.content) {
        Ok(record_id) -> extraction.set_artifact_id(conv, record_id)
        Error(err) -> {
          logging.log(
            logging.Warning,
            "brain artifact failed: " <> brain_error_to_string(err),
          )
          persist_conversation_artifact(rest, room, conv)
        }
      }
    }
  }
}

fn extraction_fields(
  conv: extraction.ConversationExtraction,
) -> List(#(String, json.Json)) {
  let artifact = case conv.artifact_record_id {
    Some(id) -> json.string(id)
    None -> json.null()
  }
  [
    #("message_count", json.int(conv.message_count)),
    #("participant_ids", json.array(conv.participant_ids, json.string)),
    #("decisions", json.array(conv.decisions, json.string)),
    #("open_questions", json.array(conv.open_questions, json.string)),
    #("unresolved_blockers", json.array(conv.unresolved_blockers, json.string)),
    #("artifact_record_id", artifact),
  ]
}

// ---------------------------------------------------------------------------
// Brain bridge helpers
// ---------------------------------------------------------------------------

fn fire_brain_bridge(
  brains: List(String),
  action: fn(BrainConfig) -> types.BrainResult(String),
) -> Nil {
  list.each(brains, fn(brain_name) {
    let cfg = BrainConfig(brain_name: brain_name)
    process.spawn(fn() {
      case action(cfg) {
        Ok(_) -> Nil
        Error(err) ->
          logging.log(
            logging.Warning,
            "brain bridge failed: " <> brain_error_to_string(err),
          )
      }
    })
    Nil
  })
}

fn brain_error_to_string(err: types.BrainError) -> String {
  case err {
    types.Timeout -> "timeout"
    types.CommandFailed(s) -> "command failed: " <> s
    types.ParseError(s) -> "parse error: " <> s
  }
}
