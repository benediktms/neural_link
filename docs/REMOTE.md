# Connecting Claude Code to a remote neural_link

Server-side deployment lives in [`deploy/README.md`](../deploy/README.md).
This doc covers the **client side**: pointing your local Claude Code (or
any MCP client) at a neural_link instance running elsewhere.

The neural_link server speaks the same MCP protocol over stdio and over
Streamable HTTP. The choice between local-only and remote-capable is a
client-config choice, not a server choice. Many users run **both**: a
local stdio instance for solo work and a remote HTTP instance for
cross-session / cross-machine coordination.

---

## Prerequisites

You need:

1. A reachable neural_link server URL — `http://host:9961/mcp` for plain
   HTTP, `https://host/mcp` if fronted by Caddy / Tailscale Funnel / a
   cloud LB.
2. The bearer token if the server has `NEURAL_LINK_AUTH_TOKEN` set
   (always recommended for non-loopback deployments).

If you run a server yourself, follow [`deploy/README.md`](../deploy/README.md) first.

---

## Topology 1 — Replace local with remote

Use this when you have a single shared server and don't need a
local-only instance.

### Add the server

```bash
# Plain HTTP, no auth (LAN / Tailscale only)
claude mcp add -s user -t http neural_link \
  http://<host>:9961/mcp

# HTTPS with bearer auth (public host)
claude mcp add -s user -t http neural_link \
  https://<host>/mcp \
  --header "Authorization: Bearer $NEURAL_LINK_AUTH_TOKEN"
```

`-s user` writes to `~/.claude/settings.json` so the registration applies
to every Claude Code session on this machine.

### Confirm it's live

In a fresh Claude Code session:

```
> use neural_link to open a room titled "ping"
```

Claude Code will call `room_open` against the remote server. A successful
response (with a `room_id`) confirms the link.

### Remove

```bash
claude mcp remove neural_link
```

---

## Topology 2 — Local stdio + remote HTTP (dual)

Use this when you want both a local-only sandbox (for solo work that
shouldn't leak to teammates) and a remote room for collaboration. Two
distinct MCP server names — `neural_link` (local) and
`neural_link_remote` (remote) — coexist in your config.

### Add both

```bash
# Local stdio — same as the standard `just install` flow
claude mcp add -s user -t http neural_link http://localhost:9961/mcp

# Remote, registered under a distinct name
claude mcp add -s user -t http neural_link_remote \
  https://<host>/mcp \
  --header "Authorization: Bearer $NEURAL_LINK_AUTH_TOKEN"
```

### Calling the right server

MCP tools are namespaced by server. Inside Claude Code, refer to them by
the server name:

- `mcp__neural_link__room_open` — local
- `mcp__neural_link_remote__room_open` — remote

Skills (e.g. `/remote-room-open`) wrap these directly so you don't have
to remember the full names. See the skills README once those land.

---

## Bearer-token distribution

The server admin generates one token (`openssl rand -hex 32`) and shares
it with teammates **out-of-band**. Suggested patterns:

- **1Password / Bitwarden shared vault** — most teams have one anyway.
- **`pass` / `gpg` encrypted file** for ops-heavy teams.
- **Environment variable in your shell rc** — convenient for development,
  not recommended for laptops that travel.

Never commit the token to a repository. Never share it in plaintext over
Slack.

> **Today's auth model is one token per server.** Multi-token / per-user
> auth is a planned follow-up. Until then, treat the token like a shared
> wifi password — anyone with it gets full access.

---

## Verifying the connection

Without Claude Code, you can probe the server directly:

```bash
# Liveness — public, no auth
curl -fsS http://<host>:9961/health
# → {"status":"ok"}

# Readiness — public, no auth, proves the runtime is responsive
curl -fsS http://<host>:9961/ready
# → {"status":"ready","rooms":N}

# Authenticated initialize
curl -fsS -X POST http://<host>:9961/mcp \
  -H "authorization: Bearer $NEURAL_LINK_AUTH_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# → {"jsonrpc":"2.0","id":1,"result":{...,"serverInfo":{...}}}
```

If `/health` succeeds but `initialize` returns `401`, your token is
wrong. If `initialize` succeeds but a `tools/call` returns `401`, the
`mcp-session-id` header is missing — Claude Code handles this for you,
but `curl` requires you to read the session id from the initialize
response and include it on subsequent calls.

---

## Troubleshooting

**`401 Missing Authorization header`** — server has auth on; client
isn't sending the bearer token. Re-run `claude mcp add` with the
`--header` flag.

**`401 Invalid bearer token`** — token mismatch. Re-check the
`NEURAL_LINK_AUTH_TOKEN` value on the server vs. what your client sends.

**`401 Authorization header must be 'Bearer <token>'`** — check the
header value. The scheme must be exactly `Bearer` (case-insensitive),
followed by a space, followed by the token.

**Connection refused / timeout** — server isn't reachable. Verify with
`curl` first. If you're using Tailscale, check `tailscale status` to
confirm both ends are connected.

**`501 Method not implemented`** or odd JSON-RPC errors — usually a
version mismatch between your Claude Code MCP client and the server.
Confirm both are recent.

**Tools work locally but not remotely** — you may have skills configured
to call `mcp__neural_link__*` (the local server name) when you want
`mcp__neural_link_remote__*`. Check the skill source.

---

## What's not yet supported

- **Per-user authentication.** One token per server. A user-aware auth
  model is on the plan.
- **Workspace namespacing.** A planned `X-Neural-Workspace` header will
  isolate room IDs across teams sharing one server. Not implemented yet.
  Until it lands, deterministic room IDs (`nlr-*`) on a shared server
  carry collision risk if teams pick the same string.
- **TLS in-process.** The server speaks plain HTTP. Front it with
  Caddy / Tailscale / a cloud LB for public exposure.
