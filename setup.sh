#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup.sh — first-time setup: install Node, dotenvx, populate and encrypt .env
# ---------------------------------------------------------------------------

# 1. Install Node.js LTS if not already present
if ! command -v node &>/dev/null; then
  echo "Installing Node.js LTS..."
  mkdir -p "$HOME/.local"
  curl -sL https://install-node.vercel.app/lts | PREFIX="$HOME/.local" bash -s -- --yes
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "node $(node --version)  /  npm $(npm --version)"
echo ""

# 2. Install dotenvx if not already present
if ! command -v dotenvx &>/dev/null; then
  echo "Installing dotenvx..."
  mkdir -p "$HOME/.local/bin"
  curl -sfS "https://dotenvx.sh?directory=$HOME/.local/bin" | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "dotenvx $(dotenvx --version)"
echo ""

# 2. Prompt helper — re-asks until a non-empty value is given.
#    Usage: prompt_var VAR_NAME "Display label" [secret]
prompt_var() {
  local var="$1"
  local label="$2"
  local secret="${3:-}"
  local value=""

  # If already set in .env and not a placeholder, offer to keep it
  if [ -f .env ]; then
    existing=$(dotenvx get "$var" 2>/dev/null || true)
    if [ -n "$existing" ] && [[ "$existing" != *"your_"* ]] && [[ "$existing" != "change-me" ]]; then
      if [ -n "$secret" ]; then
        echo "$label [current: ****]: "
      else
        echo "$label [current: $existing]: "
      fi
      read -r value
      if [ -z "$value" ]; then
        return  # keep existing
      fi
      dotenvx set "$var" "$value" >/dev/null
      return
    fi
  fi

  while [ -z "$value" ]; do
    if [ -n "$secret" ]; then
      read -rsp "$label: " value
      echo
    else
      read -rp "$label: " value
    fi
    if [ -z "$value" ]; then
      echo "  Value cannot be empty, please try again."
    fi
  done

  dotenvx set "$var" "$value" >/dev/null
}

# 3. Interactively populate all required variables
echo "Configure your Check Point MCP proxy"
echo "-------------------------------------"
echo ""

prompt_var API_KEY      "S1C API key" secret
prompt_var S1C_URL      "S1C tenant web-API URL (ending in /web_api/)"
prompt_var PROXY_API_KEY "Proxy API key (X-Api-Key callers must supply)" secret

# 4. Encrypt .env with dotenvx
echo ""
echo "Encrypting .env..."
dotenvx encrypt

echo ""
echo "Setup complete. .env is encrypted."
echo "The decryption key is stored in .env.keys — keep it secret and do NOT commit it."
echo ""
echo "To start the stack:"
echo "  ./start.sh"
