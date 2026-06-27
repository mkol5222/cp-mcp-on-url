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
  echo "  3. Run this script again"
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
    grep -E "^${var}=" .env.oauth | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
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
      _set_oauth_var MCP_BASE_URL "$MCP_URL"
      echo "  POCKET_ID_URL       → $POCKET_URL"
      echo "  OAUTH2_REDIRECT_URL → $REDIRECT_URL"
      echo "  MCP_BASE_URL        → $MCP_URL"
      echo ""
    fi
  else
    echo "Codespace detected — .env.oauth URLs already match this session."
    echo ""
  fi
fi

# ---------------------------------------------------------------------------
# Helpers: port checking and waiting
# ---------------------------------------------------------------------------
_check_port() {
  local port="$1" json="$2"
  local proto priv
  proto=$(echo "$json" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const p=d.find(x=>x.sourcePort===${port});
console.log(p ? p.protocol : '?');
" 2>/dev/null || echo "?")
  priv=$(echo "$json" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const p=d.find(x=>x.sourcePort===${port});
console.log(p ? p.privacy : '?');
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
    [ $((i % 15)) -eq 0 ] && echo "  still waiting... (${i}s elapsed)"
    sleep 2
  done
  echo "  Warning: ${label} did not respond after $((max_iterations * 2))s"
  return 1
}

# ---------------------------------------------------------------------------
# Pocket ID: create/update OIDC client via static API key
# ---------------------------------------------------------------------------
# Pocket ID API (v2):
#   GET  /api/oidc/clients            → list (data[], pagination)
#   POST /api/oidc/clients            → create {name, callbackUrls, isPublic, pkceEnabled}
#   PUT  /api/oidc/clients/{id}       → update
#   POST /api/oidc/clients/{id}/secret → generate secret, returns {secret}
# Auth: X-Api-Key header
# Note: the `id` UUID from create IS the OAuth client_id used by oauth2-proxy
_setup_pocket_id_client() {
  local pocket_base="http://localhost:1411"
  local api_key; api_key=$(_read_oauth_var POCKET_ID_STATIC_API_KEY)
  local redirect_url; redirect_url=$(_read_oauth_var OAUTH2_REDIRECT_URL)
  local current_secret; current_secret=$(_read_oauth_var OIDC_CLIENT_SECRET)
  local client_name="mcpproxy"

  echo ""
  echo "Configuring Pocket ID OIDC client..."

  if [ -z "$api_key" ]; then
    echo "  Warning: POCKET_ID_STATIC_API_KEY not set — skipping automated OIDC client setup."
    echo "  Create the OIDC client manually at: ${pocket_base:-http://localhost:1411}"
    return 1
  fi

  # List existing clients
  local list_resp
  list_resp=$(curl -s -H "X-Api-Key: ${api_key}" "${pocket_base}/api/oidc/clients" 2>/dev/null || echo '{"data":[]}')

  local existing_id existing_callback
  existing_id=$(echo "$list_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const items=Array.isArray(d)?d:(d.data||[]);
const c=items.find(x=>x.name==='${client_name}');
if(c)process.stdout.write(c.id);
" 2>/dev/null || echo "")

  if [ -n "$existing_id" ]; then
    echo "  Client '${client_name}' already exists (id=${existing_id})"

    # Update redirect URL if it changed
    existing_callback=$(echo "$list_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const items=Array.isArray(d)?d:(d.data||[]);
const c=items.find(x=>x.name==='${client_name}');
const urls=c?(c.callbackURLs||c.callbackUrls||[]):[];
if(urls.length)process.stdout.write(urls[0]);
" 2>/dev/null || echo "")

    if [ -n "$redirect_url" ] && [ "$existing_callback" != "$redirect_url" ]; then
      echo "  Redirect URL changed — updating to: ${redirect_url}"
      curl -s -X PUT \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${client_name}\",\"callbackUrls\":[\"${redirect_url}\"],\"isPublic\":false,\"pkceEnabled\":false,\"logoutCallbackUrls\":[]}" \
        "${pocket_base}/api/oidc/clients/${existing_id}" >/dev/null
    fi

    # Save client_id (the UUID is the OAuth client_id)
    _set_oauth_var OIDC_CLIENT_ID "${existing_id}"

    # If secret is a placeholder or empty, regenerate it
    local placeholder="this-is-a-secret-please-change-me-if-you-care"
    if [ -z "$current_secret" ] || [ "$current_secret" = "$placeholder" ]; then
      echo "  Generating new client secret..."
      local secret_resp new_secret
      secret_resp=$(curl -s -X POST \
        -H "X-Api-Key: ${api_key}" \
        "${pocket_base}/api/oidc/clients/${existing_id}/secret" 2>/dev/null || echo '{}')
      new_secret=$(echo "$secret_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
if(d.secret)process.stdout.write(d.secret);
" 2>/dev/null || echo "")
      if [ -n "$new_secret" ]; then
        _set_oauth_var OIDC_CLIENT_SECRET "${new_secret}"
        echo "  New client secret saved to .env.oauth"
      else
        echo "  Warning: Could not generate secret. Response: ${secret_resp}"
      fi
    else
      echo "  Client secret already set in .env.oauth"
    fi
    return 0
  fi

  # Create new OIDC client
  echo "  Creating OIDC client '${client_name}'..."
  local create_resp new_id
  create_resp=$(curl -s -X POST \
    -H "X-Api-Key: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${client_name}\",\"callbackUrls\":[\"${redirect_url}\"],\"isPublic\":false,\"pkceEnabled\":false,\"logoutCallbackUrls\":[]}" \
    "${pocket_base}/api/oidc/clients" 2>/dev/null || echo '{}')

  new_id=$(echo "$create_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
if(d.id)process.stdout.write(d.id);
" 2>/dev/null || echo "")

  if [ -z "$new_id" ]; then
    echo "  Warning: Failed to create OIDC client."
    echo "  Response: ${create_resp}"
    echo "  Please create the client manually at: ${pocket_base}"
    return 1
  fi

  # Generate client secret
  local secret_resp new_secret
  secret_resp=$(curl -s -X POST \
    -H "X-Api-Key: ${api_key}" \
    "${pocket_base}/api/oidc/clients/${new_id}/secret" 2>/dev/null || echo '{}')
  new_secret=$(echo "$secret_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
if(d.secret)process.stdout.write(d.secret);
" 2>/dev/null || echo "")

  echo "  Created: client_id=${new_id}"
  _set_oauth_var OIDC_CLIENT_ID "${new_id}"

  if [ -n "$new_secret" ]; then
    _set_oauth_var OIDC_CLIENT_SECRET "${new_secret}"
    echo "  Client secret saved to .env.oauth"
  else
    echo "  Warning: Could not generate client secret. Response: ${secret_resp}"
    echo "  Regenerate via: curl -s -X POST -H 'X-Api-Key: <key>' http://localhost:1411/api/oidc/clients/${new_id}/secret"
  fi
}

# ---------------------------------------------------------------------------
# Stage 1: Bring down any running containers, start Pocket ID only
# ---------------------------------------------------------------------------
echo "Bringing down any running containers (both profiles)..."
dotenvx run -f .env.oauth -- docker compose --profile basic down --remove-orphans 2>/dev/null || true
dotenvx run -f .env.oauth -- docker compose --profile oauth down --remove-orphans 2>/dev/null || true

echo ""
echo "Stage 1: Starting Pocket ID..."
dotenvx run -f .env.oauth -- docker compose --profile oauth up -d pocket-id

# Wait for Pocket ID to be ready (first run initializes the database)
_wait_for_port 1411 "pocket-id" 90 || {
  echo "Pocket ID did not start. Check logs: docker compose --profile oauth logs pocket-id"
  exit 1
}

# Set port 1411 public in Codespaces
if $IN_CODESPACES && command -v gh &>/dev/null; then
  gh codespace ports visibility 1411:public -c "$CODESPACE_NAME" 2>/dev/null || true
fi

# Create / verify the OIDC client in Pocket ID using the static API key
_setup_pocket_id_client

# Ensure a public PKCE client exists for direct MCP tool clients (VS Code, Claude Desktop…)
_setup_mcp_tool_client() {
  local pocket_base="http://localhost:1411"
  local api_key; api_key=$(_read_oauth_var POCKET_ID_STATIC_API_KEY)
  local client_name="mcp-tool-client"

  [ -z "$api_key" ] && return 0

  local list_resp existing_id
  list_resp=$(curl -s -H "X-Api-Key: ${api_key}" "${pocket_base}/api/oidc/clients" 2>/dev/null || echo '{"data":[]}')
  existing_id=$(echo "$list_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const items=Array.isArray(d)?d:(d.data||[]);
const c=items.find(x=>x.name==='${client_name}');
if(c)process.stdout.write(c.id);
" 2>/dev/null || echo "")

  if [ -n "$existing_id" ]; then
    echo "  Public MCP tool client already exists (id=${existing_id})"
    _set_oauth_var MCP_TOOL_CLIENT_ID "${existing_id}"
    return 0
  fi

  echo "  Creating public PKCE client '${client_name}' for MCP tools..."
  local resp new_id
  resp=$(curl -s -X POST \
    -H "X-Api-Key: ${api_key}" \
    -H "Content-Type: application/json" \
    -d '{"name":"mcp-tool-client","callbackUrls":["http://localhost","http://localhost:3000/callback","http://localhost:8085/callback","http://127.0.0.1","http://127.0.0.1:3000/callback","http://127.0.0.1:8085/callback"],"isPublic":true,"pkceEnabled":true,"logoutCallbackUrls":[]}' \
    "${pocket_base}/api/oidc/clients" 2>/dev/null || echo '{}')
  new_id=$(echo "$resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
if(d.id)process.stdout.write(d.id);
" 2>/dev/null || echo "")
  if [ -n "$new_id" ]; then
    _set_oauth_var MCP_TOOL_CLIENT_ID "${new_id}"
    echo "  Created: client_id=${new_id}  (public, PKCE, no secret needed)"
  else
    echo "  Warning: could not create mcp-tool-client. Response: ${resp}"
  fi
}
_setup_mcp_tool_client

# Ensure the admin user has a real email marked as verified so MCP clients accept the token.
# Pocket ID passkey signup sets email_verified=false and uses a placeholder domain.
_fix_admin_email() {
  local pocket_base="http://localhost:1411"
  local api_key; api_key=$(_read_oauth_var POCKET_ID_STATIC_API_KEY)
  [ -z "$api_key" ] && return 0

  local users_resp
  users_resp=$(curl -s -H "X-Api-Key: ${api_key}" "${pocket_base}/api/users" 2>/dev/null || echo '{"data":[]}')

  echo "$users_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const users=(d.data||[]).filter(u=>!u.email||u.email.endsWith('@nowhere.local')||u.emailVerified===false);
if(users.length===0){process.stdout.write('ok');return;}
users.forEach(u=>process.stdout.write(u.id+'|'+u.username+'|'+(u.email||'')+'|'+(u.firstName||'')+'|'+(u.lastName||'')+'|'+(u.isAdmin?'1':'0')+'\n'));
" 2>/dev/null | while IFS='|' read -r uid uname email fn ln isadmin; do
    if [ -z "$uid" ] || [ "$uid" = "ok" ]; then continue; fi
    if [ "${email:-}" != "ok" ] && (echo "${email:-}" | grep -q "@nowhere.local" || [ -z "${email:-}" ]); then
      echo "  User '${uname}' has placeholder email '${email:-<none>}'"
      echo "  → Update email via Pocket ID admin: ${pocket_base}/admin/users/${uid}"
    else
      # Has a real email but emailVerified=false — mark it verified
      curl -s -X PUT \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${uname}\",\"email\":\"${email}\",\"emailVerified\":true,\"firstName\":\"${fn}\",\"lastName\":\"${ln}\",\"isAdmin\":$([ "$isadmin" = "1" ] && echo true || echo false),\"locale\":null}" \
        "${pocket_base}/api/users/${uid}" >/dev/null 2>&1 && \
        echo "  User '${uname}': emailVerified set to true for ${email}"
    fi
  done
}
_fix_admin_email

# ---------------------------------------------------------------------------
# Stage 2: Start the rest of the OAuth stack with updated credentials
# ---------------------------------------------------------------------------
echo ""
echo "Stage 2: Starting OAuth proxy and Caddy..."
dotenvx run -f .env.oauth -- docker compose --profile oauth up -d "$@"

# ---------------------------------------------------------------------------
# Codespaces: wait for Caddy, then set port visibility and verify
# ---------------------------------------------------------------------------
if $IN_CODESPACES && command -v gh &>/dev/null; then
  echo ""
  _wait_for_port 8080 "Caddy" 20 && \
    gh codespace ports visibility 8080:public -c "$CODESPACE_NAME" 2>/dev/null || true

  PORTS_JSON=$(gh codespace ports --json sourcePort,privacy,protocol -c "$CODESPACE_NAME" 2>/dev/null || echo "[]")
  _check_port 8080 "$PORTS_JSON"
  _check_port 1411 "$PORTS_JSON"
  echo ""
fi

echo ""
./info-oauth.sh
echo "Logs  : docker compose --profile oauth logs -f"
echo "Stop  : docker compose --profile oauth down"
