#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# info.sh — print ready-to-run curl commands for the MCP proxy
# ---------------------------------------------------------------------------

export PATH="$HOME/.local/bin:$PATH"

if ! command -v dotenvx &>/dev/null; then
  echo "dotenvx not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -f .env ]; then
  echo ".env not found. Run ./setup.sh first."
  exit 1
fi

PROXY_API_KEY=$(dotenvx get PROXY_API_KEY 2>/dev/null)

# Resolve base URL: Codespaces vs. local
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  BASE_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
else
  BASE_URL="http://localhost:8080"
fi

echo ""
echo "Check Point MCP Proxy — try it out"
echo "==================================="
echo ""
echo "Base URL : $BASE_URL"
echo "Api-Key  : $PROXY_API_KEY"
echo ""
echo "-- Health checks --"
echo ""
echo "curl -s \"$BASE_URL/quantum/health\" -H \"X-Api-Key: $PROXY_API_KEY\""
echo ""
echo "curl -s \"$BASE_URL/logs/health\" -H \"X-Api-Key: $PROXY_API_KEY\""
echo ""
echo "-- MCP endpoints (for client config) --"
echo ""
echo "  Quantum management : $BASE_URL/quantum/mcp"
echo "  Management logs    : $BASE_URL/logs/mcp"
echo ""
