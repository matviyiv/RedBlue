#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# prepare-blue-zone.sh
# Copies the configured blue-zone folders into /tmp/blue-zone/<project>/ with red
# zone files excluded. Run this BEFORE docker compose to ensure clean filtered
# mounts. The staging root is namespaced per project (BLUE_ZONE_PROJECT /
# BLUE_ZONE_ROOT in blue-zone.config.sh) so concurrent sessions stay isolated.
#
# This is the RESET: it makes the staging tree match the repo exactly, so any
# unsynced work in the blue zone is discarded. To pull host changes into a live
# session WITHOUT discarding Claude's work, use ./ai-scripts/sync-in.sh instead —
# that merges rather than overwrites.
#
# Safe to re-run while a container is already up: it resets the staged folders in
# place (same directory inodes) instead of deleting the root, so live bind mounts
# survive and the running container picks up the refreshed content.
#
# The folder list and exclusion rules come from blue-zone.config.sh — edit that
# file to adapt the blue zone to your project. This script is project-agnostic.
#
# Usage: ./ai-scripts/prepare-blue-zone.sh
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

# Defensive defaults: an older blue-zone.config.sh may not define these newer
# options. Fall back here so `set -u` doesn't abort when the script is newer than
# the config it's paired with.
BLUE_ZONE_MANIFEST_FILE="${BLUE_ZONE_MANIFEST_FILE:-BLUE_ZONE_MANIFEST.md}"
declare -p BLUE_ZONE_ROOT_FILES >/dev/null 2>&1 || BLUE_ZONE_ROOT_FILES=()

# The red-zone filter itself (shared with sync-in.sh) and the shadow git repo
# that makes two-way sync possible.
# shellcheck source=lib/blue-zone-project.sh
source "$SCRIPT_DIR/lib/blue-zone-project.sh"
# shellcheck source=lib/blue-zone-git.sh
source "$SCRIPT_DIR/lib/blue-zone-git.sh"
# shellcheck source=lib/blue-zone-manifest.sh
source "$SCRIPT_DIR/lib/blue-zone-manifest.sh"

echo -e "${BOLD}${CYAN}🔵 Preparing Blue Zone...${RESET}\n"
echo -e "  Folders: ${BOLD}${BLUE_ZONE_FOLDERS[*]}${RESET}\n"

# ─────────────────────────────────────────────────────────────────────────────
# 🔵 Project the repo into the staging root: rsync each configured folder and
#    root file with the red-zone exclusions applied, then drop any file whose
#    contents hit the denylist. All of it lives in lib/blue-zone-project.sh so
#    sync-in.sh applies byte-for-byte the same rules.
#    Sets STAGED_ROOT_FILES.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_project_into "$BLUE_ZONE_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# 🔀 Shadow git repo — records this projection as the shared starting point for
# two-way sync. Both refs are set to the same commit here: the staging tree IS
# the repo's projection right now, so "what Claude has" and "what the host has"
# are identical, and that common ancestor is what later merges diff against.
#
# The repo lives OUTSIDE $BLUE_ZONE_ROOT (see lib/blue-zone-git.sh) so no .git
# is ever mounted into the container.
# ─────────────────────────────────────────────────────────────────────────────
if bz_git_mode; then
  echo -e "${BOLD}[sync]${RESET} recording baseline in the shadow git repo"
  bz_shadow_init
  bz_commit_work "prepare: projection of $BLUE_ZONE_PROJECT at $(date -u '+%Y-%m-%d %H:%M:%SZ')" || true
  bz_set_base_to_work
  echo -e "  ${GREEN}✓ baseline recorded${RESET} — ./ai-scripts/sync-in.sh refreshes the zone without losing Claude's work\n"
else
  echo -e "${YELLOW}[sync] git not available (or BLUE_ZONE_SYNC_MODE=legacy)${RESET}"
  echo -e "${YELLOW}       one-way copy only: sync-in.sh is unavailable and sync-back.sh${RESET}"
  echo -e "${YELLOW}       cannot merge concurrent host edits.${RESET}\n"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Snapshot of blue zone contents at prepare time.
# sync-back.sh uses this to tell Claude's changes apart from red-zone files.
# Lives at the blue zone root, which is NOT mounted into the container —
# only the configured folders and root files are. Covers both.
# ─────────────────────────────────────────────────────────────────────────────
if bz_git_mode; then
  # Derived from the base ref so it stays honest after a sync-in merge, when the
  # live tree also holds files Claude created (which the snapshot must exclude).
  bz_write_snapshot
else
  SNAPSHOT_ITEMS=("${BLUE_ZONE_FOLDERS[@]}")
  for rf in ${STAGED_ROOT_FILES[@]+"${STAGED_ROOT_FILES[@]}"}; do
    [ -f "$BLUE_ZONE_ROOT/$rf" ] && SNAPSHOT_ITEMS+=("$rf")
  done
  (cd "$BLUE_ZONE_ROOT" && find "${SNAPSHOT_ITEMS[@]}" -type f 2>/dev/null | sort > .blue-zone-snapshot)
fi

# ─────────────────────────────────────────────────────────────────────────────
# Generate the Claude-readable manifest of stripped (red-zone) files and the
# docker-compose mount overlay. Both live in lib/blue-zone-manifest.sh so
# sync-in.sh can refresh them after a mid-session merge.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_write_manifest
blue_zone_write_overlay "$SCRIPT_DIR/.."

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
for rf in ${STAGED_ROOT_FILES[@]+"${STAGED_ROOT_FILES[@]}"}; do
  [ -f "$BLUE_ZONE_ROOT/$rf" ] && \
    echo -e "   ${GREEN}•${RESET} $BLUE_ZONE_ROOT/$rf → /workspace/$rf"
done
echo -e "   ${GREEN}•${RESET} $BLUE_ZONE_ROOT/$BLUE_ZONE_MANIFEST_FILE → /workspace/$BLUE_ZONE_MANIFEST_FILE ${BOLD}(ro)${RESET}"
echo -e "${BOLD}────────────────────────────────────────${RESET}"
