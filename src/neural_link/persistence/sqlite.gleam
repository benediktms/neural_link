import gleam/dynamic/decode
import neural_link/domain/message.{type Message}
import neural_link/domain/room.{type Room}
import neural_link/persistence/types.{
  type PersistenceError, AdapterError, Unavailable,
}
import sqlight

// ---------------------------------------------------------------------------
// SqliteStore — primary operational store
// ---------------------------------------------------------------------------

/// The canonical primary operational store for neural_link.
///
/// SqliteStore persists room state, messages, participants, and conversation
/// artifacts to a local SQLite database. Writes are best-effort (fire-and-forget
/// from the MCP handler perspective) — a crash between actor state change and
/// the SQLite write can lose that single event.
///
/// SqliteStore is NOT behind the plugin interface. Plugins observe writes
/// separately; this module owns the primary write path.
///
/// ### Schema
/// - `rooms`: id, title, purpose, external_ref, tags, resolution, interaction_mode, created_at, closed_at
/// - `participants`: room_id, participant_id, display_name, role, joined_at
/// - `messages`: message_id, room_id, from_id, kind, sequence, summary, body, thread_id, persist_hint, created_at
/// - `conversation_artifacts`: record_id, room_id, content, created_at
pub type SqliteStore {
  SqliteStore(connection: sqlight.Connection)
}

// ---------------------------------------------------------------------------
// Store construction
// ---------------------------------------------------------------------------

/// Open a SqliteStore at the given filesystem path.
/// Creates the database file and bootstraps the schema if it doesn't exist.
pub fn open(path: String) -> Result(SqliteStore, PersistenceError) {
  case sqlight.open(path) {
    Error(err) ->
      Error(AdapterError(
        backend: "sqlite",
        detail: "failed to open: " <> err.message,
      ))
    Ok(conn) ->
      case bootstrap_schema(conn) {
        Error(e) -> {
          let _ = sqlight.close(conn)
          Error(e)
        }
        Ok(_) -> Ok(SqliteStore(connection: conn))
      }
  }
}

/// Close the SqliteStore connection.
pub fn close(store: SqliteStore) -> Nil {
  let _ = sqlight.close(store.connection)
  Nil
}

// ---------------------------------------------------------------------------
// Schema bootstrap
// ---------------------------------------------------------------------------

fn bootstrap_schema(conn: sqlight.Connection) -> Result(Nil, PersistenceError) {
  let sql =
    "CREATE TABLE IF NOT EXISTS rooms (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      purpose TEXT,
      external_ref TEXT,
      tags TEXT,
      resolution TEXT,
      interaction_mode TEXT,
      created_at TEXT NOT NULL,
      closed_at TEXT
    );

    CREATE TABLE IF NOT EXISTS participants (
      room_id TEXT NOT NULL,
      participant_id TEXT NOT NULL,
      display_name TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'member',
      joined_at TEXT NOT NULL,
      PRIMARY KEY (room_id, participant_id),
      FOREIGN KEY (room_id) REFERENCES rooms(id)
    );

    CREATE TABLE IF NOT EXISTS messages (
      message_id TEXT PRIMARY KEY,
      room_id TEXT NOT NULL,
      from_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      summary TEXT NOT NULL,
      body TEXT,
      thread_id TEXT,
      persist_hint TEXT,
      created_at TEXT NOT NULL,
      FOREIGN KEY (room_id) REFERENCES rooms(id)
    );

    CREATE TABLE IF NOT EXISTS conversation_artifacts (
      record_id TEXT PRIMARY KEY,
      room_id TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (room_id) REFERENCES rooms(id)
    );"

  case sqlight.exec(sql, conn) {
    Ok(_) -> Ok(Nil)
    Error(err) ->
      Error(AdapterError(
        backend: "sqlite",
        detail: "schema bootstrap failed: " <> err.message,
      ))
  }
}

// ---------------------------------------------------------------------------
// Schema introspection (for testing)
// ---------------------------------------------------------------------------

/// List all table names in the database. Used by tests to verify schema bootstrap.
pub fn list_tables(store: SqliteStore) -> Result(List(String), PersistenceError) {
  case
    sqlight.query(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      on: store.connection,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  {
    Ok(tables) -> Ok(tables)
    Error(err) ->
      Error(AdapterError(
        backend: "sqlite",
        detail: "list_tables failed: " <> err.message,
      ))
  }
}

// ---------------------------------------------------------------------------
// Primary write operations (stubs — implemented in Task 2)
// ---------------------------------------------------------------------------

/// Persist a room to the primary store.
pub fn insert_room(
  _store: SqliteStore,
  _room: Room,
) -> Result(String, PersistenceError) {
  Error(Unavailable(detail: "sqlite store not implemented"))
}

/// Insert a participant into the primary store.
pub fn insert_participant(
  _store: SqliteStore,
  _room_id: String,
  _participant_id: String,
  _display_name: String,
  _role: String,
  _joined_at: String,
) -> Result(Nil, PersistenceError) {
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
