#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# start.sh — decrypt .env and bring up the Docker Compose stack
# ---------------------------------------------------------------------------

# Ensure dotenvx is on PATH (installed by setup.sh)
export PATH="$HOME/.dotenvx/bin:$PATH"

if ! command -v dotenvx &>/dev/null; then
  echo "dotenvx not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -f .env ]; then
  echo ".env not found. Run ./setup.sh first."
  exit 1
fi

echo "Starting Check Point MCP proxy stack..."
exec dotenvx run -- docker compose up "$@"
