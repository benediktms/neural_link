import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import neural_link/domain/id
import neural_link/domain/message
import neural_link/domain/participant
import neural_link/domain/room as domain_room
import neural_link/domain/wait
import neural_link/runtime/inbox
import neural_link/runtime/registry
import neural_link/runtime/room

// ---------------------------------------------------------------------------
// Helper: set up a room with lead + member
// ---------------------------------------------------------------------------

fn setup_room_with_lead() {
  let assert Ok(reg_started) = registry.start()
  let reg = reg_started.data
  let assert Ok(inbox_started) = inbox.start()
  let inbox_subject = inbox_started.data
  let assert Ok(room_data) =
    registry.create_room(reg, "Leave Test", None, None, [], [], None)
  let id.RoomId(room_id) = room_data.id
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  // Join lead
  let lead = participant.new("lead", "Lead", participant.Lead)
  let assert Ok(Nil) = room.join(room_subject, lead)

  #(reg, inbox_subject, room_subject, room_data)
}

// ---------------------------------------------------------------------------
// Test: basic leave with no obligations
// ---------------------------------------------------------------------------

pub fn basic_leave_no_obligations_test() {
  let #(_reg, _inbox, room_subject, _room_data) = setup_room_with_lead()

  // Join a member
  let member = participant.new("agent-a", "Agent A", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, member)

  // Leave — no messages sent, so no obligations
  let drain_subject = process.new_subject()
  let result =
    room.leave(room_subject, id.ParticipantId("agent-a"), drain_subject)
  result |> should.be_ok
  let assert Ok(room.Departed) = result

  // Verify participant is departed
  let state = room.get_state(room_subject)
  let active = domain_room.active_participants(state)
  let active_ids = list.map(active, fn(p) { id.participant_id_to_string(p.id) })
  active_ids |> should.equal(["lead"])
}

// ---------------------------------------------------------------------------
// Test: lead cannot leave
// ---------------------------------------------------------------------------

pub fn lead_cannot_leave_test() {
  let #(_reg, _inbox, room_subject, _room_data) = setup_room_with_lead()

  let drain_subject = process.new_subject()
  let result = room.leave(room_subject, id.ParticipantId("lead"), drain_subject)
  result |> should.be_error
  let assert Error(msg) = result
  msg |> should.equal("Lead cannot leave; use room_close")
}

// ---------------------------------------------------------------------------
// Test: drain with pending receipts -> ack -> departure
// ---------------------------------------------------------------------------

pub fn drain_with_pending_receipts_test() {
  let #(_reg, _inbox, room_subject, _room_data) = setup_room_with_lead()

  let member = participant.new("agent-a", "Agent A", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, member)

  // Agent A sends a message to lead (creates a pending receipt)
  let assert Ok(msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("agent-a"),
      [id.ParticipantId("lead")],
      message.Finding,
      "Important finding",
    )

  // Agent A tries to leave — should enter drain
  let drain_subject = process.new_subject()
  let result =
    room.leave(room_subject, id.ParticipantId("agent-a"), drain_subject)
  result |> should.be_ok
  let assert Ok(room.DrainStarted(pending_ids)) = result
  list.length(pending_ids) |> should.equal(1)

  // Lead acks the message — drain should complete
  let assert Ok(Nil) =
    room.ack_messages(room_subject, id.ParticipantId("lead"), [msg.message_id])

  // Drain callback should have fired — receive should succeed immediately
  let drain_result = process.receive(drain_subject, 1000)
  drain_result |> should.be_ok
}

// ---------------------------------------------------------------------------
// Test: drain timeout -> forced departure
// ---------------------------------------------------------------------------

pub fn drain_timeout_forced_departure_test() {
  let #(_reg, _inbox, room_subject, _room_data) = setup_room_with_lead()

  let member = participant.new("agent-a", "Agent A", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, member)

  // Agent A sends a message (creates pending receipt)
  let assert Ok(_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("agent-a"),
      [id.ParticipantId("lead")],
      message.Finding,
      "Finding",
    )

  // Leave — enters drain
  let drain_subject = process.new_subject()
  let assert Ok(room.DrainStarted(_)) =
    room.leave(room_subject, id.ParticipantId("agent-a"), drain_subject)

  // Don't ack — drain times out after 200ms
  let drain_result = process.receive(drain_subject, 200)
  drain_result |> should.be_error

  // Force departure
  let assert Ok(Nil) =
    room.force_departure(room_subject, id.ParticipantId("agent-a"))

  // Verify departed
  let state = room.get_state(room_subject)
  let active = domain_room.active_participants(state)
  let active_ids = list.map(active, fn(p) { id.participant_id_to_string(p.id) })
  active_ids |> should.equal(["lead"])
}

// ---------------------------------------------------------------------------
// Test: departed participant excluded from broadcast
// ---------------------------------------------------------------------------

