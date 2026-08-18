#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-in.sh — Pull the repo's latest changes INTO a live blue zone.
#
# This is the half of two-way sync that lets you keep working while Claude does.
# Edit files in your repo as usual, then run this from a second terminal: your
# changes are merged into the staging tree that the running container is looking
# at, WITHOUT discarding anything Claude has written.
#
#   ./scripts/sync-in.sh            merge repo changes into the blue zone
#   ./scripts/sync-in.sh --dry-run  show what would come in, change nothing
#   ./scripts/sync-in.sh --abort    abandon a half-finished merge
#
# How it differs from prepare-blue-zone.sh: prepare RESETS the staging tree to
# match the repo, throwing away unsynced work. sync-in MERGES. Use prepare to
# start a session, sync-in to refresh one that is already running.
#
# Mechanism (see lib/blue-zone-git.sh for the full picture):
#   1. commit the live staging tree onto blue-work  — Claude's side
#   2. project the repo through the red-zone filter into a scratch tree and
#      commit it onto blue-base                     — your side
#   3. merge blue-base into blue-work
# Because both branches descend from a common commit, git can tell "the host
# changed this" apart from "Claude changed this" and only rewrites what actually
# moved on your side. Files you didn't touch are left exactly as Claude left
# them. When you both edited the same lines, the file gets standard conflict
# markers and Claude resolves them in-session; sync-back refuses to export a
# file whose markers are still there.
#
# Red-zone safety is unchanged: the incoming side is a fresh projection, so it
# can only ever contain files that passed every exclusion rule and the content
# denylist. Nothing red can enter the blue zone through this path.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../blue-zone.config.sh
source "$SCRIPT_DIR/../blue-zone.config.sh"

BLUE_ZONE_MANIFEST_FILE="${BLUE_ZONE_MANIFEST_FILE:-BLUE_ZONE_MANIFEST.md}"
declare -p BLUE_ZONE_ROOT_FILES >/dev/null 2>&1 || BLUE_ZONE_ROOT_FILES=()

# shellcheck source=lib/blue-zone-project.sh
source "$SCRIPT_DIR/lib/blue-zone-project.sh"
# shellcheck source=lib/blue-zone-git.sh
source "$SCRIPT_DIR/lib/blue-zone-git.sh"
# shellcheck source=lib/blue-zone-manifest.sh
source "$SCRIPT_DIR/lib/blue-zone-manifest.sh"

DRY_RUN=0
ABORT=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --abort)   ABORT=1 ;;
  "")        ;;
  *)
    echo -e "${RED}Unknown option: $1${RESET}"
    echo "Usage: $0 [--dry-run|--abort]"
    exit 1 ;;
esac

# ── Preconditions ────────────────────────────────────────────────────────────
if ! bz_git_mode; then
  echo -e "${RED}Two-way sync needs git on the host, and BLUE_ZONE_SYNC_MODE=git.${RESET}"
  echo "Current mode: ${BLUE_ZONE_SYNC_MODE}. Install git or unset BLUE_ZONE_SYNC_MODE."
  exit 1
fi

if [ ! -d "$BLUE_ZONE_ROOT" ]; then
  echo -e "${YELLOW}No blue zone at $BLUE_ZONE_ROOT.${RESET}"
  echo "Run ./scripts/prepare-blue-zone.sh first."
  exit 1
fi

if ! bz_shadow_ready; then
  echo -e "${YELLOW}This blue zone was staged before two-way sync existed.${RESET}"
  echo "Run ./scripts/prepare-blue-zone.sh once to record a baseline, then"
  echo "sync-in will work for the rest of the session."
  exit 1
fi

# ── --abort: throw away a half-finished merge ────────────────────────────────
if [ "$ABORT" = 1 ]; then
  if bz_merge_in_progress; then
    bz_git merge --abort 2>/dev/null || bz_git reset -q --hard HEAD
    bz_restore_mount_dirs
    echo -e "${GREEN}Merge aborted — the blue zone is back to Claude's last state.${RESET}"
  else
    echo -e "${GREEN}No merge in progress — nothing to abort.${RESET}"
  fi
  exit 0
fi

if bz_merge_in_progress; then
  echo -e "${RED}A previous merge is still unfinished in the shadow repo.${RESET}"
  echo "Run './scripts/sync-in.sh --abort' to discard it, then try again."
  exit 1
fi

