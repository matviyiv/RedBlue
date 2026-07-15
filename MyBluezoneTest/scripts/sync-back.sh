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
#   • Deletions are NEVER propagated automatically — they are reported so
#     you can delete by hand if intended.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

BLUE_ZONE_ROOT="/tmp/blue-zone"
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
done < <(find "$BLUE_ZONE_ROOT/src" "$BLUE_ZONE_ROOT/ios" "$BLUE_ZONE_ROOT/android" \
           -type f -print0 2>/dev/null)

# ── Deletions (report only, never auto-applied) ───────────────────────────────
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ ! -f "$BLUE_ZONE_ROOT/$rel" ] && [ -f "./$rel" ]; then
    echo -e "  ${YELLOW}- deleted in blue zone (kept in repo):${RESET} $rel"
    DELETED=$((DELETED + 1))
  fi
done < "$SNAPSHOT"

# ── Summary ───────────────────────────────────────────────────────────────────
if [ $((UPDATED + ADDED + BLOCKED + DELETED)) -eq 0 ]; then
  echo -e "${GREEN}No changes to sync back.${RESET}"
else
  echo -e "${BOLD}────────────────────────────────────────${RESET}"
  echo -e "  updated: ${BOLD}$UPDATED${RESET}  added: ${BOLD}$ADDED${RESET}" \
          " blocked: ${BOLD}$BLOCKED${RESET}  deletions reported: ${BOLD}$DELETED${RESET}"
  if [ "$BLOCKED" -gt 0 ]; then
    echo -e "  ${RED}Blocked files collide with red-zone paths — review them manually"
    echo -e "  in $BLUE_ZONE_ROOT before deciding what to do.${RESET}"
  fi
  if [ "$DELETED" -gt 0 ]; then
    echo -e "  ${YELLOW}Deletions are never auto-applied — remove those files by hand"
    echo -e "  if the deletion was intended.${RESET}"
  fi
  echo -e "${BOLD}────────────────────────────────────────${RESET}"
fi
