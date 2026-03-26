import birl
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import neural_link/domain/id
import neural_link/domain/message
import neural_link/domain/participant
import neural_link/domain/room
import neural_link/persistence/brain

fn make_room_with_all(
  title: String,
  purpose: option.Option(String),
  external_ref: option.Option(String),
  tags: List(String),
  participant_count: Int,
) -> room.Room {
  let base =
    room.new_with_metadata(
      "room_fixture",
      title,
      purpose,
      external_ref,
      tags,
      [],
      option.None,
    )
  case participant_count {
    0 -> base
    1 ->
      base
      |> room.add_participant(participant.new(
        "p0",
        "Person 0",
        participant.Member,
      ))
    2 ->
      base
      |> room.add_participant(participant.new(
        "p0",
        "Person 0",
        participant.Member,
      ))
      |> room.add_participant(participant.new(
        "p1",
        "Person 1",
        participant.Member,
      ))
    3 ->
      base
      |> room.add_participant(participant.new(
        "p0",
        "Person 0",
        participant.Member,
      ))
      |> room.add_participant(participant.new(
        "p1",
        "Person 1",
        participant.Member,
      ))
      |> room.add_participant(participant.new(
        "p2",
        "Person 2",
        participant.Member,
      ))
    _ ->
      base
      |> room.add_participant(participant.new(
        "p0",
        "Person 0",
        participant.Member,
      ))
      |> room.add_participant(participant.new(
        "p1",
        "Person 1",
        participant.Member,
      ))
      |> room.add_participant(participant.new(
        "p2",
        "Person 2",
        participant.Member,
      ))
      |> room.add_participant(participant.new(
        "p3",
        "Person 3",
        participant.Member,
      ))
  }
}

fn make_message(
  summary s: String,
  kind k: message.MessageKind,
  body b: option.Option(String),
  persist_hint ph: message.PersistHint,
) -> message.Message {
  message.Message(
    message_id: id.new_message_id(),
    room_id: id.new_room_id(),
    thread_id: option.None,
    from: id.new_participant_id(),
    to: [],
    kind: k,
    created_at: birl.utc_now(),
    sequence: 42,
    requires_ack: False,
    persist_hint: ph,
    references: [],
    summary: s,
    body: b,
  )
}

// ---------------------------------------------------------------------------
// build_room_open_text
// ---------------------------------------------------------------------------

pub fn build_room_open_text_all_fields_test() {
  let r =
    make_room_with_all(
      "Test Room",
      option.Some("Coordination"),
      option.Some("ext/ref/123"),
      ["tag1", "tag2"],
      2,
    )
  let text = brain.build_room_open_text(r)
  string.contains(text, "Room ID: room_fixture") |> should.be_true
  string.contains(text, "Title: Test Room") |> should.be_true
  string.contains(text, "Purpose: Coordination") |> should.be_true
  string.contains(text, "External ref: ext/ref/123") |> should.be_true
  string.contains(text, "Participants: 2") |> should.be_true
  string.contains(text, "Tags: tag1, tag2") |> should.be_true
  string.contains(text, "Created at: ") |> should.be_true
}

pub fn build_room_open_text_no_optionals_test() {
  let r =
    make_room_with_all("No Optionals Room", option.None, option.None, [], 0)
  let text = brain.build_room_open_text(r)
  string.contains(text, "Purpose: none") |> should.be_true
  string.contains(text, "External ref: none") |> should.be_true
  string.contains(text, "Tags: none") |> should.be_true
  string.contains(text, "Participants: 0") |> should.be_true
}

pub fn build_room_open_text_with_tags_test() {
  let r =
    make_room_with_all(
      "Tagged Room",
      option.None,
      option.None,
      ["urgent", "backend", "epic-42"],
      1,
    )
  let text = brain.build_room_open_text(r)
  string.contains(text, "Tags: urgent, backend, epic-42") |> should.be_true
}

pub fn build_room_open_text_single_participant_test() {
  let r = make_room_with_all("Solo Room", option.None, option.None, [], 1)
  let text = brain.build_room_open_text(r)
  string.contains(text, "Participants: 1") |> should.be_true
}

pub fn build_room_open_text_no_external_ref_test() {
  let r =
    make_room_with_all(
      "No Ref Room",
      option.Some("Testing"),
      option.None,
      [],
      0,
    )
  let text = brain.build_room_open_text(r)
  string.contains(text, "External ref: none") |> should.be_true
  string.contains(text, "Purpose: Testing") |> should.be_true
}

// ---------------------------------------------------------------------------
// build_room_close_text
// ---------------------------------------------------------------------------

