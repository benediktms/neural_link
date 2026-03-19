import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import neural_link/domain/id.{
  type ParticipantId, type WaitId, new_wait_id, participant_id_to_string,
  wait_id_to_string,
}
import neural_link/domain/message.{type Message}
import neural_link/domain/wait.{type WaitFilter, matches_filter}

// ---------------------------------------------------------------------------
// Internal state types
// ---------------------------------------------------------------------------

type PendingInboxWait {
  PendingInboxWait(
    wait_id: WaitId,
    filter: WaitFilter,
    reply: Subject(Result(Message, String)),
  )
}

type InboxState {
  InboxState(waits: Dict(String, List(PendingInboxWait)))
}

// ---------------------------------------------------------------------------
// Public message type
// ---------------------------------------------------------------------------

pub type InboxMessage {
  RegisterWait(
    participant_id: ParticipantId,
    filter: WaitFilter,
    reply: Subject(Result(Message, String)),
  )
  NotifyMessage(message: Message)
  CancelWait(participant_id: ParticipantId, wait_id: WaitId)
  Shutdown
}

// ---------------------------------------------------------------------------
// Actor lifecycle
// ---------------------------------------------------------------------------

pub fn start() -> actor.StartResult(Subject(InboxMessage)) {
  actor.new(InboxState(waits: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
}

// ---------------------------------------------------------------------------
// Message handlers
// ---------------------------------------------------------------------------

fn handle_message(
  state: InboxState,
  msg: InboxMessage,
) -> actor.Next(InboxState, InboxMessage) {
  case msg {
    RegisterWait(participant_id, filter, reply) -> {
      let key = participant_id_to_string(participant_id)
      let wait_id = new_wait_id()
      let pending =
        PendingInboxWait(wait_id: wait_id, filter: filter, reply: reply)
      let existing = case dict.get(state.waits, key) {
        Ok(ws) -> ws
        Error(_) -> []
      }
      let updated = [pending, ..existing]
      let new_waits = dict.insert(state.waits, key, updated)
      actor.continue(InboxState(waits: new_waits))
    }

    NotifyMessage(message) -> {
      let new_waits =
        dict.fold(state.waits, dict.new(), fn(acc, pid_str, pending_list) {
          let in_audience = case message.to {
            [] -> True
            recipients ->
              list.any(recipients, fn(r) {
                participant_id_to_string(r) == pid_str
              })
          }
          let #(matched, kept) =
            list.partition(pending_list, fn(pw) {
              in_audience
              && matches_filter(pw.filter, message.kind, message.from)
            })
          list.each(matched, fn(pw) { actor.send(pw.reply, Ok(message)) })
          case kept {
            [] -> acc
            _ -> dict.insert(acc, pid_str, kept)
          }
        })
      actor.continue(InboxState(waits: new_waits))
    }

    CancelWait(participant_id, wait_id) -> {
      let key = participant_id_to_string(participant_id)
      let wid_str = wait_id_to_string(wait_id)
      let new_waits = case dict.get(state.waits, key) {
        Error(_) -> state.waits
        Ok(pending_list) -> {
          let #(cancelled, kept) =
            list.partition(pending_list, fn(pw) {
              wait_id_to_string(pw.wait_id) == wid_str
            })
          list.each(cancelled, fn(pw) {
            actor.send(pw.reply, Error("Wait cancelled"))
          })
          case kept {
            [] -> dict.delete(state.waits, key)
            _ -> dict.insert(state.waits, key, kept)
          }
        }
      }
      actor.continue(InboxState(waits: new_waits))
    }

    Shutdown -> actor.stop()
  }
}

// ---------------------------------------------------------------------------
// Public helper functions
// ---------------------------------------------------------------------------

pub fn register_wait(
  inbox: Subject(InboxMessage),
  participant_id: ParticipantId,
  filter: WaitFilter,
) -> Result(Message, String) {
  actor.call(inbox, 30_000, fn(reply) {
    RegisterWait(participant_id, filter, reply)
  })
}

pub fn notify_message(inbox: Subject(InboxMessage), message: Message) -> Nil {
  actor.send(inbox, NotifyMessage(message))
}

pub fn cancel_wait(
  inbox: Subject(InboxMessage),
  participant_id: ParticipantId,
  wait_id: WaitId,
) -> Nil {
  actor.send(inbox, CancelWait(participant_id, wait_id))
}
