# Check Point MCP over HTTP

## Why

Check Point MCP servers (`quantum-management-mcp`, `management-logs-mcp`) officially support **stdio transport** — the MCP process runs as a local subprocess, communicating over stdin/stdout. This works fine for a single developer on a laptop, but breaks down in several common scenarios:

- **Automation platforms** such as N8N, Make, or custom agents expect an HTTP endpoint, not a local process.
- **Shared or cloud environments** have no natural place to run a persistent stdio process accessible to multiple callers.
- **Security posture** — stdio means the MCP process runs directly on the host with no access control, no authentication, and no isolation boundary.

Check Point MCPs do support an **HTTP transport mode**, but out of the box it publishes a plain, unauthenticated HTTP endpoint with no TLS — not suitable for anything beyond a local test.

## How

This repo wraps the MCP servers in a stack that addresses each gap:

- MCP servers run in **Docker containers**, isolated from the host.
- A **Caddy reverse proxy** sits in front, adding API-key authentication and — when deployed behind a TLS terminator (e.g. Codespaces) — HTTPS.
- The whole stack runs inside a **GitHub Codespace / Dev Container**, giving every user an identical, self-contained environment with a publicly reachable HTTPS URL — no local install, no port-forwarding configuration.
- Credentials are managed with **dotenvx** (encrypted `.env`), keeping secrets out of version control.

| Challenge | Solution | Technology |
|---|---|---|
| stdio transport not usable over network | HTTP transport mode | Check Point MCP HTTP flag |
| No authentication on HTTP endpoint | API-key header enforcement | Caddy `@unauthorized` matcher |
| No TLS / plain HTTP | HTTPS via Codespaces tunnel | GitHub Codespaces port forwarding |
| Process isolation | Containerised MCP servers | Docker / Docker Compose |
| Reproducible environment | Dev Container with pre-installed tooling | GitHub Codespaces / Dev Containers |
| Secrets in version control | Encrypted `.env` | dotenvx |
| Cloud vs on-prem flexibility | Dual backend support | S1C or local management server |
| SSO / browser auth | OAuth option | Pocket ID + oauth2-proxy |

```
caller ──(X-Api-Key, HTTPS)──► Caddy :8080
                                 ├─ /quantum/mcp ──► quantum-management-mcp:3001
                                 └─ /logs/mcp    ──► management-logs-mcp:3000
```

## Prerequisites

- Docker & Docker Compose, `curl` (to install dotenvx) - we recommend to open this repo in preconfigured Codespace/Devcontainer to cover dependencies
- **One of:**
  - A [Check Point Smart-1 Cloud tenant](https://portal.checkpoint.com/dashboard/security-management) with an API key
  - An on-premises Check Point management server (defaults provided for demo)

## Management Server Options

The stack supports two backend modes:

| Mode | When to use | Required variables |
|------|-------------|-------------------|
| **Smart-1 Cloud (S1C)** | Production S1C tenants | `API_KEY`, `S1C_URL` |
| **Local Management** | On-prem servers, demos | `MANAGEMENT_HOST`, `USERNAME`, `PASSWORD` |

**Zero-config demo:** Leave `S1C_URL` empty and the stack uses sensible defaults:
- `MANAGEMENT_HOST=cpman.duckdns.org`
- `USERNAME=admin`
- `PASSWORD=demo123`

## First-time setup

```bash
./setup.sh
```

The script interactively prompts for values, writes them with `dotenvx set`, and encrypts `.env`:

| Prompt | Variable | Description |
|---|---|---|
| S1C API key | `API_KEY` | Your S1C API key (leave empty for local mgmt) |
| S1C tenant web-API URL | `S1C_URL` | Your S1C tenant URL ending in `/web_api/` (leave empty for local mgmt) |
| Management host | `MANAGEMENT_HOST` | On-prem server hostname (default: `cpman.duckdns.org`) |
| Username | `USERNAME` | Management server username (default: `admin`) |
| Password | `PASSWORD` | Management server password (default: `demo123`) |
| Proxy API key | `PROXY_API_KEY` | Secret callers must supply as `X-Api-Key` header |

Re-running `./setup.sh` lets you update individual values — existing ones are shown and kept if you press Enter.

> **Security note:** `./setup.sh` produces a `.env.keys` file containing the decryption key.
> Both `.env` and `.env.keys` are git-ignored. Back up `.env.keys` securely — without it the encrypted `.env` cannot be decrypted.

## Starting the stack

```bash
./start.sh        # foreground
./start.sh -d     # background (detached)
```

## Try it out

After the stack is up, run:

```bash
./info.sh
```

This prints the correct base URL (Codespaces public URL or `localhost`) together with your `PROXY_API_KEY`, and ready-to-copy `curl`, MCP Inspector CLI commands, and a `.mcp.json` snippet with the exact URLs and key filled in.

## Test the stack

```bash
./test.sh
```

Runs a suite of checks and prints a colour-coded report:

- Health endpoints for both MCP servers
- Auth guard (unauthenticated requests rejected with HTTP 401)
- Full list of available tools with descriptions from both servers

## MCP endpoints

Every request must include the `X-Api-Key` header matching `PROXY_API_KEY`.

| Path | Upstream |
|---|---|
| `<base-url>/quantum/mcp` | quantum-management-mcp |
| `<base-url>/logs/mcp` | management-logs-mcp |

## Configuring VS Code

Run `./info.sh` to get a ready-to-paste `.mcp.json` block with the exact URLs and key for your environment. Save it as `.mcp.json` at the workspace root (already git-ignored) and VS Code will pick it up automatically.

## Stopping the stack

```bash
docker compose down
```

## Authentication Options

The stack supports two authentication modes for the proxy layer:

### Option 1: API Key (default)

Simple header-based authentication — callers include `X-Api-Key` header. Best for MCP clients.

```
docker compose up
```

### Option 2: OAuth with Pocket ID

Browser-based SSO using [Pocket ID](https://pocket-id.org/) as OIDC provider with passkey authentication. Supports both:
- **API key** for MCP clients (via `X-Api-Key` header)
- **OAuth flow** for browser users (redirects to Pocket ID login)

```bash
# See OAUTH-SETUP.md for full instructions
./start-oauth.sh
```

| File | Purpose |
|------|---------|
| `docker-compose.oauth.yml` | Stack with Pocket ID + oauth2-proxy |
| `conf/Caddyfile.oauth` | Dual auth: API key OR OAuth |
| `.env.oauth.example` | Environment template |
| `OAUTH-SETUP.md` | Step-by-step guide |

**Note:** Pocket ID uses passkeys (WebAuthn) — no passwords. Users must register interactively via browser.
