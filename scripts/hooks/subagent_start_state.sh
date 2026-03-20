#!/usr/bin/env bash
# SubagentStart hook: relay agent_id to the subagent via additionalContext.
# The subagent passes this agent_id to room_join, enabling the PostToolUse
# hook to query inbox counts by agent_id without filesystem state.

AGENT_ID=$(jq -r '.agent_id // empty' 2>/dev/null) || exit 0
[ -z "$AGENT_ID" ] && exit 0

# Construct JSON safely via jq — XML tags for structural extraction,
# calm declarative tone per Anthropic Claude 4.6 prompting guidance
jq -n --arg id "$AGENT_ID" '{
  additionalContext: (
    "<neural_link_registration agent_id=\"" + $id + "\">\n" +
    "Your agent_id for this session is \"" + $id + "\".\n\n" +
    "When calling room_join, pass agent_id: \"" + $id + "\" as a parameter.\n" +
    "This enables the PostToolUse hook to deliver inbox notifications between tool calls.\n" +
    "Without registration, you will not receive messages from other agents.\n\n" +
    "Call room_join with agent_id: \"" + $id + "\" before beginning work.\n" +
    "</neural_link_registration>"
  )
}'
