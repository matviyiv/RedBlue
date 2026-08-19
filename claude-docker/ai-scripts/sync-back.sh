#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-back.sh — Copy changes Claude made in the blue zone back into the repo
#
# Runs automatically after start-cli.sh / run-headless.sh sessions
# (set SYNC_BACK=0 to disable). Can also be run manually:
#   ./ai-scripts/sync-back.sh                 apply changes to your working tree
#   ./ai-scripts/sync-back.sh --dry-run       show what would change
#   ./ai-scripts/sync-back.sh --mr            also branch, commit, push, open an MR
#   ./ai-scripts/sync-back.sh --mr --merge    …and merge it when the pipeline passes
#
# By default this stops at your working tree: the changes land in your checkout
# and you review and commit them yourself. Git is only touched with --mr.
#
# ── How it decides what to copy ──────────────────────────────────────────────
# The blue zone is tracked by a shadow git repo (lib/blue-zone-git.sh) with two
# branches: blue-base (the repo as projected through the red-zone filter) and
# blue-work (the live staging tree). The change set is
#
#     git diff blue-base..blue-work
#
# which is *exactly* what Claude changed — not "everything that differs from a
# stale snapshot". That distinction is what makes concurrent work safe: if you
# edited a file on the host during the session, it isn't in Claude's diff, so it
# is never overwritten. If you both edited the same file, the two edits are
# merged with `git merge-file` instead of one silently winning.
#
# Without git on the host (BLUE_ZONE_SYNC_MODE=legacy) it falls back to the
# original one-way set-arithmetic copy, which cannot merge concurrent edits.
#
# ── Safety rules (unchanged from the original) ───────────────────────────────
#   • A file is only UPDATED if it was in the blue zone at projection time —
#     i.e. Claude was allowed to see it. Modified and deleted paths come out of
#     a diff against blue-base, so this holds by construction.
#   • A NEW file is only added if the path does not already exist in the repo.
#     If it does, it's a red-zone file that was deliberately stripped;
#     overwriting it is refused and a warning is printed.
#   • A file is DELETED from the repo only if Claude removed it AND your copy
#     still matches what he started from. If you changed it meanwhile, the
#     deletion is skipped rather than throwing your edit away.
#   • Every path is re-checked against the red-zone rules before anything is
#     written, as defense in depth.
#   • A file still carrying merge-conflict markers is never exported.
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

# shellcheck source=lib/blue-zone-project.sh
source "$SCRIPT_DIR/lib/blue-zone-project.sh"
# shellcheck source=lib/blue-zone-git.sh
source "$SCRIPT_DIR/lib/blue-zone-git.sh"

SNAPSHOT="$BLUE_ZONE_ROOT/.blue-zone-snapshot"

# ── Options ──────────────────────────────────────────────────────────────────
DRY_RUN=0
WANT_MR=0
WANT_MERGE=0
MR_BRANCH=""
MR_TARGET="$BLUE_ZONE_MR_TARGET"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --mr)        WANT_MR=1 ;;
    --merge)     WANT_MR=1; WANT_MERGE=1 ;;
    --mr-branch) MR_BRANCH="${2:-}"; shift ;;
    --mr-target) MR_TARGET="${2:-}"; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--mr [--mr-branch NAME] [--mr-target NAME] [--merge]]"
      exit 0 ;;
    *)
      echo -e "${RED}Unknown option: $1${RESET}"
      echo "Usage: $0 [--dry-run] [--mr [--mr-branch NAME] [--mr-target NAME] [--merge]]"
      exit 1 ;;
  esac
  shift
done

if [ ! -d "$BLUE_ZONE_ROOT" ]; then
  echo -e "${YELLOW}No blue zone at $BLUE_ZONE_ROOT — nothing to sync back.${RESET}"
  exit 0
fi

UPDATED=0
MERGED=0
ADDED=0
BLOCKED=0
DELETED=0
CONFLICTED=0
SYNCED_PATHS=()

