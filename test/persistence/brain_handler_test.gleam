import birl
import gleam/option
import gleeunit/should
import neural_link/domain/id
import neural_link/domain/message
import neural_link/domain/participant
import neural_link/domain/room
import neural_link/persistence/brain
import neural_link/persistence/plugin as plugin_mod
import neural_link/persistence/types as persistence_types
import persistence/brain_client_mock

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn make_room(title: String) -> room.Room {
  room.new("room_test", title)
  |> room.add_participant(participant.new("p1", "Alice", participant.Lead))
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
    sequence: 1,
    requires_ack: False,
    persist_hint: ph,
    references: [],
    summary: s,
    body: b,
  )
}

// ---------------------------------------------------------------------------
// on_room_open
// ---------------------------------------------------------------------------

pub fn on_room_open_happy_path_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let room = make_room("Test Room")
  let result = plugin_mod.notify(plugin, plugin_mod.RoomOpened(room))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.not_equal([])
  calls
  |> brain_client_mock.assert_save_snapshot(
    "Room opened: Test Room",
    "room-open",
  )
  |> should.be_true
}

pub fn on_room_open_error_returns_error_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let mock = brain_client_mock.new_mock_client(subject)
  let plugin = brain.brain_plugin_with_client("test-brain", mock)

  brain_client_mock.inject_error(subject, brain_client_mock.InjectTimeout)
  let room = make_room("Error Room")
  let result = plugin_mod.notify(plugin, plugin_mod.RoomOpened(room))

  result |> should.equal(Error(persistence_types.Timeout))
}

pub fn on_room_open_no_participants_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let room = room.new("room_test", "Solo Room")
  let result = plugin_mod.notify(plugin, plugin_mod.RoomOpened(room))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_save_snapshot(
    "Room opened: Solo Room",
    "room-open",
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// on_room_close
// ---------------------------------------------------------------------------

pub fn on_room_close_happy_path_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let room =
    make_room("Closing Room")
    |> room.close_with_resolution(room.Completed)
  let result = plugin_mod.notify(plugin, plugin_mod.RoomClosed(room, 10, 5000))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_save_snapshot(
    "Room closed: Closing Room",
    "room-close",
  )
  |> should.be_true
}

pub fn on_room_close_cancelled_resolution_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let room =
    make_room("Cancelled Room")
    |> room.close_with_resolution(room.Cancelled)
  let result = plugin_mod.notify(plugin, plugin_mod.RoomClosed(room, 3, 1000))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_save_snapshot(
    "Room closed: Cancelled Room",
    "room-close",
  )
  |> should.be_true
}

pub fn on_room_close_returns_error_on_timeout_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  brain_client_mock.inject_error(subject, brain_client_mock.InjectTimeout)
  let room =
    make_room("Error Room")
    |> room.close_with_resolution(room.Completed)
  let result = plugin_mod.notify(plugin, plugin_mod.RoomClosed(room, 5, 2000))

  result |> should.equal(Error(persistence_types.Timeout))
}

// ---------------------------------------------------------------------------
// on_conversation_artifact
// ---------------------------------------------------------------------------

pub fn on_conversation_artifact_happy_path_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let room = make_room("Conv Room")
  let result =
    plugin_mod.notify(
      plugin,
      plugin_mod.ConversationArtifact(room, "Full conversation text...", ""),
    )

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_create_artifact(
    "Conversation: Conv Room",
    "conversation",
  )
  |> should.be_true
}

pub fn on_conversation_artifact_returns_error_on_parse_failure_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  brain_client_mock.inject_error(
    subject,
    brain_client_mock.InjectParseError("invalid json"),
  )
  let room = make_room("Error Room")
  let result =
    plugin_mod.notify(
      plugin,
      plugin_mod.ConversationArtifact(room, "some content", ""),
    )

  result
  |> should.equal(
    Error(persistence_types.AdapterError("brain", "parse_error: invalid json")),
  )
}

// ---------------------------------------------------------------------------
// on_message — durability gate
// ---------------------------------------------------------------------------

