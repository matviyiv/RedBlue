#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-blue-zone.sh
# Scans prepared blue zone (/tmp/blue-zone/<project>) for secret leaks.
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

# Defensive default: an older config may not define BLUE_ZONE_ROOT_FILES.
declare -p BLUE_ZONE_ROOT_FILES >/dev/null 2>&1 || BLUE_ZONE_ROOT_FILES=()

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
  # Keyword assignments — matches `key = "value"` and `key: "value"` (JSON/YAML).
  # A quoted value is required on purpose, so TypeScript type annotations like
  # `password: string` or `secret: boolean` don't trip the scanner.
  "(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)[[:space:]]*[:=][[:space:]]*['\"][^'\"]{4,}"
  # Provider / token shapes — high-signal, quote-independent (catches unquoted
  # leaks the keyword rule above would miss).
  "sk-ant-[a-zA-Z0-9]+"
  "AKIA[0-9A-Z]{16}"
  "gh[posru]_[A-Za-z0-9]{30,}"
  "AIza[0-9A-Za-z_-]{35}"
  "xox[baprs]-[A-Za-z0-9-]{10,}"
  "eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}"
  "-----BEGIN[A-Z ]*PRIVATE KEY-----"
  "[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}"
  # Internal LAN addresses.
  "192\.168\.[0-9]+\.[0-9]+"
  "10\.[0-9]+\.[0-9]+\.[0-9]+"
)

# Test files legitimately contain fake/sample credentials (fixtures, mocks),
# so they are excluded from the secret scan to avoid false positives. Covers
# Swift (*Tests.swift, *Test.swift), JS/TS (*.test.*, *.spec.*), and
# JVM (*Test.kt/java, *Tests.kt/java) conventions, plus the usual test dirs.
TEST_EXCLUDES=(
  --exclude="*Tests.swift" --exclude="*Test.swift"
  --exclude="*.test.js" --exclude="*.test.jsx"
  --exclude="*.test.ts" --exclude="*.test.tsx"
  --exclude="*.spec.js" --exclude="*.spec.jsx"
  --exclude="*.spec.ts" --exclude="*.spec.tsx"
  --exclude="*Test.kt" --exclude="*Tests.kt"
  --exclude="*Test.java" --exclude="*Tests.java"
  --exclude="Constants.java" --exclude="constants.js"
  --exclude-dir="__tests__" --exclude-dir="__mocks__"
  --exclude-dir="test" --exclude-dir="tests"
)

SECRET_FOUND=0
for pattern in "${SECRET_PATTERNS[@]}"; do
  # Match with line context (file:line:text) so we can discount lines annotated
  # with the allow marker, then collapse what remains back to unique filenames.
  MATCHES=$(grep -rniE -e "$pattern" "$BLUE_ZONE_ROOT/" \
    --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.swift" --include="*.m" --include="*.kt" --include="*.java" \
    --include="*.json" --include="*.xml" \
    2>/dev/null | blue_zone_strip_allow_marked \
    "${TEST_EXCLUDES[@]}" \
    | cut -d: -f1 | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)
  if [ -n "$MATCHES" ]; then
    fail "Secret pattern '$pattern' found in: $MATCHES"
    SECRET_FOUND=1
  fi
done
[ $SECRET_FOUND -eq 0 ] && pass "No hardcoded secret patterns found (marked exceptions ignored)"

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
  # Scan only the staged folders — the actual mounted content. Root-level
  # tooling metadata (the manifest, snapshot, generated overlay) lists stripped
  # filenames and rule patterns, which must not be mistaken for leaked content.
  DENY_SCAN_DIRS=()
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    [ -d "$BLUE_ZONE_ROOT/$folder" ] && DENY_SCAN_DIRS+=("$BLUE_ZONE_ROOT/$folder")
  done
  for rf in ${BLUE_ZONE_ROOT_FILES[@]+"${BLUE_ZONE_ROOT_FILES[@]}"}; do
    [ -f "$BLUE_ZONE_ROOT/$rf" ] && DENY_SCAN_DIRS+=("$BLUE_ZONE_ROOT/$rf")
  done
  DENY_HITS=""
  [ "${#DENY_SCAN_DIRS[@]}" -gt 0 ] && \
    DENY_HITS=$(grep -rliaFf "$DENY_PATTERNS" "${DENY_SCAN_DIRS[@]}" 2>/dev/null || true)
  DENY_REAL=0
  if [ -n "$DENY_HITS" ]; then
    while IFS= read -r hf; do
      [ -n "$hf" ] || continue
      # Ignore files whose only hits are on allow-marked lines — a reviewed
      # exception, not a leak.
      [ -z "$(blue_zone_unmarked_denylist_hits "$DENY_PATTERNS" "$hf")" ] && continue
      fail "denylisted string present in staged file: ${hf#"$BLUE_ZONE_ROOT"/}"
      DENY_REAL=$((DENY_REAL + 1))
    done <<< "$DENY_HITS"
  fi
  [ "$DENY_REAL" -eq 0 ] && pass "No un-exempted denylisted strings found in any staged file"
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
