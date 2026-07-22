#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-back.sh — Copy changes Claude made in the blue zone back into the repo
#
# Runs automatically after start-cli.sh / run-headless.sh sessions
# (set SYNC_BACK=0 to disable). Can also be run manually:
#   ./scripts/sync-back.sh            # apply changes
#   ./scripts/sync-back.sh --dry-run  # show what would change
#
# Safety rules:
#   • A file is only UPDATED if it was in the blue zone at prepare time
#     (recorded in the snapshot) — i.e. Claude was allowed to see it.
#   • A NEW file is only added if the path does not already exist in the
#     repo. If it does, it's a red-zone file that was deliberately stripped;
#     overwriting it is refused and a warning is printed.
#   • A file is DELETED from the repo only if it was in the blue zone at
#     prepare time (recorded in the snapshot) and Claude removed it during
#     the session. Red-zone files were never in the snapshot, so they can
#     never be deleted by sync-back.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

# Load the shared folder config (defines BLUE_ZONE_FOLDERS, BLUE_ZONE_ROOT).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../blue-zone.config.sh
source "$SCRIPT_DIR/../blue-zone.config.sh"

# Defensive default: an older config may not define BLUE_ZONE_ROOT_FILES.
declare -p BLUE_ZONE_ROOT_FILES >/dev/null 2>&1 || BLUE_ZONE_ROOT_FILES=()

SNAPSHOT="$BLUE_ZONE_ROOT/.blue-zone-snapshot"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ ! -d "$BLUE_ZONE_ROOT" ]; then
  echo -e "${YELLOW}No blue zone at $BLUE_ZONE_ROOT — nothing to sync back.${RESET}"
  exit 0
fi

if [ ! -f "$SNAPSHOT" ]; then
  echo -e "${RED}No snapshot at $SNAPSHOT.${RESET}"
  echo "sync-back needs the snapshot written by prepare-blue-zone.sh to tell"
  echo "Claude's changes apart from red-zone files. Re-run a session via"
  echo "start-cli.sh / run-headless.sh and sync-back will work from then on."
  exit 1
fi

echo -e "${BOLD}${CYAN}Syncing blue zone changes back into the repo...${RESET}"
[ "$DRY_RUN" = 1 ] && echo -e "${YELLOW}(dry run — no files will be written)${RESET}"

UPDATED=0
ADDED=0
BLOCKED=0
DELETED=0

# ── New + modified files ──────────────────────────────────────────────────────
# Iterate every configured blue-zone folder (see blue-zone.config.sh).
BLUE_ZONE_DIRS=()
for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  BLUE_ZONE_DIRS+=("$BLUE_ZONE_ROOT/$folder")
done

while IFS= read -r -d '' f; do
  rel="${f#"$BLUE_ZONE_ROOT"/}"

  if grep -qxF "$rel" "$SNAPSHOT"; then
    # Existed at prepare time — safe to update if content changed
    if ! cmp -s "$f" "./$rel" 2>/dev/null; then
      echo -e "  ${GREEN}~ updated${RESET}  $rel"
      if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "./$rel")"
        cp -p "$f" "./$rel"
      fi
      UPDATED=$((UPDATED + 1))
    fi
  else
    # Created by Claude during the session
    if [ -e "./$rel" ]; then
      # Path exists in repo but was stripped from the blue zone -> red zone.
      # Never overwrite it with container-generated content.
      echo -e "  ${RED}! blocked${RESET}  $rel ${RED}(collides with a red-zone file — left untouched)${RESET}"
      BLOCKED=$((BLOCKED + 1))
    else
      echo -e "  ${GREEN}+ added${RESET}    $rel"
      if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "./$rel")"
        cp -p "$f" "./$rel"
      fi
      ADDED=$((ADDED + 1))
    fi
  fi
done < <(find "${BLUE_ZONE_DIRS[@]}" -type f -print0 2>/dev/null)

# ── Configured root files ─────────────────────────────────────────────────────
# Same rules as folder files, but they live at the blue zone root (not inside a
# BLUE_ZONE_DIR), so they're handled here. Deletions are covered by the snapshot
# loop below, which treats every snapshotted path — folder file or root file —
# the same.
for rf in ${BLUE_ZONE_ROOT_FILES[@]+"${BLUE_ZONE_ROOT_FILES[@]}"}; do
  staged="$BLUE_ZONE_ROOT/$rf"
  [ -f "$staged" ] || continue
  if grep -qxF "$rf" "$SNAPSHOT"; then
    if ! cmp -s "$staged" "./$rf" 2>/dev/null; then
      echo -e "  ${GREEN}~ updated${RESET}  $rf"
      if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "./$rf")"
        cp -p "$staged" "./$rf"
      fi
      UPDATED=$((UPDATED + 1))
    fi
  elif [ -e "./$rf" ]; then
    echo -e "  ${RED}! blocked${RESET}  $rf ${RED}(collides with a red-zone file — left untouched)${RESET}"
    BLOCKED=$((BLOCKED + 1))
  else
    echo -e "  ${GREEN}+ added${RESET}    $rf"
    if [ "$DRY_RUN" = 0 ]; then
      mkdir -p "$(dirname "./$rf")"
      cp -p "$staged" "./$rf"
    fi
    ADDED=$((ADDED + 1))
  fi
done

# ── Deletions ─────────────────────────────────────────────────────────────────
# A snapshotted file (blue zone at prepare time) that Claude removed during the
# session is deleted from the repo too. Only files Claude was allowed to see can
# reach this branch, so red-zone paths are never touched.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ ! -f "$BLUE_ZONE_ROOT/$rel" ] && [ -f "./$rel" ]; then
    echo -e "  ${RED}- deleted${RESET}  $rel"
    if [ "$DRY_RUN" = 0 ]; then
      rm -f "./$rel"
    fi
    DELETED=$((DELETED + 1))
  fi
done < "$SNAPSHOT"

# ── Summary ───────────────────────────────────────────────────────────────────
if [ $((UPDATED + ADDED + BLOCKED + DELETED)) -eq 0 ]; then
  echo -e "${GREEN}No changes to sync back.${RESET}"
else
  echo -e "${BOLD}────────────────────────────────────────${RESET}"
  echo -e "  updated: ${BOLD}$UPDATED${RESET}  added: ${BOLD}$ADDED${RESET}" \
          " blocked: ${BOLD}$BLOCKED${RESET}  deleted: ${BOLD}$DELETED${RESET}"
  if [ "$BLOCKED" -gt 0 ]; then
    echo -e "  ${RED}Blocked files collide with red-zone paths — review them manually"
    echo -e "  in $BLUE_ZONE_ROOT before deciding what to do.${RESET}"
  fi
  if [ "$DELETED" -gt 0 ]; then
    echo -e "  ${YELLOW}Deleted files were in the blue zone and removed by Claude."
    echo -e "  Review the diff before committing if you want to keep any of them.${RESET}"
  fi
  echo -e "${BOLD}────────────────────────────────────────${RESET}"
fi