pub fn on_message_durable_kind_replicates_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message(
      "Decision made",
      message.Decision,
      option.None,
      message.Ephemeral,
    )
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.not_equal([])
  calls
  |> brain_client_mock.assert_save_snapshot(
    "[decision] Decision made",
    "decision",
  )
  |> should.be_true
}

pub fn on_message_non_durable_skipped_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message(
      "Just a question",
      message.Question,
      option.None,
      message.Ephemeral,
    )
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.equal([])
}

pub fn on_message_persist_hint_durable_forces_replication_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message(
      "Ephemeral but forced",
      message.Question,
      option.None,
      message.Durable,
    )
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.not_equal([])
  calls
  |> brain_client_mock.assert_save_snapshot(
    "[question] Ephemeral but forced",
    "message",
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// on_message — kind to tag mapping
// ---------------------------------------------------------------------------

pub fn on_message_summary_creates_artifact_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message(
      "Weekly summary",
      message.Summary,
      option.Some("Summary content"),
      message.Ephemeral,
    )
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_create_artifact(
    "[summary] Weekly summary",
    "summary",
  )
  |> should.be_true
}

pub fn on_message_handoff_maps_to_handoff_tag_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message("Taking over", message.Handoff, option.None, message.Ephemeral)
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_save_snapshot("[handoff] Taking over", "handoff")
  |> should.be_true
}

pub fn on_message_blocker_maps_to_blocker_tag_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message("Need input", message.Blocker, option.None, message.Ephemeral)
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_save_snapshot("[blocker] Need input", "blocker")
  |> should.be_true
}

pub fn on_message_review_result_maps_to_review_result_tag_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message("LGTM", message.ReviewResult, option.None, message.Ephemeral)
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls
  |> brain_client_mock.assert_save_snapshot(
    "[review_result] LGTM",
    "review-result",
  )
  |> should.be_true
}

pub fn on_message_challenge_is_durable_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message(
      "Challenging this",
      message.Challenge,
      option.None,
      message.Ephemeral,
    )
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.not_equal([])
}

pub fn on_message_proposal_is_durable_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message(
      "Proposal text",
      message.Proposal,
      option.None,
      message.Ephemeral,
    )
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.not_equal([])
}

pub fn on_message_escalation_is_durable_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message(
      "Escalating",
      message.Escalation,
      option.None,
      message.Ephemeral,
    )
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.not_equal([])
}

pub fn on_message_finding_not_durable_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  let msg =
    make_message("Found a bug", message.Finding, option.None, message.Ephemeral)
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Ok(Nil))
  let calls = brain_client_mock.get_calls(subject)
  calls |> should.equal([])
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

pub fn on_message_timeout_error_returns_timeout_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  brain_client_mock.inject_error(subject, brain_client_mock.InjectTimeout)
  let msg =
    make_message("Timed out", message.Decision, option.None, message.Ephemeral)
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result |> should.equal(Error(persistence_types.Timeout))
}

pub fn on_message_command_failed_error_returns_adapter_error_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  brain_client_mock.inject_error(
    subject,
    brain_client_mock.InjectCommandFailed("brain not found"),
  )
  let msg =
    make_message("Failed cmd", message.Decision, option.None, message.Ephemeral)
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result
  |> should.equal(
    Error(persistence_types.AdapterError(
      "brain",
      "command_failed: brain not found",
    )),
  )
}

pub fn on_message_parse_error_returns_adapter_error_test() {
  let assert Ok(started) = brain_client_mock.start_mock_actor()
  let subject = brain_client_mock.mock_actor_subject(started)
  let plugin =
    brain.brain_plugin_with_client(
      "test-brain",
      brain_client_mock.new_mock_client(subject),
    )

  brain_client_mock.inject_error(
    subject,
    brain_client_mock.InjectParseError("invalid json"),
  )
  let msg =
    make_message("Bad parse", message.Decision, option.None, message.Ephemeral)
  let result = plugin_mod.notify(plugin, plugin_mod.Message(msg))

  result
  |> should.equal(
    Error(persistence_types.AdapterError("brain", "parse_error: invalid json")),
  )
}
