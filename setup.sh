#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup.sh — first-time setup: install dotenvx, create and encrypt .env
# ---------------------------------------------------------------------------

# 1. Install dotenvx if not already present
if ! command -v dotenvx &>/dev/null; then
  echo "Installing dotenvx..."
  curl -sfS https://dotenvx.sh | sh
  # Ensure the installed binary is on PATH for the rest of this script
  export PATH="$HOME/.dotenvx/bin:$PATH"
fi

echo "dotenvx $(dotenvx --version)"

# 2. Create .env from example if it does not exist yet
if [ ! -f .env ]; then
  cp .env.example .env
  echo ""
  echo "Created .env from .env.example."
  echo "Edit .env and fill in API_KEY, S1C_URL, and PROXY_API_KEY, then re-run this script."
  exit 0
fi

# 3. Verify the required variables have been filled in
missing=()
for var in API_KEY S1C_URL PROXY_API_KEY; do
  value=$(grep -E "^${var}=" .env | cut -d= -f2-)
  if [ -z "$value" ] || [[ "$value" == *"your_"* ]] || [[ "$value" == "change-me" ]]; then
    missing+=("$var")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo ""
  echo "ERROR: The following variables in .env still have placeholder values:"
  for v in "${missing[@]}"; do echo "  - $v"; done
  echo ""
  echo "Edit .env, set real values, then re-run setup.sh."
  exit 1
fi

# 4. Encrypt .env with dotenvx
echo ""
echo "Encrypting .env with dotenvx..."
dotenvx encrypt

echo ""
echo "Setup complete. .env is encrypted."
echo "The decryption key is stored in .env.keys — keep it secret and do NOT commit it."
echo ""
echo "To start the stack:"
echo "  ./start.sh"