# ─────────────────────────────────────────────────────────────────────────────
# Is this path excluded by a red-zone rule?
#
# Defense in depth. Nothing red should ever reach the change set — the blue zone
# is built by applying these very rules — but this is the last gate before we
# write into the real repo, so it re-checks rather than trusting upstream.
# Mirrors validate-blue-zone.sh: a trailing-slash pattern matches a directory
# anywhere in the path, everything else is a glob against the basename.
# ─────────────────────────────────────────────────────────────────────────────
bz_path_is_red() {
  local rel="$1"
  local folder="${rel%%/*}"
  local pattern name
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    name="${pattern%/}"
    name="${name#\*\*/}"
    [ -n "$name" ] || continue
    case "$pattern" in
      */)
        # Directory rule — match any path segment.
        case "/$rel/" in */"$name"/*) return 0 ;; esac
        ;;
      *)
        case "${rel##*/}" in $name) return 0 ;; esac
        ;;
    esac
  done < <(blue_zone_all_patterns_for "$folder")
  return 1
}

# True when the file looks binary — `git merge-file` would mangle it, so a
# two-sided change on a binary file is reported instead of merged.
bz_is_binary() {
  [ -f "$1" ] || return 1
  ! grep -Iq . "$1" 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
# GIT MODE — three-way merge in both directions
# ═════════════════════════════════════════════════════════════════════════════
sync_back_git() {
  local WORK_DIR base_file merged_file rel st rc
  WORK_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$WORK_DIR'" EXIT

  if bz_merge_in_progress; then
    echo -e "${RED}The blue zone has an unfinished merge.${RESET}"
    echo "Run './ai-scripts/sync-in.sh --abort' first, then sync back."
    exit 1
  fi

  # Record Claude's latest edits so the diff below sees them.
  bz_commit_work "sync-back: blue zone state at $(date -u '+%Y-%m-%d %H:%M:%SZ')" >/dev/null || true

  # --no-renames keeps the change set in plain add/modify/delete terms; a rename
  # reported as R would need special handling for no benefit, since we copy file
  # by file anyway.
  local CHANGES
  CHANGES="$(bz_git_bare diff --no-renames --name-status \
    "refs/heads/$BLUE_ZONE_BASE_REF" "refs/heads/$BLUE_ZONE_WORK_REF" || true)"

  # Nothing to do — the shared summary below reports it.
  [ -n "$CHANGES" ] || return 0

  while IFS=$'\t' read -r st rel; do
    [ -n "$rel" ] || continue

    # ── Gate 1: red-zone rules ────────────────────────────────────────────────
    if bz_path_is_red "$rel"; then
      echo -e "  ${RED}! blocked${RESET}  $rel ${RED}(matches a red-zone rule)${RESET}"
      BLOCKED=$((BLOCKED + 1))
      continue
    fi

    # ── Gate 2: unresolved conflict markers ───────────────────────────────────
    # A file Claude hasn't finished merging must not reach the repo.
    if [ "$st" != "D" ] && [ -f "$BLUE_ZONE_ROOT/$rel" ] \
       && bz_has_conflict_markers "$BLUE_ZONE_ROOT/$rel"; then
      echo -e "  ${YELLOW}! conflict${RESET} $rel ${YELLOW}(still has merge markers — not exported)${RESET}"
      CONFLICTED=$((CONFLICTED + 1))
      continue
    fi

    case "$st" in
      # ── Added by Claude ───────────────────────────────────────────────────
      A)
        if [ -e "./$rel" ]; then
          # Path exists in the repo but was stripped from the blue zone -> red
          # zone. Never overwrite it with container-generated content.
          echo -e "  ${RED}! blocked${RESET}  $rel ${RED}(collides with a red-zone file — left untouched)${RESET}"
          BLOCKED=$((BLOCKED + 1))
        else
          echo -e "  ${GREEN}+ added${RESET}    $rel"
          if [ "$DRY_RUN" = 0 ]; then
            mkdir -p "$(dirname "./$rel")"
            cp -p "$BLUE_ZONE_ROOT/$rel" "./$rel"
          fi
          SYNCED_PATHS+=("$rel")
          ADDED=$((ADDED + 1))
        fi
        ;;

      # ── Modified by Claude ────────────────────────────────────────────────
      M|T)
        if [ ! -f "./$rel" ]; then
          # You deleted it on the host while Claude was editing it. Re-creating
          # the file would undo a deliberate deletion, so leave it alone.
          echo -e "  ${YELLOW}! skipped${RESET}  $rel ${YELLOW}(you deleted it in the repo)${RESET}"
          BLOCKED=$((BLOCKED + 1))
          continue
        fi

        base_file="$WORK_DIR/base"
        bz_git_bare show "refs/heads/$BLUE_ZONE_BASE_REF:$rel" > "$base_file" 2>/dev/null || : > "$base_file"

        if cmp -s "./$rel" "$base_file"; then
          # Fast path: your copy is untouched since projection, so Claude's
          # version simply wins. No merge needed.
          echo -e "  ${GREEN}~ updated${RESET}  $rel"
          [ "$DRY_RUN" = 0 ] && cp -p "$BLUE_ZONE_ROOT/$rel" "./$rel"
          SYNCED_PATHS+=("$rel")
          UPDATED=$((UPDATED + 1))
          continue
        fi

        if bz_is_binary "./$rel" || bz_is_binary "$BLUE_ZONE_ROOT/$rel"; then
          echo -e "  ${YELLOW}! conflict${RESET} $rel ${YELLOW}(binary changed on both sides — resolve by hand)${RESET}"
          CONFLICTED=$((CONFLICTED + 1))
          continue
        fi

        # Both sides moved: merge them. `git merge-file` needs no object
        # database, so this works even when your change is uncommitted — or
        # when the project isn't a git repo at all.
        merged_file="$WORK_DIR/merged"
        cp "./$rel" "$merged_file"
        set +e
        git merge-file -L "yours (repo)" -L "blue-zone base" -L "claude" \
          "$merged_file" "$base_file" "$BLUE_ZONE_ROOT/$rel" >/dev/null 2>&1
        rc=$?
        set -e

        if [ "$rc" -lt 0 ] || [ "$rc" -gt 127 ]; then
          echo -e "  ${RED}! blocked${RESET}  $rel ${RED}(merge failed — left untouched)${RESET}"
          BLOCKED=$((BLOCKED + 1))
        elif [ "$rc" -gt 0 ]; then
          echo -e "  ${YELLOW}~ merged${RESET}   $rel ${YELLOW}($rc conflict(s) — markers written into your file)${RESET}"
          [ "$DRY_RUN" = 0 ] && cp "$merged_file" "./$rel"
          SYNCED_PATHS+=("$rel")
          MERGED=$((MERGED + 1))
          CONFLICTED=$((CONFLICTED + 1))
        else
          echo -e "  ${GREEN}~ merged${RESET}   $rel ${GREEN}(your edit kept)${RESET}"
          [ "$DRY_RUN" = 0 ] && cp "$merged_file" "./$rel"
          SYNCED_PATHS+=("$rel")
          MERGED=$((MERGED + 1))
        fi
        ;;

      # ── Deleted by Claude ─────────────────────────────────────────────────
      D)
        if [ ! -f "./$rel" ]; then
          continue   # already gone in the repo — nothing to do
        fi
        base_file="$WORK_DIR/base"
        bz_git_bare show "refs/heads/$BLUE_ZONE_BASE_REF:$rel" > "$base_file" 2>/dev/null || : > "$base_file"
        if cmp -s "./$rel" "$base_file"; then
          echo -e "  ${RED}- deleted${RESET}  $rel"
          [ "$DRY_RUN" = 0 ] && rm -f "./$rel"
          SYNCED_PATHS+=("$rel")
          DELETED=$((DELETED + 1))
        else
          # Claude deleted it, you changed it. Deleting would discard your work,
          # so keep the file and say so.
          echo -e "  ${YELLOW}! kept${RESET}     $rel ${YELLOW}(Claude deleted it, but you changed it — not removed)${RESET}"
          BLOCKED=$((BLOCKED + 1))
        fi
        ;;
    esac
  done <<< "$CHANGES"

  # ── Re-baseline ────────────────────────────────────────────────────────────
  # The repo now holds what we just applied, so re-project it onto blue-base and
  # merge that back into the blue zone. Both steps matter:
  #
  #   • re-projecting means running sync-back twice reports "no changes" instead
  #     of replaying the same diff (and anything blocked stays out of the base,
  #     so it is correctly offered again next time);
  #   • merging means the zone ends up holding the same merged text as the repo.
  #     Skip it and blue-work keeps Claude's pre-merge version forever, so every
  #     later sync-back re-reports a file that is already in sync.
  if [ "$DRY_RUN" = 0 ] && [ "$((UPDATED + MERGED + ADDED + DELETED))" -gt 0 ]; then
    blue_zone_project_into "$BLUE_ZONE_BASE_DIR" >/dev/null 2>&1 || true
    if bz_commit_base "sync-back: repo state after sync at $(date -u '+%Y-%m-%d %H:%M:%SZ')"; then
      bz_merge_base_into_work "sync-back: align the blue zone with the repo" >/dev/null || true
      bz_write_snapshot
    fi
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# LEGACY MODE — the original one-way set-arithmetic copy.
#
# Kept for hosts without git (BLUE_ZONE_SYNC_MODE=legacy). It cannot merge: a
# host edit made during the session is overwritten by the blue-zone copy.
#
# The snapshot is the set of files present at projection time; the blue zone is
# the set present now. The three actions are set operations between those two
# sorted lists, computed in a single `comm` pass:
#     snapshot ∩ now   → candidate updates (content compared by rsync)
#     now − snapshot   → files Claude created (add, or block on red-zone clash)
#     snapshot − now   → files Claude deleted (remove from the repo)
# ═════════════════════════════════════════════════════════════════════════════
sync_back_legacy() {
  if [ ! -f "$SNAPSHOT" ]; then
    echo -e "${RED}No snapshot at $SNAPSHOT.${RESET}"
    echo "sync-back needs the snapshot written by prepare-blue-zone.sh to tell"
    echo "Claude's changes apart from red-zone files. Re-run a session via"
    echo "start-cli.sh / run-headless.sh and sync-back will work from then on."
    exit 1
  fi

  local WORK_DIR CURRENT_LIST SNAP_SORTED UPDATE_LIST RSYNC_OUT rel line
  WORK_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$WORK_DIR'" EXIT
  CURRENT_LIST="$WORK_DIR/current"
  SNAP_SORTED="$WORK_DIR/snapshot"

  local CURRENT_ITEMS=()
  local folder rf
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

  LC_ALL=C sort -u "$SNAPSHOT" > "$SNAP_SORTED"

  UPDATE_LIST="$WORK_DIR/updates"
  comm -12 "$CURRENT_LIST" "$SNAP_SORTED" > "$UPDATE_LIST"

  if [ -s "$UPDATE_LIST" ]; then
    local RSYNC_ARGS=(-a --itemize-changes --files-from="$UPDATE_LIST")
    [ "$DRY_RUN" = 1 ] && RSYNC_ARGS+=(--dry-run)
    RSYNC_OUT="$WORK_DIR/rsync-out"
    rsync "${RSYNC_ARGS[@]}" "$BLUE_ZONE_ROOT/" "./" > "$RSYNC_OUT"
    while IFS= read -r line; do
      case "$line" in
        '>'*)
          rel="${line#* }"
          echo -e "  ${GREEN}~ updated${RESET}  $rel"
          SYNCED_PATHS+=("$rel")
          UPDATED=$((UPDATED + 1))
          ;;
      esac
    done < "$RSYNC_OUT"
  fi

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "./$rel" ]; then
      echo -e "  ${RED}! blocked${RESET}  $rel ${RED}(collides with a red-zone file — left untouched)${RESET}"
      BLOCKED=$((BLOCKED + 1))
    else
      echo -e "  ${GREEN}+ added${RESET}    $rel"
      if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "./$rel")"
        cp -p "$BLUE_ZONE_ROOT/$rel" "./$rel"
      fi
      SYNCED_PATHS+=("$rel")
      ADDED=$((ADDED + 1))
    fi
  done < <(comm -23 "$CURRENT_LIST" "$SNAP_SORTED")

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -f "./$rel" ]; then
      echo -e "  ${RED}- deleted${RESET}  $rel"
      [ "$DRY_RUN" = 0 ] && rm -f "./$rel"
      SYNCED_PATHS+=("$rel")
      DELETED=$((DELETED + 1))
    fi
  done < <(comm -13 "$CURRENT_LIST" "$SNAP_SORTED")
}