pub fn build_room_close_text_completed_test() {
  let r =
    room.new_with_metadata(
      "room_close",
      "Closing Room",
      option.Some("Test"),
      option.None,
      ["test"],
      [],
      option.None,
    )
    |> room.add_participant(participant.new("p1", "Alice", participant.Lead))
    |> room.close_with_resolution(room.Completed)
  let text = brain.build_room_close_text(r, 10, 5000)
  string.contains(text, "Room ID: room_close") |> should.be_true
  string.contains(text, "Title: Closing Room") |> should.be_true
  string.contains(text, "Resolution: completed") |> should.be_true
  string.contains(text, "Participants: 1") |> should.be_true
  string.contains(text, "Messages: 10") |> should.be_true
  string.contains(text, "Duration: 5000ms") |> should.be_true
  string.contains(text, "Purpose: Test") |> should.be_true
  string.contains(text, "Tags: test") |> should.be_true
}

pub fn build_room_close_text_cancelled_test() {
  let r =
    room.new("room_cancel", "Cancelled Room")
    |> room.add_participant(participant.new("p1", "Alice", participant.Lead))
    |> room.close_with_resolution(room.Cancelled)
  let text = brain.build_room_close_text(r, 3, 1000)
  string.contains(text, "Resolution: cancelled") |> should.be_true
}

pub fn build_room_close_text_superseded_test() {
  let r =
    room.new("room_super", "Superseded Room")
    |> room.close_with_resolution(room.Superseded)
  let text = brain.build_room_close_text(r, 0, 0)
  string.contains(text, "Resolution: superseded") |> should.be_true
}

pub fn build_room_close_text_failed_test() {
  let r =
    room.new("room_fail", "Failed Room")
    |> room.close_with_resolution(room.Failed)
  let text = brain.build_room_close_text(r, 1, 500)
  string.contains(text, "Resolution: failed") |> should.be_true
}

pub fn build_room_close_text_no_resolution_test() {
  let r =
    room.new("room_no_res", "No Resolution Room")
    |> room.close
  let text = brain.build_room_close_text(r, 5, 2500)
  string.contains(text, "Resolution: none") |> should.be_true
}

pub fn build_room_close_text_empty_tags_test() {
  let r =
    room.new_with_metadata(
      "room_no_tags",
      "No Tags Room",
      option.None,
      option.None,
      [],
      [],
      option.None,
    )
    |> room.close_with_resolution(room.Completed)
  let text = brain.build_room_close_text(r, 2, 1000)
  string.contains(text, "Tags: none") |> should.be_true
}

pub fn build_room_close_text_no_purpose_test() {
  let r =
    room.new_with_metadata(
      "room_no_purpose",
      "No Purpose Room",
      option.None,
      option.None,
      [],
      [],
      option.None,
    )
    |> room.close_with_resolution(room.Completed)
  let text = brain.build_room_close_text(r, 0, 0)
  string.contains(text, "Purpose: none") |> should.be_true
}

// ---------------------------------------------------------------------------
// build_message_text
// ---------------------------------------------------------------------------

pub fn build_message_text_with_body_test() {
  let msg =
    make_message(
      "Review completed",
      message.Summary,
      option.Some("All checks passed. Ready to merge."),
      message.Ephemeral,
    )
  let room_id_str = id.room_id_to_string(msg.room_id)
  let text = brain.build_message_text(room_id_str, "summary", msg)
  string.contains(
    text,
    "Message ID: " <> id.message_id_to_string(msg.message_id),
  )
  |> should.be_true
  string.contains(text, "Room: " <> room_id_str) |> should.be_true
  string.contains(text, "From: " <> id.participant_id_to_string(msg.from))
  |> should.be_true
  string.contains(text, "Kind: summary") |> should.be_true
  string.contains(text, "Sequence: 42") |> should.be_true
  string.contains(text, "Summary: Review completed") |> should.be_true
  string.contains(text, "Body: All checks passed. Ready to merge.")
  |> should.be_true
}

pub fn build_message_text_no_body_test() {
  let msg =
    make_message(
      "Decision made",
      message.Decision,
      option.None,
      message.Ephemeral,
    )
  let room_id_str = id.room_id_to_string(msg.room_id)
  let text = brain.build_message_text(room_id_str, "decision", msg)
  string.contains(text, "Body: none") |> should.be_true
  string.contains(text, "Kind: decision") |> should.be_true
  string.contains(text, "Summary: Decision made") |> should.be_true
}

pub fn build_message_text_all_kinds_test() {
  let kinds = [
    #("question", message.Question),
    #("answer", message.Answer),
    #("finding", message.Finding),
    #("handoff", message.Handoff),
    #("blocker", message.Blocker),
    #("decision", message.Decision),
    #("review_request", message.ReviewRequest),
    #("review_result", message.ReviewResult),
    #("artifact_ref", message.ArtifactRef),
    #("summary", message.Summary),
    #("challenge", message.Challenge),
    #("proposal", message.Proposal),
    #("escalation", message.Escalation),
  ]
  list.each(kinds, fn(kv) {
    let msg =
      make_message("Test " <> kv.0, kv.1, option.None, message.Ephemeral)
    let room_id_str = id.room_id_to_string(msg.room_id)
    let text = brain.build_message_text(room_id_str, kv.0, msg)
    string.contains(text, "Kind: " <> kv.0) |> should.be_true
    string.contains(text, "Summary: Test " <> kv.0) |> should.be_true
  })
}
