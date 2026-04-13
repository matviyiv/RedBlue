#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# prepare-blue-zone.sh
# Copies src/, ios/, android/ into /tmp/blue-zone/ with red zone files excluded.
# Run this BEFORE docker compose to ensure clean filtered mounts.
#
# Usage: ./scripts/prepare-blue-zone.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

BLUE_ZONE_ROOT="/tmp/blue-zone"

echo -e "${BOLD}${CYAN}🔵 Preparing Blue Zone...${RESET}\n"

# ── Wipe previous run ─────────────────────────────────────────────────────────
rm -rf "$BLUE_ZONE_ROOT"
mkdir -p "$BLUE_ZONE_ROOT"/{src,ios,android}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: rsync a folder with exclusions and print audit diff
# Usage: sync_zone <source> <dest> <label> [extra rsync args...]
# ─────────────────────────────────────────────────────────────────────────────
sync_zone() {
  local SRC="$1"
  local DEST="$2"
  local LABEL="$3"
  shift 3
  local EXTRA_ARGS=("$@")

  if [ ! -d "$SRC" ]; then
    echo -e "  ${YELLOW}⚠  $LABEL not found at $SRC — skipping${RESET}"
    return
  fi

  echo -e "${BOLD}[$LABEL]${RESET} $SRC → $DEST"

  rsync -a "$SRC/" "$DEST/" "${EXTRA_ARGS[@]}"

  # Audit: show what was excluded
  EXCLUDED=$(comm -23 \
    <(find "$SRC"  -type f | sed "s|$SRC/||"  | sort) \
    <(find "$DEST" -type f | sed "s|$DEST/||" | sort) \
  )

  if [ -n "$EXCLUDED" ]; then
    echo -e "  ${RED}Excluded (red zone):${RESET}"
    echo "$EXCLUDED" | while IFS= read -r f; do
      echo -e "    ${RED}✗${RESET} $f"
    done
  fi

  INCLUDED=$(find "$DEST" -type f | sed "s|$DEST/||" | wc -l | tr -d ' ')
  echo -e "  ${GREEN}✓ $INCLUDED file(s) in blue zone${RESET}\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# 🔵 src/ — JS/TS app code, excluding API/service/client files
# ─────────────────────────────────────────────────────────────────────────────
sync_zone "./src" "$BLUE_ZONE_ROOT/src" "src" \
  --exclude="*-api.ts"        \
  --exclude="*-api.js"        \
  --exclude="*Api.ts"         \
  --exclude="*Api.js"         \
  --exclude="*Service.ts"     \
  --exclude="*Service.js"     \
  --exclude="*Client.ts"      \
  --exclude="*Client.js"      \
  --exclude="*client.ts"      \
  --exclude="*client.js"      \
  --exclude="api/"            \
  --exclude="services/"       \
  --exclude="*.graphql"       \
  --exclude="*.gql"           \
  --exclude=".env*"           \
  --exclude="node_modules/"

# ─────────────────────────────────────────────────────────────────────────────
# 🔵 ios/ — Swift/ObjC source only
# Excluded: signing, certs, xcconfig secrets, pods, build artifacts
# ─────────────────────────────────────────────────────────────────────────────
sync_zone "./ios" "$BLUE_ZONE_ROOT/ios" "ios" \
  --exclude="*.p12"                     \
  --exclude="*.cer"                     \
  --exclude="*.mobileprovision"         \
  --exclude="*.provisionprofile"        \
  --exclude="GoogleService-Info.plist"  \
  --exclude="**/GoogleService-Info.plist" \
  --exclude="*.xcconfig"               \
  --exclude="Pods/"                    \
  --exclude="build/"                   \
  --exclude="DerivedData/"             \
  --exclude="*.xcworkspace/xcuserdata/"\
  --exclude="*.xcodeproj/xcuserdata/"  \
  --exclude="*.xcodeproj/project.xcworkspace/xcuserdata/" \
  --exclude="*.pbxuser"                \
  --exclude="*.mode1v3"                \
  --exclude="*.mode2v3"                \
  --exclude="*.perspectivev3"          \
  --exclude="xcuserdata/"              \
  --exclude="*.hmap"                   \
  --exclude="*.ipa"                    \
  --exclude="*.dSYM.zip"               \
  --exclude="*.dSYM"

# ─────────────────────────────────────────────────────────────────────────────
# 🔵 android/ — Kotlin/Java source only
# Excluded: signing keys, google-services, build artifacts, gradle cache
# ─────────────────────────────────────────────────────────────────────────────
sync_zone "./android" "$BLUE_ZONE_ROOT/android" "android" \
  --exclude="*.jks"                     \
  --exclude="*.keystore"                \
  --exclude="google-services.json"      \
  --exclude="**/google-services.json"   \
  --exclude="release.properties"        \
  --exclude="keystore.properties"       \
  --exclude="signing.properties"        \
  --exclude=".gradle/"                  \
  --exclude="build/"                    \
  --exclude="**/build/"                 \
  --exclude=".idea/"                    \
  --exclude="local.properties"          \
  --exclude="gradle.properties"         \
  --exclude="*.apk"                     \
  --exclude="*.aab"                     \
  --exclude="*.so"                      \
  --exclude="*.aar"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$(find "$BLUE_ZONE_ROOT" -type f | wc -l | tr -d ' ')
echo -e "${BOLD}────────────────────────────────────────${RESET}"
echo -e "${GREEN}${BOLD}✅ Blue zone ready at $BLUE_ZONE_ROOT${RESET}"
echo -e "   Total files: ${BOLD}$TOTAL${RESET}"
echo -e "   Mounts:"
echo -e "   ${GREEN}•${RESET} $BLUE_ZONE_ROOT/src     → /workspace/src"
echo -e "   ${GREEN}•${RESET} $BLUE_ZONE_ROOT/ios     → /workspace/ios"
echo -e "   ${GREEN}•${RESET} $BLUE_ZONE_ROOT/android → /workspace/android"
echo -e "${BOLD}────────────────────────────────────────${RESET}"
