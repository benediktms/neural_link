import birl
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/string
import neural_link/domain/id
import neural_link/domain/interaction_mode
import neural_link/domain/message.{type Message}
import neural_link/domain/room.{type Room}
import neural_link/persistence/types.{type PersistenceError, AdapterError}
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

pub type ClosedRoom {
  ClosedRoom(id: String, title: String, closed_at: String)
}

pub type StoredMessage {
  StoredMessage(
    from_id: String,
    kind: String,
    summary: String,
    body: Option(String),
    sequence: Int,
  )
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
  store: SqliteStore,
  room: Room,
) -> Result(String, PersistenceError) {
  let room_id = id.room_id_to_string(room.id)
  let tags = case room.tags {
    [] -> None
    values -> Some(string.join(values, ","))
  }
  let interaction_mode = case room.interaction_mode {
    Some(mode) -> Some(interaction_mode.mode_to_string(mode))
    None -> None
  }

  case
    sqlight.query(
      "INSERT INTO rooms (id, title, purpose, external_ref, tags, interaction_mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      on: store.connection,
      with: [
        sqlight.text(room_id),
        sqlight.text(room.title),
        sqlight.nullable(sqlight.text, room.purpose),
        sqlight.nullable(sqlight.text, room.external_ref),
        sqlight.nullable(sqlight.text, tags),
        sqlight.nullable(sqlight.text, interaction_mode),
        sqlight.text(birl.to_iso8601(room.created_at)),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(room_id)
    Error(err) -> Error(map_sqlite_error("insert_room failed: ", err))
  }
}

/// Insert a participant into the primary store.
pub fn insert_participant(
  store: SqliteStore,
  room_id: String,
  participant_id: String,
  display_name: String,
  role: String,
  joined_at: String,
) -> Result(Nil, PersistenceError) {
  case
    sqlight.query(
      "INSERT INTO participants (room_id, participant_id, display_name, role, joined_at) VALUES (?, ?, ?, ?, ?)",
      on: store.connection,
      with: [
        sqlight.text(room_id),
        sqlight.text(participant_id),
        sqlight.text(display_name),
        sqlight.text(role),
        sqlight.text(joined_at),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error(map_sqlite_error("insert_participant failed: ", err))
  }
}

/// Update room close metadata in the primary store.
pub fn update_room_close(
  store: SqliteStore,
  room: Room,
  _message_count: Int,
  _duration_ms: Int,
) -> Result(Nil, PersistenceError) {
  let room_id = id.room_id_to_string(room.id)
  let resolution = case room.resolution {
    Some(room.Completed) -> Some("completed")
    Some(room.Cancelled) -> Some("cancelled")
    Some(room.Superseded) -> Some("superseded")
    Some(room.Failed) -> Some("failed")
    None -> None
  }

  case
    sqlight.query(
      "UPDATE rooms SET resolution = ?, closed_at = ? WHERE id = ?",
      on: store.connection,
      with: [
        sqlight.nullable(sqlight.text, resolution),
        sqlight.text(birl.to_iso8601(birl.utc_now())),
        sqlight.text(room_id),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error(map_sqlite_error("update_room_close failed: ", err))
  }
}

/// Persist a message to the primary store.
pub fn insert_message(
  store: SqliteStore,
  msg: Message,
) -> Result(String, PersistenceError) {
  let message_id = id.message_id_to_string(msg.message_id)
  let room_id = id.room_id_to_string(msg.room_id)
  let from_id = id.participant_id_to_string(msg.from)
  let thread_id =
    msg.thread_id
    |> option.map(id.thread_id_to_string)
  let persist_hint = case msg.persist_hint {
    message.Durable -> Some("durable")
    message.Ephemeral -> Some("ephemeral")
  }

  case
    sqlight.query(
      "INSERT INTO messages (message_id, room_id, from_id, kind, sequence, summary, body, thread_id, persist_hint, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      on: store.connection,
      with: [
        sqlight.text(message_id),
        sqlight.text(room_id),
        sqlight.text(from_id),
        sqlight.text(message.kind_to_string(msg.kind)),
        sqlight.int(msg.sequence),
        sqlight.text(msg.summary),
        sqlight.nullable(sqlight.text, msg.body),
        sqlight.nullable(sqlight.text, thread_id),
        sqlight.nullable(sqlight.text, persist_hint),
        sqlight.text(birl.to_iso8601(msg.created_at)),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(message_id)
    Error(err) -> Error(map_sqlite_error("insert_message failed: ", err))
  }
}

/// Persist the full conversation artifact to the primary store.
/// Returns the artifact record ID on success.
pub fn insert_conversation_artifact(
  store: SqliteStore,
  room: Room,
  content: String,
) -> Result(String, PersistenceError) {
  let record_id = id.generate("artifact_")
  let room_id = id.room_id_to_string(room.id)

  case
    sqlight.query(
      "INSERT INTO conversation_artifacts (record_id, room_id, content, created_at) VALUES (?, ?, ?, ?)",
      on: store.connection,
      with: [
        sqlight.text(record_id),
        sqlight.text(room_id),
        sqlight.text(content),
        sqlight.text(birl.to_iso8601(birl.utc_now())),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(record_id)
    Error(err) ->
      Error(map_sqlite_error("insert_conversation_artifact failed: ", err))
  }
}

pub fn query_closed_rooms(
  store: SqliteStore,
) -> Result(List(ClosedRoom), PersistenceError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use title <- decode.field(1, decode.string)
    use closed_at <- decode.field(2, decode.string)
    decode.success(ClosedRoom(id:, title:, closed_at:))
  }

  case
    sqlight.query(
      "SELECT id, title, closed_at FROM rooms WHERE closed_at IS NOT NULL",
      on: store.connection,
      with: [],
      expecting: decoder,
    )
  {
    Ok(rows) -> Ok(rows)
    Error(err) -> Error(map_sqlite_error("query_closed_rooms failed: ", err))
  }
}

pub fn query_room_messages(
  store: SqliteStore,
  room_id: String,
) -> Result(List(StoredMessage), PersistenceError) {
  let decoder = {
    use from_id <- decode.field(0, decode.string)
    use kind <- decode.field(1, decode.string)
    use summary <- decode.field(2, decode.string)
    use body <- decode.field(3, decode.optional(decode.string))
    use sequence <- decode.field(4, decode.int)
    decode.success(StoredMessage(from_id:, kind:, summary:, body:, sequence:))
  }

  case
    sqlight.query(
      "SELECT from_id, kind, summary, body, sequence FROM messages WHERE room_id = ? ORDER BY sequence",
      on: store.connection,
      with: [sqlight.text(room_id)],
      expecting: decoder,
    )
  {
    Ok(rows) -> Ok(rows)
    Error(err) -> Error(map_sqlite_error("query_room_messages failed: ", err))
  }
}

fn map_sqlite_error(prefix: String, err: sqlight.Error) -> PersistenceError {
  let sqlight.SqlightError(_, message, _) = err
  AdapterError(backend: "sqlite", detail: prefix <> message)
}
