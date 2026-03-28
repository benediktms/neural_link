import birl
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/string
import mist.{type Connection, type ResponseData}
import neural_link/domain/id.{ParticipantId}
import neural_link/mcp/codec
import neural_link/mcp/protocol.{
  type JsonRpcRequest, type ToolDefinition, JsonRpcError,
}
import neural_link/mcp/transport.{type ToolCallHandler}
import neural_link/runtime/presence as presence_mod
import neural_link/runtime/registry as registry_mod
import neural_link/runtime/room as room_mod

// ---------------------------------------------------------------------------
// Session management actor
// ---------------------------------------------------------------------------

const session_max_age_ms = 3_600_000

const cleanup_interval_ms = 300_000

type SessionState {
  SessionState(
    sessions: Dict(String, Int),
    self_subject: Subject(SessionMessage),
  )
}

pub type SessionMessage {
  CreateSession(reply: Subject(String))
  ValidateSession(session_id: String, reply: Subject(Bool))
  CleanExpired
  SetSelf(subject: Subject(SessionMessage))
  SessionShutdown
}

fn start_session_manager() -> Result(Subject(SessionMessage), String) {
  case
    actor.new(SessionState(
      sessions: dict.new(),
      self_subject: process.new_subject(),
    ))
    |> actor.on_message(handle_session_message)
    |> actor.start
  {
    Ok(started) -> {
      // Wire the actor's own subject so it can re-arm timers
      actor.send(started.data, SetSelf(started.data))
      // Arm the initial cleanup timer
      process.send_after(started.data, cleanup_interval_ms, CleanExpired)
      Ok(started.data)
    }
    Error(_) -> Error("Failed to start session manager")
  }
}

fn handle_session_message(
  state: SessionState,
  msg: SessionMessage,
) -> actor.Next(SessionState, SessionMessage) {
  case msg {
    CreateSession(reply) -> {
      let id = generate_session_id()
      let now = birl.to_unix_milli(birl.utc_now())
      let new_sessions = dict.insert(state.sessions, id, now)
      actor.send(reply, id)
      actor.continue(SessionState(..state, sessions: new_sessions))
    }
    ValidateSession(session_id, reply) -> {
      let now = birl.to_unix_milli(birl.utc_now())
      let valid = case dict.get(state.sessions, session_id) {
        Ok(created_at) -> now - created_at < session_max_age_ms
        Error(_) -> False
      }
      actor.send(reply, valid)
      actor.continue(state)
    }
    CleanExpired -> {
      let now = birl.to_unix_milli(birl.utc_now())
      let new_sessions =
        dict.filter(state.sessions, fn(_id, created_at) {
          now - created_at < session_max_age_ms
        })
      // Re-arm the cleanup timer
      process.send_after(state.self_subject, cleanup_interval_ms, CleanExpired)
      actor.continue(SessionState(..state, sessions: new_sessions))
    }
    SetSelf(subject) -> {
      actor.continue(SessionState(..state, self_subject: subject))
    }
    SessionShutdown -> actor.stop()
  }
}

fn generate_session_id() -> String {
  let bytes = crypto.strong_random_bytes(16)
  bit_array.base16_encode(bytes) |> string.lowercase
}

fn create_session(sessions: Subject(SessionMessage)) -> String {
  actor.call(sessions, 5000, fn(reply) { CreateSession(reply) })
}

fn validate_session(sessions: Subject(SessionMessage), id: String) -> Bool {
  actor.call(sessions, 5000, fn(reply) { ValidateSession(id, reply) })
}

// ---------------------------------------------------------------------------
// HTTP transport entry point
// ---------------------------------------------------------------------------

pub fn start(
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
  port: Int,
  registry: Subject(registry_mod.RegistryMessage),
  presence: Subject(presence_mod.PresenceMessage),
) -> Nil {
  case start_server(tools, handler, port, registry, presence) {
    Error(err) -> {
      io.println_error("Failed to start HTTP server: " <> err)
    }
    Ok(_) -> {
      // Block forever — mist runs in its own supervision tree
      process.sleep_forever()
    }
  }
}

/// Start the HTTP server without blocking. Returns the session manager subject.
/// Useful for testing.
pub fn start_server(
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
  port: Int,
  registry: Subject(registry_mod.RegistryMessage),
  presence: Subject(presence_mod.PresenceMessage),
) -> Result(Subject(SessionMessage), String) {
  case start_session_manager() {
    Error(err) -> Error("Failed to start session manager: " <> err)
    Ok(sessions) -> {
      io.println(
        "neural_link MCP HTTP server starting on port " <> int.to_string(port),
      )
      let assert Ok(_) =
        mist.new(fn(req) {
          handle_request(req, tools, handler, sessions, registry, presence)
        })
        |> mist.port(port)
        |> mist.start
      Ok(sessions)
    }
  }
}

// ---------------------------------------------------------------------------
// Request routing
// ---------------------------------------------------------------------------

