import gleeunit/should
import neural_link/domain/room.{Active, Closed, Closing, Open}
import neural_link/domain/participant
import neural_link/domain/id.{ParticipantId}

pub fn new_creates_room_with_open_status_test() {
  let r = room.new("r1", "Test Room")
  r.status |> should.equal(Open)
}

pub fn new_creates_room_with_empty_participants_test() {
  let r = room.new("r1", "Test Room")
  room.participant_count(r) |> should.equal(0)
}

pub fn add_participant_increases_count_test() {
  let r = room.new("r1", "Test Room")
  let p = participant.new("p1", "Alice", participant.Member)
  let r2 = room.add_participant(r, p)
  room.participant_count(r2) |> should.equal(1)
}

pub fn remove_participant_decreases_count_test() {
  let r = room.new("r1", "Test Room")
  let p = participant.new("p1", "Alice", participant.Member)
  let r2 = room.add_participant(r, p)
  let r3 = room.remove_participant(r2, ParticipantId("p1"))
  room.participant_count(r3) |> should.equal(0)
}

pub fn status_transition_open_to_active_test() {
  let r = room.new("r1", "Test Room")
  let r2 = room.activate(r)
  r2.status |> should.equal(Active)
}

pub fn status_transition_active_to_closing_test() {
  let r = room.new("r1", "Test Room") |> room.activate
  let r2 = room.begin_close(r)
  r2.status |> should.equal(Closing)
}

pub fn status_transition_closing_to_closed_test() {
  let r = room.new("r1", "Test Room") |> room.activate |> room.begin_close
  let r2 = room.close(r)
  r2.status |> should.equal(Closed)
}

pub fn is_closed_returns_false_for_open_test() {
  let r = room.new("r1", "Test Room")
  room.is_closed(r) |> should.be_false
}

pub fn is_closed_returns_true_for_closed_test() {
  let r =
    room.new("r1", "Test Room")
    |> room.activate
    |> room.begin_close
    |> room.close
  room.is_closed(r) |> should.be_true
}
