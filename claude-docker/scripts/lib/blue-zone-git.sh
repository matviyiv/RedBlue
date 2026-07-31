#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/blue-zone-git.sh — the shadow git repo behind two-way sync.
#
# WHY THIS EXISTS
# The blue zone used to be a one-way copy: prepare overwrote the staging tree
# from the repo, sync-back overwrote the repo from the staging tree. Whoever ran
# last won, so a human could not edit the repo while Claude edited the zone.
#
# Tracking the staging tree in a git repo turns both directions into a real
# three-way merge instead of an overwrite:
#
#   blue-base  the repo, projected through the red-zone filter
#              ("what the host currently looks like")
#   blue-work  the live staging tree, including Claude's edits
#
#   repo → zone   commit the projection to blue-base, merge blue-base into
#                 blue-work (sync-in.sh)
#   zone → repo   diff blue-base..blue-work to get exactly what Claude changed,
#                 merge those changes into the repo (sync-back.sh)
#
# WHERE IT LIVES — AND WHY CLAUDE CANNOT SEE IT
# The git directory sits in $BLUE_ZONE_STATE_DIR, a SIBLING of the staging root
# (/tmp/blue-zone/<project>.gitsync), and the work tree is passed explicitly on
# every command. So:
#   • no .git directory exists anywhere under $BLUE_ZONE_ROOT, and only paths
#     under $BLUE_ZONE_ROOT are ever bind-mounted → the container cannot reach
#     the shadow repo, and the "never run git in /workspace" rule still holds;
#   • validate-blue-zone.sh, which scans all of $BLUE_ZONE_ROOT, never sees git
#     objects and cannot mistake them for project content;
#   • prepare's `chmod -R a+rwX` and file count over the root stay accurate.
#
# The shadow repo has no remote and is never pushed. It is pure local
# bookkeeping, and deleting it is always safe — the next prepare rebuilds it.
#
# Sourced, not executed. Requires blue-zone.config.sh to be sourced first.
# Kept bash-3.2 compatible (macOS default).
# ─────────────────────────────────────────────────────────────────────────────

: "${BOLD:=}" "${GREEN:=}" "${YELLOW:=}" "${RED:=}" "${CYAN:=}" "${RESET:=}"

# Defensive default: an older blue-zone.config.sh may not define these.
BLUE_ZONE_STATE_DIR="${BLUE_ZONE_STATE_DIR:-${BLUE_ZONE_ROOT}.gitsync}"
BLUE_ZONE_SHADOW_GIT="${BLUE_ZONE_SHADOW_GIT:-$BLUE_ZONE_STATE_DIR/shadow.git}"
BLUE_ZONE_BASE_DIR="${BLUE_ZONE_BASE_DIR:-$BLUE_ZONE_STATE_DIR/base}"
BLUE_ZONE_BASE_REF="${BLUE_ZONE_BASE_REF:-blue-base}"
BLUE_ZONE_WORK_REF="${BLUE_ZONE_WORK_REF:-blue-work}"
BLUE_ZONE_SYNC_MODE="${BLUE_ZONE_SYNC_MODE:-git}"
BLUE_ZONE_GIT_AUTHOR="${BLUE_ZONE_GIT_AUTHOR:-blue-zone sync}"
BLUE_ZONE_GIT_EMAIL="${BLUE_ZONE_GIT_EMAIL:-blue-zone-sync@localhost}"

BZ_BASE_INDEX="$BLUE_ZONE_STATE_DIR/base.index"

# ─────────────────────────────────────────────────────────────────────────────
# Command wrappers
# ─────────────────────────────────────────────────────────────────────────────

# Run git against the shadow repo with the LIVE staging tree as its work tree.
# HEAD is permanently on $BLUE_ZONE_WORK_REF, so ordinary porcelain (add,
# commit, merge) operates on Claude's tree.
bz_git() {
  git --git-dir="$BLUE_ZONE_SHADOW_GIT" --work-tree="$BLUE_ZONE_ROOT" "$@"
}

# Run git against the shadow repo with the SCRATCH projection tree as its work
# tree, using a separate index so it never disturbs the live tree's staged
# state. Used only to build commits on $BLUE_ZONE_BASE_REF.
bz_git_base() {
  GIT_INDEX_FILE="$BZ_BASE_INDEX" \
  git --git-dir="$BLUE_ZONE_SHADOW_GIT" --work-tree="$BLUE_ZONE_BASE_DIR" "$@"
}

