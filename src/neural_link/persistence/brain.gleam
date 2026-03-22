import gleam/result
import neural_link/brain/client
import neural_link/brain/types as brain_types
import neural_link/persistence/adapter
import neural_link/persistence/config
import neural_link/persistence/types

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

fn map_brain_error(err: brain_types.BrainError) -> types.PersistenceError {
  case err {
    brain_types.Timeout -> types.Timeout
    brain_types.CommandFailed(output) ->
      types.AdapterError(backend: "brain", detail: "command_failed: " <> output)
    brain_types.ParseError(detail) ->
      types.AdapterError(backend: "brain", detail: "parse_error: " <> detail)
  }
}

// ---------------------------------------------------------------------------
// BrainAdapter
// ---------------------------------------------------------------------------

/// A persistence adapter backed by the brain CLI.
///
/// Validates the config backend variant is `Brain`, then delegates to
/// `brain/client.gleam` functions. Maps `BrainError` -> `PersistenceError`.
pub fn brain_adapter() -> adapter.PersistenceAdapter {
  adapter.PersistenceAdapter(
    save_snapshot: save_snapshot_impl,
    create_artifact: create_artifact_impl,
  )
}

fn save_snapshot_impl(
  cfg: config.PersistenceConfig,
  title: String,
  content: String,
  tags: types.RecordTags,
) -> Result(String, types.PersistenceError) {
  case cfg.backend {
    config.Brain(name) -> {
      let brain_cfg = brain_types.BrainConfig(brain_name: name)
      client.save_snapshot(brain_cfg, title, content, tags)
      |> result.map_error(map_brain_error)
    }
    _ ->
      Error(types.AdapterError(
        backend: "brain",
        detail: "unsupported backend variant",
      ))
  }
}

fn create_artifact_impl(
  cfg: config.PersistenceConfig,
  title: String,
  content: String,
  kind: String,
  tags: types.RecordTags,
) -> Result(String, types.PersistenceError) {
  case cfg.backend {
    config.Brain(name) -> {
      let brain_cfg = brain_types.BrainConfig(brain_name: name)
      client.create_artifact(brain_cfg, title, content, kind, tags)
      |> result.map_error(map_brain_error)
    }
    _ ->
      Error(types.AdapterError(
        backend: "brain",
        detail: "unsupported backend variant",
      ))
  }
}
