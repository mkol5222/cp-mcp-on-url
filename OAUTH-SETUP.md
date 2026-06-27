# OAuth Setup with Pocket ID

This guide covers setting up the MCP proxy with OAuth authentication using Pocket ID as the OIDC provider.

## Prerequisites

- Two cloudflared tunnels (or similar public URLs):
  - One for the MCP proxy (port 8080)
  - One for Pocket ID (port 1411)
- Docker and Docker Compose installed

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     cloudflared tunnels                             │
│   https://mcp.example.com ──► :8080                                 │
│   https://id.example.com  ──► :1411                                 │
└─────────────────────────────────────────────────────────────────────┘
                    │                           │
                    ▼                           ▼
         ┌──────────────────┐         ┌──────────────────┐
         │      Caddy       │         │    Pocket ID     │
         │   (port 8080)    │         │   (port 1411)    │
         │                  │         │   OIDC Provider  │
         │  forward_auth ───┼────────►│                  │
         └────────┬─────────┘         └──────────────────┘
                  │
         ┌────────┴─────────┐
         │   oauth2-proxy   │
         │   (port 4180)    │
         └──────────────────┘
                  │
      ┌───────────┴───────────┐
      ▼                       ▼
┌─────────────┐        ┌─────────────┐
│ logs-mcp    │        │ quantum-mcp │
│ (port 3000) │        │ (port 3001) │
└─────────────┘        └─────────────┘
```

## Setup Steps

### 1. Configure environment

```bash
cp .env.oauth.example .env.oauth
```

Edit `.env.oauth` and fill in:

```bash
# Your S1C credentials (same as header-auth setup)
API_KEY=your_api_key_here
S1C_URL=https://your-tenant.maas.checkpoint.com/your-uuid/web_api/

# API key for MCP clients (still works alongside OAuth)
PROXY_API_KEY=$(openssl rand -hex 16)

# Pocket ID public URL (your tunnel)
POCKET_ID_URL=https://id.example.com

# Static API key for Pocket ID admin
POCKET_ID_STATIC_API_KEY=$(openssl rand -hex 32)

# OAuth2-proxy cookie secret
OAUTH2_COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '\n')

# OAuth callback URL (your MCP tunnel + /oauth2/callback)
OAUTH2_REDIRECT_URL=https://mcp.example.com/oauth2/callback

# OIDC client credentials (leave blank for now, fill after step 3)
OIDC_CLIENT_ID=
OIDC_CLIENT_SECRET=
```

### 2. Start the stack (Pocket ID only first)

```bash
# Start just Pocket ID to complete initial setup
docker compose -f docker-compose.oauth.yml up pocket-id -d
```

### 3. Complete Pocket ID setup

1. Open your Pocket ID tunnel URL: `https://id.example.com/setup`

2. Create your admin account:
   - Email: `guru@pocketid.local`
   - Register a passkey (requires WebAuthn-capable browser)

3. Create an OIDC client:
   - Go to Settings → Admin → OIDC Clients
   - Click "Add OIDC Client"
   - Name: `mcp-proxy`
   - Callback URL: `https://mcp.example.com/oauth2/callback`
   - Copy the Client ID and Client Secret

4. Update `.env.oauth` with the OIDC credentials:
   ```bash
   OIDC_CLIENT_ID=<copied-client-id>
   OIDC_CLIENT_SECRET=<copied-client-secret>
   ```

### 4. Encrypt and start full stack

```bash
# Encrypt the env file
dotenvx encrypt -f .env.oauth

# Start the full stack
./start-oauth.sh
```

## Authentication Methods

The OAuth setup supports dual authentication:

### 1. API Key (for MCP clients)

MCP clients can still use the `X-Api-Key` header:

```json
{
  "mcpServers": {
    "cp-logs": {
      "command": "npx",
      "args": ["mcp-remote", "https://mcp.example.com/logs/mcp"],
      "env": {
        "MCP_HEADERS": "X-Api-Key:your-proxy-api-key"
      }
    }
  }
}
```

### 2. OAuth (for browser users)

Users without an API key are redirected to Pocket ID for passkey authentication.

This is useful for:
- Testing endpoints in a browser
- Admin dashboards
- Web-based MCP clients

## Troubleshooting

### "OIDC issuer not reachable"

Ensure `POCKET_ID_URL` is accessible from the oauth2-proxy container. For internal networks, you may need to use the Docker service name:

```bash
OAUTH2_PROXY_OIDC_ISSUER_URL=http://pocket-id:1411
```

### "Invalid redirect URI"

Ensure the callback URL in Pocket ID exactly matches `OAUTH2_REDIRECT_URL`:
- Must include the protocol (`https://`)
- Must end with `/oauth2/callback`

### "Cookie not secure"

For local development without HTTPS, add to oauth2-proxy environment:
```yaml
OAUTH2_PROXY_COOKIE_SECURE: "false"
```

## Comparison: Header Auth vs OAuth

| Feature | Header Auth | OAuth |
|---------|-------------|-------|
| MCP client support | Native | Via API key fallback |
| Browser access | No | Yes |
| User identity | No | Yes (email, groups) |
| SSO | No | Yes |
| Setup complexity | Simple | Moderate |
| Passkey/WebAuthn | No | Yes |
