#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# prepare-blue-zone.sh
# Copies the configured blue-zone folders into /tmp/blue-zone/ with red zone
# files excluded. Run this BEFORE docker compose to ensure clean filtered mounts.
#
# Safe to re-run while a container is already up: it resets the staged folders in
# place (same directory inodes) instead of deleting the root, so live bind mounts
# survive and the running container picks up the refreshed content.
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

# Defensive default: an older blue-zone.config.sh may not define the manifest
# filename. Fall back here so `set -u` doesn't abort on the unbound variable when
# the script is newer than the config it's paired with.
BLUE_ZONE_MANIFEST_FILE="${BLUE_ZONE_MANIFEST_FILE:-BLUE_ZONE_MANIFEST.md}"

echo -e "${BOLD}${CYAN}🔵 Preparing Blue Zone...${RESET}\n"
echo -e "  Folders: ${BOLD}${BLUE_ZONE_FOLDERS[*]}${RESET}\n"

# ── Reset previous run — in place, without changing directory inodes ──────────
# Do NOT `rm -rf "$BLUE_ZONE_ROOT"`: each configured folder under it may be a
# live bind mount into a running container. Deleting the directory swaps its
# inode, and the container — bound to the old inode at start — loses the mount
# and stops seeing updates. Instead keep every folder directory and let the
# rsync `--delete` in sync_zone reset its *contents* in place. A developer can
# then re-run prepare while a session is up and the container picks the changes
# up live. (Root-level files — the snapshot, manifest, overlay — are rewritten
# in place further below, so their inodes are preserved too.)
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
  DENY_ALLOWED=0
  if [ "${#SCAN_DIRS[@]}" -gt 0 ]; then
    # -r recursive, -l list files, -i case-insensitive, -a treat binary as text,
    # -F fixed strings, -f patterns file. One pass over the whole staged tree.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f#"$BLUE_ZONE_ROOT"/}"

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
# Blue zone manifest — a Claude-readable record of what was STRIPPED. For each
# configured folder it lists the source files that did NOT make it into the blue
# zone (removed by a filename exclusion rule or the content denylist): the files
# that exist on the host but are deliberately absent from the workspace. Mounted
# read-only into the container at /workspace/<name> (see the overlay below) so
# Claude knows the true shape of the project — which files exist as red zone —
# without ever seeing their contents. Written at the blue zone root (not inside a
# mounted folder) so sync-back never carries it back into the repo.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[manifest]${RESET} recording stripped (red-zone) files"
MANIFEST_OUT="$BLUE_ZONE_ROOT/$BLUE_ZONE_MANIFEST_FILE"
STRIPPED_TMP="$(mktemp -d)"
STRIPPED_TOTAL=0

# Active content-denylist strings (the "insecure words"). The manifest is mounted
# where Claude can read it, so it must not contain any of them: a stripped file
# whose NAME carries one is omitted from the listing below, and — as a final
# safety net — the whole assembled manifest is filtered before it is written out
# (a red-zone rule pattern can itself equal a denylist entry, e.g.
# `google-services.json`). The manifest is assembled into MANIFEST_TMP first and
# the filtered result is written to MANIFEST_OUT.
MANIFEST_DENY_FILE="$(mktemp)"
blue_zone_denylist_strings > "$MANIFEST_DENY_FILE"
MANIFEST_TMP="$STRIPPED_TMP/manifest.md"

# Header + summary table. Detail sections are appended in a second pass so the
# per-folder stripped lists are computed only once (cached under STRIPPED_TMP).
{
  echo "# Blue Zone Manifest"
  echo
  echo "_Auto-generated by \`prepare-blue-zone.sh\` on $(date -u '+%Y-%m-%d %H:%M:%SZ'). Read-only — do not edit._"
  echo
  echo "Everything in \`/workspace\` was filtered from the host repository before it"
  echo "was mounted. This manifest records what was **stripped** — files that exist"
  echo "on the host but are deliberately **not** in your workspace (red zone)."
  echo
  echo "Use it to understand the true shape of the project: know that these files"
  echo "exist so you code against their contracts and do not recreate them, but"
  echo "never ask for their contents — they are withheld on purpose."
  echo
  echo "## Summary"
  echo
  echo "| Folder | Mounted (blue) | Stripped (red) |"
  echo "| ------ | -------------: | -------------: |"
} > "$MANIFEST_TMP"

for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
  if [ ! -d "./$folder" ]; then
    : > "$STRIPPED_TMP/$folder"
    echo "| \`$folder\` | _absent_ | _absent_ |" >> "$MANIFEST_TMP"
    continue
  fi
  # Source files (minus heavy/irrelevant trees) vs what actually got staged.
  # The difference is everything the filename excludes AND the content denylist
  # kept out. prepare-blue-zone.sh runs from the repo root, so "./$folder" is the
  # real source and "$BLUE_ZONE_ROOT/$folder" is the filtered staging copy.
  SRC_LIST="$( (cd "./$folder" && find . -type f \
      -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null) \
      | sed 's|^\./||' | sort )"
  STAGED_LIST="$( (cd "$BLUE_ZONE_ROOT/$folder" && find . -type f 2>/dev/null) \
      | sed 's|^\./||' | sort )"
  comm -23 <(printf '%s\n' "$SRC_LIST") <(printf '%s\n' "$STAGED_LIST") \
      | grep -v '^$' > "$STRIPPED_TMP/$folder" || true

  BLUE_N=$(printf '%s\n' "$STAGED_LIST" | grep -c . || true)
  RED_N=$(grep -c . "$STRIPPED_TMP/$folder" || true)
  STRIPPED_TOTAL=$((STRIPPED_TOTAL + RED_N))
  echo "| \`$folder\` | $BLUE_N | $RED_N |" >> "$MANIFEST_TMP"
