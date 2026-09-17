#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-cli.sh — Start interactive Claude Code session (blue zone only)
# Usage: ./ai-scripts/start-cli.sh            start a session (state persists)
#        ./ai-scripts/start-cli.sh --clear    wipe persisted Claude state
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
# Optional Playwright browser (off unless BLUE_ZONE_BROWSER_ENABLED=1).
# shellcheck source=lib/blue-zone-browser.sh
source "$SCRIPT_DIR/lib/blue-zone-browser.sh"

# Base file only, set early so every docker compose call below (including
# --clear and the auth check) can find it — Docker Compose does not
# auto-discover a non-default-named file. Widened to include the generated
# per-folder overlay further down, once prepare-blue-zone.sh has written it.
export COMPOSE_FILE="docker-compose.ai-sandbox.yml"

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
./ai-scripts/prepare-blue-zone.sh

echo -e "\n${BOLD}Step 2: Validating blue zone...${RESET}"
./ai-scripts/validate-blue-zone.sh

# Layer the generated per-folder mounts (docker-compose.blue-zone.yml, written
# by prepare-blue-zone.sh) on top of the base compose file for every compose
# call below.
export COMPOSE_FILE="docker-compose.ai-sandbox.yml:$BLUE_ZONE_COMPOSE_FILE"

# ── Optional browser (Playwright MCP) ────────────────────────────────────────
# Off by default. When on, the egress policy is re-checked here and the run is
# ABORTED if it doesn't hold up — the browser is the one component that can
# carry workspace content out of the sandbox, so a policy we can't verify is
# not a policy we start with. validate-blue-zone.sh checks the same rules; this
# repeat is deliberate, since BLUE_ZONE_BROWSER_* can be overridden per-run
# from the environment after validation ran.
CLAUDE_EXTRA_ARGS=()
COMPOSE_RUN_ARGS=()
if blue_zone_browser_enabled; then
  echo -e "\n${BOLD}Step 3: Checking browser egress policy...${RESET}"
  if ! blue_zone_browser_check; then
    echo -e "\n${RED}${BOLD}Browser egress policy rejected — not starting.${RESET}"
    echo    "Fix BLUE_ZONE_BROWSER_ORIGINS in blue-zone.config.sh, or set"
    echo    "BLUE_ZONE_BROWSER_ENABLED=0 to run without the browser."
    exit 1
  fi
  blue_zone_browser_write "$(pwd)"
  export COMPOSE_FILE="$COMPOSE_FILE:$BLUE_ZONE_BROWSER_COMPOSE_FILE"
  # --strict-mcp-config: this generated file is the ONLY MCP config the session
  # loads. An MCP server left in the persisted ~/.claude.json by an earlier run
  # (or added mid-session and remembered) cannot come along for the ride.
  CLAUDE_EXTRA_ARGS+=(--mcp-config /workspace/.mcp.json --strict-mcp-config)
  [ -n "$BLUE_ZONE_BROWSER_TOOLS" ] && \
    CLAUDE_EXTRA_ARGS+=(--allowedTools "$BLUE_ZONE_BROWSER_TOOLS")
  # `docker compose run` ignores a service's network aliases unless told not to.
  # Without this the dev-server alias generated into the overlay would simply
  # not exist, and the browser could not resolve the name at all.
  if blue_zone_browser_dev_enabled; then
    COMPOSE_RUN_ARGS+=(--use-aliases)
    # Tell the session the exact dev-server URL. CLAUDE.md teaches the workflow
    # but cannot know the port, and a session left to guess reaches for
    # http://localhost:<port>, which is the browser's own container.
    CLAUDE_EXTRA_ARGS+=(--append-system-prompt "$(blue_zone_browser_prompt_note)")
  fi
  echo -e "  ${GREEN}OK${RESET} egress policy accepted"
fi

