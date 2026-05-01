import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should
import neural_link/domain/id.{type RoomId, ParticipantId, RoomId}
import neural_link/domain/message as message_mod
import neural_link/domain/participant
import neural_link/domain/room as domain_room
import neural_link/persistence/database
import neural_link/runtime/presence as presence_mod
import neural_link/runtime/registry as registry_mod
import neural_link/runtime/room as room_mod
import neural_link/runtime/supervisor

// ---------------------------------------------------------------------------
// N1: Registry removes room entry after close
// ---------------------------------------------------------------------------

pub fn n1_registry_removes_room_after_close_test() {
  let assert Ok(services) = supervisor.start_with_database(database.Memory)
  let registry = services.registry

  let assert Ok(room) =
    registry_mod.create_room(registry, "Test Room", None, None, [], [], None)

  let room_id = room_mod_id_string(room.id)

  let assert Ok(room_subject) = registry_mod.get_room(registry, room_id)

  let p = participant.new("p1", "Alice", participant.Member)
  let assert Ok(_) = room_mod.join(room_subject, p)
  let assert Ok(_) = room_mod.close_room(room_subject, domain_room.Completed)
  process.sleep(50)

  let assert Ok(_) = registry_mod.remove_room(registry, room_id)

  registry_mod.get_room(registry, room_id) |> should.be_error
}

pub fn n1_registry_room_absent_means_get_room_returns_error_test() {
  let assert Ok(reg_started) = registry_mod.start()
  let registry = reg_started.data

  registry_mod.get_room(registry, "room_nonexistent") |> should.be_error
}

// ---------------------------------------------------------------------------
// N2: Receipts pruned when messages exceed max_messages
// ---------------------------------------------------------------------------

pub fn n2_receipts_size_matches_message_count_after_trim_test() {
  let max = 5
  let overfill = max + 10
  let room_data = domain_room.new("test-room-n2", "N2 Test Room")
  let assert Ok(started) = room_mod.start_with_max_messages(room_data, max)
  let room_subject = started.data

  let sender = ParticipantId("sender")
  let receiver = ParticipantId("receiver")
  let sender_p = participant.new("sender", "Sender", participant.Member)
  let receiver_p = participant.new("receiver", "Receiver", participant.Member)
  let assert Ok(_) = room_mod.join(room_subject, sender_p)
  let assert Ok(_) = room_mod.join(room_subject, receiver_p)

  list.repeat(Nil, overfill)
  |> list.each(fn(_) {
    let assert Ok(_) =
      room_mod.send_msg(
        room_subject,
        sender,
        [receiver],
        message_mod.Finding,
        "msg",
      )
  })

  let messages = room_mod.get_messages(room_subject, None)
  list.length(messages) |> should.equal(max)

  let receipts_size = room_mod.get_receipts_size(room_subject)
  receipts_size |> should.equal(max)
}

pub fn n2_receipts_size_equals_messages_below_max_test() {
  let max = 10
  let count = 5
  let room_data = domain_room.new("test-room-n2b", "N2 Below Max")
  let assert Ok(started) = room_mod.start_with_max_messages(room_data, max)
  let room_subject = started.data

  let sender = ParticipantId("sender")
  let receiver = ParticipantId("receiver")
  let sender_p = participant.new("sender", "Sender", participant.Member)
  let receiver_p = participant.new("receiver", "Receiver", participant.Member)
  let assert Ok(_) = room_mod.join(room_subject, sender_p)
  let assert Ok(_) = room_mod.join(room_subject, receiver_p)

  list.repeat(Nil, count)
  |> list.each(fn(_) {
    let assert Ok(_) =
      room_mod.send_msg(
        room_subject,
        sender,
        [receiver],
        message_mod.Finding,
        "msg",
      )
  })

  let receipts_size = room_mod.get_receipts_size(room_subject)
  receipts_size |> should.equal(count)
}

// ---------------------------------------------------------------------------
// N3: Presence evicts stale entries on CheckExpired
// ---------------------------------------------------------------------------

pub fn n3_check_expired_evicts_stale_participants_test() {
  let assert Ok(pres_started) = presence_mod.start()
  let presence = pres_started.data

  let pid = ParticipantId("stale-p1")
  // lease_ms = 1 so it expires immediately
  presence_mod.register(presence, pid, "room_x", 1)
  process.sleep(10)

  let expired = presence_mod.check_expired(presence)
  list.contains(expired, "stale-p1") |> should.be_true

  presence_mod.query_participant(presence, pid) |> should.be_error
}

pub fn n3_check_expired_keeps_fresh_participants_test() {
  let assert Ok(pres_started) = presence_mod.start()
  let presence = pres_started.data

  let pid = ParticipantId("fresh-p1")
  presence_mod.register(presence, pid, "room_y", 60_000)

  let expired = presence_mod.check_expired(presence)
  list.contains(expired, "fresh-p1") |> should.be_false

  presence_mod.query_participant(presence, pid) |> should.be_ok
}

pub fn n3_check_expired_rearming_does_not_crash_test() {
  let assert Ok(pres_started) = presence_mod.start()
  let presence = pres_started.data

  let pid = ParticipantId("timer-p1")
  presence_mod.register(presence, pid, "room_z", 1)
  process.sleep(10)

  let _expired = presence_mod.check_expired(presence)
  process.sleep(10)

  // A second check_expired call must succeed (timer re-arm does not crash)
  let _expired2 = presence_mod.check_expired(presence)
  True |> should.be_true
}

// ---------------------------------------------------------------------------
// Internal helper
// ---------------------------------------------------------------------------

fn room_mod_id_string(id: RoomId) -> String {
  let RoomId(s) = id
  s
}
