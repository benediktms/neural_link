#!/usr/bin/env bash
# PostToolUse hook: check neural_link inbox for pending messages.
# Queries the server by agent_id (registered during room_join).
# Outputs additionalContext JSON when messages are pending, nothing otherwise.
# Fails silently on any error — never blocks agent work.

PORT="${NEURAL_LINK_PORT:-9961}"

# Read hook payload from stdin — extract agent_id
PAYLOAD=$(cat)
AGENT_ID=$(echo "$PAYLOAD" | jq -r '.agent_id // empty' 2>/dev/null) || exit 0
[ -z "$AGENT_ID" ] && exit 0

# Query inbox count by agent_id — fast, no auth, no state files
# Use --max-time 2 to stay within the 2000ms hook timeout budget
RESULT=$(curl -sf --max-time 2 "http://localhost:${PORT}/agent/${AGENT_ID}/inbox/count" 2>/dev/null) || exit 0

TOTAL=$(echo "$RESULT" | jq -r '.total // 0' 2>/dev/null) || exit 0
[ "$TOTAL" -eq 0 ] 2>/dev/null && exit 0

# Construct JSON safely via jq to prevent injection
jq -n --arg t "$TOTAL" '{
  additionalContext: ("⚡ " + $t + " unread neural_link messages. Call inbox_read to check your inbox.")
}'
