import neural_link/mcp/protocol.{ToolDefinition, ToolProperty}

pub fn all_tools() -> List(protocol.ToolDefinition) {
  [
    room_open(),
    room_join(),
    message_send(),
    inbox_read(),
    message_ack(),
    wait_for(),
    thread_summarize(),
    room_close(),
  ]
}

fn room_open() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "room_open",
    description: "Create a new coordination room",
    properties: [
      ToolProperty(
        name: "title",
        prop_type: "string",
        description: "Room title",
        required: True,
      ),
      ToolProperty(
        name: "purpose",
        prop_type: "string",
        description: "Purpose or context for the room",
        required: False,
      ),
      ToolProperty(
        name: "external_ref",
        prop_type: "string",
        description: "External reference (e.g., task ID)",
        required: False,
      ),
      ToolProperty(
        name: "tags",
        prop_type: "string",
        description: "Comma-separated tags",
        required: False,
      ),
      ToolProperty(
        name: "brains",
        prop_type: "string",
        description: "Comma-separated brain names for event persistence",
        required: False,
      ),
      ToolProperty(
        name: "interaction_mode",
        prop_type: "string",
        description: "Interaction mode: adversarial, informative, deliberative, supervisory. Governs expected communication patterns and compliance tracking at room close.",
        required: False,
      ),
    ],
  )
}

fn room_join() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "room_join",
    description: "Add a participant to a room",
    properties: [
      ToolProperty(
        name: "room_id",
        prop_type: "string",
        description: "Room ID to join",
        required: True,
      ),
      ToolProperty(
        name: "participant_id",
        prop_type: "string",
        description: "Participant identifier",
        required: True,
      ),
      ToolProperty(
        name: "display_name",
        prop_type: "string",
        description: "Display name for the participant",
        required: True,
      ),
      ToolProperty(
        name: "role",
        prop_type: "string",
        description: "Role: owner, member, observer (default: member)",
        required: False,
      ),
    ],
  )
}

fn message_send() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "message_send",
    description: "Send a typed message to a room",
    properties: [
      ToolProperty(
        name: "room_id",
        prop_type: "string",
        description: "Target room ID",
        required: True,
      ),
      ToolProperty(
        name: "from",
        prop_type: "string",
        description: "Sender participant ID",
        required: True,
      ),
      ToolProperty(
        name: "kind",
        prop_type: "string",
        description: "Message kind: question, answer, finding, handoff, blocker, decision, review_request, review_result, artifact_ref, summary, challenge, proposal",
        required: True,
      ),
      ToolProperty(
        name: "summary",
        prop_type: "string",
        description: "Brief message summary",
        required: True,
      ),
      ToolProperty(
        name: "to",
        prop_type: "string",
        description: "Comma-separated recipient participant IDs (empty = broadcast)",
        required: False,
      ),
      ToolProperty(
        name: "body",
        prop_type: "string",
        description: "Full message body",
        required: False,
      ),
      ToolProperty(
        name: "thread_id",
        prop_type: "string",
        description: "Thread ID to attach to",
        required: False,
      ),
      ToolProperty(
        name: "persist_hint",
        prop_type: "string",
        description: "Persistence hint: durable or ephemeral (default: auto based on kind)",
        required: False,
      ),
    ],
  )
}

fn inbox_read() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "inbox_read",
    description: "Read a participant's inbox for a room",
    properties: [
      ToolProperty(
        name: "room_id",
        prop_type: "string",
        description: "Room ID",
        required: True,
      ),
      ToolProperty(
        name: "participant_id",
        prop_type: "string",
        description: "Participant whose inbox to read",
        required: True,
      ),
    ],
  )
}

fn message_ack() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "message_ack",
    description: "Acknowledge messages in a room",
    properties: [
      ToolProperty(
        name: "room_id",
        prop_type: "string",
        description: "Room ID",
        required: True,
      ),
      ToolProperty(
        name: "participant_id",
        prop_type: "string",
        description: "Acknowledging participant ID",
        required: True,
      ),
      ToolProperty(
        name: "message_ids",
        prop_type: "string",
        description: "Comma-separated message IDs to acknowledge",
        required: True,
      ),
    ],
  )
}

fn wait_for() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "wait_for",
    description: "Block until a matching message arrives in a room",
    properties: [
      ToolProperty(
        name: "room_id",
        prop_type: "string",
        description: "Room ID to watch",
        required: True,
      ),
      ToolProperty(
        name: "participant_id",
        prop_type: "string",
        description: "Waiting participant ID",
        required: True,
      ),
      ToolProperty(
        name: "since_sequence",
        prop_type: "string",
        description: "Only match messages after this sequence number (default: 0)",
        required: False,
      ),
      ToolProperty(
        name: "kinds",
        prop_type: "string",
        description: "Comma-separated message kinds to match (empty = any)",
        required: False,
      ),
      ToolProperty(
        name: "from",
        prop_type: "string",
        description: "Comma-separated sender IDs to match (empty = any)",
        required: False,
      ),
      ToolProperty(
        name: "timeout_ms",
        prop_type: "string",
        description: "Timeout in milliseconds (default: 30000, max: 120000)",
        required: False,
      ),
    ],
  )
}

fn thread_summarize() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "thread_summarize",
    description: "Get structured coordination status for a room or thread. Returns decisions, open questions, unresolved blockers, and message count. Read-only, no persistence.",
    properties: [
      ToolProperty(
        name: "room_id",
        prop_type: "string",
        description: "Room ID",
        required: True,
      ),
      ToolProperty(
        name: "thread_id",
        prop_type: "string",
        description: "Thread ID (omit for entire room)",
        required: False,
      ),
    ],
  )
}

fn room_close() -> protocol.ToolDefinition {
  ToolDefinition(
    name: "room_close",
    description: "Close a coordination room. Persists the full conversation as a brain artifact and returns structured extraction (decisions, open questions, unresolved blockers, artifact record ID). If interaction_mode was set, also returns compliance data.",
    properties: [
      ToolProperty(
        name: "room_id",
        prop_type: "string",
        description: "Room ID to close",
        required: True,
      ),
      ToolProperty(
        name: "resolution",
        prop_type: "string",
        description: "Close resolution: completed, cancelled, superseded, or failed",
        required: True,
      ),
    ],
  )
}