# ═════════════════════════════════════════════════════════════════════════════
# Merge request flow (--mr) — host-side only.
#
# The container's egress allowlist covers Anthropic, GitHub and the npm
# registries, not GitLab, so this could not run inside the container even if we
# wanted it to. Every preflight failure degrades gracefully: the synced changes
# are already in your working tree, so the worst case is "you commit it
# yourself".
# ═════════════════════════════════════════════════════════════════════════════
open_merge_request() {
  local branch target orig_branch title body attempt delay pushed

  if [ "${#SYNCED_PATHS[@]}" -eq 0 ]; then
    echo -e "${YELLOW}Nothing was synced — no merge request to open.${RESET}"
    return 0
  fi

  if ! command -v git >/dev/null 2>&1 \
     || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo -e "${YELLOW}Not a git repository — changes are in your working tree, but${RESET}"
    echo -e "${YELLOW}there is nothing to branch from. Skipping --mr.${RESET}"
    return 0
  fi

  # Refuse to sweep someone else's staged work into the AI commit.
  if ! git diff --cached --quiet 2>/dev/null; then
    echo -e "${RED}Your git index has staged changes.${RESET}"
    echo "Commit or unstage them first — --mr must not fold them into its commit."
    echo "The synced changes are already in your working tree."
    return 1
  fi

  orig_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  if [ "$orig_branch" = "HEAD" ] && [ -z "$MR_TARGET" ]; then
    echo -e "${RED}Detached HEAD and no target branch given.${RESET}"
    echo "Re-run with --mr-target <branch>."
    return 1
  fi
  target="${MR_TARGET:-$orig_branch}"

  branch="$MR_BRANCH"
  [ -n "$branch" ] || branch="${BLUE_ZONE_MR_BRANCH_PREFIX}-$(date -u +%Y%m%d-%H%M%S)"

  title="AI review changes from the $BLUE_ZONE_PROJECT blue zone"
  body="$(mr_description "$target")"

  if [ "$DRY_RUN" = 1 ]; then
    echo
    echo -e "${BOLD}Would open a merge request:${RESET}"
    echo -e "  branch : ${BOLD}$branch${RESET}"
    echo -e "  target : ${BOLD}$target${RESET}"
    echo -e "  title  : $title"
    echo -e "  files  : ${#SYNCED_PATHS[@]}"
    [ "$WANT_MERGE" = 1 ] && echo -e "  ${YELLOW}and merge it when the pipeline succeeds${RESET}"
    return 0
  fi

  echo
  echo -e "${BOLD}${CYAN}Opening a merge request...${RESET}"

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git checkout -q "$branch"
  else
    git checkout -q -b "$branch"
  fi

  # Stage ONLY what we synced. Never `git add -A`: unrelated work in your tree
  # (and every red-zone file in the repo) must stay out of this commit.
  git add -- "${SYNCED_PATHS[@]}" 2>/dev/null || true

  if git diff --cached --quiet; then
    echo -e "${YELLOW}Nothing to commit on $branch — the changes were already committed.${RESET}"
    git checkout -q "$orig_branch" 2>/dev/null || true
    return 0
  fi

  git commit -q -m "$title" -m "$body"
  echo -e "  ${GREEN}✓ committed${RESET} ${#SYNCED_PATHS[@]} path(s) on $branch"

  # Push with backoff — a transient network failure shouldn't lose the commit.
  pushed=0
  delay=2
  for attempt in 1 2 3 4 5; do
    if git push -u origin "$branch" >/dev/null 2>&1; then
      pushed=1
      break
    fi
    [ "$attempt" = 5 ] && break
    echo -e "  ${YELLOW}push failed — retrying in ${delay}s (attempt $attempt/4)${RESET}"
    sleep "$delay"
    delay=$((delay * 2))
  done

  if [ "$pushed" = 0 ]; then
    echo -e "${RED}Push failed.${RESET} The commit is intact on branch $branch —"
    echo "push it yourself once the remote is reachable."
    return 1
  fi
  echo -e "  ${GREEN}✓ pushed${RESET} origin/$branch"

  if ! command -v "$BLUE_ZONE_GLAB" >/dev/null 2>&1; then
    echo -e "${YELLOW}glab not installed — branch pushed, but no MR opened.${RESET}"
    echo "  Install it (https://gitlab.com/gitlab-org/cli) or open the MR in the UI."
    git checkout -q "$orig_branch" 2>/dev/null || true
    return 0
  fi

  if ! "$BLUE_ZONE_GLAB" auth status >/dev/null 2>&1; then
    echo -e "${YELLOW}glab is not authenticated — branch pushed, but no MR opened.${RESET}"
    echo "  Run 'glab auth login' (or set GITLAB_TOKEN), then open the MR."
    git checkout -q "$orig_branch" 2>/dev/null || true
    return 0
  fi

  if ! git remote get-url origin 2>/dev/null | grep -qi gitlab; then
    echo -e "${YELLOW}origin doesn't look like GitLab — branch pushed, but no MR opened.${RESET}"
    echo "  glab targets GitLab; open the merge/pull request in your forge's UI."
    git checkout -q "$orig_branch" 2>/dev/null || true
    return 0
  fi

  if "$BLUE_ZONE_GLAB" mr create \
       --source-branch "$branch" \
       --target-branch "$target" \
       --title "$title" \
       --description "$body" \
       --yes; then
    echo -e "  ${GREEN}✓ merge request opened${RESET} ($branch → $target)"
    if [ "$WANT_MERGE" = 1 ]; then
      if "$BLUE_ZONE_GLAB" mr merge "$branch" --yes --when-pipeline-succeeds; then
        echo -e "  ${GREEN}✓ set to merge when the pipeline succeeds${RESET}"
      else
        echo -e "  ${YELLOW}Could not set auto-merge — merge it from the MR page.${RESET}"
      fi
    fi
  else
    echo -e "${YELLOW}glab could not open the MR — the branch is pushed, so you can${RESET}"
    echo -e "${YELLOW}open it from the GitLab UI.${RESET}"
  fi

  git checkout -q "$orig_branch" 2>/dev/null || true
  echo -e "  ${CYAN}back on $orig_branch${RESET}"
}

