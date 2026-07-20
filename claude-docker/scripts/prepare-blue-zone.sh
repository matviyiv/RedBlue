#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# prepare-blue-zone.sh
# Copies the configured blue-zone folders into /tmp/blue-zone/ with red zone
# files excluded. Run this BEFORE docker compose to ensure clean filtered mounts.
#
# The folder list and exclusion rules come from blue-zone.config.sh — edit that
# file to adapt the blue zone to your project. This script is project-agnostic.
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

# Load the shared folder / exclusion config (defines BLUE_ZONE_FOLDERS,
# BLUE_ZONE_ROOT, BLUE_ZONE_COMPOSE_FILE and helpers).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../blue-zone.config.sh
source "$SCRIPT_DIR/../blue-zone.config.sh"

echo -e "${BOLD}${CYAN}🔵 Preparing Blue Zone...${RESET}\n"
echo -e "  Folders: ${BOLD}${BLUE_ZONE_FOLDERS[*]}${RESET}\n"

# ── Wipe previous run ─────────────────────────────────────────────────────────
rm -rf "$BLUE_ZONE_ROOT"
mkdir -p "$BLUE_ZONE_ROOT"
for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  mkdir -p "$BLUE_ZONE_ROOT/$folder"
done

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
# 🔵 Stage each configured folder with its exclusions
#    (common excludes + per-folder rules, both from blue-zone.config.sh)
# ─────────────────────────────────────────────────────────────────────────────
for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  blue_zone_build_excludes "$folder" EXCLUDE_ARGS
  sync_zone "./$folder" "$BLUE_ZONE_ROOT/$folder" "$folder" "${EXCLUDE_ARGS[@]}"
done

# ─────────────────────────────────────────────────────────────────────────────
# 🔒 Content denylist — drop any staged file that CONTAINS a forbidden string
# (from blue-zone-insecure-strings.txt) so it is never mounted. This catches
# secrets/insecure markers living inside otherwise-innocuous files, which the
# filename-based excludes above can't see. Runs before the snapshot so removed
# files are treated as if they were never in the blue zone.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[content denylist]${RESET} scanning staged files for forbidden strings"
PATTERN_FILE="$(mktemp)"
blue_zone_denylist_strings > "$PATTERN_FILE"

if [ ! -s "$PATTERN_FILE" ]; then
  echo -e "  ${YELLOW}⚠  no active entries in ${BLUE_ZONE_DENYLIST_FILE##*/} — content scan skipped${RESET}\n"
else
  # Existing staged folders only (skip any that were absent from the repo).
  SCAN_DIRS=()
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    [ -d "$BLUE_ZONE_ROOT/$folder" ] && SCAN_DIRS+=("$BLUE_ZONE_ROOT/$folder")
  done

  DENY_REMOVED=0
  if [ "${#SCAN_DIRS[@]}" -gt 0 ]; then
    # -r recursive, -l list files, -i case-insensitive, -a treat binary as text,
    # -F fixed strings, -f patterns file. One pass over the whole staged tree.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      HIT="$(grep -aoiFf "$PATTERN_FILE" "$f" 2>/dev/null | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')"
      rel="${f#"$BLUE_ZONE_ROOT"/}"
      echo -e "  ${RED}✗ removed${RESET} $rel ${RED}(matched: ${HIT:-forbidden string})${RESET}"
      rm -f "$f"
      DENY_REMOVED=$((DENY_REMOVED + 1))
    done < <(grep -rliaFf "$PATTERN_FILE" "${SCAN_DIRS[@]}" 2>/dev/null || true)
  fi

  if [ "$DENY_REMOVED" -eq 0 ]; then
    echo -e "  ${GREEN}✓ no staged file contained a forbidden string${RESET}\n"
  else
    echo -e "  ${RED}${BOLD}$DENY_REMOVED file(s) removed — not mounted into the container${RESET}\n"
  fi
fi
rm -f "$PATTERN_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Make the blue zone writable by the container's non-root user
# (container uid differs from host uid, so group/other need rw on everything)
# ─────────────────────────────────────────────────────────────────────────────
chmod -R a+rwX "$BLUE_ZONE_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# Snapshot of blue zone contents at prepare time.
# sync-back.sh uses this to tell Claude's changes apart from red-zone files.
# Lives at the blue zone root, which is NOT mounted into the container —
# only the configured folders are.
# ─────────────────────────────────────────────────────────────────────────────
(cd "$BLUE_ZONE_ROOT" && find "${BLUE_ZONE_FOLDERS[@]}" -type f 2>/dev/null | sort > .blue-zone-snapshot)

# ─────────────────────────────────────────────────────────────────────────────
# Generate the docker-compose overlay that mounts each configured folder into
# both Claude services. Layered on top of docker-compose.yml via COMPOSE_FILE by
# start-cli.sh / run-headless.sh. Regenerated every run — never edit by hand.
# ─────────────────────────────────────────────────────────────────────────────
COMPOSE_OUT="$SCRIPT_DIR/../$BLUE_ZONE_COMPOSE_FILE"
{
  echo "# ─────────────────────────────────────────────────────────────────────"
  echo "# AUTO-GENERATED by prepare-blue-zone.sh from blue-zone.config.sh."
  echo "# Regenerated on every prepare run — do NOT edit by hand."
  echo "# Mounts each configured blue-zone folder into both Claude services."
  echo "# ─────────────────────────────────────────────────────────────────────"
  echo "services:"
  for svc in claude-code claude-cli; do
    echo "  $svc:"
    echo "    volumes:"
    for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
      echo "      - $BLUE_ZONE_ROOT/$folder:/workspace/$folder"
    done
  done
} > "$COMPOSE_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$(find "$BLUE_ZONE_ROOT" -type f | wc -l | tr -d ' ')
echo -e "${BOLD}────────────────────────────────────────${RESET}"
echo -e "${GREEN}${BOLD}✅ Blue zone ready at $BLUE_ZONE_ROOT${RESET}"
echo -e "   Total files: ${BOLD}$TOTAL${RESET}"
echo -e "   Mounts:"
for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  echo -e "   ${GREEN}•${RESET} $BLUE_ZONE_ROOT/$folder → /workspace/$folder"
done
echo -e "${BOLD}────────────────────────────────────────${RESET}"