# Plumbing that needs neither work tree (rev-parse, update-ref, diff of refs…).
bz_git_bare() {
  git --git-dir="$BLUE_ZONE_SHADOW_GIT" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# Availability
# ─────────────────────────────────────────────────────────────────────────────

# True when git-mode sync can run: the engine is enabled and git exists.
# Callers fall back to the legacy one-way copy when this is false.
bz_git_mode() {
  [ "$BLUE_ZONE_SYNC_MODE" = "git" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  return 0
}

# True when the shadow repo exists and both refs are present — i.e. a prepare
# has run and two-way sync is usable.
bz_shadow_ready() {
  bz_git_mode || return 1
  [ -d "$BLUE_ZONE_SHADOW_GIT" ] || return 1
  bz_git_bare rev-parse --verify --quiet "refs/heads/$BLUE_ZONE_BASE_REF" >/dev/null || return 1
  bz_git_bare rev-parse --verify --quiet "refs/heads/$BLUE_ZONE_WORK_REF" >/dev/null || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# The set of paths the shadow repo is allowed to track: the configured folders
# and root files, and nothing else. Every `git add` is scoped to this list, so
# the snapshot, manifest and generated overlay sitting at the staging root are
# never committed even if info/exclude were wrong.
# Populates BZ_TRACK_PATHS from paths that exist under <root>.
# ─────────────────────────────────────────────────────────────────────────────
bz_track_paths() {
  local root="$1" folder rf
  BZ_TRACK_PATHS=()
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    [ -d "$root/$folder" ] && BZ_TRACK_PATHS+=("$folder")
  done
  for rf in ${BLUE_ZONE_ROOT_FILES[@]+"${BLUE_ZONE_ROOT_FILES[@]}"}; do
    [ -f "$root/$rf" ] && BZ_TRACK_PATHS+=("$rf")
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Write $BLUE_ZONE_SHADOW_GIT/info/exclude so everything at the staging root is
# ignored except the configured folders and root files. Regenerated on every run
# because BLUE_ZONE_FOLDERS can change between runs.
#
# Git cannot re-include a path whose parent directory is excluded, so a root
# file nested in a directory (e.g. config/app.json) needs each parent
# re-included on its own line before the file itself.
# ─────────────────────────────────────────────────────────────────────────────
bz_write_exclude() {
  local out="$BLUE_ZONE_SHADOW_GIT/info/exclude"
  local folder rf dir acc seg oldifs
  mkdir -p "$BLUE_ZONE_SHADOW_GIT/info"
  {
    echo "# AUTO-GENERATED by lib/blue-zone-git.sh — regenerated on every run."
    echo "# Ignore everything at the staging root (snapshot, manifest, overlay),"
    echo "# then re-include only the configured blue-zone paths."
    echo "/*"
    for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
      echo "!/$folder/"
    done
    for rf in ${BLUE_ZONE_ROOT_FILES[@]+"${BLUE_ZONE_ROOT_FILES[@]}"}; do
      case "$rf" in
        */*)
          dir="${rf%/*}"
          acc=""
          oldifs="$IFS"
          IFS='/'
          for seg in $dir; do
            acc="$acc/$seg"
            echo "!$acc/"
          done
          IFS="$oldifs"
          ;;
      esac
      echo "!/$rf"
    done
  } > "$out"
}

# ─────────────────────────────────────────────────────────────────────────────
# Create the shadow repo if absent and (re)apply its configuration. Idempotent —
# safe to call on every prepare.
# ─────────────────────────────────────────────────────────────────────────────
bz_shadow_init() {
  mkdir -p "$BLUE_ZONE_STATE_DIR" "$BLUE_ZONE_BASE_DIR"

  if [ ! -d "$BLUE_ZONE_SHADOW_GIT" ]; then
    # A bare init gives us a git directory with no work tree of its own, which
    # is what we want — every command supplies --work-tree explicitly. Flipping
    # core.bare back off is what makes those work-tree commands legal.
    git init --quiet --bare "$BLUE_ZONE_SHADOW_GIT"
    bz_git_bare config core.bare false
    # HEAD lives on the work branch for good: the live staging tree is the only
    # tree we ever check out, and blue-base is written with plumbing.
    bz_git_bare symbolic-ref HEAD "refs/heads/$BLUE_ZONE_WORK_REF"
  fi

  # Local identity — the shadow repo must be able to commit on a machine with no
  # global git config. Signing is disabled: these commits are local bookkeeping
  # and a signing prompt would hang an automated sync.
  bz_git_bare config user.name  "$BLUE_ZONE_GIT_AUTHOR"
  bz_git_bare config user.email "$BLUE_ZONE_GIT_EMAIL"
  bz_git_bare config commit.gpgsign false
  # The staging tree is written by rsync and by a container running as another
  # uid; neither preserves the executable bit reliably across hosts, and mode
  # churn would show up as spurious changes in every diff.
  bz_git_bare config core.fileMode false

  bz_write_exclude
}

# ─────────────────────────────────────────────────────────────────────────────
# Commit the SCRATCH projection tree onto $BLUE_ZONE_BASE_REF.
#
# Pure plumbing: stage into a throwaway index, write a tree, and hang a commit
# off the previous base. Nothing is ever checked out, so the live staging tree —
# and any bind mount into a running container — is untouched.
#
# Returns 0 if a new commit was made, 1 if the projection was unchanged.
# ─────────────────────────────────────────────────────────────────────────────
bz_commit_base() {
  local msg="$1"
  local ref="refs/heads/$BLUE_ZONE_BASE_REF"
  local tree parent commit

  # Start from an empty index every time: staging into a fresh index makes
  # deletions fall out for free (a file no longer on disk is simply never
  # added), with no reconciliation logic.
  rm -f "$BZ_BASE_INDEX"

  bz_track_paths "$BLUE_ZONE_BASE_DIR"
  if [ "${#BZ_TRACK_PATHS[@]}" -gt 0 ]; then
    bz_git_base add -A -- "${BZ_TRACK_PATHS[@]}"
  fi

  tree="$(bz_git_base write-tree)"
  parent="$(bz_git_bare rev-parse --verify --quiet "$ref" || true)"

  # Nothing changed on the host since the last projection — don't pile up empty
  # commits, and let the caller skip the merge entirely.
  if [ -n "$parent" ] && [ "$(bz_git_bare rev-parse "$ref^{tree}")" = "$tree" ]; then
    return 1
  fi

  if [ -n "$parent" ]; then
    commit="$(bz_git_bare commit-tree "$tree" -p "$parent" -m "$msg")"
  else
    commit="$(bz_git_bare commit-tree "$tree" -m "$msg")"
  fi
  bz_git_bare update-ref "$ref" "$commit"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Commit the LIVE staging tree onto $BLUE_ZONE_WORK_REF (HEAD).
# Returns 0 if a new commit was made, 1 if nothing changed.
# ─────────────────────────────────────────────────────────────────────────────
bz_commit_work() {
  local msg="$1"
  bz_track_paths "$BLUE_ZONE_ROOT"
  if [ "${#BZ_TRACK_PATHS[@]}" -gt 0 ]; then
    bz_git add -A -- "${BZ_TRACK_PATHS[@]}"
  fi
  # An unborn HEAD has no tree to diff against, so always commit the first time.
  if bz_git_bare rev-parse --verify --quiet HEAD >/dev/null; then
    bz_git diff --cached --quiet && return 1
  fi
  bz_git commit -q -m "$msg"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Point $BLUE_ZONE_BASE_REF at the current work commit.
#
# Used by prepare, where the staging tree IS a fresh projection of the repo, so
# "what Claude has" and "what the host has" are by definition the same tree.
# Collapsing both refs onto one commit is what gives the two branches shared
# history — and shared history is what makes every later sync a true three-way
# merge rather than a guess.
# ─────────────────────────────────────────────────────────────────────────────
bz_set_base_to_work() {
  bz_git_bare update-ref "refs/heads/$BLUE_ZONE_BASE_REF" \
    "$(bz_git_bare rev-parse "refs/heads/$BLUE_ZONE_WORK_REF")"
}

# ─────────────────────────────────────────────────────────────────────────────
# Write .blue-zone-snapshot — the list of files Claude was allowed to see, which
# sync-back uses to tell his changes apart from red-zone files.
#
# It is derived from the BASE tree, not from what is on disk: after a sync-in
# the live tree also contains files Claude created, and those are precisely what
# the snapshot must NOT vouch for. The base tree is exactly the projection, so
# this is the honest answer to "what was staged for him".
# ─────────────────────────────────────────────────────────────────────────────
bz_write_snapshot() {
  bz_git_bare ls-tree -r --name-only "refs/heads/$BLUE_ZONE_BASE_REF" \
    | LC_ALL=C sort > "$BLUE_ZONE_ROOT/.blue-zone-snapshot"
}

# ─────────────────────────────────────────────────────────────────────────────
# Recreate the configured folder directories.
#
# A merge that deletes the last tracked file in a directory makes git remove the
# directory too. If that directory is bind-mounted into a running container, its
# inode is what the mount is pinned to, so losing it detaches the mount. We
# cannot undo that from here — recreating the path gives a NEW inode, which the
# running container will not pick up — but recreating it keeps every subsequent
# host-side script working, and the caller warns the user to restart the
# session. In practice a whole top-level folder never empties mid-session.
# ─────────────────────────────────────────────────────────────────────────────
bz_restore_mount_dirs() {
  local folder
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    [ -d "$BLUE_ZONE_ROOT/$folder" ] || {
      mkdir -p "$BLUE_ZONE_ROOT/$folder"
      echo -e "  ${YELLOW}⚠  recreated $folder/ — it was emptied by the merge."
      echo -e "     A running container's mount for it is now stale; restart the session.${RESET}"
    }
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Merge $BLUE_ZONE_BASE_REF into the live tree ($BLUE_ZONE_WORK_REF).
#
# This is the one operation that both directions end with:
#   • sync-in runs it to bring host changes into the zone;
#   • sync-back runs it after writing into the repo, so the zone reflects the
#     merged result. Without that, blue-work would keep its pre-merge version
#     forever and every later sync-back would re-report the same file.
# Afterwards the two branches agree, so the next diff is empty until someone
# actually changes something.
#
# On conflict the merge is CONCLUDED with the markers left in the files rather
# than left in progress: a half-finished merge blocks every later commit in the
# shadow repo, and Claude — who must never run git — has no way to finish it.
# Committing keeps the repo usable, leaves the markers where Claude can see and
# resolve them, and records both parents so future merge bases stay correct.
# sync-back independently refuses to export a file whose markers remain.
#
# Sets BZ_MERGE_CONFLICTS to the newline-separated conflicted paths ("" if none).
# Returns 0 on success (with or without conflicts), 1 if the merge failed for
# some other reason and was rolled back.
# ─────────────────────────────────────────────────────────────────────────────
bz_merge_base_into_work() {
  local msg="${1:-merge repo changes into the blue zone}"
  local out rc
  BZ_MERGE_CONFLICTS=""

  set +e
  # Merge by SHORT branch name: git stamps it into the conflict markers, so a
  # conflicted file reads ">>>>>>> blue-base" (the host's version) instead of an
  # opaque "refs/heads/…". The other side is labelled HEAD — Claude's own work.
  out="$(bz_git merge --no-edit -m "$msg" "$BLUE_ZONE_BASE_REF" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    BZ_MERGE_CONFLICTS="$(bz_git diff --name-only --diff-filter=U 2>/dev/null || true)"
    if [ -z "$BZ_MERGE_CONFLICTS" ]; then
      echo -e "${RED}Merge failed:${RESET}"
      printf '%s\n' "$out"
      bz_git merge --abort 2>/dev/null || true
      bz_restore_mount_dirs
      return 1
    fi
    bz_track_paths "$BLUE_ZONE_ROOT"
    [ "${#BZ_TRACK_PATHS[@]}" -gt 0 ] && bz_git add -A -- "${BZ_TRACK_PATHS[@]}"
    bz_git commit -q --no-edit -m "$msg (unresolved conflicts)"
  fi

  bz_restore_mount_dirs
  # Files arriving from the host must be writable by the container's non-root
  # user, whose uid differs from the host user's.
  chmod -R a+rwX "$BLUE_ZONE_ROOT"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Conflict detection
# ─────────────────────────────────────────────────────────────────────────────

# True when a merge is in progress / left unmerged index entries.
bz_merge_in_progress() {
  [ -e "$BLUE_ZONE_SHADOW_GIT/MERGE_HEAD" ] && return 0
  [ -n "$(bz_git ls-files -u 2>/dev/null)" ] && return 0
  return 1
}

# Print (one per line) every tracked staging file still carrying conflict
# markers. Claude resolves these by editing the file and deleting the markers;
# sync-back refuses to export a file that still has them.
bz_conflicted_paths() {
  bz_track_paths "$BLUE_ZONE_ROOT"
  [ "${#BZ_TRACK_PATHS[@]}" -gt 0 ] || return 0
  ( cd "$BLUE_ZONE_ROOT" && \
    bz_git ls-files -z -- "${BZ_TRACK_PATHS[@]}" 2>/dev/null \
      | xargs -0 grep -lE '^(<<<<<<<|>>>>>>>) ' 2>/dev/null ) || true
}

# True when <file> carries conflict markers.
bz_has_conflict_markers() {
  grep -qE '^(<<<<<<<|>>>>>>>) ' "$1" 2>/dev/null
}
