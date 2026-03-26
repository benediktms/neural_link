import gleeunit/should
import neural_link/domain/message

// ---------------------------------------------------------------------------
// is_durable
// ---------------------------------------------------------------------------

pub fn is_durable_decision_test() {
  message.is_durable(message.Decision) |> should.be_true
}

pub fn is_durable_blocker_test() {
  message.is_durable(message.Blocker) |> should.be_true
}

pub fn is_durable_handoff_test() {
  message.is_durable(message.Handoff) |> should.be_true
}

pub fn is_durable_review_result_test() {
  message.is_durable(message.ReviewResult) |> should.be_true
}

pub fn is_durable_summary_test() {
  message.is_durable(message.Summary) |> should.be_true
}

pub fn is_durable_challenge_test() {
  message.is_durable(message.Challenge) |> should.be_true
}

pub fn is_durable_proposal_test() {
  message.is_durable(message.Proposal) |> should.be_true
}

pub fn is_durable_escalation_test() {
  message.is_durable(message.Escalation) |> should.be_true
}

pub fn is_durable_question_test() {
  message.is_durable(message.Question) |> should.be_false
}

pub fn is_durable_answer_test() {
  message.is_durable(message.Answer) |> should.be_false
}

pub fn is_durable_finding_test() {
  message.is_durable(message.Finding) |> should.be_false
}

pub fn is_durable_review_request_test() {
  message.is_durable(message.ReviewRequest) |> should.be_false
}

pub fn is_durable_artifact_ref_test() {
  message.is_durable(message.ArtifactRef) |> should.be_false
}

// ---------------------------------------------------------------------------
// kind_to_string
// ---------------------------------------------------------------------------

pub fn kind_to_string_question_test() {
  message.kind_to_string(message.Question) |> should.equal("question")
}

pub fn kind_to_string_answer_test() {
  message.kind_to_string(message.Answer) |> should.equal("answer")
}

pub fn kind_to_string_finding_test() {
  message.kind_to_string(message.Finding) |> should.equal("finding")
}

pub fn kind_to_string_handoff_test() {
  message.kind_to_string(message.Handoff) |> should.equal("handoff")
}

pub fn kind_to_string_blocker_test() {
  message.kind_to_string(message.Blocker) |> should.equal("blocker")
}

pub fn kind_to_string_decision_test() {
  message.kind_to_string(message.Decision) |> should.equal("decision")
}

pub fn kind_to_string_review_request_test() {
  message.kind_to_string(message.ReviewRequest)
  |> should.equal("review_request")
}

pub fn kind_to_string_review_result_test() {
  message.kind_to_string(message.ReviewResult) |> should.equal("review_result")
}

pub fn kind_to_string_artifact_ref_test() {
  message.kind_to_string(message.ArtifactRef) |> should.equal("artifact_ref")
}

pub fn kind_to_string_summary_test() {
  message.kind_to_string(message.Summary) |> should.equal("summary")
}

pub fn kind_to_string_challenge_test() {
  message.kind_to_string(message.Challenge) |> should.equal("challenge")
}

pub fn kind_to_string_proposal_test() {
  message.kind_to_string(message.Proposal) |> should.equal("proposal")
}

pub fn kind_to_string_escalation_test() {
  message.kind_to_string(message.Escalation) |> should.equal("escalation")
}