# ── Ensure the node_modules cache volume is writable by the non-root user ─────
# A `node-modules` volume created before the image pre-created
# /workspace/node_modules (or created by an older image) is owned by root, so
# `npm install` fails with EACCES. Fix ownership once, as root, in a throwaway
# container — a fast no-op when it's already claude-owned.
docker compose run --rm --no-deps --user 0 --entrypoint sh claude-code -c \
  'd=/workspace/node_modules; [ "$(stat -c %U "$d" 2>/dev/null)" = claude ] || chown -R claude:claude "$d"' \
  >/dev/null 2>&1 || echo "  (note: could not pre-fix node_modules volume ownership)"

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

if blue_zone_browser_enabled; then
  blue_zone_browser_summary
  echo ""
fi

# Shared agents/skills, if the project commits any. Worth naming explicitly:
# these change how the session behaves, and a developer should know which ones
# are in play before it starts.
if [ -n "${BLUE_ZONE_CLAUDE_DIR:-}" ] && [ -d "$BLUE_ZONE_CLAUDE_DIR" ]; then
  SHARED_LISTED=0
  for sub in ${BLUE_ZONE_CLAUDE_SUBDIRS[@]+"${BLUE_ZONE_CLAUDE_SUBDIRS[@]}"}; do
    [ -d "$BLUE_ZONE_CLAUDE_DIR/$sub" ] || continue
    if [ "$SHARED_LISTED" -eq 0 ]; then
      echo -e "${BOLD}Shared agents & skills${RESET} (from $BLUE_ZONE_CLAUDE_DIR/, mounted read-only):"
      SHARED_LISTED=1
    fi
    N=$(find "$BLUE_ZONE_CLAUDE_DIR/$sub" -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${GREEN}$sub${RESET}  $N file(s) -> /workspace/.claude/$sub"
  done
  [ "$SHARED_LISTED" -eq 1 ] && echo ""
fi

echo -e "${BOLD}Working alongside Claude:${RESET}"
echo -e "  Keep editing this repo while the session runs. From another terminal,"
echo -e "  ${GREEN}./ai-scripts/sync-in.sh${RESET} merges your changes into the live blue zone"
echo -e "  without discarding Claude's work (${GREEN}--dry-run${RESET} to preview first)."
echo ""

echo -e "${YELLOW}Starting Claude Code session... (Ctrl+C to exit)${RESET}\n"

# When the session ends, however it ends (exit, Ctrl+C, error):
#   1. Sync Claude's changes back into the repo (set SYNC_BACK=0 to disable).
#   2. Tear down the egress proxy that `docker compose run` started as a
#      dependency, so no proxy container (which can reach the internet) is
#      left running after the session.
#   3. Tear down the browser containers, if they were started, so no Chromium
#      and no second proxy outlive the session.
cleanup() {
  echo ""
  [ "${SYNC_BACK:-1}" != "0" ] && ./ai-scripts/sync-back.sh
  docker compose rm -sf egress-proxy >/dev/null 2>&1 || true
  if blue_zone_browser_enabled; then
    docker compose rm -sf playwright-mcp browser-proxy >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# claude-cli is attached only to the internal `egress` network; its sole route
# out is the egress-proxy allowlist. It cannot reach your LAN or any other host.
# See docker-compose.ai-sandbox.yml + ai-proxy/ for details.
echo -e "${GREEN}Network: isolated — egress restricted to the proxy allowlist (no LAN access).${RESET}\n"

# Recreate the proxy from the current ai-proxy/filter + ai-proxy/tinyproxy.conf so any
# allowlist edits take effect immediately (the config is mounted, not baked in).
docker compose up -d --force-recreate egress-proxy

# Same treatment for the browser stack: recreate from the freshly generated
# allowlist so a policy edit takes effect on the next session, never a stale
# one. browser-proxy comes up first — if the browser started before its only
# route out existed, its first requests would fail rather than be filtered.
if blue_zone_browser_enabled; then
  echo -e "${BOLD}Starting browser stack (playwright-mcp + browser-proxy)...${RESET}"
  docker compose up -d --force-recreate browser-proxy
  docker compose up -d --force-recreate playwright-mcp
fi

docker compose run --rm \
  ${COMPOSE_RUN_ARGS[@]+"${COMPOSE_RUN_ARGS[@]}"} \
  ${AUTH_ENV_ARGS[@]+"${AUTH_ENV_ARGS[@]}"} \
  claude-cli \
  ${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"}
