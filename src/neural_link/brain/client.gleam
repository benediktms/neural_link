import gleam/result
import gleam/string
import neural_link/brain/types.{
  type BrainConfig, type BrainResult, BrainConfig, CommandFailed, Timeout,
}

/// Create a new brain client config
pub fn new(brain_name: String) -> BrainConfig {
  BrainConfig(brain_name: brain_name)
}

/// Execute a shell command via FFI
@external(erlang, "neural_link_ffi", "exec_command")
fn exec_command(command: String) -> Result(String, String)

/// Run a brain CLI command, handling errors
fn run_brain_command(config: BrainConfig, args: String) -> BrainResult(String) {
  let command = "brain --brain " <> config.brain_name <> " " <> args
  case exec_command(command) {
    Ok(output) -> Ok(string.trim(output))
    Error("timeout") -> Error(Timeout)
    Error(output) -> Error(CommandFailed(string.trim(output)))
  }
}

/// Create a record in brain
/// Returns the record ID on success
pub fn create_record(
  config: BrainConfig,
  title: String,
  text: String,
  tags: List(String),
) -> BrainResult(String) {
  let tags_arg = case tags {
    [] -> ""
    _ -> " --tag " <> string.join(tags, " --tag ")
  }
  let args =
    "records create"
    <> " --title "
    <> shell_quote(title)
    <> " --text "
    <> shell_quote(text)
    <> tags_arg
    <> " --json"
  run_brain_command(config, args)
}

/// Create an artifact in brain
/// Returns the record ID on success
pub fn create_artifact(
  config: BrainConfig,
  title: String,
  text: String,
  kind: String,
  tags: List(String),
) -> BrainResult(String) {
  let tags_arg = case tags {
    [] -> ""
    _ -> " --tag " <> string.join(tags, " --tag ")
  }
  let args =
    "records create-artifact"
    <> " --title "
    <> shell_quote(title)
    <> " --text "
    <> shell_quote(text)
    <> " --kind "
    <> shell_quote(kind)
    <> tags_arg
    <> " --json"
  run_brain_command(config, args)
}

/// Add a comment to a brain task
pub fn add_task_comment(
  config: BrainConfig,
  task_id: String,
  body: String,
) -> BrainResult(Nil) {
  let args = "tasks comment " <> task_id <> " " <> shell_quote(body)
  run_brain_command(config, args)
  |> result.map(fn(_) { Nil })
}

/// Save a snapshot record
pub fn save_snapshot(
  config: BrainConfig,
  title: String,
  text: String,
  tags: List(String),
) -> BrainResult(String) {
  let tags_arg = case tags {
    [] -> ""
    _ -> " --tag " <> string.join(tags, " --tag ")
  }
  let args =
    "records save-snapshot"
    <> " --title "
    <> shell_quote(title)
    <> " --text "
    <> shell_quote(text)
    <> tags_arg
    <> " --json"
  run_brain_command(config, args)
}

/// Shell-escape a string argument (wrap in single quotes, escape internal quotes)
fn shell_quote(s: String) -> String {
  "'" <> string.replace(s, "'", "'\\''") <> "'"
}
