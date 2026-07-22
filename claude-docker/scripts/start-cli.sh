#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-cli.sh — Start interactive Claude Code session (blue zone only)
# Usage: ./scripts/start-cli.sh            start a session (state persists)
#        ./scripts/start-cli.sh --clear    wipe persisted Claude state
#                                          (login, onboarding, session history)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

# Load the shared folder config (defines BLUE_ZONE_FOLDERS, BLUE_ZONE_ROOT,
# BLUE_ZONE_COMPOSE_FILE).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../blue-zone.config.sh
source "$SCRIPT_DIR/../blue-zone.config.sh"

if [ "${1:-}" = "--clear" ]; then
  echo -e "${BOLD}Clearing persisted Claude state (login, onboarding, sessions)...${RESET}"
  docker compose down --volumes --remove-orphans
  echo -e "${GREEN}Cleared. The next session will start fresh.${RESET}"
  exit 0
fi

echo -e "${BOLD}${CYAN}Claude Code - Interactive CLI (Blue Zone)${RESET}\n"

# ── Resolve authentication (token optional) ──────────────────────────────────
source "$(dirname "$0")/auth.sh"
resolve_auth

case "$AUTH_MODE" in
  oauth-token)
    echo -e "${GREEN}Auth: CLAUDE_CODE_OAUTH_TOKEN (subscription)${RESET}" ;;
  persisted-login)
    echo -e "${GREEN}Auth: persisted login from claude-home volume${RESET}" ;;
  none)
    echo -e "${YELLOW}No CLAUDE_CODE_OAUTH_TOKEN found.${RESET}"
    echo -e "${YELLOW}You'll be prompted to log in with your Claude account inside the${RESET}"
    echo -e "${YELLOW}session (run /login). Credentials persist in the claude-home${RESET}"
    echo -e "${YELLOW}Docker volume, so this is only needed once.${RESET}" ;;
esac

# ── Prepare and validate blue zone ───────────────────────────────────────────
echo -e "${BOLD}Step 1: Preparing blue zone...${RESET}"
./scripts/prepare-blue-zone.sh

echo -e "\n${BOLD}Step 2: Validating blue zone...${RESET}"
./scripts/validate-blue-zone.sh

# Layer the generated per-folder mounts (docker-compose.blue-zone.yml, written
# by prepare-blue-zone.sh) on top of the base compose file for every compose
# call below.
export COMPOSE_FILE="docker-compose.yml:$BLUE_ZONE_COMPOSE_FILE"

# ── Show mount summary ────────────────────────────────────────────────────────
echo -e "\n${BOLD}Mounting into container (writable — changes land in $BLUE_ZONE_ROOT):${RESET}"
for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  echo -e "  ${GREEN}$folder${RESET}  $BLUE_ZONE_ROOT/$folder -> /workspace/$folder"
done
echo ""
echo -e "${BOLD}NOT mounted (red zone):${RESET}"
echo -e "  ${RED}x${RESET} .env.* files"
echo -e "  ${RED}x${RESET} .gitlab-ci.yml / infra/"
echo -e "  ${RED}x${RESET} *-api.ts *Service.ts *Client.ts (stripped from src/)"
echo -e "  ${RED}x${RESET} ios: *.p12, *.mobileprovision, GoogleService-Info.plist, Pods/"
echo -e "  ${RED}x${RESET} android: *.jks, *.keystore, google-services.json, build/"
echo ""

echo -e "${YELLOW}Starting Claude Code session... (Ctrl+C to exit)${RESET}\n"

# When the session ends, however it ends (exit, Ctrl+C, error):
#   1. Sync Claude's changes back into the repo (set SYNC_BACK=0 to disable).
#   2. Tear down the egress proxy that `docker compose run` started as a
#      dependency, so no proxy container (which can reach the internet) is
#      left running after the session.
cleanup() {
  echo ""
  [ "${SYNC_BACK:-1}" != "0" ] && ./scripts/sync-back.sh
  docker compose rm -sf egress-proxy >/dev/null 2>&1 || true
}
trap cleanup EXIT

# claude-cli is attached only to the internal `egress` network; its sole route
# out is the egress-proxy allowlist. It cannot reach your LAN or any other host.
# See docker-compose.yml + proxy/ for details.
echo -e "${GREEN}Network: isolated — egress restricted to the proxy allowlist (no LAN access).${RESET}\n"

# Recreate the proxy from the current proxy/filter + proxy/tinyproxy.conf so any
# allowlist edits take effect immediately (the config is mounted, not baked in).
docker compose up -d --force-recreate egress-proxy

docker compose run --rm \
  ${AUTH_ENV_ARGS[@]+"${AUTH_ENV_ARGS[@]}"} \
  claude-cli
