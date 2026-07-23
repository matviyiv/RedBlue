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
#
# How it decides (and why it's fast): the snapshot is the set of files present
# at prepare time; the blue zone is the set present now. The three actions above
# are just set operations between those two sorted lists, computed in a single
# `comm` pass instead of grepping the whole snapshot once per file (which made
# sync-back O(files × snapshot) — the previous bottleneck on large trees):
#     snapshot ∩ now   → candidate updates (content compared by rsync)
#     now − snapshot   → files Claude created (add, or block on red-zone clash)
#     snapshot − now   → files Claude deleted (remove from the repo)
# Updates go through a single rsync restricted to the intersection list, so it
# skips unchanged files by size/mtime instead of byte-reading every file, and
# can never touch a red-zone or Claude-created path.
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

# Scratch space for the sorted file lists, cleaned up on exit.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
CURRENT_LIST="$WORK_DIR/current"   # files in the blue zone right now
SNAP_SORTED="$WORK_DIR/snapshot"   # files that were there at prepare time

# ── Build the "now" set: folder files + configured root files ─────────────────
# Paths are relative to the blue zone root, matching the snapshot's format. We
# `cd` into the root and `find` the items by relative name (mirroring how
# prepare-blue-zone.sh wrote the snapshot) so no fragile prefix-stripping is
# needed. Only configured folders/root files are ever mounted into the
# container, so this is exactly the universe Claude could have changed — the
# snapshot itself, the manifest, and the generated overlay stay out of it.
CURRENT_ITEMS=()
for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  [ -d "$BLUE_ZONE_ROOT/$folder" ] && CURRENT_ITEMS+=("$folder")
done
for rf in ${BLUE_ZONE_ROOT_FILES[@]+"${BLUE_ZONE_ROOT_FILES[@]}"}; do
  [ -f "$BLUE_ZONE_ROOT/$rf" ] && CURRENT_ITEMS+=("$rf")
done

if [ "${#CURRENT_ITEMS[@]}" -gt 0 ]; then
  ( cd "$BLUE_ZONE_ROOT" && find "${CURRENT_ITEMS[@]}" -type f 2>/dev/null ) \
    | LC_ALL=C sort -u > "$CURRENT_LIST"
else
  : > "$CURRENT_LIST"
fi

# Re-sort the snapshot with the same collation so `comm` sees consistent order
# regardless of the locale it was originally written under.
LC_ALL=C sort -u "$SNAPSHOT" > "$SNAP_SORTED"

# ── Updates: snapshot ∩ now — existed at prepare time and still present ────────
# rsync copies only the files whose size/mtime differ, in a single pass, and
# creates parent directories as needed. `--files-from` bounds it to the
# intersection list, so it can only ever write files Claude was allowed to see
# and that already existed — never a red-zone path or a newly created file.
UPDATE_LIST="$WORK_DIR/updates"
comm -12 "$CURRENT_LIST" "$SNAP_SORTED" > "$UPDATE_LIST"

if [ -s "$UPDATE_LIST" ]; then
  RSYNC_ARGS=(-a --itemize-changes --files-from="$UPDATE_LIST")
  [ "$DRY_RUN" = 1 ] && RSYNC_ARGS+=(--dry-run)
  # `--itemize-changes` prints one line per considered file; a leading '>' means
  # rsync sent it to the repo (i.e. content changed). Everything else (unchanged
  # files print nothing; created parent dirs print 'c…') is ignored.
  RSYNC_OUT="$WORK_DIR/rsync-out"
  rsync "${RSYNC_ARGS[@]}" "$BLUE_ZONE_ROOT/" "./" > "$RSYNC_OUT"
  while IFS= read -r line; do
    case "$line" in
      '>'*)
        # Itemize format is "<flags> <path>"; strip the flags up to the space.
        rel="${line#* }"
        echo -e "  ${GREEN}~ updated${RESET}  $rel"
        UPDATED=$((UPDATED + 1))
        ;;
    esac
  done < "$RSYNC_OUT"
fi

# ── Additions: now − snapshot — files Claude created during the session ───────
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ -e "./$rel" ]; then
    # Path exists in the repo but was stripped from the blue zone -> red zone.
    # Never overwrite it with container-generated content.
    echo -e "  ${RED}! blocked${RESET}  $rel ${RED}(collides with a red-zone file — left untouched)${RESET}"
    BLOCKED=$((BLOCKED + 1))
  else
    echo -e "  ${GREEN}+ added${RESET}    $rel"
    if [ "$DRY_RUN" = 0 ]; then
      mkdir -p "$(dirname "./$rel")"
      cp -p "$BLUE_ZONE_ROOT/$rel" "./$rel"
    fi
    ADDED=$((ADDED + 1))
  fi
done < <(comm -23 "$CURRENT_LIST" "$SNAP_SORTED")

# ── Deletions: snapshot − now — files Claude removed during the session ───────
# Only snapshotted paths reach here, so red-zone files are never touched.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ -f "./$rel" ]; then
    echo -e "  ${RED}- deleted${RESET}  $rel"
    [ "$DRY_RUN" = 0 ] && rm -f "./$rel"
    DELETED=$((DELETED + 1))
  fi
done < <(comm -13 "$CURRENT_LIST" "$SNAP_SORTED")

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
