#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-headless.sh — Run any Claude Code prompt in headless/CI mode
# Usage: ./scripts/run-headless.sh "Review src/ for TypeScript errors"
#        ./scripts/run-headless.sh "Review ios/ native modules" --output-format json
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

# Load the shared folder config (defines BLUE_ZONE_COMPOSE_FILE).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../blue-zone.config.sh
source "$SCRIPT_DIR/../blue-zone.config.sh"

PROMPT="${1:-}"
shift || true
EXTRA_ARGS=("$@")

if [ -z "$PROMPT" ]; then
  echo -e "${RED}Usage: $0 \"<prompt>\" [extra claude flags...]${RESET}"
  echo    "Examples:"
  echo    "  $0 \"Review src/ for bugs\""
  echo    "  $0 \"Check ios/ native modules for memory leaks\""
  echo    "  $0 \"Review android/ Kotlin bridge code\" --output-format json"
  exit 1
fi

# ── Resolve authentication (token optional) ──────────────────────────────────
source "$(dirname "$0")/auth.sh"
resolve_auth

if [ "$AUTH_MODE" = "none" ]; then
  echo -e "${RED}No authentication found for headless run.${RESET}"
  print_auth_help
  exit 1
fi

echo -e "${BOLD}${CYAN}Claude Code - Headless Run${RESET}"
echo -e "Auth: ${BOLD}${AUTH_MODE}${RESET}"
echo -e "Prompt: ${BOLD}${PROMPT}${RESET}\n"

# ── Prepare and validate blue zone ───────────────────────────────────────────
echo -e "${BOLD}[1/3] Preparing blue zone...${RESET}"
./scripts/prepare-blue-zone.sh

echo -e "${BOLD}[2/3] Validating blue zone...${RESET}"
./scripts/validate-blue-zone.sh

# Layer the generated per-folder mounts (docker-compose.blue-zone.yml, written
# by prepare-blue-zone.sh) on top of the base compose file.
export COMPOSE_FILE="docker-compose.yml:$BLUE_ZONE_COMPOSE_FILE"

# Ensure the node_modules cache volume is writable by the non-root user. A volume
# created before the image pre-created /workspace/node_modules (or by an older
# image) is owned by root, so `npm install` fails with EACCES. Fix ownership
# once, as root, in a throwaway container — a fast no-op when already claude-owned.
docker compose run --rm --no-deps --user 0 --entrypoint sh claude-code -c \
  'd=/workspace/node_modules; [ "$(stat -c %U "$d" 2>/dev/null)" = claude ] || chown -R claude:claude "$d"' \
  >/dev/null 2>&1 || echo "  (note: could not pre-fix node_modules volume ownership)"

echo -e "\n${BOLD}[3/3] Running Claude Code...${RESET}\n"

docker compose run --rm \
  ${AUTH_ENV_ARGS[@]+"${AUTH_ENV_ARGS[@]}"} \
  claude-code \
    -p "$PROMPT" \
    --allowedTools "Read,Write,Edit" \
    --no-update-check \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

# Sync any files Claude wrote back into the repo. Set SYNC_BACK=0 to disable.
if [ "${SYNC_BACK:-1}" != "0" ]; then
  echo ""
  ./scripts/sync-back.sh
fi

echo -e "\n${GREEN}Done${RESET}"
