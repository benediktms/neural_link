import neural_link/domain/message.{type Message}
import neural_link/domain/room.{type Room}
import neural_link/persistence/types.{type PersistenceError}

// ---------------------------------------------------------------------------
// PluginEvent — tagged union for all plugin lifecycle events
// ---------------------------------------------------------------------------

/// All events that a PersistencePlugin can receive.
/// The canonical record ID for ConversationArtifact comes from SqliteStore
/// as the primary store; plugins receive it via the event and replicate.
pub type PluginEvent {
  /// Called when the plugin is registered (startup).
  PluginInit
  /// Called after a room is opened. Room metadata is already persisted.
  RoomOpened(room: Room)
  /// Called after a room is closed. Room close metadata is already persisted.
  RoomClosed(room: Room, message_count: Int, duration_ms: Int)
  /// Called after conversation artifact is persisted to primary store.
  /// The record_id is canonical (from SqliteStore); plugins replicate only.
  ConversationArtifact(room: Room, content: String, record_id: String)
  /// Called for each durable message. Message is already persisted.
  Message(msg: Message)
}

// ---------------------------------------------------------------------------
// PersistencePlugin behaviour
// ---------------------------------------------------------------------------

/// A replication plugin that observes writes to the SqliteStore primary.
///
/// Plugins receive events after the primary write succeeds. Failures are logged
/// by the caller but do not propagate — the primary write is always authoritative.
///
/// ### Plugin interface
/// Plugins implement a single `notify` function that receives PluginEvent values.
/// They pattern-match on the event variant and handle what they care about.
/// Returning `Ok(Nil)` means "I handled this"; plugins can also return errors
/// to signal replication failures (logged but not blocking).
pub type PersistencePlugin {
  PersistencePlugin(
    name: String,
    notify: fn(PluginEvent) -> Result(Nil, PersistenceError),
  )
}

/// Dispatch an event to a plugin.
/// All plugin notifications flow through this single entrypoint.
pub fn notify(
  plugin: PersistencePlugin,
  event: PluginEvent,
) -> Result(Nil, PersistenceError) {
  plugin.notify(event)
}
