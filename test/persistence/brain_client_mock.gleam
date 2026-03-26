import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import neural_link/brain/types.{
  type BrainConfig, CommandFailed, ParseError, Timeout,
}
import neural_link/persistence/brain.{type BrainClient, BrainClient}

// ---------------------------------------------------------------------------
// Mock call types
// ---------------------------------------------------------------------------

pub type MockCall {
  SaveSnapshotCall(
    config: BrainConfig,
    title: String,
    content: String,
    tags: List(String),
  )
  CreateArtifactCall(
    config: BrainConfig,
    title: String,
    content: String,
    kind: String,
    tags: List(String),
  )
}

pub type MockErrorInjection {
  NoError
  InjectTimeout
  InjectCommandFailed(output: String)
  InjectParseError(detail: String)
}

// ---------------------------------------------------------------------------
// Mock actor state and messages
// ---------------------------------------------------------------------------

type MockState {
  MockState(calls: List(MockCall), error: MockErrorInjection)
}

pub type MockMessage {
  AppendCall(call: MockCall)
  GetCalls(reply_with: process.Subject(List(MockCall)))
  GetError(reply_with: process.Subject(MockErrorInjection))
  InjectError(err: MockErrorInjection, reply_with: process.Subject(Nil))
  Reset(reply_with: process.Subject(Nil))
}

fn handle_mock_message(
  state: MockState,
  msg: MockMessage,
) -> actor.Next(MockState, MockMessage) {
  case msg {
    AppendCall(call) -> {
      actor.continue(MockState(calls: [call, ..state.calls], error: state.error))
    }
    GetCalls(reply) -> {
      process.send(reply, state.calls)
      actor.continue(state)
    }
    GetError(reply) -> {
      process.send(reply, state.error)
      actor.continue(state)
    }
    InjectError(err, reply) -> {
      process.send(reply, Nil)
      actor.continue(MockState(calls: state.calls, error: err))
    }
    Reset(reply) -> {
      process.send(reply, Nil)
      actor.continue(MockState(calls: [], error: NoError))
    }
  }
}

// ---------------------------------------------------------------------------
// Mock actor lifecycle
// ---------------------------------------------------------------------------

pub fn start_mock_actor() -> Result(
  actor.Started(process.Subject(MockMessage)),
  actor.StartError,
) {
  actor.new(MockState(calls: [], error: NoError))
  |> actor.on_message(handle_mock_message)
  |> actor.start
}

pub fn mock_actor_subject(
  started: actor.Started(process.Subject(MockMessage)),
) -> process.Subject(MockMessage) {
  started.data
}

// ---------------------------------------------------------------------------
// Mock client
// ---------------------------------------------------------------------------

pub fn new_mock_client(subject: process.Subject(MockMessage)) -> BrainClient {
  BrainClient(
    save_snapshot: fn(cfg, title, content, tags) {
      let call = SaveSnapshotCall(cfg, title, content, tags)
      process.send(subject, AppendCall(call))
      case get_error(subject) {
        NoError -> Ok("mock-record-id")
        InjectTimeout -> Error(Timeout)
        InjectCommandFailed(output) -> Error(CommandFailed(output))
        InjectParseError(detail) -> Error(ParseError(detail))
      }
    },
    create_artifact: fn(cfg, title, content, kind, tags) {
      let call = CreateArtifactCall(cfg, title, content, kind, tags)
      process.send(subject, AppendCall(call))
      case get_error(subject) {
        NoError -> Ok("mock-record-id")
        InjectTimeout -> Error(Timeout)
        InjectCommandFailed(output) -> Error(CommandFailed(output))
        InjectParseError(detail) -> Error(ParseError(detail))
      }
    },
  )
}

fn get_error(subject: process.Subject(MockMessage)) -> MockErrorInjection {
  let reply = process.new_subject()
  process.send(subject, GetError(reply))
  let assert Ok(err) = process.receive(reply, within: 10)
  err
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

pub fn get_calls(subject: process.Subject(MockMessage)) -> List(MockCall) {
  let reply = process.new_subject()
  process.send(subject, GetCalls(reply))
  let assert Ok(calls) = process.receive(reply, within: 10)
  calls
}

pub fn inject_error(
  subject: process.Subject(MockMessage),
  err: MockErrorInjection,
) -> Nil {
  let reply = process.new_subject()
  process.send(subject, InjectError(err, reply))
  let assert Ok(Nil) = process.receive(reply, within: 10)
  Nil
}

pub fn reset_mock(subject: process.Subject(MockMessage)) -> Nil {
  let reply = process.new_subject()
  process.send(subject, Reset(reply))
  let assert Ok(Nil) = process.receive(reply, within: 10)
  Nil
}

pub fn last_call(subject: process.Subject(MockMessage)) -> MockCall {
  case get_calls(subject) {
    [] -> panic as "no calls recorded"
    [c, ..] -> c
  }
}

pub fn assert_save_snapshot(
  calls: List(MockCall),
  title: String,
  tag: String,
) -> Bool {
  list.any(calls, fn(c) {
    case c {
      SaveSnapshotCall(_, t, _, tags) -> t == title && list.contains(tags, tag)
      _ -> False
    }
  })
}

pub fn assert_create_artifact(
  calls: List(MockCall),
  title: String,
  kind: String,
) -> Bool {
  list.any(calls, fn(c) {
    case c {
      CreateArtifactCall(_, t, _, k, _) -> t == title && k == kind
      _ -> False
    }
  })
}