# The MR body. Reviewers need to know these changes were written against a
# filtered copy of the repo — Claude could not see the red-zone files, so any
# assumption about them is inference, not knowledge.
mr_description() {
  local target="$1" p
  echo "Changes produced by Claude Code running in the blue zone for \`$BLUE_ZONE_PROJECT\`."
  echo
  echo "- updated: $UPDATED"
  echo "- merged with local edits: $MERGED"
  echo "- added: $ADDED"
  echo "- deleted: $DELETED"
  echo "- target: \`$target\`"
  echo
  echo "Files:"
  for p in "${SYNCED_PATHS[@]}"; do
    echo "- \`$p\`"
  done
  echo
  echo "Claude worked against a red-zone-filtered copy of this repository: API"
  echo "clients, service implementations, signing material and environment files"
  echo "were never visible to it. Review anything that depends on those with that"
  echo "in mind."
}

# ═════════════════════════════════════════════════════════════════════════════
# Run
# ═════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}${CYAN}Syncing blue zone changes back into the repo...${RESET}"
[ "$DRY_RUN" = 1 ] && echo -e "${YELLOW}(dry run — no files will be written)${RESET}"

if bz_shadow_ready; then
  sync_back_git
else
  if bz_git_mode; then
    echo -e "${YELLOW}No shadow git baseline for this blue zone — falling back to the${RESET}"
    echo -e "${YELLOW}one-way copy. Re-run prepare-blue-zone.sh to enable merging.${RESET}"
  fi
  sync_back_legacy
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((UPDATED + MERGED + ADDED + BLOCKED + DELETED + CONFLICTED))
if [ "$TOTAL" -eq 0 ]; then
  echo -e "${GREEN}No changes to sync back.${RESET}"
