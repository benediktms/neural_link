import birl
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import neural_link/domain/id
import neural_link/domain/interaction_mode
import neural_link/domain/message
import neural_link/domain/room
import neural_link/persistence/sqlite
import simplifile
import sqlight

fn cleanup(path: String) {
  case simplifile.delete(file_or_dir_at: path) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

fn test_db_path() -> String {
  "/tmp/" <> id.generate("sqlite_store_test_") <> ".db"
}

fn with_store(f: fn(sqlite.SqliteStore) -> Nil) {
  let path = test_db_path()
  cleanup(path)
  let assert Ok(store) = sqlite.open(path)
  f(store)
  sqlite.close(store)
  cleanup(path)
}

fn make_room(room_id: String, title: String) -> room.Room {
  room.new_with_metadata(
    room_id,
    title,
    Some("Purpose"),
    Some("external/ref"),
    ["tag-a", "tag-b"],
    [],
    Some(interaction_mode.Informative),
  )
}

fn make_message(
  message_id: String,
  room_id: String,
  sequence: Int,
  summary: String,
) -> message.Message {
  message.Message(
    message_id: id.MessageId(message_id),
    room_id: id.RoomId(room_id),
    thread_id: Some(id.ThreadId("thread-1")),
    from: id.ParticipantId("participant-1"),
    to: [],
    kind: message.Decision,
    created_at: birl.utc_now(),
    sequence: sequence,
    requires_ack: False,
    persist_hint: message.Durable,
    references: [],
    summary: summary,
    body: Some("Body " <> int.to_string(sequence)),
  )
}

pub fn insert_room_test() {
  with_store(fn(store) {
    let room = make_room("room_insert", "Insert Room")
    let assert Ok(room_id) = sqlite.insert_room(store, room)
    room_id |> should.equal("room_insert")

    let sqlite.SqliteStore(connection: conn) = store
    let decoder = {
      use id <- decode.field(0, decode.string)
      use title <- decode.field(1, decode.string)
      use purpose <- decode.field(2, decode.optional(decode.string))
      use external_ref <- decode.field(3, decode.optional(decode.string))
      use tags <- decode.field(4, decode.optional(decode.string))
      use interaction_mode <- decode.field(5, decode.optional(decode.string))
      decode.success(#(id, title, purpose, external_ref, tags, interaction_mode))
    }

    let assert Ok(rows) =
      sqlight.query(
        "SELECT id, title, purpose, external_ref, tags, interaction_mode FROM rooms WHERE id = ?",
        on: conn,
        with: [sqlight.text("room_insert")],
        expecting: decoder,
      )

    rows
    |> should.equal([
      #(
        "room_insert",
        "Insert Room",
        Some("Purpose"),
        Some("external/ref"),
        Some("tag-a,tag-b"),
        Some("informative"),
      ),
    ])
  })
}

pub fn insert_participant_test() {
  with_store(fn(store) {
    let room = make_room("room_participant", "Participant Room")
    let assert Ok(_) = sqlite.insert_room(store, room)

    let joined_at = birl.to_iso8601(birl.utc_now())
    let assert Ok(_) =
      sqlite.insert_participant(
        store,
        "room_participant",
        "participant_a",
        "Alice",
        "lead",
        joined_at,
      )

    let sqlite.SqliteStore(connection: conn) = store
    let decoder = {
      use room_id <- decode.field(0, decode.string)
      use participant_id <- decode.field(1, decode.string)
      use display_name <- decode.field(2, decode.string)
      use role <- decode.field(3, decode.string)
      decode.success(#(room_id, participant_id, display_name, role))
    }

    let assert Ok(rows) =
      sqlight.query(
        "SELECT room_id, participant_id, display_name, role FROM participants WHERE room_id = ?",
        on: conn,
        with: [sqlight.text("room_participant")],
        expecting: decoder,
      )

    rows
    |> should.equal([#("room_participant", "participant_a", "Alice", "lead")])
  })
}

pub fn insert_message_test() {
  with_store(fn(store) {
    let room = make_room("room_message", "Message Room")
    let assert Ok(_) = sqlite.insert_room(store, room)

    let msg = make_message("msg_insert", "room_message", 7, "Decision made")
    let assert Ok(message_id) = sqlite.insert_message(store, msg)
    message_id |> should.equal("msg_insert")

    let sqlite.SqliteStore(connection: conn) = store
    let decoder = {
      use message_id <- decode.field(0, decode.string)
      use from_id <- decode.field(1, decode.string)
      use kind <- decode.field(2, decode.string)
      use sequence <- decode.field(3, decode.int)
      use summary <- decode.field(4, decode.string)
      use body <- decode.field(5, decode.optional(decode.string))
      use thread_id <- decode.field(6, decode.optional(decode.string))
      use persist_hint <- decode.field(7, decode.optional(decode.string))
      decode.success(#(
        message_id,
        from_id,
        kind,
        sequence,
        summary,
        body,
        thread_id,
        persist_hint,
      ))
    }

    let assert Ok(rows) =
      sqlight.query(
        "SELECT message_id, from_id, kind, sequence, summary, body, thread_id, persist_hint FROM messages WHERE room_id = ?",
        on: conn,
        with: [sqlight.text("room_message")],
        expecting: decoder,
      )

    rows
    |> should.equal([
      #(
        "msg_insert",
        "participant-1",
        "decision",
        7,
        "Decision made",
        Some("Body 7"),
        Some("thread-1"),
        Some("durable"),
      ),
    ])
  })
}

pub fn update_room_close_test() {
  with_store(fn(store) {
    let open_room = make_room("room_close", "Close Room")
    let assert Ok(_) = sqlite.insert_room(store, open_room)

    let closed_room = room.close_with_resolution(open_room, room.Completed)
    let assert Ok(_) = sqlite.update_room_close(store, closed_room, 12, 3456)

    let sqlite.SqliteStore(connection: conn) = store
    let decoder = {
      use resolution <- decode.field(0, decode.optional(decode.string))
      use closed_at <- decode.field(1, decode.optional(decode.string))
      decode.success(#(resolution, closed_at))
    }

    let assert Ok(rows) =
      sqlight.query(
        "SELECT resolution, closed_at FROM rooms WHERE id = ?",
        on: conn,
        with: [sqlight.text("room_close")],
        expecting: decoder,
      )

    let assert [#(Some("completed"), closed_at)] = rows
    case closed_at {
      Some(ts) -> should.be_true(string.length(ts) > 0)
      None -> should.fail()
    }
  })
}

pub fn insert_conversation_artifact_test() {
  with_store(fn(store) {
    let room = make_room("room_artifact", "Artifact Room")
    let assert Ok(_) = sqlite.insert_room(store, room)

    let assert Ok(record_id) =
      sqlite.insert_conversation_artifact(
        store,
        room,
        "# Conversation\n\nA durable transcript",
      )
    record_id |> string.starts_with("artifact_") |> should.be_true

    let sqlite.SqliteStore(connection: conn) = store
    let decoder = {
      use stored_record_id <- decode.field(0, decode.string)
      use content <- decode.field(1, decode.string)
      decode.success(#(stored_record_id, content))
    }

    let assert Ok(rows) =
      sqlight.query(
        "SELECT record_id, content FROM conversation_artifacts WHERE record_id = ?",
        on: conn,
        with: [sqlight.text(record_id)],
        expecting: decoder,
      )

    rows
    |> should.equal([
      #(record_id, "# Conversation\n\nA durable transcript"),
    ])
  })
}

pub fn query_closed_rooms_test() {
  with_store(fn(store) {
    let open_room = make_room("room_open_only", "Open Room")
    let closed_room = make_room("room_closed", "Closed Room")

    let assert Ok(_) = sqlite.insert_room(store, open_room)
    let assert Ok(_) = sqlite.insert_room(store, closed_room)
    let assert Ok(_) =
      sqlite.update_room_close(
        store,
        room.close_with_resolution(closed_room, room.Failed),
        1,
        50,
      )

    let assert Ok(closed_rooms) = sqlite.query_closed_rooms(store)
    list.length(closed_rooms) |> should.equal(1)

    let assert [sqlite.ClosedRoom(id:, title:, closed_at:)] = closed_rooms
    id |> should.equal("room_closed")
    title |> should.equal("Closed Room")
    should.be_true(string.length(closed_at) > 0)
  })
}

pub fn query_room_messages_test() {
  with_store(fn(store) {
    let room = make_room("room_query_messages", "Messages Room")
    let assert Ok(_) = sqlite.insert_room(store, room)

    let assert Ok(_) =
      sqlite.insert_message(
        store,
        make_message("msg_two", "room_query_messages", 2, "Second"),
      )
    let assert Ok(_) =
      sqlite.insert_message(
        store,
        make_message("msg_one", "room_query_messages", 1, "First"),
      )
    let assert Ok(_) =
      sqlite.insert_message(
        store,
        make_message("msg_three", "room_query_messages", 3, "Third"),
      )

    let assert Ok(messages) =
      sqlite.query_room_messages(store, "room_query_messages")

    messages
    |> should.equal([
      sqlite.StoredMessage(
        from_id: "participant-1",
        kind: "decision",
        summary: "First",
        body: Some("Body 1"),
        sequence: 1,
      ),
      sqlite.StoredMessage(
        from_id: "participant-1",
        kind: "decision",
        summary: "Second",
        body: Some("Body 2"),
        sequence: 2,
      ),
      sqlite.StoredMessage(
        from_id: "participant-1",
        kind: "decision",
        summary: "Third",
        body: Some("Body 3"),
        sequence: 3,
      ),
    ])
  })
}
