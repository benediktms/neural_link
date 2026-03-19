import gleam/int

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
