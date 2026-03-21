import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import neural_link/domain/id.{
  type ParticipantId, type RoomId, type WaitId, new_wait_id,
  participant_id_to_string, wait_id_to_string,
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
    since_sequence: Int,
    reply: Subject(Result(Message, String)),
    lead_eligible: Bool,
    lead_id: Option(ParticipantId),
    room_id: Option(RoomId),
  )
}

type InboxState {
  InboxState(
    waits: Dict(String, List(PendingInboxWait)),
    self_subject: Subject(InboxMessage),
  )
}

// ---------------------------------------------------------------------------
// Public message type
// ---------------------------------------------------------------------------

/// Result of ParticipantDeparted — reports which waits became lead-eligible
pub type DepartureResult {
  DepartureResult(escalated_waiter_ids: List(String))
}

pub type InboxMessage {
  RegisterWait(
    participant_id: ParticipantId,
    filter: WaitFilter,
    since_sequence: Int,
    timeout_ms: Int,
    room_id: Option(RoomId),
    reply: Subject(Result(Message, String)),
  )
  NotifyMessage(message: Message)
  ParticipantDeparted(
    room_id: RoomId,
    departed_id: ParticipantId,
    lead_id: ParticipantId,
    active_participant_ids: List(ParticipantId),
    reply: Subject(DepartureResult),
  )
  CancelWait(participant_id: ParticipantId, wait_id: WaitId)
  TimeoutWait(participant_id: ParticipantId, wait_id: WaitId)
  SetSelf(subject: Subject(InboxMessage))
  Shutdown
}

// ---------------------------------------------------------------------------
// Actor lifecycle
// ---------------------------------------------------------------------------

pub fn start() -> actor.StartResult(Subject(InboxMessage)) {
  let result =
    actor.new(InboxState(waits: dict.new(), self_subject: process.new_subject()))
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> {
      actor.send(started.data, SetSelf(started.data))
      Ok(started)
    }
    Error(e) -> Error(e)
  }
}

// ---------------------------------------------------------------------------
// Message handlers
// ---------------------------------------------------------------------------

