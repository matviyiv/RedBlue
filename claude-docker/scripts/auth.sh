#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# auth.sh — Shared authentication resolution for Claude Code containers
#
# Supported auth methods, in priority order:
#   1. api-key          ANTHROPIC_API_KEY (sk-ant-api...)
#   2. oauth-token      CLAUDE_CODE_OAUTH_TOKEN (sk-ant-oat...), a long-lived
#                       token created with `claude setup-token` from a
#                       Claude Pro/Max subscription — no API key needed
#   3. persisted-login  OAuth credentials saved in the claude-config Docker
#                       volume by a previous interactive /login session
#   4. none             nothing found — interactive sessions can still start
#                       and log in via /login; headless runs must abort
#
# Source this file, then call resolve_auth. It sets:
#   AUTH_MODE       one of: api-key | oauth-token | persisted-login | none
#   AUTH_ENV_ARGS   array of `-e VAR=value` args for `docker compose run`
#                   (expand with: ${AUTH_ENV_ARGS[@]+"${AUTH_ENV_ARGS[@]}"})
# ─────────────────────────────────────────────────────────────────────────────

# True if a previous /login left credentials in the claude-config volume.
# Runs a throwaway container; any failure (e.g. image not built yet) counts
# as "no persisted login".
has_persisted_login() {
  docker compose run --rm --no-deps --entrypoint sh claude-code \
    -c 'test -s "$HOME/.claude/.credentials.json"' >/dev/null 2>&1
}

resolve_auth() {
  AUTH_ENV_ARGS=()
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    AUTH_MODE="api-key"
    AUTH_ENV_ARGS+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    AUTH_MODE="oauth-token"
    AUTH_ENV_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
  elif has_persisted_login; then
    AUTH_MODE="persisted-login"
  else
    AUTH_MODE="none"
  fi
}

print_auth_help() {
  echo "Authenticate with any ONE of the following:"
  echo "  1. API key            export ANTHROPIC_API_KEY=sk-ant-..."
  echo "  2. Subscription token run 'claude setup-token' on the host, then:"
  echo "                        export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat..."
  echo "  3. Interactive login  ./scripts/start-cli.sh and run /login once —"
  echo "                        credentials persist in the claude-config volume"
}