fn handle_request(
  req: Request(Connection),
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
  sessions: Subject(SessionMessage),
  registry: Subject(registry_mod.RegistryMessage),
  presence: Subject(presence_mod.PresenceMessage),
) -> response.Response(ResponseData) {
  case req.method, request.path_segments(req) {
    http.Post, ["mcp"] -> handle_mcp_post(req, tools, handler, sessions)
    _, ["mcp"] -> json_error_response(405, "Method not allowed for /mcp")
    http.Get, ["inbox", participant_id, "count"] ->
      handle_inbox_count(participant_id, registry, presence)
    http.Get, ["agent", agent_id, "inbox", "count"] ->
      handle_agent_inbox_count(agent_id, registry, presence)
    http.Get, ["health"] ->
      response.new(200)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")),
      )
      |> response.set_header("content-type", "application/json")
    _, _ -> json_error_response(404, "Not found")
  }
}

fn handle_mcp_post(
  req: Request(Connection),
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
  sessions: Subject(SessionMessage),
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1_048_576) {
    Error(_) -> json_error_response(400, "Failed to read request body")
    Ok(req_with_body) -> {
      let body = case bit_array.to_string(req_with_body.body) {
        Ok(s) -> s
        Error(_) -> ""
      }
      case codec.decode_request(body) {
        Error(_) -> {
          let err_body =
            codec.encode_error(
              None,
              JsonRpcError(code: protocol.parse_error, message: "Parse error"),
            )
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_string(err_body)))
          |> response.set_header("content-type", "application/json")
        }
        Ok(rpc_request) -> {
          // Route based on method
          case rpc_request.method {
            "initialize" -> handle_initialize(rpc_request, sessions)
            _ ->
              handle_authenticated_request(
                req_with_body,
                rpc_request,
                tools,
                handler,
                sessions,
              )
          }
        }
      }
    }
  }
}

fn handle_initialize(
  rpc_request: JsonRpcRequest,
  sessions: Subject(SessionMessage),
) -> response.Response(ResponseData) {
  let session_id = create_session(sessions)
  let result_body =
    codec.encode_response(rpc_request.id, codec.encode_initialize_result())
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(result_body)))
  |> response.set_header("content-type", "application/json")
  |> response.set_header("mcp-session-id", session_id)
}

fn handle_authenticated_request(
  req: Request(BitArray),
  rpc_request: JsonRpcRequest,
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
  sessions: Subject(SessionMessage),
) -> response.Response(ResponseData) {
  let session_id = request.get_header(req, "mcp-session-id")
  case session_id {
    Error(_) -> json_error_response(401, "Missing Mcp-Session-Id header")
    Ok(sid) -> {
      case validate_session(sessions, sid) {
        False -> json_error_response(401, "Invalid session")
        True -> route_rpc_request(rpc_request, tools, handler)
      }
    }
  }
}

fn route_rpc_request(
  rpc_request: JsonRpcRequest,
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
) -> response.Response(ResponseData) {
  let result_body = case rpc_request.method {
    "ping" -> codec.encode_response(rpc_request.id, json.object([]))
    "tools/list" ->
      codec.encode_response(rpc_request.id, codec.encode_tools_list(tools))
    "tools/call" -> transport.handle_tool_call(rpc_request, handler)
    _ ->
      codec.encode_error(
        rpc_request.id,
        JsonRpcError(
          code: protocol.method_not_found,
          message: "Method not found: " <> rpc_request.method,
        ),
      )
  }
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(result_body)))
  |> response.set_header("content-type", "application/json")
}

// ---------------------------------------------------------------------------
// REST: GET /inbox/:participant_id/count
// ---------------------------------------------------------------------------

fn handle_inbox_count(
  participant_id: String,
  registry: Subject(registry_mod.RegistryMessage),
  presence: Subject(presence_mod.PresenceMessage),
) -> response.Response(ResponseData) {
  let pid = ParticipantId(participant_id)
  case presence_mod.query_participant(presence, pid) {
    Error(_) -> json_error_response(404, "Participant not found")
    Ok(entry) -> {
      let room_counts =
        list.filter_map(entry.rooms, fn(room_id) {
          case registry_mod.get_room(registry, room_id) {
            Error(_) -> Error(Nil)
            Ok(room_subject) -> {
              let count = room_mod.inbox_count(room_subject, pid)
              Ok(#(room_id, count))
            }
          }
        })
      let total = list.fold(room_counts, 0, fn(acc, pair) { acc + pair.1 })
      let rooms_json =
        list.map(room_counts, fn(pair) { #(pair.0, json.int(pair.1)) })
      let body =
        json.object([
          #("total", json.int(total)),
          #("rooms", json.object(rooms_json)),
        ])
        |> json.to_string
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
      |> response.set_header("content-type", "application/json")
    }
  }
}

fn handle_agent_inbox_count(
  agent_id: String,
  registry: Subject(registry_mod.RegistryMessage),
  presence: Subject(presence_mod.PresenceMessage),
) -> response.Response(ResponseData) {
  case presence_mod.query_agent(presence, agent_id) {
    Error(_) -> json_error_response(404, "Agent not found")
    Ok(participant_id) -> handle_inbox_count(participant_id, registry, presence)
  }
}

fn json_error_response(
  status: Int,
  msg: String,
) -> response.Response(ResponseData) {
  let body =
    json.object([#("error", json.string(msg))])
    |> json.to_string
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  |> response.set_header("content-type", "application/json")
}
