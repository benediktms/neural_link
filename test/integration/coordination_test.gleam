import gleam/list
import gleam/option
import gleeunit/should
import neural_link/domain/id
import neural_link/domain/message
import neural_link/domain/participant
import neural_link/domain/room as domain_room
import neural_link/runtime/registry
import neural_link/runtime/room

pub fn full_coordination_workflow_test() {
  // 1. Start Registry
  let assert Ok(started) = registry.start()
  let reg = started.data

  // 2. Create room
  let assert Ok(room_data) = registry.create_room(reg, "Test Coordination Room")
  let id.RoomId(room_id) = room_data.id

  // 3. Get room subject
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  // 4. Join participant A
  let participant_a =
    participant.new("agent-a", "Agent Alpha", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, participant_a)

  // 5. Join participant B
  let participant_b =
    participant.new("agent-b", "Agent Beta", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, participant_b)

  // 6. A sends question to B (directed)
  let assert Ok(question_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("agent-a"),
      [id.ParticipantId("agent-b")],
      message.Question,
      "What did you find?",
    )
  question_msg.sequence |> should.equal(1)

  // 7. B reads inbox — should see the question
  let b_inbox = room.read_inbox(room_subject, id.ParticipantId("agent-b"))
  list.length(b_inbox) |> should.equal(1)

  // 8. A reads inbox — should NOT see their own question (directed to B only)
  let a_inbox_1 = room.read_inbox(room_subject, id.ParticipantId("agent-a"))
  list.length(a_inbox_1) |> should.equal(0)

  // 9. B sends answer to A
  let assert Ok(answer_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("agent-b"),
      [id.ParticipantId("agent-a")],
      message.Answer,
      "Found the issue in config",
    )
  answer_msg.sequence |> should.equal(2)

  // 10. A reads inbox — should see the answer
  let a_inbox_2 = room.read_inbox(room_subject, id.ParticipantId("agent-a"))
  list.length(a_inbox_2) |> should.equal(1)

  // 11. A acks the answer
  let assert Ok(Nil) =
    room.ack_messages(room_subject, id.ParticipantId("agent-a"), [
      answer_msg.message_id,
    ])

  // 12. Get all messages — verify order (messages stored newest first)
  let all_msgs = room.get_messages(room_subject, option.None)
  list.length(all_msgs) |> should.equal(2)

  // 13. Close room
  let assert Ok(Nil) = room.close_room(room_subject, domain_room.Completed)

  // 14. Verify room is closed
  let final_state = room.get_state(room_subject)
  domain_room.is_closed(final_state) |> should.be_true

  // 15. Verify can't send to closed room
  let closed_result =
    room.send_msg(
      room_subject,
      id.ParticipantId("agent-a"),
      [],
      message.Finding,
      "Should fail",
    )
  closed_result |> should.be_error
}

pub fn broadcast_sends_to_all_except_sender_test() {
  let assert Ok(started) = registry.start()
  let reg = started.data
  let assert Ok(room_data) = registry.create_room(reg, "Broadcast Test")
  let id.RoomId(room_id) = room_data.id
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  // Join 3 participants
  let assert Ok(Nil) =
    room.join(room_subject, participant.new("p1", "P1", participant.Member))
  let assert Ok(Nil) =
    room.join(room_subject, participant.new("p2", "P2", participant.Member))
  let assert Ok(Nil) =
    room.join(room_subject, participant.new("p3", "P3", participant.Member))

  // Broadcast from p1 (empty to list)
  let assert Ok(_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("p1"),
      [],
      message.Finding,
      "Broadcast finding",
    )

  // p2 and p3 should see it
  let p2_inbox = room.read_inbox(room_subject, id.ParticipantId("p2"))
  list.length(p2_inbox) |> should.equal(1)

  let p3_inbox = room.read_inbox(room_subject, id.ParticipantId("p3"))
  list.length(p3_inbox) |> should.equal(1)

  // p1 (sender) should NOT see it
  let p1_inbox = room.read_inbox(room_subject, id.ParticipantId("p1"))
  list.length(p1_inbox) |> should.equal(0)
}

pub fn idempotent_join_test() {
  let assert Ok(started) = registry.start()
  let reg = started.data
  let assert Ok(room_data) = registry.create_room(reg, "Join Test")
  let id.RoomId(room_id) = room_data.id
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  let p = participant.new("agent-x", "Agent X", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, p)
  // Second join should succeed (idempotent)
  let assert Ok(Nil) = room.join(room_subject, p)

  // Participant count should be 1, not 2
  let state = room.get_state(room_subject)
  domain_room.participant_count(state) |> should.equal(1)
}
