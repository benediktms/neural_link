import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Transport {
  Http
  Stdio
}

@external(erlang, "neural_link_ffi", "get_env")
fn get_env(name: String) -> Result(String, String)

pub fn load_transport() -> Transport {
  case get_env("NEURAL_LINK_TRANSPORT") {
    Ok("stdio") -> Stdio
    _ -> Http
  }
}

pub fn load_port() -> Int {
  case get_env("NEURAL_LINK_PORT") {
    Ok(port_str) ->
      case int.parse(port_str) {
        Ok(port) -> port
        Error(_) -> 9961
      }
    Error(_) -> 9961
  }
}

pub fn load_auth_token() -> Option(String) {
  case get_env("NEURAL_LINK_AUTH_TOKEN") {
    Ok(raw) ->
      case string.trim(raw) {
        "" -> None
        token -> Some(token)
      }
    Error(_) -> None
  }
}
