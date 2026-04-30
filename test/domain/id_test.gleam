import gleam/string
import gleeunit/should
import neural_link/domain/id

pub fn generate_starts_with_prefix_test() {
  let result = id.generate("room_")
  result |> string.starts_with("room_") |> should.be_true
}

pub fn generate_produces_different_values_test() {
  let a = id.generate("room_")
  let b = id.generate("room_")
  a |> should.not_equal(b)
}

pub fn new_room_id_returns_room_id_test() {
  let rid = id.new_room_id()
  let s = id.room_id_to_string(rid)
  s |> string.starts_with("room_") |> should.be_true
}

pub fn new_participant_id_returns_participant_id_test() {
  let pid = id.new_participant_id()
  let s = id.participant_id_to_string(pid)
  s |> string.starts_with("participant_") |> should.be_true
}

pub fn new_message_id_returns_message_id_test() {
  let mid = id.new_message_id()
  let s = id.message_id_to_string(mid)
  s |> string.starts_with("msg_") |> should.be_true
}

pub fn room_id_round_trip_test() {
  let raw = "room_abc123"
  let rid = id.RoomId(raw)
  id.room_id_to_string(rid) |> should.equal(raw)
}

pub fn participant_id_round_trip_test() {
  let raw = "participant_xyz789"
  let pid = id.ParticipantId(raw)
  id.participant_id_to_string(pid) |> should.equal(raw)
}

pub fn message_id_round_trip_test() {
  let raw = "msg_deadbeef"
  let mid = id.MessageId(raw)
  id.message_id_to_string(mid) |> should.equal(raw)
}
