# Check Point MCP over HTTP

Runs Check Point MCP servers (`quantum-management-mcp` and `management-logs-mcp`) in HTTP transport mode behind a Caddy reverse proxy with API-key authentication.

```
caller ──(X-Api-Key)──► Caddy :8080
                          ├─ /quantum/mcp ──► quantum-management-mcp:3001
                          └─ /logs/mcp    ──► management-logs-mcp:3000
```

## Prerequisites

- Docker & Docker Compose, `curl` (to install dotenvx) - we recommend to open this repo in preconfigured Codespace/Devcontainer to cover dependencies
- A [Check Point Smart-1 Cloud tenant](https://portal.checkpoint.com/dashboard/security-management) with an API key - we are suggesting S1C demo tenant for experiments

## First-time setup

```bash
./setup.sh
```

The script interactively prompts for the three required values, writes them with `dotenvx set`, and encrypts `.env`:

| Prompt | Variable | Description |
|---|---|---|
| S1C API key | `API_KEY` | Your S1C API key |
| S1C tenant web-API URL | `S1C_URL` | Your S1C tenant URL ending in `/web_api/` |
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
