import gleam/erlang/process.{type Subject}
import neural_link/runtime/inbox
import neural_link/runtime/presence
import neural_link/runtime/registry

pub type Services {
  Services(
    registry: Subject(registry.RegistryMessage),
    inbox: Subject(inbox.InboxMessage),
    presence: Subject(presence.PresenceMessage),
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
              Ok(Services(
                registry: reg_started.data,
                inbox: inbox_started.data,
                presence: presence_started.data,
              ))
          }
      }
  }
}
