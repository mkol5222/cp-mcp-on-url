#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# start.sh — bring up the basic stack (API-key auth, docker compose --profile basic)
# ---------------------------------------------------------------------------

export PATH="$HOME/.dotenvx/bin:$HOME/.local/bin:$PATH"

if ! command -v dotenvx &>/dev/null; then
  echo "dotenvx not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -f .env ]; then
  echo ".env not found. Run ./setup.sh first."
  exit 1
fi

MCP_URL=""
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  MCP_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
fi

echo "Bringing down any running containers (both profiles)..."
dotenvx run -- docker compose --profile oauth down --remove-orphans 2>/dev/null || true
dotenvx run -- docker compose --profile basic down --remove-orphans 2>/dev/null || true

echo "Starting Check Point MCP proxy stack..."
dotenvx run -- docker compose --profile basic up -d "$@"

# Codespaces: wait for port 8080 to be listening, then set public + verify
# gh codespace ports --json fields: sourcePort, privacy (public/private/org), protocol (http/https)
if [ -n "$MCP_URL" ] && command -v gh &>/dev/null; then
  echo ""
  echo "Waiting for proxy to be ready on localhost..."
  for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8080 2>/dev/null || echo "000")
    if [ "$CODE" != "000" ]; then
      gh codespace ports visibility 8080:public -c "$CODESPACE_NAME" 2>/dev/null \
        || echo "  Warning: could not set port visibility (check: gh auth status)"
      PORTS_JSON=$(gh codespace ports --json sourcePort,privacy,protocol -c "$CODESPACE_NAME" 2>/dev/null || echo "[]")
      proto=$(echo "$PORTS_JSON" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    if p.get('sourcePort') == 8080:
        print(p.get('protocol','?'))
        break
" 2>/dev/null || echo "?")
      priv=$(echo "$PORTS_JSON" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    if p.get('sourcePort') == 8080:
        print(p.get('privacy','?'))
        break
" 2>/dev/null || echo "?")
      if [ "$proto" = "http" ] && [ "$priv" = "public" ]; then
        echo "  port 8080 : protocol=${proto}  visibility=${priv} ✓"
      else
        echo "  port 8080 : protocol=${proto}  visibility=${priv} ← expected http/public"
      fi
      echo ""
      echo "Public endpoints:"
      echo "  MCP quantum : $MCP_URL/quantum/mcp"
      echo "  MCP logs    : $MCP_URL/logs/mcp"
      break
    fi
    sleep 2
  done
fi

echo ""
./info.sh
echo "Logs  : docker compose --profile basic logs -f"
echo "Stop  : docker compose --profile basic down"
