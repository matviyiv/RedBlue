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

STRICT=false
VIOLATIONS=0
WARNINGS=0
BLUE_ZONE_ROOT="/tmp/blue-zone"

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
# Check 1: API/Service/Client files not in src blue zone
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[1] API/endpoint files excluded from src/...${RESET}"

API_PATTERNS=("*-api.ts" "*-api.js" "*Api.ts" "*Api.js"
              "*Service.ts" "*Service.js" "*Client.ts" "*Client.js"
              "*client.ts" "*client.js")

for pattern in "${API_PATTERNS[@]}"; do
  FOUND=$(find "$BLUE_ZONE_ROOT/src" -name "$pattern" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    fail "API/service file leaked into blue zone src/: $FOUND"
  fi
done
[ $VIOLATIONS -eq 0 ] && pass "No API/service/client files in src/"

# ─────────────────────────────────────────────────────────────────────────────
# Check 2: iOS signing and config files excluded
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2] iOS sensitive files excluded...${RESET}"

IOS_RED_PATTERNS=("*.p12" "*.cer" "*.mobileprovision" "*.provisionprofile"
                  "GoogleService-Info.plist" "*.xcconfig" "*.ipa"
                  "*.dSYM" "*.pbxuser")

for pattern in "${IOS_RED_PATTERNS[@]}"; do
  FOUND=$(find "$BLUE_ZONE_ROOT/ios" -name "$pattern" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    fail "iOS sensitive file leaked into blue zone: $FOUND"
  fi
done

# Check Pods and build dirs not mounted
for dir in "Pods" "build" "DerivedData" "xcuserdata"; do
  FOUND=$(find "$BLUE_ZONE_ROOT/ios" -type d -name "$dir" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    fail "iOS build/cache dir leaked into blue zone: $FOUND"
  fi
done
[ $VIOLATIONS -eq 0 ] && pass "No iOS signing/cert/build files in ios/"

# ─────────────────────────────────────────────────────────────────────────────
# Check 3: Android signing and config files excluded
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3] Android sensitive files excluded...${RESET}"

ANDROID_RED_PATTERNS=("*.jks" "*.keystore" "google-services.json"
                       "keystore.properties" "signing.properties"
                       "release.properties" "*.apk" "*.aab")

for pattern in "${ANDROID_RED_PATTERNS[@]}"; do
  FOUND=$(find "$BLUE_ZONE_ROOT/android" -name "$pattern" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    fail "Android sensitive file leaked into blue zone: $FOUND"
  fi
done

for dir in "build" ".gradle" ".idea"; do
  FOUND=$(find "$BLUE_ZONE_ROOT/android" -type d -name "$dir" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    fail "Android build/cache dir leaked into blue zone: $FOUND"
  fi
done

# gradle.properties can contain secrets — warn if present
GRADLE_PROPS=$(find "$BLUE_ZONE_ROOT/android" -name "gradle.properties" 2>/dev/null || true)
if [ -n "$GRADLE_PROPS" ]; then
  warn "gradle.properties present - verify it contains no signing secrets"
  $STRICT && fail "gradle.properties must be excluded (strict mode)"
fi

[ $VIOLATIONS -eq 0 ] && pass "No Android signing/keystore/build files in android/"

# ─────────────────────────────────────────────────────────────────────────────
# Check 4: Hardcoded secret patterns across all blue zone
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[4] Scanning for hardcoded secrets...${RESET}"

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
# Check 5: No .env files anywhere in blue zone
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[5] No .env files in blue zone...${RESET}"

ENV_FILES=$(find "$BLUE_ZONE_ROOT" -name ".env*" 2>/dev/null || true)
if [ -n "$ENV_FILES" ]; then
  fail ".env file(s) found in blue zone: $ENV_FILES"
else
  pass "No .env files in blue zone"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check 6: .env.example has no real values
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}[6] .env.example has no real values...${RESET}"

REAL_VALUES=$(grep -vE '^\s*#|^\s*$' .env.example 2>/dev/null | grep -E '=.+' || true)
if [ -n "$REAL_VALUES" ]; then
  warn ".env.example has non-empty values - verify these are safe placeholders"
  $STRICT && fail ".env.example has real values (strict mode)"
else
  pass ".env.example values are all empty"
fi

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
