import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub type PresenceMessage {
  Shutdown
}

pub fn start() -> actor.StartResult(Subject(PresenceMessage)) {
  actor.new(Nil)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  _state: Nil,
  msg: PresenceMessage,
) -> actor.Next(Nil, PresenceMessage) {
  case msg {
    Shutdown -> actor.stop()
  }
}
