import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import neural_link/domain/id.{
  type MessageId, type ParticipantId, type ThreadId, message_id_to_string,
  participant_id_to_string,
}
import neural_link/domain/message.{
  type Message, type MessageKind, type Receipt, type Reference,
}
import neural_link/domain/participant.{type Participant}
import neural_link/domain/room.{type Room, type RoomResolution}

// ---------------------------------------------------------------------------
// Leave result type
// ---------------------------------------------------------------------------

pub type LeaveResult {
  Departed
  DrainStarted(pending_message_ids: List(String))
}

// ---------------------------------------------------------------------------
// Internal state types
// ---------------------------------------------------------------------------

type RoomState {
  RoomState(
    room: Room,
    messages: List(Message),
    receipts: Dict(String, List(Receipt)),
    sequence: Int,
    max_messages: Int,
    message_count: Int,
    /// Incremental pending count per participant — O(1) inbox count lookups
    pending_counts: Dict(String, Int),
    /// Drain callbacks: participant_id_str -> Subject(Nil) to fire on drain completion
    drain_callbacks: Dict(String, Subject(Nil)),
  )
}

// ---------------------------------------------------------------------------
// Public message protocol
// ---------------------------------------------------------------------------

pub type RoomMessage {
  // Participant management
  Join(participant: Participant, reply: Subject(Result(Nil, String)))

  // Message sending
  SendMsg(
    from: ParticipantId,
    to: List(ParticipantId),
    kind: MessageKind,
    summary: String,
    body: Option(String),
    thread_id: Option(ThreadId),
    references: List(Reference),
    reply: Subject(Result(Message, String)),
  )

  // Inbox operations
  ReadInbox(participant_id: ParticipantId, reply: Subject(List(Message)))
  AckMessages(
    participant_id: ParticipantId,
    message_ids: List(MessageId),
    reply: Subject(Result(Nil, String)),
  )

  // Query
  GetMessages(thread_id: Option(ThreadId), reply: Subject(List(Message)))
  CountInbox(participant_id: ParticipantId, reply: Subject(Int))

  // Lifecycle
  Leave(
    participant_id: ParticipantId,
    drain_reply: Subject(Nil),
    reply: Subject(Result(LeaveResult, String)),
  )
  ForceDeparture(
    participant_id: ParticipantId,
    reply: Subject(Result(Nil, String)),
  )
  CloseRoom(resolution: RoomResolution, reply: Subject(Result(Nil, String)))
  GetState(reply: Subject(Room))
  Shutdown
}

// ---------------------------------------------------------------------------
// Actor entry point
// ---------------------------------------------------------------------------

