#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.dotenvx/bin:$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Colors & helpers
# ---------------------------------------------------------------------------
RESET="\033[0m"; BOLD="\033[1m"
GREEN="\033[0;32m"; RED="\033[0;31m"; CYAN="\033[0;36m"
YELLOW="\033[0;33m"; DIM="\033[2m"

OK="${GREEN}✔${RESET}"; FAIL="${RED}✖${RESET}"; SKIP="${YELLOW}–${RESET}"

pass()   { echo -e " ${OK}  $*"; }
fail()   { echo -e " ${FAIL}  $*"; (( ERRORS++ )) || true; }
skip()   { echo -e " ${SKIP}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }

ERRORS=0

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
header "Prerequisites"

if ! command -v dotenvx &>/dev/null; then
  fail "dotenvx not found — run ./setup.sh first"; exit 1
fi
pass "dotenvx found"

if [ ! -f .env.oauth ]; then
  fail ".env.oauth not found — run ./start-oauth.sh first"; exit 1
fi
pass ".env.oauth found"

# Load vars
PROXY_API_KEY=$(dotenvx get PROXY_API_KEY      -f .env.oauth 2>/dev/null || true)
POCKET_ID_URL=$(dotenvx get POCKET_ID_URL      -f .env.oauth 2>/dev/null || true)
MCP_TOOL_CLIENT_ID=$(dotenvx get MCP_TOOL_CLIENT_ID -f .env.oauth 2>/dev/null || true)
OIDC_CLIENT_ID=$(dotenvx get OIDC_CLIENT_ID    -f .env.oauth 2>/dev/null || true)
OIDC_CLIENT_SECRET=$(dotenvx get OIDC_CLIENT_SECRET -f .env.oauth 2>/dev/null || true)

if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  BASE_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
else
  BASE_URL="http://localhost:8080"
fi
POCKET_ID_URL="${POCKET_ID_URL:-http://localhost:1411}"

echo -e "   MCP proxy : ${CYAN}${BASE_URL}${RESET}"
echo -e "   Pocket ID : ${CYAN}${POCKET_ID_URL}${RESET}"

# Basic reachability
# _http: return HTTP status code; _body: return response body
# _resp: dump headers + body together (headers end at blank line), used for WWW-Authenticate parsing
_http() { curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$@" 2>/dev/null || echo "000"; }
_body() { curl -s                                --max-time 8 "$@" 2>/dev/null || echo ""; }
_resp() { curl -sD - --max-time 8 "$@" 2>/dev/null || echo ""; }  # headers + body

code=$(_http "${BASE_URL}/")
if [[ "$code" =~ ^[2-4] ]]; then
  pass "MCP proxy reachable  ${DIM}(HTTP ${code})${RESET}"
else
  fail "MCP proxy not reachable at ${BASE_URL}  ${DIM}(HTTP ${code})${RESET}"; exit 1
fi

# Pocket ID: any HTTP response (even 404) means it's up; connection failure = not running
code=$(_http "${POCKET_ID_URL}/api/application-configuration")
if [ "$code" != "000" ]; then
  pass "Pocket ID reachable  ${DIM}(HTTP ${code})${RESET}"
else
  fail "Pocket ID not reachable at ${POCKET_ID_URL}  ${DIM}(connection refused)${RESET}"
fi

# Wait for MCP backends + oauth2-proxy (backends download npm on first run)
echo -e "   ${DIM}Waiting for stack to be ready...${RESET}"
for i in $(seq 1 20); do
  logs_ok=$(_http -H "X-Api-Key: ${PROXY_API_KEY}" "${BASE_URL}/logs/health")
  qmgmt_ok=$(_http -H "X-Api-Key: ${PROXY_API_KEY}" "${BASE_URL}/quantum/health")
  # oauth2-proxy: /oauth2/auth with no credentials → 401 means it's up
  oauth_ok=$(_http "${BASE_URL}/oauth2/auth")
  [ "$logs_ok" = "200" ] && [ "$qmgmt_ok" = "200" ] && [ "$oauth_ok" != "000" ] && break
  [ $((i % 5)) -eq 0 ] && echo -e "   ${DIM}still waiting... (${i}/${20})${RESET}"
  sleep 3
done

# ---------------------------------------------------------------------------
# 1. OAuth discovery — unauthenticated, must not require auth
# ---------------------------------------------------------------------------
header "1. OAuth discovery (RFC 9728 / RFC 8414)"

_check_json_field() {
  local url="$1" field="$2" expected="$3" label="$4"
  local body; body=$(_body "$url")
  local got; got=$(echo "$body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const v=d['${field}'];
process.stdout.write(Array.isArray(v)?JSON.stringify(v):String(v||''));
" 2>/dev/null || echo "")
  if [ -n "$expected" ] && [ "$got" != "$expected" ]; then
    fail "${label}  ${DIM}${field}=${got} (expected ${expected})${RESET}"
  else
    pass "${label}  ${DIM}${field}=${got}${RESET}"
  fi
}

# Base resource metadata
body=$(_body "${BASE_URL}/.well-known/oauth-protected-resource")
code=$(_http "${BASE_URL}/.well-known/oauth-protected-resource")
[ "$code" = "200" ] && pass "/.well-known/oauth-protected-resource  ${DIM}(200)${RESET}" \
                     || fail "/.well-known/oauth-protected-resource  ${DIM}(${code})${RESET}"
echo "$body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const ok=f=>d[f]?'\033[2m'+f+'='+JSON.stringify(d[f]).slice(0,60)+'\033[0m':'MISSING:'+f;
console.log('     resource           :', d.resource||'MISSING');
console.log('     authorization_servers:', JSON.stringify(d.authorization_servers||[]));
console.log('     registration_endpoint:', d.registration_endpoint||'MISSING');
" 2>/dev/null || true

# Per-path resource metadata — resource field must match exact path (RFC 9728)
for path in logs/mcp quantum/mcp; do
  url="${BASE_URL}/.well-known/oauth-protected-resource/${path}"
  code=$(_http "$url")
  body=$(_body "$url")
  expected_resource="${BASE_URL}/${path}"
  got_resource=$(echo "$body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(d.resource||'');
" 2>/dev/null || echo "")
  reg=$(echo "$body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(d.registration_endpoint||'');
" 2>/dev/null || echo "")
  if [ "$code" = "200" ] && [ "$got_resource" = "$expected_resource" ] && [ -n "$reg" ]; then
    pass "/.well-known/oauth-protected-resource/${path}  ${DIM}resource matches, registration_endpoint present${RESET}"
  else
    fail "/.well-known/oauth-protected-resource/${path}  ${DIM}code=${code} resource=${got_resource} reg=${reg}${RESET}"
  fi
done

# Synthetic AS metadata (Pocket ID returns 404 for this; Caddy serves it)
code=$(_http "${BASE_URL}/.well-known/oauth-authorization-server")
body=$(_body "${BASE_URL}/.well-known/oauth-authorization-server")
if [ "$code" = "200" ]; then
  reg=$(echo "$body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(d.registration_endpoint||'');
" 2>/dev/null || echo "")
  auth=$(echo "$body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(d.authorization_endpoint||'');
" 2>/dev/null || echo "")
  if [ -n "$reg" ] && [ -n "$auth" ]; then
    pass "/.well-known/oauth-authorization-server  ${DIM}registration_endpoint + authorization_endpoint present${RESET}"
  else
    fail "/.well-known/oauth-authorization-server  ${DIM}missing fields: reg=${reg} auth=${auth}${RESET}"
  fi
else
  fail "/.well-known/oauth-authorization-server  ${DIM}(HTTP ${code})${RESET}"
fi

# ---------------------------------------------------------------------------
# 2. Dynamic Client Registration (RFC 7591)
# ---------------------------------------------------------------------------
header "2. Dynamic Client Registration (RFC 7591)"

dcr_body=$(_body -X POST "${BASE_URL}/oauth/register" \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://127.0.0.1:12345/"],"grant_types":["authorization_code"]}')
dcr_code=$(_http -X POST "${BASE_URL}/oauth/register" \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://127.0.0.1:12345/"],"grant_types":["authorization_code"]}')

got_client_id=$(echo "$dcr_body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(d.client_id||'');
" 2>/dev/null || echo "")
auth_method=$(echo "$dcr_body" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(d.token_endpoint_auth_method||'');
" 2>/dev/null || echo "")

if [ "$dcr_code" = "201" ] && [ -n "$got_client_id" ]; then
  pass "POST /oauth/register → 201  ${DIM}client_id=${got_client_id}  auth_method=${auth_method}${RESET}"
  if [ -n "$MCP_TOOL_CLIENT_ID" ] && [ "$got_client_id" = "$MCP_TOOL_CLIENT_ID" ]; then
    pass "Returned client_id matches MCP_TOOL_CLIENT_ID  ${DIM}(shared public PKCE client)${RESET}"
  else
    skip "MCP_TOOL_CLIENT_ID not set in .env.oauth — cannot verify client_id match"
  fi
else
  fail "POST /oauth/register  ${DIM}(HTTP ${dcr_code}, client_id=${got_client_id})${RESET}"
fi

# ---------------------------------------------------------------------------
# 3. Unauthenticated MCP access — must return 401 + WWW-Authenticate
# ---------------------------------------------------------------------------
header "3. Unauthenticated MCP access (RFC 9728 §5)"

for path in logs/mcp quantum/mcp; do
  full_resp=$(_resp -X POST "${BASE_URL}/${path}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}')
  code=$(echo "$full_resp" | head -1 | grep -o '[0-9]\{3\}' | head -1 || echo "000")
  www_auth=$(echo "$full_resp" | grep -i "^www-authenticate:" | head -1 | tr -d '\r' || echo "")

  if [ "$code" = "401" ] && echo "$www_auth" | grep -qi "resource_metadata"; then
    pass "/${path} unauthenticated → 401 + WWW-Authenticate with resource_metadata"
  elif [ "$code" = "401" ]; then
    fail "/${path} → 401 but WWW-Authenticate missing resource_metadata  ${DIM}(got: ${www_auth})${RESET}"
  else
    fail "/${path} unauthenticated → expected 401, got ${code}"
  fi
done

# ---------------------------------------------------------------------------
# 4. API key auth
# ---------------------------------------------------------------------------
header "4. API key auth (X-Api-Key)"

for path in logs/health quantum/health; do
  code=$(_http -H "X-Api-Key: ${PROXY_API_KEY}" "${BASE_URL}/${path}")
  [ "$code" = "200" ] \
    && pass "GET /${path}  ${DIM}(HTTP ${code})${RESET}" \
    || fail "GET /${path}  ${DIM}(HTTP ${code})${RESET}"
done

# MCP initialize via API key (raw JSON-RPC — no inspector needed)
for service in logs quantum; do
  path="${service}/mcp"
  resp=$(_body -X POST "${BASE_URL}/${path}" \
    -H "X-Api-Key: ${PROXY_API_KEY}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test-oauth.sh","version":"1"}}}')
  # SSE response: look for the result event
  if echo "$resp" | grep -q '"protocolVersion"'; then
    ver=$(echo "$resp" | grep -o '"protocolVersion":"[^"]*"' | head -1 | cut -d'"' -f4)
    srv=$(echo "$resp" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    pass "MCP initialize /${path}  ${DIM}server=${srv} protocol=${ver}${RESET}"
  else
    fail "MCP initialize /${path}  ${DIM}unexpected response: ${resp:0:120}${RESET}"
  fi
done

# Tool count via MCP inspector
echo ""
for service in logs quantum; do
  path="${service}/mcp"
  echo -e "   ${DIM}tools/list → ${BASE_URL}/${path}${RESET}"
  if tool_output=$(npx -y @modelcontextprotocol/inspector --cli -- \
      "${BASE_URL}/${path}" \
      --header "X-Api-Key: ${PROXY_API_KEY}" \
      --method tools/list 2>/dev/null); then
    count=$(echo "$tool_output" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(String((d.tools||[]).length));
" 2>/dev/null || echo "?")
    pass "tools/list /${path}  ${DIM}(${count} tools)${RESET}"
  else
    fail "tools/list /${path}  ${DIM}inspector error${RESET}"
  fi
done

# ---------------------------------------------------------------------------
# 5. Bearer token auth (client_credentials via mcpproxy confidential client)
# ---------------------------------------------------------------------------
header "5. Bearer token auth"

TOKEN_ENDPOINT="${POCKET_ID_URL}/api/oidc/token"
BEARER_TOKEN=""

if [ -n "$OIDC_CLIENT_ID" ] && [ -n "$OIDC_CLIENT_SECRET" ]; then
  tok_resp=$(_body -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${OIDC_CLIENT_ID}&client_secret=${OIDC_CLIENT_SECRET}&scope=openid")
  BEARER_TOKEN=$(echo "$tok_resp" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
process.stdout.write(d.access_token||'');
" 2>/dev/null || echo "")
fi

if [ -n "$BEARER_TOKEN" ]; then
  pass "Obtained Bearer token via client_credentials  ${DIM}(${BEARER_TOKEN:0:20}...)${RESET}"

  for service in logs quantum; do
    path="${service}/mcp"
    resp=$(_body -X POST "${BASE_URL}/${path}" \
      -H "Authorization: Bearer ${BEARER_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test-oauth.sh","version":"1"}}}')
    if echo "$resp" | grep -q '"protocolVersion"'; then
      pass "MCP initialize /${path} via Bearer token  ${DIM}✔${RESET}"
    else
      fail "MCP initialize /${path} via Bearer token  ${DIM}${resp:0:120}${RESET}"
    fi
  done
else
  skip "client_credentials grant not supported by Pocket ID — Bearer token test skipped"
  skip "To test Bearer auth manually: obtain a token via browser OAuth flow at:"
  echo -e "     ${DIM}${POCKET_ID_URL}/authorize?client_id=${MCP_TOOL_CLIENT_ID:-<mcp-tool-client-id>}&response_type=code&...${RESET}"
  echo -e "   ${DIM}Or use: npx @modelcontextprotocol/inspector ${BASE_URL}/logs/mcp  (OAuth flow in browser)${RESET}"
fi

# Invalid Bearer token must be rejected
full_resp=$(_resp -X POST "${BASE_URL}/logs/mcp" \
  -H "Authorization: Bearer invalid.token.here" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}')
code=$(echo "$full_resp" | head -1 | grep -o '[0-9]\{3\}' | head -1 || echo "000")
[ "$code" = "401" ] \
  && pass "Invalid Bearer token rejected  ${DIM}(HTTP 401)${RESET}" \
  || fail "Invalid Bearer token not rejected  ${DIM}(expected 401, got ${code})${RESET}"

# ---------------------------------------------------------------------------
# 6. Generate .mcp.json for OAuth mode
# ---------------------------------------------------------------------------
header "6. VS Code .mcp.json (OAuth mode)"

cat > .mcp.json.oauth <<EOF
{
  "mcpServers": {
    "quantum-management": {
      "type": "http",
      "url": "${BASE_URL}/quantum/mcp"
    },
    "management-logs": {
      "type": "http",
      "url": "${BASE_URL}/logs/mcp"
    }
  }
}
EOF
pass ".mcp.json.oauth written  ${DIM}(OAuth flow — no header needed, browser auth via Pocket ID)${RESET}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${BOLD}${GREEN} ✔  All checks passed${RESET}"
else
  echo -e "${BOLD}${RED} ✖  ${ERRORS} check(s) failed${RESET}"
fi

echo ""
echo -e "${BOLD}OAuth endpoints:${RESET}"
echo -e "  Register (DCR)       : POST ${CYAN}${BASE_URL}/oauth/register${RESET}"
echo -e "  Resource metadata    : GET  ${CYAN}${BASE_URL}/.well-known/oauth-protected-resource${RESET}"
echo -e "  AS metadata          : GET  ${CYAN}${BASE_URL}/.well-known/oauth-authorization-server${RESET}"
echo -e "  Pocket ID login      : ${CYAN}${POCKET_ID_URL}/authorize${RESET}"
echo ""

[ "$ERRORS" -eq 0 ] || exit 1