echo -e "${BOLD}${CYAN}Syncing repo changes into the blue zone...${RESET}"
[ "$DRY_RUN" = 1 ] && echo -e "${YELLOW}(dry run — nothing will be written)${RESET}"
echo

# ── 1. Capture Claude's current state on blue-work ───────────────────────────
# Committing here is what makes the merge three-way: without it, Claude's
# in-flight edits would be uncommitted noise that git would refuse to merge over.
if bz_commit_work "sync-in: blue zone state before refresh"; then
  echo -e "${BOLD}[work]${RESET} recorded Claude's current changes"
else
  echo -e "${BOLD}[work]${RESET} no new changes in the blue zone"
fi

# ── 2. Project the repo into the scratch tree ────────────────────────────────
# Exactly the same red-zone filter prepare uses — same excludes, same denylist —
# just aimed at a scratch directory that is never mounted. Sets STAGED_ROOT_FILES.
echo -e "\n${BOLD}[repo]${RESET} projecting the repo through the red-zone filter\n"
blue_zone_project_into "$BLUE_ZONE_BASE_DIR"

# ── 3. Compare, then merge ───────────────────────────────────────────────────
if [ "$DRY_RUN" = 1 ]; then
  # Build the tree WITHOUT moving the base ref: advancing it here would make the
  # next real sync-in believe the repo hadn't changed and skip the merge.
  rm -f "$BZ_BASE_INDEX"
  bz_track_paths "$BLUE_ZONE_BASE_DIR"
  [ "${#BZ_TRACK_PATHS[@]}" -gt 0 ] && bz_git_base add -A -- "${BZ_TRACK_PATHS[@]}"
  PREVIEW_TREE="$(bz_git_base write-tree)"

  echo -e "${BOLD}Changes that would come in from the repo:${RESET}"
  CHANGES="$(bz_git_bare diff --name-status "refs/heads/$BLUE_ZONE_WORK_REF" "$PREVIEW_TREE" || true)"
  if [ -z "$CHANGES" ]; then
    echo -e "  ${GREEN}none — the blue zone already matches the repo${RESET}"
  else
    printf '%s\n' "$CHANGES" | while IFS=$'\t' read -r st path; do
      case "$st" in
        A*) echo -e "  ${GREEN}+ new${RESET}      $path" ;;
        D*) echo -e "  ${RED}- removed${RESET}  $path" ;;
        *)  echo -e "  ${YELLOW}~ changed${RESET}  $path" ;;
      esac
    done
    echo
    echo -e "${YELLOW}Note: this is the net difference between the two sides. Files Claude${RESET}"
    echo -e "${YELLOW}changed and you didn't appear here too; the real merge leaves those alone.${RESET}"
  fi
  exit 0
fi

if ! bz_commit_base "sync-in: repo projection at $(date -u '+%Y-%m-%d %H:%M:%SZ')"; then
  echo -e "\n${GREEN}The repo hasn't changed since the last sync — nothing to merge.${RESET}"
  exit 0
fi

echo -e "${BOLD}[merge]${RESET} merging repo changes into the blue zone"
if ! bz_merge_base_into_work "sync-in: merge repo changes into the blue zone"; then
  exit 1
fi
CONFLICTS="$BZ_MERGE_CONFLICTS"

# ── 4. Refresh the derived artefacts ─────────────────────────────────────────
# The snapshot comes from the base ref, so it describes the new projection —
# what Claude is now allowed to see — and not the files he created himself.
bz_write_snapshot
echo
blue_zone_write_manifest
blue_zone_write_overlay "$SCRIPT_DIR/.."

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}────────────────────────────────────────${RESET}"
if [ -n "$CONFLICTS" ]; then
  N=$(printf '%s\n' "$CONFLICTS" | grep -c . || true)
  echo -e "${YELLOW}${BOLD}Merged with $N conflict(s).${RESET}"
  printf '%s\n' "$CONFLICTS" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo -e "  ${YELLOW}!${RESET} $f"
  done
  echo
  echo -e "  These files now contain ${BOLD}<<<<<<< / >>>>>>>${RESET} markers in the workspace."
  echo -e "  Ask Claude to resolve them (edit the file, delete the markers) — it can"
  echo -e "  see them at /workspace/. sync-back will refuse to export a file that"
  echo -e "  still has markers, so nothing half-merged reaches your repo."
else
  echo -e "${GREEN}${BOLD}✅ Blue zone refreshed from the repo — Claude's work is intact.${RESET}"
fi
echo -e "${BOLD}────────────────────────────────────────${RESET}"
