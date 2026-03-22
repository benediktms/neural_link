import neural_link/persistence/config.{type PersistenceConfig}
import neural_link/persistence/types.{type PersistenceError, type RecordTags}

// ---------------------------------------------------------------------------
// Adapter behaviour
// ---------------------------------------------------------------------------

/// A backend-agnostic persistence adapter.
///
/// Adapters implement this behaviour to provide concrete persistence for
/// neural_link's coordination room events (room-open snapshots, room-close
/// metadata, durable message snapshots, and conversation artifacts).
///
/// The adapter receives a `PersistenceConfig` at each call site — no global
/// state is maintained by the interface.
///
/// ### Migration path for NLR-01KM9AD.2
/// Replace direct calls to `brain/bridge` in `mcp/handlers.gleam` with calls
/// through an adapter instance. The adapter is selected by matching the
/// `PersistenceConfig.backend` variant to the corresponding adapter module
/// (e.g. `BrainAdapter` for `Brain` variant, `HttpAdapter` for `Http`).
///
/// ### Migration path for NLR-01KM9AD.3
/// Rename `brains: List(String)` in `domain/room.gleam` and `runtime/registry.gleam`
/// to `persisters: List(PersistenceConfig)`. Update `mcp/handlers.gleam` to build
/// a `PersistenceConfig(Brain(name))` for each brain name rather than passing
/// raw brain names to the bridge.
///
/// ### Breaking change
/// The `brains` field is removed from `Room` and `RoomState`. Code that
/// references `room.brains` must be updated to use `room.persisters` and
/// handle the `PersistenceConfig` structure instead of raw `String` brain names.
///
/// ### Backends
/// - `BrainAdapter` (src/neural_link/persistence/brain.gleam): current brain CLI
/// - `HttpAdapter` (src/neural_link/persistence/http.gleam): stub returning
///   `Unavailable` — a second adapter proving the interface is backend-agnostic
pub type PersistenceAdapter {
  PersistenceAdapter(
    save_snapshot: fn(PersistenceConfig, String, String, RecordTags) ->
      Result(String, PersistenceError),
    create_artifact: fn(PersistenceConfig, String, String, String, RecordTags) ->
      Result(String, PersistenceError),
  )
}

/// Save a lightweight snapshot record (room metadata, message, etc.).
///
/// Returns the backend-assigned record ID on success.
pub fn save_snapshot(
  adapter: PersistenceAdapter,
  config: PersistenceConfig,
  title: String,
  content: String,
  tags: RecordTags,
) -> Result(String, PersistenceError) {
  adapter.save_snapshot(config, title, content, tags)
}

/// Save a heavyweight artifact record (full conversation transcript).
///
/// The `kind` parameter carries backend-specific type information (e.g. "conversation").
///
/// Returns the backend-assigned record ID on success.
pub fn create_artifact(
  adapter: PersistenceAdapter,
  config: PersistenceConfig,
  title: String,
  content: String,
  kind: String,
  tags: RecordTags,
) -> Result(String, PersistenceError) {
  adapter.create_artifact(config, title, content, kind, tags)
}
