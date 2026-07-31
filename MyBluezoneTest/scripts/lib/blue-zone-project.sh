#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib/blue-zone-project.sh — the red-zone filter, as a reusable function.
#
# "Projecting" the repo means copying the configured blue-zone folders and root
# files into a destination tree with every red-zone rule applied: the per-folder
# rsync exclusions, the `.env*` refusal, and the content denylist. The result is
# the set of files Claude is allowed to see.
#
# This lives in a library because it now runs against TWO destinations:
#   • prepare-blue-zone.sh projects into $BLUE_ZONE_ROOT — the live staging tree
#     that gets mounted into the container.
#   • sync-in.sh projects into $BLUE_ZONE_BASE_DIR — a scratch tree used only to
#     compute what the repo currently looks like, so it can be merged into the
#     live tree without clobbering Claude's work.
# Both must apply exactly the same rules, so there is exactly one copy of them.
#
# Sourced, not executed. Requires blue-zone.config.sh to be sourced first.
#
# Usage:
#   blue_zone_project_into <dest>
# Sets:
#   STAGED_ROOT_FILES — root files that were actually staged (existing, not
#                       refused, not dropped by the denylist). The caller needs
#                       this for the mount overlay and the manifest.
# ─────────────────────────────────────────────────────────────────────────────

# Colours are defined by the calling script; fall back to empty strings so this
# library also works when sourced by something that doesn't set them.
: "${BOLD:=}" "${GREEN:=}" "${YELLOW:=}" "${RED:=}" "${RESET:=}"

