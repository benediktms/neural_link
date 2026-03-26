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
import neural_link/persistence/brain as brain_persistence
import neural_link/persistence/config.{type PersistencePluginConfig}
import neural_link/persistence/plugin as persistence_plugin
import neural_link/persistence/types as persistence_types
import neural_link/runtime/inbox as inbox_mod
import neural_link/runtime/presence as presence_mod
import neural_link/runtime/registry as registry_mod
import neural_link/runtime/room as room_mod

// ---------------------------------------------------------------------------
// Handler configuration (for testing injection)
// ---------------------------------------------------------------------------

pub type HandlerConfig {
  HandlerConfig(
    registry: Subject(registry_mod.RegistryMessage),
    inbox: Subject(inbox_mod.InboxMessage),
    presence: Subject(presence_mod.PresenceMessage),
  )
}

fn resolve_plugin_config_real(
  cfg: PersistencePluginConfig,
) -> Option(persistence_plugin.PersistencePlugin) {
  case cfg {
    config.BrainPlugin(brain_name: brain_name) ->
      Some(brain_persistence.brain_plugin(brain_name))
    _ -> None
  }
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn make_handler(config: HandlerConfig) -> transport.ToolCallHandler {
  do_make_handler(config, resolve_plugin_config_real)
}

pub fn make_handler_for_testing(
  config: HandlerConfig,
  plugin_resolver: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
) -> transport.ToolCallHandler {
  do_make_handler(config, plugin_resolver)
}

fn do_make_handler(
  config: HandlerConfig,
  resolve_plugin: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
) -> transport.ToolCallHandler {
  let HandlerConfig(registry: registry, inbox: inbox, presence: presence) =
    config
  fn(tool_name: String, arguments: Option(Dynamic)) -> Result(json.Json, String) {
    case tool_name {
      "room_open" ->
        handle_room_open(registry, presence, arguments, resolve_plugin)
      "room_join" -> handle_room_join(registry, presence, arguments)
      "room_leave" -> handle_room_leave(registry, inbox, presence, arguments)
      "message_send" ->
        handle_message_send(registry, inbox, arguments, resolve_plugin)
      "inbox_read" -> handle_inbox_read(registry, arguments)
      "message_ack" -> handle_message_ack(registry, arguments)
      "wait_for" -> handle_wait_for(registry, inbox, arguments)
      "thread_summarize" -> handle_thread_summarize(registry, arguments)
      "room_close" ->
        handle_room_close(registry, presence, arguments, resolve_plugin)
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
    "escalation" -> Ok(message.Escalation)
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
    // "lead" falls through to Member — lead is auto-assigned via room_open
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
  presence: Subject(presence_mod.PresenceMessage),
  arguments: Option(Dynamic),
  resolve_plugin: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use title <- result.try(get_string_param(params, "title"))
  use pid_str <- result.try(get_string_param(params, "participant_id"))
  use display_name <- result.try(get_string_param(params, "display_name"))
  let purpose = get_optional_string_param(params, "purpose")
  let external_ref = get_optional_string_param(params, "external_ref")
  let tags =
    get_optional_string_param(params, "tags")
    |> option.map(split_comma)
    |> option.unwrap([])
  let plugins =
    get_optional_string_param(params, "brains")
    |> option.map(split_comma)
    |> option.unwrap([])
    |> list.map(config.brain_plugin)
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
    plugins,
    mode,
  ))
  // Fire-and-forget plugin notification per declared plugin
  notify_plugins(room.plugins, resolve_plugin, fn(p) {
    persistence_plugin.notify(p, persistence_plugin.RoomOpened(room))
  })
  let id.RoomId(room_id_str) = room.id
  // Auto-join opener as Lead
  let lead =
    participant_domain.new(pid_str, display_name, participant_domain.Lead)
  use room_subject <- result.try(registry_mod.get_room(registry, room_id_str))
  use _ <- result.try(room_mod.join(room_subject, lead))
  presence_mod.register(presence, ParticipantId(pid_str), room_id_str, 300_000)
  Ok(
    json.object([
      #("room_id", json.string(room_id_str)),
      #("title", json.string(room.title)),
      #("status", json.string("open")),
      #("participant_id", json.string(pid_str)),
      #("role", json.string("lead")),
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
  let agent_id = get_optional_string_param(params, "agent_id")
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
  use _ <- result.try(room_mod.join(room_subject, p))
  // Register in presence tracker
  presence_mod.register(
    presence,
    ParticipantId(participant_id),
    room_id,
    300_000,
  )
  // Register agent_id → participant_id mapping (for PostToolUse hook)
  case agent_id {
    Some(aid) ->
      presence_mod.register_agent(presence, aid, ParticipantId(participant_id))
    None -> Nil
  }
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
// Handler: room_leave
// ---------------------------------------------------------------------------

fn handle_room_leave(
  registry: Subject(registry_mod.RegistryMessage),
  inbox: Subject(inbox_mod.InboxMessage),
  presence: Subject(presence_mod.PresenceMessage),
  arguments: Option(Dynamic),
) -> Result(json.Json, String) {
  use params <- result.try(require_params(arguments))
  use room_id <- result.try(get_string_param(params, "room_id"))
  use pid_str <- result.try(get_string_param(params, "participant_id"))
  let pid = ParticipantId(pid_str)
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
  use room_subject <- result.try(registry_mod.get_room(registry, room_id))
  let drain_subject = process.new_subject()
  use leave_result <- result.try(room_mod.leave(
    room_subject,
    pid,
    drain_subject,
  ))
  // Resolve drain
  let drain_completed = case leave_result {
    room_mod.Departed -> True
    room_mod.DrainStarted(_) -> {
      case process.receive(drain_subject, timeout_ms) {
        Ok(Nil) -> True
        Error(Nil) -> {
          // Timeout — force departure
          let _ = room_mod.force_departure(room_subject, pid)
          False
        }
      }
    }
  }
  // Departure cleanup
  let room_state = room_mod.get_state(room_subject)
  let lead_opt = domain_room.find_lead(room_state)
  let active = domain_room.active_participants(room_state)
  let active_ids = list.map(active, fn(p) { p.id })
  // Notify inbox of departure (only if lead exists)
  case lead_opt {
    Some(lead) -> {
      let departure_result =
        inbox_mod.participant_departed(
          inbox,
          id.RoomId(room_id),
          pid,
          lead.id,
          active_ids,
        )
      // Only send escalation if waits were actually affected
      case departure_result.escalated_waiter_ids {
        [] -> Nil
        _escalated -> {
          let escalation_body =
            json.to_string(
              json.object([
                #("departed_participant_id", json.string(pid_str)),
                #("event", json.string("participant_departed")),
              ]),
            )
          let escalation_result =
            room_mod.send_msg_full(
              room_subject,
              lead.id,
              [lead.id],
              message.Escalation,
              "Agent "
                <> pid_str
                <> " departed. Pending waits escalated to lead.",
              Some(escalation_body),
              None,
            )
          case escalation_result {
            Ok(esc_msg) -> inbox_mod.notify_message(inbox, esc_msg)
            Error(_) -> Nil
          }
        }
      }
    }
    None -> Nil
  }
  // Unregister from presence
  presence_mod.unregister(presence, pid, room_id)
  Ok(
    json.object([
      #("room_id", json.string(room_id)),
      #("participant_id", json.string(pid_str)),
      #("status", json.string("departed")),
      #("drain_completed", json.bool(drain_completed)),
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
  resolve_plugin: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
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
  // Fire-and-forget plugin notification using per-room plugins
  let room_state = room_mod.get_state(room_subject)
  notify_plugins(room_state.plugins, resolve_plugin, fn(p) {
    persistence_plugin.notify(p, persistence_plugin.Message(msg))
  })
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
        inbox_mod.register_wait(
          inbox,
          pid,
          filter,
          since_seq,
          timeout_ms,
          Some(id.RoomId(room_id)),
        )
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
  resolve_plugin: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
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
  let conv =
    persist_conversation_artifact(
      room_state.plugins,
      closed_room,
      conv,
      resolve_plugin,
    )
  // Fire-and-forget metadata record (lightweight index)
  let message_count = list.length(messages)
  let duration_ms =
    birl.to_unix_milli(birl.utc_now())
    - birl.to_unix_milli(room_state.created_at)
  notify_plugins(room_state.plugins, resolve_plugin, fn(p) {
    persistence_plugin.notify(
      p,
      persistence_plugin.RoomClosed(closed_room, message_count, duration_ms),
    )
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
  plugins: List(PersistencePluginConfig),
  room: domain_room.Room,
  conv: extraction.ConversationExtraction,
  resolve_plugin: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
) -> extraction.ConversationExtraction {
  // Notify each plugin synchronously. Collect the first successful record ID.
  // The canonical ID comes from SqliteStore; this ID is from the first
  // replication plugin that succeeds (typically BrainPlugin).
  let record_id = case conv.artifact_record_id {
    Some(id) -> Some(id)
    None -> {
      find_first_artifact_record_id(plugins, room, conv.content, resolve_plugin)
    }
  }
  extraction.ConversationExtraction(..conv, artifact_record_id: record_id)
}

fn find_first_artifact_record_id(
  plugins: List(PersistencePluginConfig),
  room: domain_room.Room,
  content: String,
  resolve_plugin: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
) -> option.Option(String) {
  case plugins {
    [] -> option.None
    [plugin_cfg, ..rest] -> {
      case resolve_plugin(plugin_cfg) {
        None ->
          find_first_artifact_record_id(rest, room, content, resolve_plugin)
        Some(p) -> {
          case
            persistence_plugin.notify(
              p,
              persistence_plugin.ConversationArtifact(room, content, ""),
            )
          {
            Ok(Nil) -> option.Some("")
            Error(err) -> {
              logging.log(
                logging.Warning,
                "plugin artifact failed: "
                  <> persistence_types.error_to_string(err),
              )
              find_first_artifact_record_id(rest, room, content, resolve_plugin)
            }
          }
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
// Plugin notification helpers
// ---------------------------------------------------------------------------

/// Fire-and-forget plugin notification. Builds a PersistencePlugin for each
/// BrainPlugin config, spawns a process to call the action, and logs errors.
/// SqlitePlugin configs are ignored (stub, not yet implemented).
fn notify_plugins(
  plugins: List(PersistencePluginConfig),
  resolve_plugin: fn(PersistencePluginConfig) ->
    Option(persistence_plugin.PersistencePlugin),
  action: fn(persistence_plugin.PersistencePlugin) ->
    Result(Nil, persistence_types.PersistenceError),
) -> Nil {
  list.each(plugins, fn(plugin_cfg) {
    case resolve_plugin(plugin_cfg) {
      None -> Nil
      Some(p) -> {
        process.spawn(fn() {
          case action(p) {
            Ok(Nil) -> Nil
            Error(err) ->
              logging.log(
                logging.Warning,
                "plugin notification failed: "
                  <> persistence_types.error_to_string(err),
              )
          }
        })
        Nil
      }
    }
  })
}
