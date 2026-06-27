#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# info-oauth.sh — print URLs and client config for the OAuth MCP stack
# ---------------------------------------------------------------------------

export PATH="$HOME/.dotenvx/bin:$HOME/.local/bin:$PATH"

if ! command -v dotenvx &>/dev/null; then
  echo "dotenvx not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -f .env.oauth ]; then
  echo ".env.oauth not found. Run ./setup.sh first or copy .env.oauth.example."
  exit 1
fi

PROXY_API_KEY=$(dotenvx get PROXY_API_KEY -f .env.oauth 2>/dev/null || true)

# Resolve base URLs: Codespaces vs local
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  MCP_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  POCKET_URL="https://${CODESPACE_NAME}-1411.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
else
  MCP_URL="http://localhost:8080"
  POCKET_URL="http://localhost:1411"
fi

# Check if Pocket ID is actually reachable
POCKET_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${POCKET_URL}/setup" 2>/dev/null || echo "000")
if [ "$POCKET_CODE" = "000" ]; then
  POCKET_STATUS="  ⚠  not reachable yet — run: docker compose --profile oauth logs pocket-id"
else
  POCKET_STATUS="  ✓  reachable (HTTP ${POCKET_CODE})"
fi

echo ""
echo "Check Point MCP Proxy — OAuth stack"
echo "===================================="
echo ""
echo "Pocket ID (OIDC provider)  ${POCKET_STATUS}"
echo "  Admin UI  : $POCKET_URL/admin"
echo "  Setup     : $POCKET_URL/setup      (first run only — creates admin account)"
echo ""
echo "MCP Proxy"
echo "  Base URL  : $MCP_URL"
echo "  quantum   : $MCP_URL/quantum/mcp"
echo "  logs      : $MCP_URL/logs/mcp"
echo ""
echo "Authentication"
echo "  Browser   : open $MCP_URL  — redirects to Pocket ID passkey login"
echo "  API key   : X-Api-Key: ${PROXY_API_KEY:-<see .env.oauth>}"
echo "  Bearer    : obtain token from Pocket ID, pass as Authorization: Bearer <token>"
echo ""
echo "-- VS Code .mcp.json (API key auth) --"
echo ""
cat <<EOF
{
  "mcpServers": {
    "quantum-management": {
      "type": "http",
      "url": "$MCP_URL/quantum/mcp",
      "headers": { "X-Api-Key": "${PROXY_API_KEY:-<PROXY_API_KEY>}" }
    },
    "management-logs": {
      "type": "http",
      "url": "$MCP_URL/logs/mcp",
      "headers": { "X-Api-Key": "${PROXY_API_KEY:-<PROXY_API_KEY>}" }
    }
  }
}
EOF
echo ""
echo "-- Stack management --"
echo ""
echo "  Logs   : docker compose --profile oauth logs -f"
echo "  Stop   : docker compose --profile oauth down"
echo "  Status : docker compose --profile oauth ps"
echo ""
