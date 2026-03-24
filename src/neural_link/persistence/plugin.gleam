import neural_link/domain/message.{type Message}
import neural_link/domain/room.{type Room}
import neural_link/persistence/types.{type PersistenceError}

// ---------------------------------------------------------------------------
// Plugin behaviour
// ---------------------------------------------------------------------------

/// A replication plugin that observes writes to the SqliteStore primary.
///
/// Plugins receive events after the primary write succeeds. Failures are logged
/// by the caller but do not propagate — the primary write is always authoritative.
///
/// ### Events
/// - `on_init` — called when the plugin is registered (startup)
/// - `on_room_open` — called after a room is opened
/// - `on_room_close` — called after a room is closed
/// - `on_conversation_artifact` — called with the full conversation text on room close
/// - `on_message` — called for each durable message
///
/// ### Migration path for NLR-01KM9AD.2
/// Extract `brain/bridge.gleam` into a `BrainPlugin`. The bridge functions
/// (`on_room_open`, `on_room_close`, `on_message`) become plugin event handlers.
/// `on_conversation_artifact` maps to `bridge.on_room_close_with_artifact`.
///
/// ### Primary vs. plugin write
/// The SqliteStore receives ALL writes synchronously as the primary store.
/// Plugins receive events asynchronously and replicate to external systems.
/// A plugin failure does not roll back or block the primary write.
pub type PersistencePlugin {
  PersistencePlugin(
    name: String,
    on_init: fn() -> Result(Nil, PersistenceError),
    on_room_open: fn(Room) -> Result(Nil, PersistenceError),
    on_room_close: fn(Room, Int, Int) -> Result(Nil, PersistenceError),
    on_conversation_artifact: fn(Room, String) ->
      Result(String, PersistenceError),
    on_message: fn(Message) -> Result(Nil, PersistenceError),
  )
}

/// Notification that a room has been opened.
/// The room metadata snapshot is already persisted to SqliteStore.
/// Plugins replicate to external systems as needed.
pub fn notify_room_open(
  plugin: PersistencePlugin,
  room: Room,
) -> Result(Nil, PersistenceError) {
  plugin.on_room_open(room)
}

/// Notification that a room has been closed.
/// The room close metadata is already persisted to SqliteStore.
/// Plugins replicate to external systems as needed.
pub fn notify_room_close(
  plugin: PersistencePlugin,
  room: Room,
  message_count: Int,
  duration_ms: Int,
) -> Result(Nil, PersistenceError) {
  plugin.on_room_close(room, message_count, duration_ms)
}

/// Notification that a conversation artifact has been persisted.
/// The artifact is already in SqliteStore. Plugins replicate to external
/// systems (e.g. BrainPlugin → brain CLI for memory graph indexing).
///
/// Returns the plugin's record ID on success (plugins may generate their own IDs).
/// The canonical record ID comes from SqliteStore as the primary store.
///
/// This is the one SYNC path — it is called synchronously from the room close
/// handler and blocks until all plugins acknowledge or return error.
/// Plugin errors are logged but do not block the primary write.
pub fn notify_conversation_artifact(
  plugin: PersistencePlugin,
  room: Room,
  content: String,
) -> Result(String, PersistenceError) {
  plugin.on_conversation_artifact(room, content)
}

/// Notification that a durable message has been persisted.
/// The message is already in SqliteStore. Plugins replicate to external
/// systems as needed.
pub fn notify_message(
  plugin: PersistencePlugin,
  msg: Message,
) -> Result(Nil, PersistenceError) {
  plugin.on_message(msg)
}
