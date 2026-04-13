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

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo -e "${RED}ANTHROPIC_API_KEY is not set.${RESET}"
  echo    "  Run: export ANTHROPIC_API_KEY=sk-ant-..."
  exit 1
fi

# ── Prepare and validate blue zone ───────────────────────────────────────────
echo -e "${BOLD}Step 1: Preparing blue zone...${RESET}"
./scripts/prepare-blue-zone.sh

echo -e "\n${BOLD}Step 2: Validating blue zone...${RESET}"
./scripts/validate-blue-zone.sh

# ── Show mount summary ────────────────────────────────────────────────────────
echo -e "\n${BOLD}Mounting into container (read-only):${RESET}"
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

docker compose run --rm \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  claude-cli