fn handle_message(
  state: InboxState,
  msg: InboxMessage,
) -> actor.Next(InboxState, InboxMessage) {
  case msg {
    RegisterWait(
      participant_id,
      filter,
      since_sequence,
      timeout_ms,
      room_id,
      reply,
    ) -> {
      let key = participant_id_to_string(participant_id)
      let wait_id = new_wait_id()
      let pending =
        PendingInboxWait(
          wait_id: wait_id,
          filter: filter,
          since_sequence: since_sequence,
          reply: reply,
          lead_eligible: False,
          lead_id: None,
          room_id: room_id,
        )
      let existing = case dict.get(state.waits, key) {
        Ok(ws) -> ws
        Error(_) -> []
      }
      let updated = [pending, ..existing]
      let new_waits = dict.insert(state.waits, key, updated)
      // Schedule timeout
      process.send_after(
        state.self_subject,
        timeout_ms,
        TimeoutWait(participant_id, wait_id),
      )
      actor.continue(InboxState(..state, waits: new_waits))
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
              let filter_matches =
                matches_filter(pw.filter, message.kind, message.from)
              // Lead override: lead stands in for the *sender*, not the kind.
              // The kind filter must still match.
              let kind_matches = case pw.filter.kinds {
                [] -> True
                kinds -> list.contains(kinds, message.kind)
              }
              let lead_override =
                pw.lead_eligible
                && pw.lead_id == Some(message.from)
                && kind_matches
              in_audience
              && message.sequence > pw.since_sequence
              && { filter_matches || lead_override }
            })
          list.each(matched, fn(pw) { actor.send(pw.reply, Ok(message)) })
          case kept {
            [] -> acc
            _ -> dict.insert(acc, pid_str, kept)
          }
        })
      actor.continue(InboxState(..state, waits: new_waits))
    }

    ParticipantDeparted(
      room_id,
      departed_id,
      lead_id,
      active_participant_ids,
      reply,
    ) -> {
      let departed_str = participant_id_to_string(departed_id)
      let room_id_str = id.room_id_to_string(room_id)
      let active_strs =
        list.map(active_participant_ids, participant_id_to_string)
      let #(new_waits, escalated_ids) =
        dict.fold(
          state.waits,
          #(dict.new(), []),
          fn(acc, pid_str, pending_list) {
            let #(waits_acc, esc_acc) = acc
            let #(updated_list, newly_escalated) =
              list.fold(pending_list, #([], False), fn(inner_acc, pw) {
                let #(kept, was_escalated) = inner_acc
                case pid_str == departed_str {
                  True -> {
                    actor.send(pw.reply, Error("Participant departed"))
                    #(kept, was_escalated)
                  }
                  False -> {
                    let same_room = case pw.room_id {
                      Some(rid) -> id.room_id_to_string(rid) == room_id_str
                      None -> False
                    }
                    case same_room && !list.is_empty(pw.filter.from) {
                      False -> #([pw, ..kept], was_escalated)
                      True -> {
                        let all_from_departed =
                          list.all(pw.filter.from, fn(from_pid) {
                            let from_str = participant_id_to_string(from_pid)
                            !list.contains(active_strs, from_str)
                          })
                        case all_from_departed {
                          True -> #(
                            [
                              PendingInboxWait(
                                ..pw,
                                lead_eligible: True,
                                lead_id: Some(lead_id),
                              ),
                              ..kept
                            ],
                            True,
                          )
                          False -> #([pw, ..kept], was_escalated)
                        }
                      }
                    }
                  }
                }
              })
            let new_esc = case newly_escalated {
              True -> [pid_str, ..esc_acc]
              False -> esc_acc
            }
            case updated_list {
              [] -> #(waits_acc, new_esc)
              _ -> #(dict.insert(waits_acc, pid_str, updated_list), new_esc)
            }
          },
        )
      actor.send(reply, DepartureResult(escalated_waiter_ids: escalated_ids))
      actor.continue(InboxState(..state, waits: new_waits))
    }

    CancelWait(participant_id, wait_id) -> {
      let new_waits =
        remove_wait(state.waits, participant_id, wait_id, fn(pw) {
          actor.send(pw.reply, Error("Wait cancelled"))
        })
      actor.continue(InboxState(..state, waits: new_waits))
    }

    TimeoutWait(participant_id, wait_id) -> {
      let wid_str = wait_id_to_string(wait_id)
      let key = participant_id_to_string(participant_id)
      // Only fire timeout if the wait is still pending
      case dict.get(state.waits, key) {
        Error(_) -> actor.continue(state)
        Ok(pending_list) -> {
          let still_pending =
            list.any(pending_list, fn(pw) {
              wait_id_to_string(pw.wait_id) == wid_str
            })
          case still_pending {
            False -> actor.continue(state)
            True -> {
              let new_waits =
                remove_wait(state.waits, participant_id, wait_id, fn(pw) {
                  actor.send(
                    pw.reply,
                    Error(
                      "Wait timed out after " <> int.to_string(30_000) <> "ms",
                    ),
                  )
                })
              actor.continue(InboxState(..state, waits: new_waits))
            }
          }
        }
      }
    }

    SetSelf(subject) -> {
      actor.continue(InboxState(..state, self_subject: subject))
    }

    Shutdown -> actor.stop()
  }
}

fn remove_wait(
  waits: Dict(String, List(PendingInboxWait)),
  participant_id: ParticipantId,
  wait_id: WaitId,
  on_removed: fn(PendingInboxWait) -> Nil,
) -> Dict(String, List(PendingInboxWait)) {
  let key = participant_id_to_string(participant_id)
  let wid_str = wait_id_to_string(wait_id)
  case dict.get(waits, key) {
    Error(_) -> waits
    Ok(pending_list) -> {
      let #(removed, kept) =
        list.partition(pending_list, fn(pw) {
          wait_id_to_string(pw.wait_id) == wid_str
        })
      list.each(removed, on_removed)
      case kept {
        [] -> dict.delete(waits, key)
        _ -> dict.insert(waits, key, kept)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Public helper functions
// ---------------------------------------------------------------------------

pub fn register_wait(
  inbox: Subject(InboxMessage),
  participant_id: ParticipantId,
  filter: WaitFilter,
  since_sequence: Int,
  timeout_ms: Int,
  room_id: Option(RoomId),
) -> Result(Message, String) {
  let call_timeout = timeout_ms + 5000
  actor.call(inbox, call_timeout, fn(reply) {
    RegisterWait(
      participant_id,
      filter,
      since_sequence,
      timeout_ms,
      room_id,
      reply,
    )
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

pub fn participant_departed(
  inbox: Subject(InboxMessage),
  room_id: RoomId,
  departed_id: ParticipantId,
  lead_id: ParticipantId,
  active_participant_ids: List(ParticipantId),
) -> DepartureResult {
  actor.call(inbox, 5000, fn(reply) {
    ParticipantDeparted(
      room_id,
      departed_id,
      lead_id,
      active_participant_ids,
      reply,
    )
  })
}
