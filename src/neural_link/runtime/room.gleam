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
// Internal state types
// ---------------------------------------------------------------------------

type RoomState {
  RoomState(
    room: Room,
    messages: List(Message),
    receipts: Dict(String, List(Receipt)),
    sequence: Int,
    max_messages: Int,
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
          let audience = case to {
            [] ->
              list.filter_map(state.room.participants, fn(p) {
                case
                  participant_id_to_string(p.id)
                  == participant_id_to_string(from)
                {
                  True -> Error(Nil)
                  False -> Ok(p.id)
                }
              })
            ids -> ids
          }

          // Create receipts for audience
          let new_receipts = message.expand_receipts(msg, audience)
          let msg_key = message_id_to_string(msg.message_id)
          let updated_receipts =
            dict.insert(state.receipts, msg_key, new_receipts)

          // Store message (prepend), enforce max
          let updated_messages = [msg, ..state.messages]
          let bounded_messages = case
            list.length(updated_messages) > state.max_messages
          {
            True -> list.take(updated_messages, state.max_messages)
            False -> updated_messages
          }

          actor.send(reply, Ok(msg))
          actor.continue(
            RoomState(
              ..state,
              messages: bounded_messages,
              receipts: updated_receipts,
              sequence: new_seq,
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
      let updated_receipts =
        list.fold(message_ids, state.receipts, fn(acc, mid) {
          let msg_key = message_id_to_string(mid)
          case dict.get(acc, msg_key) {
            Error(_) -> acc
            Ok(receipt_list) -> {
              let updated_list =
                list.map(receipt_list, fn(r) {
                  case participant_id_to_string(r.participant_id) == pid_str {
                    True -> message.ack_receipt(r)
                    False -> r
                  }
                })
              dict.insert(acc, msg_key, updated_list)
            }
          }
        })
      actor.send(reply, Ok(Nil))
      actor.continue(RoomState(..state, receipts: updated_receipts))
    }

    // -----------------------------------------------------------------------
    CountInbox(participant_id, reply) -> {
      let pid_str = participant_id_to_string(participant_id)
      let count =
        list.count(state.messages, fn(msg) {
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
