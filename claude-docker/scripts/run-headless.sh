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

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo -e "${RED}ANTHROPIC_API_KEY is not set.${RESET}"
  exit 1
fi

echo -e "${BOLD}${CYAN}Claude Code - Headless Run${RESET}"
echo -e "Prompt: ${BOLD}${PROMPT}${RESET}\n"

# ── Prepare and validate blue zone ───────────────────────────────────────────
echo -e "${BOLD}[1/3] Preparing blue zone...${RESET}"
./scripts/prepare-blue-zone.sh

echo -e "${BOLD}[2/3] Validating blue zone...${RESET}"
./scripts/validate-blue-zone.sh

echo -e "\n${BOLD}[3/3] Running Claude Code...${RESET}\n"

docker compose run --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  claude-code \
    -p "$PROMPT" \
    --allowedTools "Read" \
    --no-update-check \
    "${EXTRA_ARGS[@]}"

echo -e "\n${GREEN}Done${RESET}"
