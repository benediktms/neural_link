import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub type InboxMessage {
  Shutdown
}

pub fn start() -> actor.StartResult(Subject(InboxMessage)) {
  actor.new(Nil)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  _state: Nil,
  msg: InboxMessage,
) -> actor.Next(Nil, InboxMessage) {
  case msg {
    Shutdown -> actor.stop()
  }
}
