import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import neural_link/brain/client
import neural_link/brain/types as brain_types
import neural_link/persistence/brain as brain_persistence
import neural_link/persistence/sqlite
import neural_link/persistence/sync_log
import neural_link/persistence/types

pub type SyncResult {
  SyncResult(
    total_closed_rooms: Int,
    already_synced: Int,
    synced: Int,
    failed: Int,
  )
}

type SyncStats {
  SyncStats(
    total_closed_rooms: Int,
    already_synced: Int,
    synced: Int,
    failed: Int,
  )
}

type CliConfig {
  CliConfig(db_path: String, sync_log_path: String, brain_name: String)
}

const default_db_path = "neural_link.db"

const default_sync_log_path = ".neural_link/sync.jsonl"

pub fn run(args: List(String)) -> Nil {
  let CliConfig(db_path:, sync_log_path:, brain_name:) = parse_config(args)

  case sqlite.open(db_path) {
    Error(err) ->
      io.println_error(
        "sync: failed to open sqlite store: " <> types.error_to_string(err),
      )
    Ok(store) -> {
      let result =
        sync_rooms_with_brain(
          store,
          sync_log_path,
          brain_name,
          brain_persistence.BrainClient(
            save_snapshot: client.save_snapshot,
            create_artifact: client.create_artifact,
          ),
        )
      sqlite.close(store)
      print_summary(result)
    }
  }
}

/// Core sync logic — testable with injectable brain client.
pub fn sync_rooms(
  store: sqlite.SqliteStore,
  sync_log_path: String,
  brain_client: brain_persistence.BrainClient,
) -> SyncResult {
  sync_rooms_with_brain(store, sync_log_path, "", brain_client)
}

pub fn sync_rooms_with_brain(
  store: sqlite.SqliteStore,
  sync_log_path: String,
  brain_name: String,
  brain_client: brain_persistence.BrainClient,
) -> SyncResult {
  case sqlite.query_closed_rooms(store) {
    Error(err) -> {
      io.println_error(
        "sync: failed to query closed rooms: " <> types.error_to_string(err),
      )
      SyncResult(total_closed_rooms: 0, already_synced: 0, synced: 0, failed: 0)
    }
    Ok(rooms) -> {
      let initial =
        SyncStats(
          total_closed_rooms: list.length(rooms),
          already_synced: 0,
          synced: 0,
          failed: 0,
        )

      let final_stats =
        list.fold(rooms, initial, fn(stats, room) {
          sync_room(store, sync_log_path, brain_name, brain_client, stats, room)
        })

      SyncResult(
        total_closed_rooms: final_stats.total_closed_rooms,
        already_synced: final_stats.already_synced,
        synced: final_stats.synced,
        failed: final_stats.failed,
      )
    }
  }
}

fn sync_room(
  store: sqlite.SqliteStore,
  sync_log_path: String,
  brain_name: String,
  brain_client: brain_persistence.BrainClient,
  stats: SyncStats,
  room: sqlite.ClosedRoom,
) -> SyncStats {
  let sqlite.ClosedRoom(id: room_id, title: room_title, closed_at: closed_at) =
    room

  case sync_log.is_synced(sync_log_path, room_id) {
    True ->
      SyncStats(
        total_closed_rooms: stats.total_closed_rooms,
        already_synced: stats.already_synced + 1,
        synced: stats.synced,
        failed: stats.failed,
      )
    False ->
      case sqlite.query_room_messages(store, room_id) {
        Error(err) -> {
          io.println_error(
            "sync: failed to query messages for room "
            <> room_id
            <> ": "
            <> types.error_to_string(err),
          )
          SyncStats(
            total_closed_rooms: stats.total_closed_rooms,
            already_synced: stats.already_synced,
            synced: stats.synced,
            failed: stats.failed + 1,
          )
        }
        Ok(messages) -> {
          let transcript = build_transcript(room_title, closed_at, messages)
          let brain_cfg = brain_types.BrainConfig(brain_name: brain_name)
          let title = "Room: " <> room_title
          let tags = ["neural-link", "conversation", room_id]

          let brain_persistence.BrainClient(create_artifact:, save_snapshot: _) =
            brain_client

          case
            create_artifact(brain_cfg, title, transcript, "conversation", tags)
          {
            Error(err) -> {
              io.println_error(
                "sync: failed to push room "
                <> room_id
                <> " to brain: "
                <> describe_brain_error(err),
              )
              SyncStats(
                total_closed_rooms: stats.total_closed_rooms,
                already_synced: stats.already_synced,
                synced: stats.synced,
                failed: stats.failed + 1,
              )
            }
            Ok(_) ->
              case sync_log.mark_synced(sync_log_path, room_id, brain_name) {
                Ok(Nil) ->
                  SyncStats(
                    total_closed_rooms: stats.total_closed_rooms,
                    already_synced: stats.already_synced,
                    synced: stats.synced + 1,
                    failed: stats.failed,
                  )
                Error(err) -> {
                  io.println_error(
                    "sync: failed to mark room "
                    <> room_id
                    <> " as synced: "
                    <> err,
                  )
                  SyncStats(
                    total_closed_rooms: stats.total_closed_rooms,
                    already_synced: stats.already_synced,
                    synced: stats.synced,
                    failed: stats.failed + 1,
                  )
                }
              }
          }
        }
      }
  }
}

fn build_transcript(
  room_title: String,
  closed_at: String,
  messages: List(sqlite.StoredMessage),
) -> String {
  let message_lines =
    messages
    |> list.map(fn(message) {
      let sqlite.StoredMessage(
        from_id: from_id,
        kind: kind,
        summary: summary,
        body: body,
        sequence: sequence,
      ) = message

      let header =
        "["
        <> int.to_string(sequence)
        <> "] ["
        <> from_id
        <> "] ("
        <> kind
        <> ") "
        <> summary
      case body {
        Some(text) -> header <> "\n" <> text
        None -> header
      }
    })
    |> string.join("\n\n")

  string.join(
    [
      "# Room: " <> room_title,
      "Closed at: " <> closed_at,
      "",
      "## Messages (" <> int.to_string(list.length(messages)) <> ")",
      "",
      message_lines,
    ],
    "\n",
  )
}

fn describe_brain_error(err: brain_types.BrainError) -> String {
  case err {
    brain_types.Timeout -> "timeout"
    brain_types.CommandFailed(output) -> output
    brain_types.ParseError(detail) -> detail
  }
}

fn parse_config(args: List(String)) -> CliConfig {
  parse_args(
    args,
    CliConfig(
      db_path: default_db_path,
      sync_log_path: default_sync_log_path,
      brain_name: "",
    ),
  )
}

fn parse_args(args: List(String), config: CliConfig) -> CliConfig {
  case args {
    ["--db", db_path, ..rest] ->
      parse_args(rest, CliConfig(..config, db_path: db_path))
    ["--log", sync_log_path, ..rest] ->
      parse_args(rest, CliConfig(..config, sync_log_path: sync_log_path))
    ["--brain", brain_name, ..rest] ->
      parse_args(rest, CliConfig(..config, brain_name: brain_name))
    [_unknown, ..rest] -> parse_args(rest, config)
    [] -> config
  }
}

fn print_summary(result: SyncResult) -> Nil {
  let SyncResult(total_closed_rooms:, already_synced:, synced:, failed:) =
    result
  io.println(
    "sync complete:"
    <> " total_closed="
    <> int.to_string(total_closed_rooms)
    <> " already_synced="
    <> int.to_string(already_synced)
    <> " synced="
    <> int.to_string(synced)
    <> " failed="
    <> int.to_string(failed),
  )
}
