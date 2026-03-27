import gleam/erlang/process.{type Subject}
import logging
import neural_link/persistence/database
import neural_link/persistence/sqlite
import neural_link/runtime/inbox
import neural_link/runtime/presence
import neural_link/runtime/registry

pub type Services {
  Services(
    registry: Subject(registry.RegistryMessage),
    inbox: Subject(inbox.InboxMessage),
    presence: Subject(presence.PresenceMessage),
    store: sqlite.SqliteStore,
  )
}

pub fn start() -> Result(Services, String) {
  case database.runtime_paths() {
    Error(err) -> Error("Failed runtime path resolution: " <> err)
    Ok(runtime_paths) -> {
      let database.RuntimePaths(data_dir: _, db_path: db_path, sync_log_path: _) =
        runtime_paths
      start_with_database(database.File(db_path))
    }
  }
}

pub fn start_with_database(
  target: database.DatabaseTarget,
) -> Result(Services, String) {
  case registry.start() {
    Error(_) -> Error("Failed to start registry")
    Ok(reg_started) ->
      case inbox.start() {
        Error(_) -> Error("Failed to start inbox")
        Ok(inbox_started) ->
          case presence.start() {
            Error(_) -> Error("Failed to start presence")
            Ok(presence_started) ->
              case database.open(target) {
                Ok(store) ->
                  Ok(Services(
                    registry: reg_started.data,
                    inbox: inbox_started.data,
                    presence: presence_started.data,
                    store: store,
                  ))
                Error(err) -> {
                  logging.log(
                    logging.Warning,
                    "Failed to open SQLite store: " <> err,
                  )
                  Error("Failed to open sqlite store: " <> err)
                }
              }
          }
      }
  }
}
