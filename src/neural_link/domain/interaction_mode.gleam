import gleam/list
import gleam/option.{type Option}
import neural_link/domain/id.{participant_id_to_string}
import neural_link/domain/message.{
  type Message, type MessageKind, Challenge, Decision, Finding, Handoff,
  Proposal, Question,
}
import neural_link/domain/participant.{
  type Participant, type ParticipantRole, Owner,
}

// ---------------------------------------------------------------------------
// Interaction modes
// ---------------------------------------------------------------------------

pub type InteractionMode {
  Adversarial
  Informative
  Deliberative
  Supervisory
}

// ---------------------------------------------------------------------------
// Response expectations
// ---------------------------------------------------------------------------

pub type ResponderConstraint {
  AnyParticipant
  DifferentParticipant
  RoleOnly(ParticipantRole)
}

pub type ResponseExpectation {
  ResponseExpectation(
    trigger: MessageKind,
    expected_response: MessageKind,
    responder: ResponderConstraint,
  )
}

/// Static response expectations for a given mode.
pub fn expectations_for(mode: InteractionMode) -> List(ResponseExpectation) {
  case mode {
    Adversarial -> [
      ResponseExpectation(
        trigger: Finding,
        expected_response: Challenge,
        responder: DifferentParticipant,
      ),
      ResponseExpectation(
        trigger: Challenge,
        expected_response: Decision,
        responder: AnyParticipant,
      ),
    ]
    Informative -> [
      ResponseExpectation(
        trigger: Finding,
        expected_response: Handoff,
        responder: AnyParticipant,
      ),
    ]
    Deliberative -> [
      ResponseExpectation(
        trigger: Question,
        expected_response: Finding,
        responder: AnyParticipant,
      ),
      ResponseExpectation(
        trigger: Proposal,
        expected_response: Challenge,
        responder: DifferentParticipant,
      ),
      ResponseExpectation(
        trigger: Finding,
        expected_response: Decision,
        responder: AnyParticipant,
      ),
    ]
    Supervisory -> [
      ResponseExpectation(
        trigger: Finding,
        expected_response: Question,
        responder: RoleOnly(Owner),
      ),
    ]
  }
}

// ---------------------------------------------------------------------------
// Compliance tracking
// ---------------------------------------------------------------------------

pub type ExpectationResult {
  Fulfilled(trigger_sequence: Int, response_sequence: Int)
  Unfulfilled(trigger_sequence: Int)
}

pub type ComplianceReport {
  ComplianceReport(
    mode: InteractionMode,
    expectations_checked: Int,
    expectations_fulfilled: Int,
    results: List(ExpectationResult),
    unchallenged_findings: List(Int),
  )
}

/// Compute compliance for a list of messages against an interaction mode.
/// Messages must be sorted by sequence (ascending).
/// Thread-aware: threaded triggers match same-thread responses only.
/// Participants are needed to resolve RoleOnly constraints.
pub fn compute_compliance(
  messages: List(Message),
  participants: List(Participant),
  mode: InteractionMode,
) -> ComplianceReport {
  let expectations = expectations_for(mode)
  let results =
    list.flat_map(messages, fn(msg) {
      list.filter_map(expectations, fn(exp) {
        case msg.kind == exp.trigger {
          False -> Error(Nil)
          True -> {
            let response =
              find_response(
                messages,
                msg,
                exp.expected_response,
                exp.responder,
                participants,
              )
            case response {
              option.Some(resp) ->
                Ok(Fulfilled(
                  trigger_sequence: msg.sequence,
                  response_sequence: resp.sequence,
                ))
              option.None -> Ok(Unfulfilled(trigger_sequence: msg.sequence))
            }
          }
        }
      })
    })

  let fulfilled =
    list.count(results, fn(r) {
      case r {
        Fulfilled(_, _) -> True
        Unfulfilled(_) -> False
      }
    })

  let unchallenged = case mode {
    Adversarial -> compute_unchallenged_findings(messages)
    _ -> []
  }

  ComplianceReport(
    mode: mode,
    expectations_checked: list.length(results),
    expectations_fulfilled: fulfilled,
    results: results,
    unchallenged_findings: unchallenged,
  )
}

/// Find a response message matching the expected kind and responder constraint.
/// Respects thread boundaries: threaded triggers require same-thread responses.
fn find_response(
  messages: List(Message),
  trigger: Message,
  expected_kind: MessageKind,
  constraint: ResponderConstraint,
  participants: List(Participant),
) -> Option(Message) {
  list.find(messages, fn(candidate) {
    // Must be after the trigger
    candidate.sequence > trigger.sequence
    // Must match expected kind
    && candidate.kind == expected_kind
    // Thread-aware: same thread or both unthreaded
    && candidate.thread_id == trigger.thread_id
    // Responder constraint
    && satisfies_constraint(candidate, trigger, constraint, participants)
  })
  |> option.from_result
}

fn satisfies_constraint(
  candidate: Message,
  trigger: Message,
  constraint: ResponderConstraint,
  participants: List(Participant),
) -> Bool {
  case constraint {
    AnyParticipant -> True
    DifferentParticipant -> candidate.from != trigger.from
    RoleOnly(required_role) -> {
      let candidate_id = participant_id_to_string(candidate.from)
      let has_role =
        list.any(participants, fn(p) {
          participant_id_to_string(p.id) == candidate_id
          && p.role == required_role
        })
      has_role
    }
  }
}

/// Find Finding messages with no subsequent Challenge in the same thread scope.
fn compute_unchallenged_findings(messages: List(Message)) -> List(Int) {
  list.filter_map(messages, fn(msg) {
    case msg.kind {
      Finding -> {
        let has_challenge =
          list.any(messages, fn(c) {
            c.sequence > msg.sequence
            && c.kind == Challenge
            && c.thread_id == msg.thread_id
          })
        case has_challenge {
          True -> Error(Nil)
          False -> Ok(msg.sequence)
        }
      }
      _ -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

pub fn mode_to_string(mode: InteractionMode) -> String {
  case mode {
    Adversarial -> "adversarial"
    Informative -> "informative"
    Deliberative -> "deliberative"
    Supervisory -> "supervisory"
  }
}

pub fn mode_from_string(s: String) -> Result(InteractionMode, Nil) {
  case s {
    "adversarial" -> Ok(Adversarial)
    "informative" -> Ok(Informative)
    "deliberative" -> Ok(Deliberative)
    "supervisory" -> Ok(Supervisory)
    _ -> Error(Nil)
  }
}
