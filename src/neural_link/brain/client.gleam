import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import neural_link/brain/types.{
  type BrainConfig, type BrainResult, BrainConfig, CommandFailed, ParseError,
  Timeout,
}

/// Create a new brain client config
pub fn new(brain_name: String) -> BrainConfig {
  BrainConfig(brain_name: brain_name)
}

/// Execute a shell command via FFI
@external(erlang, "neural_link_ffi", "exec_command")
fn exec_command(command: String) -> Result(String, String)

/// Execute a shell command with content piped via stdin
@external(erlang, "neural_link_ffi", "exec_command_stdin")
fn exec_command_stdin(command: String, stdin: String) -> Result(String, String)

/// Run a brain CLI command, handling errors
fn run_command(args: String) -> BrainResult(String) {
  let command = "brain " <> args
  case exec_command(command) {
    Ok(output) -> Ok(string.trim(output))
    Error("timeout") -> Error(Timeout)
    Error(output) -> Error(CommandFailed(string.trim(output)))
  }
}

/// Run a brain CLI command with content piped via stdin
fn run_command_stdin(args: String, content: String) -> BrainResult(String) {
  let command = "brain " <> args
  case exec_command_stdin(command, content) {
    Ok(output) -> Ok(string.trim(output))
    Error("timeout") -> Error(Timeout)
    Error(output) -> Error(CommandFailed(string.trim(output)))
  }
}

fn build_tags(tags: List(String)) -> String {
  case tags {
    [] -> ""
    _ -> " --tag " <> string.join(list.map(tags, shell_quote), " --tag ")
  }
}

/// Extract record_id from brain CLI JSON output.
/// Output format: {"record_id": "...", "content_hash": "...", "size": ...}
fn parse_record_id(json_output: String) -> BrainResult(String) {
  let decoder = decode.field("record_id", decode.string, decode.success)
  case json.parse(json_output, decoder) {
    Ok(record_id) -> Ok(record_id)
    Error(_) ->
      Error(ParseError("failed to parse record_id from: " <> json_output))
  }
}

/// Create an artifact in brain via `brain artifacts create --stdin`
/// Returns the record ID on success.
pub fn create_artifact(
  _config: BrainConfig,
  title: String,
  content: String,
  kind: String,
  tags: List(String),
) -> BrainResult(String) {
  let args =
    "artifacts create"
    <> " --title "
    <> shell_quote(title)
    <> " --kind "
    <> shell_quote(kind)
    <> build_tags(tags)
    <> " --stdin --json"
  run_command_stdin(args, content)
  |> result.try(parse_record_id)
}

/// Save a snapshot in brain via `brain snapshots save --stdin`
/// Returns the record ID on success.
pub fn save_snapshot(
  _config: BrainConfig,
  title: String,
  content: String,
  tags: List(String),
) -> BrainResult(String) {
  let args =
    "snapshots save"
    <> " --title "
    <> shell_quote(title)
    <> build_tags(tags)
    <> " --stdin --json"
  run_command_stdin(args, content)
  |> result.try(parse_record_id)
}

/// Add a comment to a brain task
pub fn add_task_comment(
  _config: BrainConfig,
  task_id: String,
  body: String,
) -> BrainResult(Nil) {
  let args = "tasks comment " <> task_id <> " " <> shell_quote(body)
  run_command(args)
  |> result.map(fn(_) { Nil })
}

/// Shell-escape a string argument (wrap in single quotes, escape internal quotes)
fn shell_quote(s: String) -> String {
  "'" <> string.replace(s, "'", "'\\''") <> "'"
}
