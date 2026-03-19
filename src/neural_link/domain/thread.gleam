import gleam/option.{type Option, None}
import neural_link/domain/id.{type RoomId, type ThreadId, new_thread_id}

pub type Thread {
  Thread(
    thread_id: ThreadId,
    room_id: RoomId,
    title: Option(String),
    first_sequence: Int,
    last_sequence: Int,
  )
}

pub fn new_thread(room_id: RoomId, first_sequence: Int) -> Thread {
  Thread(
    thread_id: new_thread_id(),
    room_id: room_id,
    title: None,
    first_sequence: first_sequence,
    last_sequence: first_sequence,
  )
}

pub fn update_last_sequence(thread: Thread, seq: Int) -> Thread {
  Thread(..thread, last_sequence: seq)
}
