import gleam/erlang/process.{type Subject}
import logging
import neural_link/persistence/sqlite
import neural_link/persistence/types
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
  case registry.start() {
    Error(_) -> Error("Failed to start registry")
    Ok(reg_started) ->
      case inbox.start() {
        Error(_) -> Error("Failed to start inbox")
        Ok(inbox_started) ->
          case presence.start() {
            Error(_) -> Error("Failed to start presence")
            Ok(presence_started) ->
              case sqlite.open("neural_link.db") {
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
                    "Failed to open SQLite store: "
                      <> types.error_to_string(err),
                  )
                  Error("Failed to open sqlite store")
                }
              }
          }
      }
  }
}
