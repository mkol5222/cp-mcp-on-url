#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup.sh — first-time setup: install Node, dotenvx, cloudflared, populate and encrypt .env
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

# 3. Install cloudflared if not already present
if ! command -v cloudflared &>/dev/null; then
  echo "Installing cloudflared..."
  mkdir -p "$HOME/.local/bin"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  CF_ARCH="amd64" ;;
    aarch64|arm64) CF_ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    -o "$HOME/.local/bin/cloudflared"
  chmod +x "$HOME/.local/bin/cloudflared"
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "cloudflared $(cloudflared --version | head -1)"
echo ""

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

# prompt_required VAR_NAME "label" [secret] — re-asks until non-empty
prompt_required() {
  local var="$1" label="$2" secret="${3:-}" value=""
  while [ -z "$value" ]; do
    if [ -n "$secret" ]; then
      read -rsp "$label: " value; echo
    else
      read -rp "$label: " value
    fi
    [ -z "$value" ] && echo "  Value cannot be empty, please try again."
  done
  dotenvx set "$var" "$value" >/dev/null
}

# prompt_optional VAR_NAME "label" [secret] — allows empty, returns value
prompt_optional() {
  local var="$1" label="$2" secret="${3:-}" value=""
  if [ -n "$secret" ]; then
    read -rsp "$label: " value; echo
  else
    read -rp "$label: " value
  fi
  dotenvx set "$var" "$value" >/dev/null
  echo "$value"
}

# set_var VAR_NAME value — silently set a variable
set_var() {
  dotenvx set "$1" "$2" >/dev/null
}

# ---------------------------------------------------------------------------
# 4. Interactively populate all required variables
# ---------------------------------------------------------------------------
echo "Configure your Check Point MCP proxy"
echo "-------------------------------------"
echo ""
echo "Choose configuration mode:"
echo "  1) Demo (cpman.duckdns.org with default credentials)"
echo "  2) Smart-1 Cloud (S1C)"
echo "  3) Local Management Server"
echo ""
read -rp "Selection [1/2/3]: " mode

case "$mode" in
  1)
    # Demo mode: cpman.duckdns.org with defaults
    echo ""
    echo "Using demo configuration:"
    echo "  MANAGEMENT_HOST = cpman.duckdns.org"
    echo "  USERNAME        = admin"
    echo "  PASSWORD        = demo123"
    set_var S1C_URL ""
    set_var API_KEY ""
    set_var MANAGEMENT_HOST "cpman.duckdns.org"
    set_var USERNAME "admin"
    set_var PASSWORD "demo123"
    ;;
  2)
    # S1C mode
    echo ""
    echo "Smart-1 Cloud configuration"
    prompt_required S1C_URL "S1C tenant web-API URL (ending in /web_api/)"
    prompt_required API_KEY "S1C API key" secret
    set_var MANAGEMENT_HOST ""
    set_var USERNAME ""
    set_var PASSWORD ""
    ;;
  3)
    # Local management mode
    echo ""
    echo "Local Management Server configuration"
    prompt_required MANAGEMENT_HOST "Management server hostname or IP"
    echo ""
    echo "Authentication: API key (recommended) or username/password"
    api_key=$(prompt_optional API_KEY "API key (press Enter to use username/password instead)" secret)
    if [ -z "$api_key" ]; then
      prompt_required USERNAME "Username"
      prompt_required PASSWORD "Password" secret
    else
      set_var USERNAME ""
      set_var PASSWORD ""
    fi
    set_var S1C_URL ""
    ;;
  *)
    echo "Invalid selection. Exiting."
    exit 1
    ;;
esac

echo ""
prompt_required PROXY_API_KEY "Proxy API key (X-Api-Key callers must supply)" secret

# 5. Encrypt .env with dotenvx
echo ""
echo "Encrypting .env..."
dotenvx encrypt

echo ""
echo "Setup complete. .env is encrypted."
echo "The decryption key is stored in .env.keys — keep it secret and do NOT commit it."
echo ""
echo "To start the stack:"
echo "  ./start.sh"
