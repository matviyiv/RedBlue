#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-cli.sh — Start interactive Claude Code session (blue zone only)
# Usage: ./scripts/start-cli.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}Claude Code - Interactive CLI (Blue Zone)${RESET}\n"

# ── Resolve authentication (API key optional) ────────────────────────────────
source "$(dirname "$0")/auth.sh"
resolve_auth

case "$AUTH_MODE" in
  api-key)
    echo -e "${GREEN}Auth: ANTHROPIC_API_KEY${RESET}" ;;
  oauth-token)
    echo -e "${GREEN}Auth: CLAUDE_CODE_OAUTH_TOKEN (subscription)${RESET}" ;;
  persisted-login)
    echo -e "${GREEN}Auth: persisted login from claude-config volume${RESET}" ;;
  none)
    echo -e "${YELLOW}No ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN found.${RESET}"
    echo -e "${YELLOW}You'll be prompted to log in with your Claude account inside the${RESET}"
    echo -e "${YELLOW}session (run /login). Credentials persist in the claude-config${RESET}"
    echo -e "${YELLOW}Docker volume, so this is only needed once.${RESET}" ;;
esac

# ── Prepare and validate blue zone ───────────────────────────────────────────
echo -e "${BOLD}Step 1: Preparing blue zone...${RESET}"
./scripts/prepare-blue-zone.sh

echo -e "\n${BOLD}Step 2: Validating blue zone...${RESET}"
./scripts/validate-blue-zone.sh

# ── Show mount summary ────────────────────────────────────────────────────────
echo -e "\n${BOLD}Mounting into container (writable — changes land in /tmp/blue-zone):${RESET}"
echo -e "  ${GREEN}src${RESET}     /tmp/blue-zone/src     -> /workspace/src"
echo -e "  ${GREEN}ios${RESET}     /tmp/blue-zone/ios     -> /workspace/ios"
echo -e "  ${GREEN}android${RESET} /tmp/blue-zone/android -> /workspace/android"
echo ""
echo -e "${BOLD}NOT mounted (red zone):${RESET}"
echo -e "  ${RED}x${RESET} .env.* files"
echo -e "  ${RED}x${RESET} .gitlab-ci.yml / infra/"
echo -e "  ${RED}x${RESET} *-api.ts *Service.ts *Client.ts (stripped from src/)"
echo -e "  ${RED}x${RESET} ios: *.p12, *.mobileprovision, GoogleService-Info.plist, Pods/"
echo -e "  ${RED}x${RESET} android: *.jks, *.keystore, google-services.json, build/"
echo ""

echo -e "${YELLOW}Starting Claude Code session... (Ctrl+C to exit)${RESET}\n"

# Sync Claude's changes back into the repo when the session ends, however it
# ends (exit, Ctrl+C, error). Set SYNC_BACK=0 to disable.
if [ "${SYNC_BACK:-1}" != "0" ]; then
  trap 'echo ""; ./scripts/sync-back.sh' EXIT
fi

docker compose run --rm \
  ${AUTH_ENV_ARGS[@]+"${AUTH_ENV_ARGS[@]}"} \
  claude-cli
