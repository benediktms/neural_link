import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub type RegistryMessage {
  Shutdown
}

pub fn start() -> actor.StartResult(Subject(RegistryMessage)) {
  actor.new(Nil)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  _state: Nil,
  msg: RegistryMessage,
) -> actor.Next(Nil, RegistryMessage) {
  case msg {
    Shutdown -> actor.stop()
  }
}
