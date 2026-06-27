#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# start-oauth.sh — bring up the OAuth stack (docker compose --profile oauth)
# ---------------------------------------------------------------------------

export PATH="$HOME/.dotenvx/bin:$HOME/.local/bin:$PATH"

if ! command -v dotenvx &>/dev/null; then
  echo "dotenvx not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -f .env.oauth ]; then
  echo ".env.oauth not found."
  echo ""
  echo "To set up OAuth with Pocket ID:"
  echo "  1. Copy .env.oauth.example to .env.oauth"
  echo "  2. Fill in the values (see OAUTH-SETUP.md for details)"
  echo "  3. Encrypt with: dotenvx encrypt -f .env.oauth"
  echo "  4. Run this script again"
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers: read/write .env.oauth (handles both plaintext and encrypted files)
# ---------------------------------------------------------------------------
_is_encrypted() {
  grep -q "^DOTENV_PUBLIC_KEY" .env.oauth 2>/dev/null
}

_read_oauth_var() {
  local var="$1"
  if _is_encrypted; then
    dotenvx get "$var" -f .env.oauth 2>/dev/null || true
  else
    grep -E "^${var}=" .env.oauth | head -1 | cut -d= -f2- | tr -d '"' || true
  fi
}

_set_oauth_var() {
  local var="$1" value="$2"
  if _is_encrypted; then
    dotenvx set "${var}=${value}" -f .env.oauth >/dev/null
  else
    if grep -qE "^${var}=" .env.oauth; then
      sed -i "s|^${var}=.*|${var}=${value}|" .env.oauth
    else
      printf '\n%s=%s\n' "$var" "$value" >> .env.oauth
    fi
  fi
}

# ---------------------------------------------------------------------------
# Codespaces: detect public URLs and patch .env.oauth if needed
# ---------------------------------------------------------------------------
IN_CODESPACES=false
POCKET_URL=""
MCP_URL=""
REDIRECT_URL=""

if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  IN_CODESPACES=true
  POCKET_URL="https://${CODESPACE_NAME}-1411.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  MCP_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  REDIRECT_URL="${MCP_URL}/oauth2/callback"

  CURRENT_POCKET=$(_read_oauth_var POCKET_ID_URL)
  CURRENT_REDIRECT=$(_read_oauth_var OAUTH2_REDIRECT_URL)
  CURRENT_POCKET="${CURRENT_POCKET%/}"
  CURRENT_REDIRECT="${CURRENT_REDIRECT%/}"

  if [ "$CURRENT_POCKET" != "$POCKET_URL" ] || [ "$CURRENT_REDIRECT" != "$REDIRECT_URL" ]; then
    echo "Codespace detected — public URLs for this session:"
    echo "  Pocket ID (port 1411) : $POCKET_URL"
    echo "  MCP proxy (port 8080) : $MCP_URL"
    echo "  OAuth callback        : $REDIRECT_URL"
    echo ""
    echo "Current .env.oauth:"
    echo "  POCKET_ID_URL       = ${CURRENT_POCKET:-<not set>}"
    echo "  OAUTH2_REDIRECT_URL = ${CURRENT_REDIRECT:-<not set>}"
    echo ""
    read -rp "Update .env.oauth with Codespace URLs? [Y/n] " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy] ]]; then
      _set_oauth_var POCKET_ID_URL "$POCKET_URL"
      _set_oauth_var OAUTH2_REDIRECT_URL "$REDIRECT_URL"
      echo "  POCKET_ID_URL       → $POCKET_URL"
      echo "  OAUTH2_REDIRECT_URL → $REDIRECT_URL"
      echo ""
    fi
  else
    echo "Codespace detected — .env.oauth URLs already match this session."
    echo ""
  fi
fi

# ---------------------------------------------------------------------------
# Start the OAuth stack — bring down first for a clean start
# ---------------------------------------------------------------------------
echo "Bringing down any running containers (both profiles)..."
dotenvx run -f .env.oauth -- docker compose --profile basic down --remove-orphans 2>/dev/null || true
dotenvx run -f .env.oauth -- docker compose --profile oauth down --remove-orphans 2>/dev/null || true

echo "Starting Check Point MCP proxy stack with OAuth..."
dotenvx run -f .env.oauth -- \
  docker compose --profile oauth up -d "$@"

# ---------------------------------------------------------------------------
# Codespaces: wait for ports to be listening, then set public + verify
# ---------------------------------------------------------------------------
# gh codespace ports --json fields: sourcePort, privacy (public/private/org), protocol (http/https)
_check_port() {
  local port="$1" json="$2"
  local proto priv
  proto=$(echo "$json" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    if p.get('sourcePort') == ${port}:
        print(p.get('protocol','?'))
        break
" 2>/dev/null || echo "?")
  priv=$(echo "$json" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    if p.get('sourcePort') == ${port}:
        print(p.get('privacy','?'))
        break
" 2>/dev/null || echo "?")
  if [ "$proto" = "http" ] && [ "$priv" = "public" ]; then
    echo "  port ${port} : protocol=${proto}  visibility=${priv} ✓"
  else
    echo "  port ${port} : protocol=${proto}  visibility=${priv} ← expected http/public"
  fi
}

_wait_for_port() {
  local port="$1" label="$2" max_iterations="$3"
  echo "Waiting for ${label} (port ${port})..."
  for i in $(seq 1 "$max_iterations"); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:${port}" 2>/dev/null || echo "000")
    if [ "$CODE" != "000" ]; then
      echo "  ${label} is ready (HTTP ${CODE})"
      return 0
    fi
    [ $((i % 15)) -eq 0 ] && echo "  still waiting... (${i}s elapsed — first run initialises database)"
    sleep 2
  done
  echo "  Warning: ${label} did not respond after $((max_iterations * 2))s"
  echo "  Check logs: docker compose --profile oauth logs ${label,,}"
  return 1
}

if $IN_CODESPACES && command -v gh &>/dev/null; then
  echo ""
  _wait_for_port 8080 "Caddy" 20 && \
    gh codespace ports visibility 8080:public -c "$CODESPACE_NAME" 2>/dev/null || true

  _wait_for_port 1411 "pocket-id" 90  # up to 3 min — first run needs DB init
  POCKET_READY=$?

  if [ $POCKET_READY -eq 0 ]; then
    gh codespace ports visibility 1411:public -c "$CODESPACE_NAME" 2>/dev/null || true
  fi

  PORTS_JSON=$(gh codespace ports --json sourcePort,privacy,protocol -c "$CODESPACE_NAME" 2>/dev/null || echo "[]")
  _check_port 8080 "$PORTS_JSON"
  _check_port 1411 "$PORTS_JSON"
  echo ""

  if [ $POCKET_READY -ne 0 ]; then
    echo "  Pocket ID is not yet reachable — check logs and retry:"
    echo "    docker compose --profile oauth logs pocket-id"
    echo ""
  fi
fi

echo ""
./info-oauth.sh
echo "Logs  : docker compose --profile oauth logs -f"
echo "Stop  : docker compose --profile oauth down"
