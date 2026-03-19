import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleeunit/should
import neural_link/domain/id
import neural_link/domain/message
import neural_link/domain/participant
import neural_link/domain/wait
import neural_link/runtime/registry
import neural_link/runtime/room

pub fn wait_for_resolves_on_matching_message_test() {
  let assert Ok(started) = registry.start()
  let reg = started.data
  let assert Ok(room_data) = registry.create_room(reg, "Wait Test")
  let id.RoomId(room_id) = room_data.id
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  let assert Ok(Nil) =
    room.join(
      room_subject,
      participant.new("waiter", "Waiter", participant.Member),
    )
  let assert Ok(Nil) =
    room.join(
      room_subject,
      participant.new("sender", "Sender", participant.Member),
    )

  // Spawn a process that sends an answer after 100ms
  let room_ref = room_subject
  let _ =
    process.spawn(fn() {
      process.sleep(100)
      let _ =
        room.send_msg(
          room_ref,
          id.ParticipantId("sender"),
          [id.ParticipantId("waiter")],
          message.Answer,
          "Here is the answer",
        )
    })

  // Register wait — this blocks until matching message arrives
  let filter = wait.WaitFilter(kinds: [message.Answer], from: [])
  let wait_result =
    actor.call(room_subject, 5000, fn(reply) {
      room.RegisterWait(
        participant_id: id.ParticipantId("waiter"),
        filter: filter,
        since_sequence: 0,
        timeout_ms: 5000,
        reply: reply,
      )
    })

  // Should resolve with the answer
  wait_result |> should.be_ok
  let assert Ok(msg) = wait_result
  msg.kind |> should.equal(message.Answer)
  msg.summary |> should.equal("Here is the answer")
}

pub fn handoff_message_workflow_test() {
  let assert Ok(started) = registry.start()
  let reg = started.data
  let assert Ok(room_data) = registry.create_room(reg, "Handoff Test")
  let id.RoomId(room_id) = room_data.id
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  let assert Ok(Nil) =
    room.join(
      room_subject,
      participant.new("alpha", "Alpha", participant.Member),
    )
  let assert Ok(Nil) =
    room.join(room_subject, participant.new("beta", "Beta", participant.Member))

  // Alpha sends handoff to Beta
  let assert Ok(handoff_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("alpha"),
      [id.ParticipantId("beta")],
      message.Handoff,
      "Continue the analysis",
    )

  // Verify handoff message properties
  handoff_msg.kind |> should.equal(message.Handoff)
  handoff_msg.sequence |> should.equal(1)

  // Beta sees the handoff in inbox
  let beta_inbox = room.read_inbox(room_subject, id.ParticipantId("beta"))
  list.length(beta_inbox) |> should.equal(1)

  // Beta acks the handoff
  let assert Ok(Nil) =
    room.ack_messages(room_subject, id.ParticipantId("beta"), [
      handoff_msg.message_id,
    ])

  // Alpha does NOT see it (directed to beta only)
  let alpha_inbox = room.read_inbox(room_subject, id.ParticipantId("alpha"))
  list.length(alpha_inbox) |> should.equal(0)
}

pub fn receipt_isolation_across_participants_test() {
  let assert Ok(started) = registry.start()
  let reg = started.data
  let assert Ok(room_data) = registry.create_room(reg, "Receipt Isolation Test")
  let id.RoomId(room_id) = room_data.id
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  // Join 3 participants
  let assert Ok(Nil) =
    room.join(room_subject, participant.new("a", "A", participant.Member))
  let assert Ok(Nil) =
    room.join(room_subject, participant.new("b", "B", participant.Member))
  let assert Ok(Nil) =
    room.join(room_subject, participant.new("c", "C", participant.Member))

  // A broadcasts a decision (to all except sender)
  let assert Ok(decision_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("a"),
      [],
      message.Decision,
      "Use mutex approach",
    )

  // B and C both see it
  let b_inbox = room.read_inbox(room_subject, id.ParticipantId("b"))
  list.length(b_inbox) |> should.equal(1)
  let c_inbox = room.read_inbox(room_subject, id.ParticipantId("c"))
  list.length(c_inbox) |> should.equal(1)

  // B acks — should succeed
  let assert Ok(Nil) =
    room.ack_messages(room_subject, id.ParticipantId("b"), [
      decision_msg.message_id,
    ])

  // C still sees the message (C's receipt is independent of B's)
  let c_inbox_after = room.read_inbox(room_subject, id.ParticipantId("c"))
  list.length(c_inbox_after) |> should.equal(1)

  // B still sees the message too (read_inbox does not filter by ack status at actor level)
  let b_inbox_after = room.read_inbox(room_subject, id.ParticipantId("b"))
  list.length(b_inbox_after) |> should.equal(1)
}
