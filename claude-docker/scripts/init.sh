#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# init.sh — One-time setup for Claude Code blue zone Docker environment
# Usage: ./scripts/init.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}Claude Code Blue Zone - Init${RESET}\n"

# ── 1. Check prerequisites ────────────────────────────────────────────────────
echo -e "${BOLD}[1/6] Checking prerequisites...${RESET}"

command -v docker >/dev/null 2>&1       || { echo -e "${RED}Docker not found.${RESET}"; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo -e "${RED}docker compose not found.${RESET}"; exit 1; }
command -v rsync >/dev/null 2>&1        || { echo -e "${RED}rsync not found. Run: brew install rsync${RESET}"; exit 1; }
command -v jq >/dev/null 2>&1           || echo -e "${YELLOW}jq not found (optional). Install: brew install jq${RESET}"

echo -e "${GREEN}Prerequisites OK${RESET}"

# ── 2. Check authentication (API key optional) ───────────────────────────────
echo -e "\n${BOLD}[2/6] Checking authentication...${RESET}"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo -e "${GREEN}ANTHROPIC_API_KEY is set${RESET}"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo -e "${GREEN}CLAUDE_CODE_OAUTH_TOKEN is set (subscription auth)${RESET}"
else
  echo -e "${YELLOW}No ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN set.${RESET}"
  read -p "  Enter an API key or setup-token now (or press Enter to skip): " -r INPUT_KEY
  if [ -n "$INPUT_KEY" ]; then
    case "$INPUT_KEY" in
      sk-ant-oat*)
        export CLAUDE_CODE_OAUTH_TOKEN="$INPUT_KEY"
        echo -e "${GREEN}OAuth token set for this session${RESET}"
        echo    "  Add to your shell profile to persist:"
        echo    "  export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat..."
        ;;
      *)
        export ANTHROPIC_API_KEY="$INPUT_KEY"
        echo -e "${GREEN}API key set for this session${RESET}"
        echo    "  Add to your shell profile to persist:"
        echo    "  export ANTHROPIC_API_KEY=sk-ant-..."
        ;;
    esac
  else
    echo -e "${YELLOW}Skipped - no problem. Alternative login options:${RESET}"
    echo    "  • Claude Pro/Max subscription: run 'claude setup-token' and"
    echo    "    export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat..."
    echo    "  • Or just run ./scripts/start-cli.sh and log in with /login —"
    echo    "    credentials persist in the claude-config Docker volume"
  fi
fi

# ── 3. Make scripts executable ────────────────────────────────────────────────
echo -e "\n${BOLD}[3/6] Setting script permissions...${RESET}"
chmod +x scripts/*.sh
echo -e "${GREEN}Scripts are executable${RESET}"

# ── 4. Create .env.example if missing ────────────────────────────────────────
echo -e "\n${BOLD}[4/6] Checking .env.example...${RESET}"

if [ ! -f ".env.example" ]; then
  cat > .env.example << 'ENVEOF'
# ─────────────────────────────────────────────────────────────
# .env.example - BLUE ZONE - committed, no real values
# Real values go in .env.local / .env.production (RED ZONE)
# ─────────────────────────────────────────────────────────────
API_BASE_URL=
WEBSOCKET_URL=
SENTRY_DSN=
JITSI_SERVER=
AUTH_TOKEN_SECRET=
PUSH_NOTIFICATION_KEY=
ENVEOF
  echo -e "${GREEN}Created .env.example${RESET}"
else
  echo -e "${GREEN}.env.example exists${RESET}"
fi

# ── 5. Verify folder structure ────────────────────────────────────────────────
echo -e "\n${BOLD}[5/6] Checking project structure...${RESET}"

for dir in src ios android; do
  if [ -d "./$dir" ]; then
    echo -e "  ${GREEN}$dir/ found${RESET}"
  else
    echo -e "  ${YELLOW}$dir/ not found - will be skipped in blue zone prep${RESET}"
  fi
done

# ── 6. Build Docker image ─────────────────────────────────────────────────────
echo -e "\n${BOLD}[6/6] Building Claude Code Docker image...${RESET}"
docker compose build claude-code

echo -e "\n${GREEN}${BOLD}Init complete!${RESET}"
echo ""
echo "  Next steps:"
echo "  • Interactive session : ./scripts/start-cli.sh"
echo "  • Headless run        : ./scripts/run-headless.sh \"Review src/ for bugs\""
echo "  • Validate only       : ./scripts/validate-blue-zone.sh"
echo "  • Prepare only        : ./scripts/prepare-blue-zone.sh"
echo ""
