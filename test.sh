#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Colors & icons
# ---------------------------------------------------------------------------
RESET="\033[0m"
BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
DIM="\033[2m"

OK="${GREEN}✔${RESET}"
FAIL="${RED}✖${RESET}"
ARROW="${CYAN}▶${RESET}"
TOOL_ICON="🔧"

pass() { echo -e " ${OK}  $*"; }
fail() { echo -e " ${FAIL}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }
subheader() { echo -e "\n${BOLD}$*${RESET}"; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v dotenvx &>/dev/null; then
  fail "dotenvx not found — run ./setup.sh first"
  exit 1
fi
if [ ! -f .env ]; then
  fail ".env not found — run ./setup.sh first"
  exit 1
fi

PROXY_API_KEY=$(dotenvx get PROXY_API_KEY 2>/dev/null)

if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  BASE_URL="https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
else
  BASE_URL="http://localhost:8080"
fi

ERRORS=0

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}Check Point MCP Proxy — test suite${RESET}"
echo -e "${DIM}${BASE_URL}${RESET}"

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------
header "Health checks"

check_health() {
  local label="$1"
  local path="$2"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-Api-Key: $PROXY_API_KEY" "${BASE_URL}${path}")
  if [ "$http_code" = "200" ]; then
    pass "${label}  ${DIM}(HTTP ${http_code})${RESET}"
  else
    fail "${label}  ${DIM}(HTTP ${http_code})${RESET}"
    (( ERRORS++ )) || true
  fi
}

check_health "quantum-management-mcp" /quantum/health
check_health "management-logs-mcp   " /logs/health

# ---------------------------------------------------------------------------
# Auth guard check
# ---------------------------------------------------------------------------
header "Auth guard"

unauth_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/quantum/health")
if [ "$unauth_code" = "401" ]; then
  pass "Request without X-Api-Key header is rejected  ${DIM}(HTTP 401)${RESET}"
else
  fail "Expected HTTP 401 without X-Api-Key, got ${unauth_code}"
  (( ERRORS++ )) || true
fi

# ---------------------------------------------------------------------------
# Tool listing helper
# ---------------------------------------------------------------------------
list_tools() {
  local label="$1"
  local mcp_url="$2"

  subheader "${ARROW} ${label}"

  local output
  if ! output=$(npx -y @modelcontextprotocol/inspector --cli -- \
      "$mcp_url" \
      --header "X-Api-Key: $PROXY_API_KEY" \
      --method tools/list 2>/dev/null); then
    fail "Could not reach ${mcp_url}"
    (( ERRORS++ )) || true
    return
  fi

  # Parse tool names and descriptions with jq if available, else basic grep
  if command -v jq &>/dev/null; then
    local count
    count=$(echo "$output" | jq '.tools | length')
    echo -e "   ${GREEN}${count} tools available${RESET}\n"
    while IFS=$'\t' read -r name desc; do
      echo -e "   ${TOOL_ICON} ${BOLD}${name}${RESET}"
      echo -e "      ${DIM}${desc}${RESET}\n"
    done < <(echo "$output" | jq -r '.tools[] | [.name, (.description | split(".")[0])] | @tsv')
  else
    echo "$output" | grep -o '"name":"[^"]*"' | sed "s/\"name\":\"/${TOOL_ICON}  /;s/\"//"
  fi

  pass "${label} tool list  ${DIM}($(echo "$output" | jq '.tools | length' 2>/dev/null || echo '?') tools)${RESET}"
}

# ---------------------------------------------------------------------------
# Tool lists
# ---------------------------------------------------------------------------
header "Available tools"

list_tools "quantum-management-mcp" "${BASE_URL}/quantum/mcp"
list_tools "management-logs-mcp"    "${BASE_URL}/logs/mcp"

# ---------------------------------------------------------------------------
# Generate .mcp.json
# ---------------------------------------------------------------------------
header "VS Code MCP configuration"

cat > .mcp.json <<EOF
{
  "mcpServers": {
    "quantum-management": {
      "type": "http",
      "url": "$BASE_URL/quantum/mcp",
      "headers": { "X-Api-Key": "$PROXY_API_KEY" }
    },
    "management-logs": {
      "type": "http",
      "url": "$BASE_URL/logs/mcp",
      "headers": { "X-Api-Key": "$PROXY_API_KEY" }
    }
  }
}
EOF

pass ".mcp.json written  ${DIM}($(pwd)/.mcp.json)${RESET}"

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
echo -e "${BOLD}Try it in VS Code GitHub Copilot chat:${RESET}"
echo -e "  1. Open ${CYAN}.mcp.json${RESET} in the editor (it is already in the workspace root)"
echo -e "  2. Click ${BOLD}\"Start\"${RESET} in the MCP servers notification, or open the"
echo -e "     GitHub Copilot chat panel and switch to ${BOLD}Agent${RESET} mode"
echo -e "  3. Ask: ${YELLOW}\"Initialize the quantum management MCP and list available gateways\"${RESET}"
echo ""

[ "$ERRORS" -eq 0 ] || exit 1