else
  echo -e "${BOLD}────────────────────────────────────────${RESET}"
  echo -e "  updated: ${BOLD}$UPDATED${RESET}  merged: ${BOLD}$MERGED${RESET}" \
          " added: ${BOLD}$ADDED${RESET}  blocked: ${BOLD}$BLOCKED${RESET}" \
          " deleted: ${BOLD}$DELETED${RESET}"
  if [ "$BLOCKED" -gt 0 ]; then
    echo -e "  ${RED}Blocked files collide with red-zone paths or with your own edits —"
    echo -e "  review them in $BLUE_ZONE_ROOT before deciding what to do.${RESET}"
  fi
  if [ "$CONFLICTED" -gt 0 ]; then
    echo -e "  ${YELLOW}$CONFLICTED file(s) need a human: either Claude left merge markers in"
    echo -e "  the blue zone, or your edit and his overlapped. Search for '<<<<<<<'.${RESET}"
  fi
  if [ "$DELETED" -gt 0 ]; then
    echo -e "  ${YELLOW}Deleted files were in the blue zone and removed by Claude."
    echo -e "  Review the diff before committing if you want to keep any of them.${RESET}"
  fi
  echo -e "${BOLD}────────────────────────────────────────${RESET}"
fi

if [ "$WANT_MR" = 1 ]; then
  open_merge_request
fi

exit 0
