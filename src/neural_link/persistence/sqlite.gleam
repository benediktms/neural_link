import neural_link/domain/message.{type Message}
import neural_link/domain/room.{type Room}
import neural_link/persistence/types.{type PersistenceError, Unavailable}

// ---------------------------------------------------------------------------
// SqliteStore — primary operational store
// ---------------------------------------------------------------------------

/// The canonical primary operational store for neural_link.
///
/// SqliteStore owns room state, messages, participants, and presence.
/// It is NOT behind the plugin interface — plugins observe writes to it,
/// they do not participate in the primary write path.
///
/// All primary writes go through SqliteStore. Plugins receive replication
/// events after the primary write succeeds.
///
/// ### Schema (stub)
/// - `rooms`: id, title, purpose, external_ref, tags, resolution, created_at
/// - `messages`: id, room_id, from, kind, sequence, summary, body, created_at
/// - `participants`: room_id, participant_id, display_name, joined_at
/// - `presence`: room_id, participant_id, last_seen_at
///
/// ### Status
/// This is a STUB. All operations return `Error(Unavailable("sqlite not implemented"))`.
/// A future task implements the full SqliteStore.
pub type SqliteStore {
  SqliteStore(path: String)
}

// ---------------------------------------------------------------------------
// Store construction
// ---------------------------------------------------------------------------

/// Build a SqliteStore pointing at the given filesystem path.
pub fn open(path: String) -> SqliteStore {
  SqliteStore(path: path)
}

// ---------------------------------------------------------------------------
// Primary write operations
// ---------------------------------------------------------------------------

/// Persist a room to the primary store.
/// Returns the room ID on success.
pub fn insert_room(
  _store: SqliteStore,
  _room: Room,
) -> Result(String, PersistenceError) {
  Error(Unavailable(detail: "sqlite store not implemented"))
}

/// Update room close metadata in the primary store.
pub fn update_room_close(
  _store: SqliteStore,
  _room: Room,
  _message_count: Int,
  _duration_ms: Int,
) -> Result(Nil, PersistenceError) {
  Error(Unavailable(detail: "sqlite store not implemented"))
}

/// Persist a message to the primary store.
/// Returns the message ID on success.
pub fn insert_message(
  _store: SqliteStore,
  _msg: Message,
) -> Result(String, PersistenceError) {
  Error(Unavailable(detail: "sqlite store not implemented"))
}

/// Persist the full conversation artifact to the primary store.
/// Returns the artifact record ID on success.
pub fn insert_conversation_artifact(
  _store: SqliteStore,
  _room: Room,
  _content: String,
) -> Result(String, PersistenceError) {
  Error(Unavailable(detail: "sqlite store not implemented"))
}
