import gleam/bit_array
import gleam/crypto
import gleam/int

const node_name = "nlk@127.0.0.1"

/// Check if the neural_link node is running by pinging it
pub fn is_running() -> Bool {
  let cookie = load_or_create_cookie()
  let cmd =
    "erl -noinput -dist_listen false -name nlk_ping@127.0.0.1 -setcookie "
    <> cookie
    <> " -eval \""
    <> "case net_adm:ping('"
    <> node_name
    <> "') of pong -> halt(0); pang -> halt(1) end.\""
  case exec_command(cmd) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Start the neural_link node in detached BEAM mode
pub fn start_detached(port: Int) -> Result(String, String) {
  let cookie = load_or_create_cookie()
  let port_str = int.to_string(port)
  let shipment = find_shipment_path()
  let erl_flags = "-detached -name " <> node_name <> " -setcookie " <> cookie
  let cmd =
    "/usr/bin/env"
    <> " ERL_FLAGS='"
    <> erl_flags
    <> "' NEURAL_LINK_PORT="
    <> port_str
    <> " /bin/sh "
    <> shipment
    <> " run start --foreground"
  exec_command(cmd)
}

/// Stop the remote neural_link node via RPC
pub fn stop_remote() -> Result(String, String) {
  let cookie = load_or_create_cookie()
  let cmd =
    "erl -noinput -dist_listen false -name nlk_stop@127.0.0.1 -setcookie "
    <> cookie
    <> " -eval \""
    <> "rpc:call('"
    <> node_name
    <> "', init, stop, []), halt().\""
  exec_command(cmd)
}

fn load_or_create_cookie() -> String {
  case get_home_dir() {
    Error(_) -> generate_cookie()
    Ok(home) -> {
      let cookie_path = home <> "/.nlk/cookie"
      case read_file(cookie_path) {
        Ok(cookie) -> cookie
        Error(_) -> {
          let cookie = generate_cookie()
          let _ = write_file(cookie_path, cookie)
          cookie
        }
      }
    }
  }
}

fn generate_cookie() -> String {
  crypto.strong_random_bytes(32)
  |> bit_array.base16_encode
}

fn find_shipment_path() -> String {
  // Derive from the running BEAM's code path — the ebin dir is a sibling
  // of entrypoint.sh under build/erlang-shipment/
  case shipment_dir() {
    Ok(dir) -> dir <> "/entrypoint.sh"
    Error(_) -> "build/erlang-shipment/entrypoint.sh"
  }
}

@external(erlang, "neural_link_ffi", "shipment_dir")
fn shipment_dir() -> Result(String, String)

@external(erlang, "neural_link_ffi", "exec_command")
fn exec_command(cmd: String) -> Result(String, String)

@external(erlang, "neural_link_ffi", "get_home_dir")
fn get_home_dir() -> Result(String, String)

@external(erlang, "neural_link_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "neural_link_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