pub fn departed_excluded_from_broadcast_test() {
  let #(_reg, _inbox, room_subject, _room_data) = setup_room_with_lead()

  let member_a = participant.new("agent-a", "Agent A", participant.Member)
  let member_b = participant.new("agent-b", "Agent B", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, member_a)
  let assert Ok(Nil) = room.join(room_subject, member_b)

  // Agent A departs
  let drain_subject = process.new_subject()
  let assert Ok(room.Departed) =
    room.leave(room_subject, id.ParticipantId("agent-a"), drain_subject)

  // Lead broadcasts — agent-a should NOT get a receipt
  let assert Ok(_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("lead"),
      [],
      message.Decision,
      "Final decision",
    )

  // Agent B sees the message
  let b_inbox = room.read_inbox(room_subject, id.ParticipantId("agent-b"))
  list.length(b_inbox) |> should.equal(1)

  // Agent A does NOT see the message
  let a_inbox = room.read_inbox(room_subject, id.ParticipantId("agent-a"))
  list.length(a_inbox) |> should.equal(0)
}

// ---------------------------------------------------------------------------
// Test: escalation on departure with pending wait
// ---------------------------------------------------------------------------

pub fn escalation_on_departure_with_pending_wait_test() {
  let #(_reg, inbox_subject, room_subject, room_data) = setup_room_with_lead()

  let member_a = participant.new("agent-a", "Agent A", participant.Member)
  let member_b = participant.new("agent-b", "Agent B", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, member_a)
  let assert Ok(Nil) = room.join(room_subject, member_b)

  // Agent B registers a wait for messages from agent-a
  let filter =
    wait.WaitFilter(kinds: [message.Answer], from: [id.ParticipantId("agent-a")])
  let wait_subject = process.new_subject()
  process.send(
    inbox_subject,
    inbox.RegisterWait(
      participant_id: id.ParticipantId("agent-b"),
      filter: filter,
      since_sequence: 0,
      timeout_ms: 10_000,
      room_id: Some(room_data.id),
      reply: wait_subject,
    ),
  )

  // Small delay to ensure wait is registered
  process.sleep(50)

  // Agent A departs — notify inbox
  let drain_subject = process.new_subject()
  let assert Ok(room.Departed) =
    room.leave(room_subject, id.ParticipantId("agent-a"), drain_subject)

  // Get room state for departure notification
  let state = room.get_state(room_subject)
  let active = domain_room.active_participants(state)
  let active_ids = list.map(active, fn(p) { p.id })

  // Notify inbox of departure — should report escalated waiters
  let departure_result =
    inbox.participant_departed(
      inbox_subject,
      room_data.id,
      id.ParticipantId("agent-a"),
      id.ParticipantId("lead"),
      active_ids,
    )
  list.length(departure_result.escalated_waiter_ids) |> should.equal(1)

  // Lead sends an answer — should trigger lead override on agent-b's wait
  let assert Ok(lead_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("lead"),
      [id.ParticipantId("agent-b")],
      message.Answer,
      "Lead stepping in for agent-a",
    )
  inbox.notify_message(inbox_subject, lead_msg)

  // Agent B's wait should resolve with the lead's message
  let assert Ok(Ok(resolved_msg)) = process.receive(wait_subject, 5000)
  resolved_msg.summary |> should.equal("Lead stepping in for agent-a")
}

// ---------------------------------------------------------------------------
// Test: room_open auto-joins lead
// ---------------------------------------------------------------------------

pub fn room_open_auto_joins_lead_test() {
  let assert Ok(reg_started) = registry.start()
  let reg = reg_started.data
  let assert Ok(room_data) =
    registry.create_room(reg, "Auto Lead Test", None, None, [], [], None)
  let id.RoomId(room_id) = room_data.id
  let assert Ok(room_subject) = registry.get_room(reg, room_id)

  // Join as lead (simulating what room_open handler does)
  let lead = participant.new("queen", "The Queen", participant.Lead)
  let assert Ok(Nil) = room.join(room_subject, lead)

  // Verify lead exists
  let state = room.get_state(room_subject)
  let lead_opt = domain_room.find_lead(state)
  lead_opt |> should.be_some

  // Verify lead cannot leave
  let drain_subject = process.new_subject()
  let result =
    room.leave(room_subject, id.ParticipantId("queen"), drain_subject)
  result |> should.be_error

  // Verify is_lead check
  domain_room.is_lead(state, id.ParticipantId("queen")) |> should.be_true
  domain_room.is_lead(state, id.ParticipantId("nonexistent"))
  |> should.be_false
}

// ---------------------------------------------------------------------------
// Test: lead override rejects wrong message kind
// ---------------------------------------------------------------------------

