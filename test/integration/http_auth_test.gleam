import gleam/erlang/process
import gleam/int
import gleam/option.{type Option}
import gleam/string
import gleeunit/should
import neural_link/mcp/handlers
import neural_link/mcp/tools
import neural_link/mcp/transport/http as http_transport
import neural_link/persistence/database
import neural_link/runtime/supervisor
import support/http_helpers

@external(erlang, "neural_link_http_test_ffi", "http_post")
fn http_post(
  url: String,
  body: String,
  headers: List(#(String, String)),
) -> Result(#(Int, String, List(#(String, String))), String)

@external(erlang, "neural_link_http_test_ffi", "http_get")
fn http_get(
  url: String,
  headers: List(#(String, String)),
) -> Result(#(Int, String, List(#(String, String))), String)

const init_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"

const tools_list_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"

pub fn http_auth_unauthed_request_passes_when_token_unset_test() {
  let port = start_test_server(option.None)
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  let assert Ok(#(200, _, _)) = http_post(url, init_body, [])
}

pub fn http_auth_request_without_header_returns_401_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  let assert Ok(#(401, body, _)) = http_post(url, init_body, [])
  string.contains(body, "Missing Authorization") |> should.be_true
}

pub fn http_auth_request_with_wrong_token_returns_401_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  let assert Ok(#(401, body, _)) =
    http_post(url, init_body, [#("authorization", "Bearer wrong")])
  string.contains(body, "Invalid bearer token") |> should.be_true
}

pub fn http_auth_request_with_correct_token_passes_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  let assert Ok(#(200, _, init_headers)) =
    http_post(url, init_body, [#("authorization", "Bearer s3cret-token")])
  let assert Ok(sid) = http_helpers.find_header(init_headers, "mcp-session-id")

  let assert Ok(#(200, body, _)) =
    http_post(url, tools_list_body, [
      #("authorization", "Bearer s3cret-token"),
      #("mcp-session-id", sid),
    ])
  string.contains(body, "room_open") |> should.be_true
}

pub fn http_auth_request_with_lowercase_scheme_passes_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  let assert Ok(#(200, _, _)) =
    http_post(url, init_body, [#("authorization", "bearer s3cret-token")])
}

pub fn http_auth_request_with_malformed_header_returns_401_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/mcp"

  let assert Ok(#(401, body, _)) =
    http_post(url, init_body, [#("authorization", "Basic xxx")])
  string.contains(body, "must be 'Bearer") |> should.be_true
}

pub fn http_auth_health_endpoint_is_public_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/health"

  let assert Ok(#(200, body, _)) = http_get(url, [])
  string.contains(body, "ok") |> should.be_true
}

pub fn http_auth_ready_endpoint_is_public_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/ready"

  let assert Ok(#(200, body, _)) = http_get(url, [])
  string.contains(body, "ready") |> should.be_true
  string.contains(body, "rooms") |> should.be_true
}

pub fn http_ready_reports_room_count_test() {
  let port = start_test_server(option.None)
  let url = "http://localhost:" <> int.to_string(port) <> "/ready"

  let assert Ok(#(200, body, _)) = http_get(url, [])
  string.contains(body, "\"rooms\":0") |> should.be_true
}

pub fn http_auth_inbox_count_requires_auth_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/inbox/anyone/count"

  let assert Ok(#(401, _, _)) = http_get(url, [])
}

pub fn http_auth_agent_inbox_count_requires_auth_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url =
    "http://localhost:" <> int.to_string(port) <> "/agent/anyone/inbox/count"

  let assert Ok(#(401, _, _)) = http_get(url, [])
}

pub fn http_auth_unknown_route_requires_auth_test() {
  let port = start_test_server(option.Some("s3cret-token"))
  let url = "http://localhost:" <> int.to_string(port) <> "/nope"

  let assert Ok(#(401, _, _)) = http_get(url, [])
}

fn start_test_server(auth_token: Option(String)) -> Int {
  let port =
    21_000
    + http_helpers.erlang_abs(http_helpers.erlang_unique_integer())
    % 1000
  let assert Ok(services) = supervisor.start_with_database(database.Memory)
  let tool_defs = tools.all_tools()
  let handler =
    handlers.make_handler(handlers.HandlerConfig(
      registry: services.registry,
      inbox: services.inbox,
      presence: services.presence,
      store: services.store,
    ))
  let assert Ok(_) =
    http_transport.start_server(
      tool_defs,
      handler,
      port,
      services.registry,
      services.presence,
      auth_token,
    )
  process.sleep(100)
  port
}
