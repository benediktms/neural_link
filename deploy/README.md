# Deploying neural_link

This directory packages the neural_link MCP server for remote operation.
Three deployment topologies are supported:

| Topology | Use case | Auth required? |
|---|---|---|
| Local stdio | Solo agents, single-machine | No |
| Tailscale / LAN port-forward | Small team on a private network | Recommended |
| Public host (VPS, Fly.io, fly machines, ECS, …) | Org-wide / remote teams | **Required** |

Deployment is **transport-agnostic** — the same binary serves stdio,
HTTP-on-loopback, port-forwarded HTTP, and HTTP-behind-a-LB. Pick the
topology that matches your trust boundary; the server doesn't care.

---

## Configuration surface

All configuration lives in environment variables. There is no config file.

| Variable | Default | Notes |
|---|---|---|
| `NEURAL_LINK_TRANSPORT` | `http` | `stdio` for single-machine; `http` for everything else |
| `NEURAL_LINK_PORT` | `9961` | HTTP listen port |
| `NEURAL_LINK_DATA_DIR` | `~/.neural_link` | SQLite + sync log location |
| `NEURAL_LINK_AUTH_TOKEN` | *(unset)* | When set, every endpoint except `/health` and `/ready` requires `Authorization: Bearer <token>` |

`/health` is liveness — returns `200` if the process is up. `/ready` calls
the registry actor and returns `200 {"status":"ready","rooms":N}` once the
runtime is responsive. Both are public so load balancers can scrape them
without credentials.

---

## Topology 1 — Tailscale / LAN port-forward

Cheapest path to multi-machine coordination. One node hosts the server;
teammates connect over a private network.

### Step 1 — Run the server

Either with Docker:

```bash
docker compose -f deploy/docker-compose.yml up -d
```

…or directly via the justfile target on the host:

```bash
just install      # builds, deploys to ~/bin, registers MCP, starts daemon
```

### Step 2 — Make it reachable

Pick **one**:

- **Tailscale (recommended).** Install Tailscale on host and clients;
  connect them to the same tailnet. The server is reachable at
  `http://<host-tailnet-name>:9961/mcp`. No port forwarding, no public
  exposure, no certificate setup.
- **SSH tunnel.** Each client opens
  `ssh -L 9961:localhost:9961 user@host` and connects to
  `http://localhost:9961/mcp`. Works without third-party software but
  every client must keep the tunnel open.
- **LAN bind.** Edit `docker-compose.yml` to bind to `0.0.0.0:9961`
  instead of `127.0.0.1:9961`. Only safe on a fully trusted LAN.

### Step 3 — Auth (optional, recommended)

Even on a private network, set `NEURAL_LINK_AUTH_TOKEN` to defend against
lateral movement. Generate one with `openssl rand -hex 32` and propagate
to clients out-of-band (e.g. 1Password).

---

## Topology 2 — Public host

For org-wide use or when teams span networks. Auth is **required**.

### Step 1 — Provision

Any Linux host with Docker works (Fly.io, Hetzner, EC2, DigitalOcean…).
Minimum: 256MB RAM, 1 vCPU, 1GB disk for SQLite + WAL.

### Step 2 — Deploy

#### With Docker Compose

```bash
git clone <this-repo> && cd neural_link
NEURAL_LINK_AUTH_TOKEN=$(openssl rand -hex 32) \
  docker compose -f deploy/docker-compose.yml up -d
docker compose logs -f neural_link  # confirm it started
```

#### With systemd (no Docker)

```bash
# On the target host
sudo useradd --system --home /opt/neural_link --shell /usr/sbin/nologin neural_link
sudo mkdir -p /opt/neural_link /var/lib/neural_link
sudo chown -R neural_link:neural_link /var/lib/neural_link

# Build the shipment locally and rsync it
gleam export erlang-shipment
rsync -av build/erlang-shipment/ user@host:/tmp/neural_link/
ssh user@host 'sudo mv /tmp/neural_link/* /opt/neural_link/'

# Install the service
sudo cp deploy/systemd/neural-link.service /etc/systemd/system/
sudo mkdir -p /etc/neural_link
echo "NEURAL_LINK_AUTH_TOKEN=$(openssl rand -hex 32)" | sudo tee /etc/neural_link/env
sudo chmod 600 /etc/neural_link/env
# Uncomment the EnvironmentFile line in the unit, then:
sudo systemctl daemon-reload
sudo systemctl enable --now neural-link
sudo systemctl status neural-link
```

### Step 3 — TLS (required for public hosts)

The neural_link binary speaks plain HTTP. **Do not** expose it directly
to the internet. Front it with one of:

- **Caddy** — automatic Let's Encrypt; simplest:

  ```caddyfile
  neural-link.example.com {
      reverse_proxy 127.0.0.1:9961
  }
  ```

- **Tailscale Funnel** — TLS + public hostname without DNS surgery.
- **A cloud load balancer** (ALB, GCP LB) when running on managed infra.

The reverse proxy terminates TLS; neural_link sees plain HTTP from
`127.0.0.1`.

### Step 4 — Distribute the auth token

The server admin generates one token and shares it out-of-band with
teammates. Each client adds it to their MCP client config (see
`docs/REMOTE.md` once written, or the configure-client CLI).

> Multi-token / per-user auth is not yet implemented. Today the model is
> "one server = one shared secret". Plan accordingly.

---

## Verifying a deployment

From any client that can reach the server:

```bash
# Liveness — always public
curl -fsS http://<host>:9961/health
# → {"status":"ok"}

# Readiness — proves the registry actor responds
curl -fsS http://<host>:9961/ready
# → {"status":"ready","rooms":0}

# Auth probe — should fail with 401 when token is set
curl -i -X POST http://<host>:9961/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# → HTTP/1.1 401 Unauthorized

# Authenticated call
curl -fsS -X POST http://<host>:9961/mcp \
  -H "authorization: Bearer $NEURAL_LINK_AUTH_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

---

## What this directory contains

- `Dockerfile` — multi-stage build; produces a ~50MB runtime image.
- `.dockerignore` — keeps the build context lean.
- `docker-compose.yml` — single-node compose file with persistent volume.
- `systemd/neural-link.service` — for non-Docker VPS deployments.
- This README.

## What this directory does **not** contain

- TLS termination — out of scope; use Caddy / Tailscale / a cloud LB.
- A Kubernetes manifest — generate from the compose file with `kompose`
  or write one when actually targeting k8s.
- Backup tooling for SQLite — for now, snapshot the data volume.