pub fn lead_override_rejects_wrong_kind_test() {
  let #(_reg, inbox_subject, room_subject, room_data) = setup_room_with_lead()

  let member_a = participant.new("agent-a", "Agent A", participant.Member)
  let member_b = participant.new("agent-b", "Agent B", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, member_a)
  let assert Ok(Nil) = room.join(room_subject, member_b)

  // Agent B registers a wait for Answer from agent-a
  let filter =
    wait.WaitFilter(kinds: [message.Answer], from: [id.ParticipantId("agent-a")])
  let wait_subject = process.new_subject()
  process.send(
    inbox_subject,
    inbox.RegisterWait(
      participant_id: id.ParticipantId("agent-b"),
      filter: filter,
      since_sequence: 0,
      timeout_ms: 2000,
      room_id: Some(room_data.id),
      reply: wait_subject,
    ),
  )
  process.sleep(50)

  // Agent A departs
  let drain_subject = process.new_subject()
  let assert Ok(room.Departed) =
    room.leave(room_subject, id.ParticipantId("agent-a"), drain_subject)

  let state = room.get_state(room_subject)
  let active = domain_room.active_participants(state)
  let active_ids = list.map(active, fn(p) { p.id })
  let _departure_result =
    inbox.participant_departed(
      inbox_subject,
      room_data.id,
      id.ParticipantId("agent-a"),
      id.ParticipantId("lead"),
      active_ids,
    )

  // Lead sends a Decision (wrong kind — wait is for Answer)
  let assert Ok(wrong_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("lead"),
      [id.ParticipantId("agent-b")],
      message.Decision,
      "This is a decision, not an answer",
    )
  inbox.notify_message(inbox_subject, wrong_msg)

  // Wait should NOT resolve — timeout after 500ms
  let wait_result = process.receive(wait_subject, 500)
  wait_result |> should.be_error

  // Now send the correct kind — Answer from lead
  let assert Ok(correct_msg) =
    room.send_msg(
      room_subject,
      id.ParticipantId("lead"),
      [id.ParticipantId("agent-b")],
      message.Answer,
      "Correct kind from lead",
    )
  inbox.notify_message(inbox_subject, correct_msg)

  // Now the wait resolves
  let assert Ok(Ok(resolved)) = process.receive(wait_subject, 2000)
  resolved.summary |> should.equal("Correct kind from lead")
}

// ---------------------------------------------------------------------------
// Test: concurrent drains
// ---------------------------------------------------------------------------

pub fn concurrent_drains_test() {
  let #(_reg, _inbox, room_subject, _room_data) = setup_room_with_lead()

  let member_a = participant.new("agent-a", "Agent A", participant.Member)
  let member_b = participant.new("agent-b", "Agent B", participant.Member)
  let assert Ok(Nil) = room.join(room_subject, member_a)
  let assert Ok(Nil) = room.join(room_subject, member_b)

  // Both agents send messages to each other (creating cross-obligations)
  let assert Ok(msg_a) =
    room.send_msg(
      room_subject,
      id.ParticipantId("agent-a"),
      [id.ParticipantId("agent-b")],
      message.Finding,
      "Finding from A",
    )
  let assert Ok(msg_b) =
    room.send_msg(
      room_subject,
      id.ParticipantId("agent-b"),
      [id.ParticipantId("agent-a")],
      message.Finding,
      "Finding from B",
    )

  // Both try to leave — both should enter drain
  let drain_a = process.new_subject()
  let assert Ok(room.DrainStarted(_)) =
    room.leave(room_subject, id.ParticipantId("agent-a"), drain_a)

  let drain_b = process.new_subject()
  let assert Ok(room.DrainStarted(_)) =
    room.leave(room_subject, id.ParticipantId("agent-b"), drain_b)

  // Ack agent-a's message (by agent-b) — agent-a's drain should complete
  let assert Ok(Nil) =
    room.ack_messages(room_subject, id.ParticipantId("agent-b"), [
      msg_a.message_id,
    ])
  let drain_a_result = process.receive(drain_a, 1000)
  drain_a_result |> should.be_ok

  // Agent-b still draining (agent-a hasn't acked msg_b)
  let drain_b_check = process.receive(drain_b, 200)
  drain_b_check |> should.be_error

  // Ack agent-b's message (by agent-a) — agent-b's drain should complete
  let assert Ok(Nil) =
    room.ack_messages(room_subject, id.ParticipantId("agent-a"), [
      msg_b.message_id,
    ])
  let drain_b_result = process.receive(drain_b, 1000)
  drain_b_result |> should.be_ok

  // Both should be departed now
  let state = room.get_state(room_subject)
  let active = domain_room.active_participants(state)
  let active_ids = list.map(active, fn(p) { id.participant_id_to_string(p.id) })
  active_ids |> should.equal(["lead"])
}