# ─────────────────────────────────────────────────────────────────────────────
# rsync one folder with its exclusions, then print an audit of what was left out.
# Usage: blue_zone_sync_folder <source> <dest> <label> [extra rsync args...]
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_sync_folder() {
  local SRC="$1"
  local DEST="$2"
  local LABEL="$3"
  shift 3
  local EXTRA_ARGS=("$@")

  if [ ! -d "$SRC" ]; then
    echo -e "  ${YELLOW}⚠  $LABEL not found at $SRC — skipping${RESET}"
    # Empty any stale content in place (keep the directory so a live mount that
    # points at it survives) — the source is gone, so the blue zone must be too.
    [ -d "$DEST" ] && find "$DEST" -mindepth 1 -delete 2>/dev/null || true
    return
  fi

  echo -e "${BOLD}[$LABEL]${RESET} $SRC → $DEST"

  # --delete resets DEST to match SRC (minus excludes) by updating files inside
  # the existing directory rather than replacing it, so its inode — and any bind
  # mount into a running container — is preserved and the container sees the
  # refreshed content live.
  rsync -a --delete "$SRC/" "$DEST/" "${EXTRA_ARGS[@]}"

  # Audit: show what was excluded
  local EXCLUDED INCLUDED
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
# Project the repo (cwd) into <dest>, applying every red-zone rule.
# ─────────────────────────────────────────────────────────────────────────────
blue_zone_project_into() {
  local DEST_ROOT="$1"
  local folder rf f rel

  # ── Reset previous run — in place, without changing directory inodes ────────
  # Do NOT `rm -rf "$DEST_ROOT"`: when the destination is the live staging root,
  # each configured folder under it may be a bind mount into a running
  # container. Deleting the directory swaps its inode, and the container — bound
  # to the old inode at start — loses the mount and stops seeing updates.
  # Instead keep every folder directory and let the rsync `--delete` in
  # blue_zone_sync_folder reset its *contents* in place. A developer can then
  # re-run prepare (or sync-in) while a session is up and the container picks
  # the changes up live. (Root-level files are rewritten in place by the callers
  # further down, so their inodes are preserved too.)
  mkdir -p "$DEST_ROOT"
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    mkdir -p "$DEST_ROOT/$folder"
  done

  # ── Stage each configured folder with its exclusions ───────────────────────
  #    (common excludes + per-folder rules, both from blue-zone.config.sh)
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    blue_zone_build_excludes "$folder" EXCLUDE_ARGS
    blue_zone_sync_folder "./$folder" "$DEST_ROOT/$folder" "$folder" "${EXCLUDE_ARGS[@]}"
  done

  # ── Stage each configured root-level file (BLUE_ZONE_ROOT_FILES) ───────────
  # These get the same downstream treatment as folder files — content denylist,
  # secret scan, snapshot, sync-back, manifest — they just live at the blue zone
  # root and are mounted individually at /workspace/<path>. `.env*` files are
  # refused. STAGED_ROOT_FILES holds the ones actually copied in.
  STAGED_ROOT_FILES=()
  if [ "${#BLUE_ZONE_ROOT_FILES[@]}" -gt 0 ]; then
    echo -e "${BOLD}[root files]${RESET} ${BLUE_ZONE_ROOT_FILES[*]}"
    for rf in "${BLUE_ZONE_ROOT_FILES[@]}"; do
      case "${rf##*/}" in
        .env*)
          echo -e "  ${RED}✗ refused${RESET} $rf ${RED}(.env files are red zone)${RESET}"
          continue ;;
      esac
      if [ ! -f "./$rf" ]; then
        echo -e "  ${YELLOW}⚠  $rf not found — skipping${RESET}"
        continue
      fi
      mkdir -p "$(dirname "$DEST_ROOT/$rf")"
      # cp truncates an existing destination in place (same inode), so a live
      # single-file mount from a previous run survives the refresh.
      cp -p "./$rf" "$DEST_ROOT/$rf"
      STAGED_ROOT_FILES+=("$rf")
      echo -e "  ${GREEN}✓${RESET} $rf → /workspace/$rf"
    done
    echo
  fi

  # ── Content denylist ───────────────────────────────────────────────────────
  # In addition to the filename exclusions above, drop any staged file whose
  # CONTENT contains a forbidden string (from blue-zone-insecure-strings.txt) so
  # it is never mounted. This catches secrets living inside otherwise-innocuous
  # files, which the filename-based excludes can't see. Runs before the snapshot
  # so removed files are treated as if they were never in the blue zone.
  echo -e "${BOLD}[content denylist]${RESET} scanning staged files for forbidden strings"
  local PATTERN_FILE
  PATTERN_FILE="$(mktemp)"
  blue_zone_denylist_strings > "$PATTERN_FILE"

  if [ ! -s "$PATTERN_FILE" ]; then
    echo -e "  ${YELLOW}⚠  no active entries in ${BLUE_ZONE_DENYLIST_FILE##*/} — content scan skipped${RESET}\n"
  else
    # Existing staged folders + root files (skip any that were absent).
    local SCAN_DIRS=()
    for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
      [ -d "$DEST_ROOT/$folder" ] && SCAN_DIRS+=("$DEST_ROOT/$folder")
    done
    for rf in ${STAGED_ROOT_FILES[@]+"${STAGED_ROOT_FILES[@]}"}; do
      [ -f "$DEST_ROOT/$rf" ] && SCAN_DIRS+=("$DEST_ROOT/$rf")
    done

    local DENY_REMOVED=0 DENY_ALLOWED=0 UNMARKED HIT
    if [ "${#SCAN_DIRS[@]}" -gt 0 ]; then
      # -r recursive, -l list files, -i case-insensitive, -a treat binary as
      # text, -F fixed strings, -f patterns file. One pass over the staged tree.
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$DEST_ROOT"/}"

        # A file is only dropped for hits that AREN'T annotated with the allow
        # marker. If every denylist hit sits on a `fine-for-claude` line, it's a
        # reviewed exception and the file stays.
        UNMARKED="$(blue_zone_unmarked_denylist_hits "$PATTERN_FILE" "$f")"
        if [ -z "$UNMARKED" ]; then
          echo -e "  ${YELLOW}↷ kept${RESET} $rel ${YELLOW}(denylist hit(s) marked '${BLUE_ZONE_ALLOW_MARKER}')${RESET}"
          DENY_ALLOWED=$((DENY_ALLOWED + 1))
          continue
        fi

        HIT="$(printf '%s\n' "$UNMARKED" | grep -aoiFf "$PATTERN_FILE" 2>/dev/null | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')"
        echo -e "  ${RED}✗ removed${RESET} $rel ${RED}(matched: ${HIT:-forbidden string})${RESET}"
        rm -f "$f"
        DENY_REMOVED=$((DENY_REMOVED + 1))
      done < <(grep -rliaFf "$PATTERN_FILE" "${SCAN_DIRS[@]}" 2>/dev/null || true)
    fi

    [ "$DENY_ALLOWED" -gt 0 ] && \
      echo -e "  ${YELLOW}$DENY_ALLOWED file(s) kept via '${BLUE_ZONE_ALLOW_MARKER}' marker${RESET}"
    if [ "$DENY_REMOVED" -eq 0 ]; then
      echo -e "  ${GREEN}✓ no staged file contained an un-exempted forbidden string${RESET}\n"
    else
      echo -e "  ${RED}${BOLD}$DENY_REMOVED file(s) removed — not mounted into the container${RESET}\n"
    fi
  fi
  rm -f "$PATTERN_FILE"

  # ── Make the tree writable by the container's non-root user ────────────────
  # (container uid differs from host uid, so group/other need rw on everything)
  chmod -R a+rwX "$DEST_ROOT"
}
