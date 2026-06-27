#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# start-oauth.sh — decrypt .env.oauth and bring up OAuth Docker Compose stack
# ---------------------------------------------------------------------------

# Ensure dotenvx is on PATH (installed by setup.sh)
export PATH="$HOME/.dotenvx/bin:$PATH"

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

echo "Starting Check Point MCP proxy stack with OAuth..."
exec dotenvx run -f .env.oauth -- docker compose -f docker-compose.oauth.yml up "$@"