done

{
  echo
  echo "## Stripped files (red zone)"
  echo
  echo "Present on the host but removed before mounting. Not in your workspace and"
  echo "cannot be read."
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    echo
    echo "### $folder"
    echo
    if [ ! -s "$STRIPPED_TMP/$folder" ]; then
      echo "_Nothing stripped from this folder._"
    else
      # Omit any stripped path whose name contains a denylisted (insecure) word,
      # so the manifest never surfaces one. Matching mirrors the content
      # denylist: case-insensitive, fixed-string (substring).
      SHOWN_LIST="$STRIPPED_TMP/$folder"
      HIDDEN_N=0
      if [ -s "$MANIFEST_DENY_FILE" ]; then
        grep -viFf "$MANIFEST_DENY_FILE" "$STRIPPED_TMP/$folder" \
          > "$STRIPPED_TMP/$folder.shown" || true
        HIDDEN_N=$(( $(grep -c . "$STRIPPED_TMP/$folder" || true) \
                   - $(grep -c . "$STRIPPED_TMP/$folder.shown" || true) ))
        SHOWN_LIST="$STRIPPED_TMP/$folder.shown"
      fi
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "- \`$folder/$f\`"
      done < "$SHOWN_LIST"
      if [ "$HIDDEN_N" -gt 0 ]; then
        echo "- _$HIDDEN_N file(s) omitted — name contains a denylisted string._"
      fi
    fi
  done
  echo
  echo "## Why these were stripped"
  echo
  echo "Files are removed by the red-zone filename rules below or because their"
  echo "contents matched a forbidden string. Source of truth: \`blue-zone.config.sh\`."
  echo
  echo "### Filename rules — every folder"
  echo
  for p in "${BLUE_ZONE_COMMON_EXCLUDES[@]}"; do
    echo "- \`$p\`"
  done
  for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
    PER="$(blue_zone_excludes_for "$folder")"
    [ -n "$PER" ] || continue
    echo
    echo "### Filename rules — $folder"
    echo
    printf '%s\n' "$PER" | while IFS= read -r p; do
      [ -n "$p" ] || continue
      echo "- \`$p\`"
    done
  done
  echo
  echo "### Content denylist"
  echo
  if [ -n "$(blue_zone_denylist_strings)" ]; then
    DN=$(blue_zone_denylist_strings | grep -c . || true)
    echo "Active — any staged file whose contents matched one of $DN forbidden"
    echo "string(s) was dropped as well."
  else
    echo "Inactive — no content strings are configured."
  fi
} >> "$MANIFEST_TMP"

# Final safety net: write the manifest out with any line carrying a denylisted
# string dropped, so the mounted manifest can never contain one (matching mirrors
# the denylist: case-insensitive, fixed-string). `>` truncates MANIFEST_OUT in
# place, preserving its inode so a live single-file mount survives a re-run.
if [ -s "$MANIFEST_DENY_FILE" ]; then
  grep -viFf "$MANIFEST_DENY_FILE" "$MANIFEST_TMP" > "$MANIFEST_OUT" || true
  REDACTED=$(( $(wc -l < "$MANIFEST_TMP") - $(wc -l < "$MANIFEST_OUT") ))
  if [ "$REDACTED" -gt 0 ]; then
    { echo
      echo "_$REDACTED line(s) redacted from this manifest for containing a denylisted string; see \`blue-zone.config.sh\` for the full red-zone rules._"
    } >> "$MANIFEST_OUT"
  fi
else
  cat "$MANIFEST_TMP" > "$MANIFEST_OUT"
fi

rm -rf "$STRIPPED_TMP"
rm -f "$MANIFEST_DENY_FILE"
echo -e "  ${GREEN}✓ manifest written${RESET} ($STRIPPED_TOTAL file(s) stripped) → mounted read-only at /workspace/$BLUE_ZONE_MANIFEST_FILE\n"

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
  echo "# Mounts each configured blue-zone folder into both Claude services,"
  echo "# plus the read-only blue zone manifest at /workspace/$BLUE_ZONE_MANIFEST_FILE."
  echo "# ─────────────────────────────────────────────────────────────────────"
  echo "services:"
  for svc in claude-code claude-cli; do
    echo "  $svc:"
    echo "    volumes:"
    for folder in "${BLUE_ZONE_FOLDERS[@]}"; do
      echo "      - $BLUE_ZONE_ROOT/$folder:/workspace/$folder"
    done
    # Read-only manifest of what was stripped, so Claude knows the true project
    # shape. Lives at the blue zone root, mounted into the workspace root.
    echo "      - $BLUE_ZONE_ROOT/$BLUE_ZONE_MANIFEST_FILE:/workspace/$BLUE_ZONE_MANIFEST_FILE:ro"
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
echo -e "   ${GREEN}•${RESET} $BLUE_ZONE_ROOT/$BLUE_ZONE_MANIFEST_FILE → /workspace/$BLUE_ZONE_MANIFEST_FILE ${BOLD}(ro)${RESET}"
echo -e "${BOLD}────────────────────────────────────────${RESET}"
