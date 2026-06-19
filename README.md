# Check Point MCP over HTTP

Runs Check Point MCP servers (`quantum-management-mcp` and `management-logs-mcp`) in HTTP transport mode behind a Caddy reverse proxy with API-key authentication.

```
caller ──(X-Api-Key)──► Caddy :8080
                          ├─ /quantum/mcp ──► quantum-management-mcp:3001
                          └─ /logs/mcp    ──► management-logs-mcp:3000
```

## Prerequisites

- Docker & Docker Compose
- `curl` (to install dotenvx)
- A SentinelOne Cloud (S1C) tenant with an API key

## First-time setup

### 1. Install dotenvx

```bash
curl -sfS https://dotenvx.sh | sh
```

### 2. Run the setup script

```bash
chmod +x setup.sh start.sh
./setup.sh
```

The script will:
1. Copy `.env.example` → `.env` on the first run.
2. Ask you to fill in the required variables, then re-run.
3. Encrypt `.env` with dotenvx on the second run.

### 3. Fill in `.env`

| Variable | Description |
|---|---|
| `API_KEY` | Your S1C API key |
| `S1C_URL` | Your S1C tenant web-API URL (ending in `/web_api/`) |
| `PROXY_API_KEY` | Secret that callers must supply as `X-Api-Key` header |

After editing `.env`, re-run `./setup.sh` to encrypt it.

> **Security note:** `./setup.sh` produces a `.env.keys` file containing the decryption key.  
> Both `.env` and `.env.keys` are git-ignored. Back up `.env.keys` securely — without it the encrypted `.env` cannot be decrypted.

## Starting the stack

```bash
./start.sh
```

To run in the background:

```bash
./start.sh -d
```

The proxy is reachable at `http://localhost:8080`.

## MCP endpoints

| Path | Upstream |
|---|---|
| `http://localhost:8080/quantum/mcp` | quantum-management-mcp |
| `http://localhost:8080/logs/mcp` | management-logs-mcp |

Every request must include the `X-Api-Key` header matching `PROXY_API_KEY`.

### Health checks

```bash
curl -s localhost:8080/quantum/health -H "X-Api-Key: <your-PROXY_API_KEY>"
curl -s localhost:8080/logs/health    -H "X-Api-Key: <your-PROXY_API_KEY>"
```

## Configuring an MCP client

Add both servers to your MCP client configuration (e.g. Claude Desktop, VS Code MCP extension):

```json
{
  "mcpServers": {
    "quantum-management": {
      "url": "http://localhost:8080/quantum/mcp",
      "headers": { "X-Api-Key": "<your-PROXY_API_KEY>" }
    },
    "management-logs": {
      "url": "http://localhost:8080/logs/mcp",
      "headers": { "X-Api-Key": "<your-PROXY_API_KEY>" }
    }
  }
}
```

## Stopping the stack

```bash
docker compose down
```
