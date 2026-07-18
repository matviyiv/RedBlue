#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-blue-zone.sh
# Scans prepared blue zone (/tmp/blue-zone) for secret leaks.
# Run AFTER prepare-blue-zone.sh, BEFORE docker compose.
#
# Usage: ./scripts/validate-blue-zone.sh [--strict]
# Exit codes: 0 = clean, 1 = violations found
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

# Load the shared folder / exclusion config (defines BLUE_ZONE_FOLDERS,
# BLUE_ZONE_ROOT, blue_zone_all_patterns_for).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../blue-zone.config.sh
source "$SCRIPT_DIR/../blue-zone.config.sh"

STRICT=false
VIOLATIONS=0
WARNINGS=0

[[ "${1:-}" == "--strict" ]] && STRICT=true

echo -e "${BOLD}Validating Blue Zone at $BLUE_ZONE_ROOT...${RESET}\n"

# ── Helpers ───────────────────────────────────────────────────────────────────
fail() { echo -e "  ${RED}VIOLATION${RESET} - $1"; ((VIOLATIONS++)) || true; }
warn() { echo -e "  ${YELLOW}WARNING${RESET}  - $1"; ((WARNINGS++)) || true; }
pass() { echo -e "  ${GREEN}OK${RESET} $1"; }

# ── Guard: prepare must have run first ───────────────────────────────────────
if [ ! -d "$BLUE_ZONE_ROOT" ]; then
  echo -e "${RED}Blue zone not found at $BLUE_ZONE_ROOT.${RESET}"
  echo    "Run ./scripts/prepare-blue-zone.sh first."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check 1: Every configured exclusion pattern actually kept its files out.
#
# Driven entirely by blue-zone.config.sh — for each configured folder we take
# its full exclusion list (common + per-folder) and assert nothing matching
# leaked into the staged copy. This stays correct automatically when you add a
# folder or change an exclusion rule; there is nothing folder-specific hardcoded
# here anymore.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[1] Configured red-zone patterns excluded from each folder...${RESET}"

for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  DEST="$BLUE_ZONE_ROOT/$folder"
  [ -d "$DEST" ] || continue

  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # Normalize an rsync dir pattern ("Pods/", "api/") to a plain name for find.
    name="${pattern%/}"
    # Strip a leading "**/" recursive prefix — find -name matches basenames.
    name="${name#**/}"
    [ -n "$name" ] || continue

    FOUND=$(find "$DEST" \( -name "$name" \) 2>/dev/null || true)
    if [ -n "$FOUND" ]; then
      fail "red-zone pattern '$pattern' leaked into $folder/: $FOUND"
    fi
  done < <(blue_zone_all_patterns_for "$folder")
done
[ $VIOLATIONS -eq 0 ] && pass "No configured red-zone patterns found in any blue-zone folder"

# ─────────────────────────────────────────────────────────────────────────────
# Check 2: Hardcoded secret patterns across all blue zone
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2] Scanning for hardcoded secrets...${RESET}"

SECRET_PATTERNS=(
  "password[[:space:]]*=[[:space:]]*['\"][^'\"]{4,}"
  "secret[[:space:]]*=[[:space:]]*['\"][^'\"]{4,}"
  "api_key[[:space:]]*=[[:space:]]*['\"][^'\"]{4,}"
  "private_key[[:space:]]*=[[:space:]]*['\"][^'\"]{4,}"
  "sk-ant-[a-zA-Z0-9]+"
  "AKIA[0-9A-Z]{16}"
  "192\.168\.[0-9]+\.[0-9]+"
  "10\.[0-9]+\.[0-9]+\.[0-9]+"
)

SECRET_FOUND=0
for pattern in "${SECRET_PATTERNS[@]}"; do
  MATCHES=$(grep -rniE "$pattern" "$BLUE_ZONE_ROOT/" \
    --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.swift" --include="*.m" --include="*.kt" --include="*.java" \
    --include="*.json" --include="*.xml" \
    -l 2>/dev/null || true)
  if [ -n "$MATCHES" ]; then
    fail "Secret pattern '$pattern' found in: $MATCHES"
    SECRET_FOUND=1
  fi
done
[ $SECRET_FOUND -eq 0 ] && pass "No hardcoded secret patterns found"

# ─────────────────────────────────────────────────────────────────────────────
# Check 3: No .env files anywhere in blue zone
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3] No .env files in blue zone...${RESET}"

ENV_FILES=$(find "$BLUE_ZONE_ROOT" -name ".env*" 2>/dev/null || true)
if [ -n "$ENV_FILES" ]; then
  fail ".env file(s) found in blue zone: $ENV_FILES"
else
  pass "No .env files in blue zone"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check 4: .env.example has no real values
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[4] .env.example has no real values...${RESET}"

REAL_VALUES=$(grep -vE '^\s*#|^\s*$' .env.example 2>/dev/null | grep -E '=.+' || true)
if [ -n "$REAL_VALUES" ]; then
  warn ".env.example has non-empty values - verify these are safe placeholders"
  $STRICT && fail ".env.example has real values (strict mode)"
else
  pass ".env.example values are all empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check 5: No content-denylist strings survived into the blue zone
# (defense in depth — prepare-blue-zone.sh should already have removed any file
#  containing one; this confirms nothing slipped through.)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[5] Content denylist strings excluded...${RESET}"

DENY_PATTERNS="$(mktemp)"
blue_zone_denylist_strings > "$DENY_PATTERNS"

if [ ! -s "$DENY_PATTERNS" ]; then
  pass "No content denylist configured (${BLUE_ZONE_DENYLIST_FILE##*/} has no active entries)"
else
  DENY_HITS=$(grep -rliaFf "$DENY_PATTERNS" "$BLUE_ZONE_ROOT" 2>/dev/null || true)
  if [ -n "$DENY_HITS" ]; then
    while IFS= read -r hf; do
      [ -n "$hf" ] || continue
      fail "denylisted string present in staged file: ${hf#"$BLUE_ZONE_ROOT"/}"
    done <<< "$DENY_HITS"
  else
    pass "No denylisted strings found in any staged file"
  fi
fi
rm -f "$DENY_PATTERNS"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────${RESET}"
echo -e "  Violations : $VIOLATIONS"
echo -e "  Warnings   : $WARNINGS"
echo -e "${BOLD}────────────────────────────────${RESET}"

if [ $VIOLATIONS -gt 0 ]; then
  echo -e "\n${RED}${BOLD}Blue zone validation FAILED${RESET}"
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo -e "\n${YELLOW}${BOLD}Blue zone validated with warnings${RESET}"
  exit 0
else
  echo -e "\n${GREEN}${BOLD}Blue zone is clean - safe to mount into Claude Code${RESET}"
  exit 0
fi
