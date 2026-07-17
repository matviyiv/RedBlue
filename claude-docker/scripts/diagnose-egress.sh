#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# diagnose-egress.sh — Find out what the egress allowlist proxy permits/blocks.
#
# Use this when a session dies with:
#   "Unable to connect to Anthropic services / ERR_SOCKET_CLOSED"
#
# It starts ONLY the egress-proxy (detached, so nothing tears it down), prints
# the allowlist as the running container actually sees it, probes a set of hosts
# *through* the proxy using the same env the CLI uses, and dumps the proxy logs.
# claude-cli is never started, so there is no crashing container to race against.
#
# Usage:
#   ./scripts/diagnose-egress.sh                 # probe the default host set
#   ./scripts/diagnose-egress.sh example.org …   # also probe extra hosts
#
# The proxy is left running afterwards so you can inspect it further:
#   docker compose logs -f egress-proxy
#   docker compose rm -sf egress-proxy           # stop it when done
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"; GREEN="\033[0;32m"; RED="\033[0;31m"
YELLOW="\033[0;33m"; CYAN="\033[0;36m"; RESET="\033[0m"

# Run from the compose project root regardless of where we're invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Hosts to probe: the ones Claude Code needs, plus a couple that MUST be blocked
# (example.com, a LAN address) as negative controls. Extra args are appended.
HOSTS=(platform.claude.com api.anthropic.com console.anthropic.com \
       statsig.anthropic.com claude.ai github.com \
       example.com "$@")

echo -e "${BOLD}${CYAN}Egress proxy diagnostics${RESET}\n"

# ── 1. Build + start ONLY the proxy, detached so it survives this script ──────
echo -e "${BOLD}[1/4] (Re)building and starting egress-proxy...${RESET}"
docker compose up -d --build --force-recreate egress-proxy

# ── 2. Show the active allowlist as the RUNNING container sees it ─────────────
# (This is the mounted proxy/filter — if a host you expect is missing here, the
#  running proxy is stale or your working copy is out of date.)
echo -e "\n${BOLD}[2/4] Active allowlist patterns inside the running proxy:${RESET}"
docker compose exec -T egress-proxy \
  sh -c 'grep -vE "^[[:space:]]*#|^[[:space:]]*$" /etc/tinyproxy/filter' \
  | sed 's/^/  /'

# ── 3. Probe each host THROUGH the proxy, with the CLI's proxy env ───────────
# Any HTTP status = the CONNECT tunnel was allowed (server answered). A curl
# error / 000 = the proxy refused the tunnel (filtered) and closed the socket —
# exactly what surfaces in Claude Code as ERR_SOCKET_CLOSED.
echo -e "\n${BOLD}[3/4] Probing hosts through the proxy (ALLOW = tunnel opened):${RESET}"
docker compose run --rm --no-deps --entrypoint sh claude-cli -c '
  for h in '"${HOSTS[*]}"'; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 8 "https://$h/" 2>/tmp/err) || code="ERR"
    if [ "$code" = "ERR" ] || [ "$code" = "000" ]; then
      printf "  \033[0;31mBLOCKED\033[0m %-26s %s\n" "$h" "$(tr "\n" " " </tmp/err | tail -c 90)"
    else
      printf "  \033[0;32mALLOW  \033[0m %-26s HTTP %s\n" "$h" "$code"
    fi
  done
'

# ── 4. Recent proxy logs — filter denials show up here ───────────────────────
echo -e "\n${BOLD}[4/4] Recent egress-proxy logs (look for 'Filtered'/'refused'):${RESET}"
docker compose logs --no-log-prefix --tail 60 egress-proxy | sed 's/^/  /'

echo ""
echo -e "${YELLOW}Proxy left running so you can keep inspecting it:${RESET}"
echo -e "  ${BOLD}docker compose logs -f egress-proxy${RESET}   # follow live"
echo -e "  ${BOLD}docker compose rm -sf egress-proxy${RESET}    # stop it when done"
echo ""
echo -e "${BOLD}Reading the result:${RESET}"
echo -e "  • ${GREEN}platform.claude.com = ALLOW${RESET}, but Claude still fails → likely an"
echo -e "    account/region issue, not the proxy (see the supported-countries link)."
echo -e "  • ${RED}platform.claude.com = BLOCKED${RESET} → the allowlist in step [2] is missing"
echo -e "    'claude.com'. Update proxy/filter and re-run this script."
echo -e "  • ${RED}example.com = ALLOW${RESET} → the filter isn't being applied at all"
echo -e "    (check FilterDefaultDeny / that proxy/filter is mounted)."