pub fn start(room_data: Room) -> actor.StartResult(Subject(RoomMessage)) {
  let state =
    RoomState(
      room: room_data,
      messages: [],
      receipts: dict.new(),
      sequence: 0,
      max_messages: 1000,
      message_count: 0,
      pending_counts: dict.new(),
      drain_callbacks: dict.new(),
    )
  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.start
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: RoomState,
  msg: RoomMessage,
) -> actor.Next(RoomState, RoomMessage) {
  case msg {
    // -----------------------------------------------------------------------
    Join(participant, reply) -> {
      case room.is_closed(state.room) {
        True -> {
          actor.send(reply, Error("Room is closed"))
          actor.continue(state)
        }
        False -> {
          // Idempotent: check if participant already exists
          let already_joined =
            list.any(state.room.participants, fn(p) {
              participant_id_to_string(p.id)
              == participant_id_to_string(participant.id)
            })
          case already_joined {
            True -> {
              actor.send(reply, Ok(Nil))
              actor.continue(state)
            }
            False -> {
              let updated_room = room.add_participant(state.room, participant)
              let activated_room = case updated_room.status {
                room.Open -> room.activate(updated_room)
                _ -> updated_room
              }
              actor.send(reply, Ok(Nil))
              actor.continue(RoomState(..state, room: activated_room))
            }
          }
        }
      }
    }

    // -----------------------------------------------------------------------
    SendMsg(from, to, kind, summary, body, thread_id, references, reply) -> {
      case room.is_closed(state.room) {
        True -> {
          actor.send(reply, Error("Room is closed"))
          actor.continue(state)
        }
        False -> {
          let new_seq = state.sequence + 1
          let base_msg =
            message.new_message(state.room.id, from, to, kind, summary)
          let msg =
            message.Message(
              ..base_msg,
              sequence: new_seq,
              body: body,
              thread_id: thread_id,
              references: references,
            )

          // Determine audience participant IDs
          // Broadcast: only Active participants (exclude sender, Draining, Departed)
          // Directed: exclude Departed participants from receipt creation
          let audience = case to {
            [] ->
              list.filter_map(state.room.participants, fn(p) {
                let is_sender =
                  participant_id_to_string(p.id)
                  == participant_id_to_string(from)
                case is_sender || !participant.is_active(p) {
                  True -> Error(Nil)
                  False -> Ok(p.id)
                }
              })
            ids ->
              list.filter(ids, fn(pid) {
                let pid_str = participant_id_to_string(pid)
                case
                  list.find(state.room.participants, fn(p) {
                    participant_id_to_string(p.id) == pid_str
                  })
                {
                  Ok(p) -> !participant.is_departed(p)
                  Error(_) -> False
                }
              })
          }

          // Create receipts for audience
          let new_receipts = message.expand_receipts(msg, audience)
          let msg_key = message_id_to_string(msg.message_id)
          let updated_receipts =
            dict.insert(state.receipts, msg_key, new_receipts)

          // Increment pending counts for audience
          let updated_pending =
            list.fold(audience, state.pending_counts, fn(acc, pid) {
              let key = participant_id_to_string(pid)
              let current = case dict.get(acc, key) {
                Ok(n) -> n
                Error(_) -> 0
              }
              dict.insert(acc, key, current + 1)
            })

          // Store message (prepend), enforce max
          let new_count = state.message_count + 1
          let updated_messages = [msg, ..state.messages]
          let bounded_messages = case new_count > state.max_messages {
            True -> list.take(updated_messages, state.max_messages)
            False -> updated_messages
          }
          let bounded_count = case new_count > state.max_messages {
            True -> state.max_messages
            False -> new_count
          }

          actor.send(reply, Ok(msg))
          actor.continue(
            RoomState(
              ..state,
              messages: bounded_messages,
              receipts: updated_receipts,
              sequence: new_seq,
              message_count: bounded_count,
              pending_counts: updated_pending,
            ),
          )
        }
      }
    }

    // -----------------------------------------------------------------------
    ReadInbox(participant_id, reply) -> {
      let pid_str = participant_id_to_string(participant_id)
      // Collect messages where participant has a pending (unacked) receipt
      let inbox =
        list.filter(state.messages, fn(msg) {
          let msg_key = message_id_to_string(msg.message_id)
          case dict.get(state.receipts, msg_key) {
            Error(_) -> False
            Ok(receipt_list) ->
              list.any(receipt_list, fn(r) {
                participant_id_to_string(r.participant_id) == pid_str
                && r.status == message.Pending
              })
          }
        })
      actor.send(reply, inbox)
      actor.continue(state)
    }

    // -----------------------------------------------------------------------
    AckMessages(participant_id, message_ids, reply) -> {
      let pid_str = participant_id_to_string(participant_id)
      let #(updated_receipts, ack_count) =
        list.fold(message_ids, #(state.receipts, 0), fn(acc, mid) {
          let #(receipts, count) = acc
          let msg_key = message_id_to_string(mid)
          case dict.get(receipts, msg_key) {
            Error(_) -> acc
            Ok(receipt_list) -> {
              // Count how many pending receipts we're acking for this participant
              let was_pending =
                list.any(receipt_list, fn(r) {
                  participant_id_to_string(r.participant_id) == pid_str
                  && r.status == message.Pending
                })
              let updated_list =
                list.map(receipt_list, fn(r) {
                  case participant_id_to_string(r.participant_id) == pid_str {
                    True -> message.ack_receipt(r)
                    False -> r
                  }
                })
              let new_count = case was_pending {
                True -> count + 1
                False -> count
              }
              #(dict.insert(receipts, msg_key, updated_list), new_count)
            }
          }
        })
      // Decrement pending count
      let updated_pending = case dict.get(state.pending_counts, pid_str) {
        Error(_) -> state.pending_counts
        Ok(current) -> {
          let new_val = case current - ack_count > 0 {
            True -> current - ack_count
            False -> 0
          }
          dict.insert(state.pending_counts, pid_str, new_val)
        }
      }
      // Check drain completion for any draining participants
      let #(completed_drains, remaining_callbacks) =
        dict.fold(
          state.drain_callbacks,
          #([], dict.new()),
          fn(acc, drain_pid_str, callback) {
            let #(completed, remaining) = acc
            let obligations =
              check_outbound_obligations_with_receipts(
                updated_receipts,
                state.messages,
                drain_pid_str,
              )
            case obligations {
              [] -> #([#(drain_pid_str, callback), ..completed], remaining)
              _ -> #(completed, dict.insert(remaining, drain_pid_str, callback))
            }
          },
        )
      // Fire callbacks and depart completed participants
      let updated_room =
        list.fold(completed_drains, state.room, fn(rm, entry) {
          let #(drain_pid_str, callback) = entry
          actor.send(callback, Nil)
          room.depart_participant(rm, id.ParticipantId(drain_pid_str))
        })
      actor.send(reply, Ok(Nil))
      actor.continue(
        RoomState(
          ..state,
          room: updated_room,
          receipts: updated_receipts,
          pending_counts: updated_pending,
          drain_callbacks: remaining_callbacks,
        ),
      )
    }

    // -----------------------------------------------------------------------
    CountInbox(participant_id, reply) -> {
      let pid_str = participant_id_to_string(participant_id)
      let count = case dict.get(state.pending_counts, pid_str) {
        Ok(n) -> n
        Error(_) -> 0
      }
      actor.send(reply, count)
      actor.continue(state)
    }

    // -----------------------------------------------------------------------
    GetMessages(thread_id, reply) -> {
      let filtered = case thread_id {
        None -> state.messages
        Some(tid) ->
          list.filter(state.messages, fn(msg) {
            case msg.thread_id {
              None -> False
              Some(msg_tid) -> msg_tid == tid
            }
          })
      }
      actor.send(reply, filtered)
      actor.continue(state)
    }

    // -----------------------------------------------------------------------
    Leave(participant_id, drain_reply, reply) -> {
      let pid_str = participant_id_to_string(participant_id)
      case room.is_closed(state.room) {
        True -> {
          actor.send(reply, Error("Room is closed"))
          actor.continue(state)
        }
        False -> {
          // Check if already departed (idempotent)
          let already_departed =
            list.any(state.room.participants, fn(p) {
              participant_id_to_string(p.id) == pid_str
              && participant.is_departed(p)
            })
          case already_departed {
            True -> {
              actor.send(drain_reply, Nil)
              actor.send(reply, Ok(Departed))
              actor.continue(state)
            }
            False -> {
              // Reject if participant is the Lead
              case room.is_lead(state.room, participant_id) {
                True -> {
                  actor.send(reply, Error("Lead cannot leave; use room_close"))
                  actor.continue(state)
                }
                False -> {
                  let obligations = check_outbound_obligations(state, pid_str)
                  case obligations {
                    [] -> {
                      let updated_room =
                        room.depart_participant(state.room, participant_id)
                      actor.send(drain_reply, Nil)
                      actor.send(reply, Ok(Departed))
                      actor.continue(RoomState(..state, room: updated_room))
                    }
                    pending_ids -> {
                      let updated_room =
                        room.set_participant_draining(
                          state.room,
                          participant_id,
                        )
                      let updated_callbacks =
                        dict.insert(state.drain_callbacks, pid_str, drain_reply)
                      actor.send(reply, Ok(DrainStarted(pending_ids)))
                      actor.continue(
                        RoomState(
                          ..state,
                          room: updated_room,
                          drain_callbacks: updated_callbacks,
                        ),
                      )
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // -----------------------------------------------------------------------
    ForceDeparture(participant_id, reply) -> {
      let pid_str = participant_id_to_string(participant_id)
      let updated_room = room.depart_participant(state.room, participant_id)
      // Fire and remove any stored drain callback
      case dict.get(state.drain_callbacks, pid_str) {
        Ok(callback) -> actor.send(callback, Nil)
        Error(_) -> Nil
      }
      let updated_callbacks = dict.delete(state.drain_callbacks, pid_str)
      actor.send(reply, Ok(Nil))
      actor.continue(
        RoomState(
          ..state,
          room: updated_room,
          drain_callbacks: updated_callbacks,
        ),
      )
    }

    // -----------------------------------------------------------------------
    CloseRoom(resolution, reply) -> {
      case room.is_closed(state.room) {
        True -> {
          actor.send(reply, Error("Room is already closed"))
          actor.continue(state)
        }
        False -> {
          let closed_room = room.close_with_resolution(state.room, resolution)
          actor.send(reply, Ok(Nil))
          actor.continue(RoomState(..state, room: closed_room))
        }
      }
    }

    // -----------------------------------------------------------------------
    GetState(reply) -> {
      actor.send(reply, state.room)
      actor.continue(state)
    }

    // -----------------------------------------------------------------------
    Shutdown -> actor.stop()
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Check outbound obligations: messages sent by this participant that have
/// any pending (unacked) receipts from other participants.
fn check_outbound_obligations(state: RoomState, pid_str: String) -> List(String) {
  check_outbound_obligations_with_receipts(
    state.receipts,
    state.messages,
    pid_str,
  )
}

fn check_outbound_obligations_with_receipts(
  receipts: Dict(String, List(Receipt)),
  messages: List(Message),
  pid_str: String,
) -> List(String) {
  list.filter_map(messages, fn(msg) {
    case participant_id_to_string(msg.from) == pid_str {
      False -> Error(Nil)
      True -> {
        let msg_key = message_id_to_string(msg.message_id)
        case dict.get(receipts, msg_key) {
          Error(_) -> Error(Nil)
          Ok(receipt_list) -> {
            let has_pending =
              list.any(receipt_list, fn(r) { r.status == message.Pending })
            case has_pending {
              True -> Ok(msg_key)
              False -> Error(Nil)
            }
          }
        }
      }
    }
  })
}

// ---------------------------------------------------------------------------
// Public caller helpers
// ---------------------------------------------------------------------------

pub fn join(
  room: Subject(RoomMessage),
  participant: Participant,
) -> Result(Nil, String) {
  actor.call(room, 5000, fn(reply) { Join(participant, reply) })
}

pub fn send_msg(
  room: Subject(RoomMessage),
  from: ParticipantId,
  to: List(ParticipantId),
  kind: MessageKind,
  summary: String,
) -> Result(Message, String) {
  actor.call(room, 5000, fn(reply) {
    SendMsg(from, to, kind, summary, None, None, [], reply)
  })
}

pub fn send_msg_full(
  room: Subject(RoomMessage),
  from: ParticipantId,
  to: List(ParticipantId),
  kind: MessageKind,
  summary: String,
  body: Option(String),
  thread_id: Option(ThreadId),
) -> Result(Message, String) {
  actor.call(room, 5000, fn(reply) {
    SendMsg(from, to, kind, summary, body, thread_id, [], reply)
  })
}

pub fn read_inbox(
  room: Subject(RoomMessage),
  participant_id: ParticipantId,
) -> List(Message) {
  actor.call(room, 5000, fn(reply) { ReadInbox(participant_id, reply) })
}

pub fn ack_messages(
  room: Subject(RoomMessage),
  participant_id: ParticipantId,
  message_ids: List(MessageId),
) -> Result(Nil, String) {
  actor.call(room, 5000, fn(reply) {
    AckMessages(participant_id, message_ids, reply)
  })
}

pub fn inbox_count(
  room: Subject(RoomMessage),
  participant_id: ParticipantId,
) -> Int {
  actor.call(room, 5000, fn(reply) { CountInbox(participant_id, reply) })
}

pub fn close_room(
  room: Subject(RoomMessage),
  resolution: RoomResolution,
) -> Result(Nil, String) {
  actor.call(room, 5000, fn(reply) { CloseRoom(resolution, reply) })
}

pub fn get_messages(
  room: Subject(RoomMessage),
  thread_id: Option(ThreadId),
) -> List(Message) {
  actor.call(room, 5000, fn(reply) { GetMessages(thread_id, reply) })
}

pub fn get_state(room: Subject(RoomMessage)) -> Room {
  actor.call(room, 5000, fn(reply) { GetState(reply) })
}

pub fn leave(
  room: Subject(RoomMessage),
  participant_id: ParticipantId,
  drain_reply: Subject(Nil),
) -> Result(LeaveResult, String) {
  actor.call(room, 5000, fn(reply) { Leave(participant_id, drain_reply, reply) })
}

pub fn force_departure(
  room: Subject(RoomMessage),
  participant_id: ParticipantId,
) -> Result(Nil, String) {
  actor.call(room, 5000, fn(reply) { ForceDeparture(participant_id, reply) })
}
