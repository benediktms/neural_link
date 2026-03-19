import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import neural_link/domain/room.{type Room}

pub type RoomMessage {
  GetState(reply_with: Subject(Room))
  Shutdown
}

pub fn start(room_data: Room) -> actor.StartResult(Subject(RoomMessage)) {
  actor.new(room_data)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: Room,
  msg: RoomMessage,
) -> actor.Next(Room, RoomMessage) {
  case msg {
    GetState(reply) -> {
      actor.send(reply, state)
      actor.continue(state)
    }
    Shutdown -> actor.stop()
  }
}
