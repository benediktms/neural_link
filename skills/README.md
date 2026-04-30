# neural_link skills

Claude Code skills that wrap the neural_link MCP tools. They make the
remote-room workflow ergonomic — you invoke `/coordinator` once and
get nudged whenever teammates send messages, then use `/reply` and
`/send-message` to interact ad-hoc.

## Installation

```bash
just install-skills
```

This symlinks every directory under `skills/neural_link/` into
`~/.claude/skills/neural_link/` and copies `agents/*.md` into
`~/.claude/agents/`.

To remove:

```bash
just uninstall-skills
```

## The suite

| Skill | Purpose |
|---|---|
| `/remote-room-open` | Open a new room on the remote server |
| `/remote-room-join` | Join an existing remote room as a member |
| `/remote-room-close` | Close a remote room with a resolution |
| `/send-message` | Send an ad-hoc message to a remote room |
| `/reply` | Reply to the most recent inbox message in a remote room |
| `/coordinator` | Spawn a teammate that bridges a remote room into local notifications |

## The headline workflow

```text
1. Someone opens a room remotely (any machine):
       /remote-room-open "feature X coordination"
       → returns room_id <R>

2. You join from your laptop:
       /remote-room-join <R> drone-bs "Bensch's drone"

3. You spawn a coordinator so you don't have to poll:
       /coordinator <R>

4. Teammate sends a message → coordinator relays it to your local
   room → PostToolUse hook nudges you in your active session.

5. You reply ad-hoc:
       /reply <R> drone-bs "yes, going with approach A"
```

## Prerequisites

- `neural_link_remote` registered as an MCP server in Claude Code
  (`docs/REMOTE.md`).
- `neural_link` (local stdio) also registered for the coordinator
  workflow — see the standard `just install` flow.
- PostToolUse + SubagentStart hooks installed (`just install-hooks`)
  for inbox nudges.

## Customization

Skills live as markdown files. To tweak behavior, edit the `.md`
files in `skills/neural_link/<name>/SKILL.md` and re-run
`just install-skills`. The change takes effect on the next Claude Code
session.

## Limitations

- **No state persistence** — skills don't remember the active room
  between invocations. You pass `<room_id>` and `<participant_id>` on
  every call. A future iteration will persist active-room state per
  project.
- **One token per server** — same as the server-side limitation.
  Per-user auth is on the plan.
- **Coordinator stop is manual** — there's no clean shutdown skill
  yet; killing the parent session works.
