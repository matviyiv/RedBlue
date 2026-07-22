#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# blue-zone.config.sh — Single source of truth for the blue zone layout.
#
# This is the ONE file you edit to adapt the blue zone to your project. It is
# sourced by every script (prepare / validate / sync-back / start-cli /
# run-headless / init), so the folder list and exclusion rules live in exactly
# one place instead of being duplicated across each script and docker-compose.
#
# To change which top-level folders are mounted into the container, edit
# BLUE_ZONE_FOLDERS below. To change what gets stripped out of a folder, edit
# BLUE_ZONE_COMMON_EXCLUDES (applies to every folder) or the per-folder rules in
# blue_zone_excludes_for().
#
# Kept POSIX-bash-3.2 compatible (macOS default) — no associative arrays or
# name-refs.
# ─────────────────────────────────────────────────────────────────────────────

# ── Top-level folders copied into the blue zone ──────────────────────────────
# These are the ONLY directories mounted into the container, each at
# /workspace/<folder>. List whatever top-level folders your project keeps its
# reviewable source in. A folder that doesn't exist in the repo is skipped with
# a warning — so it's safe to list folders that only some projects have.
#
# Examples for other stacks:
#   BLUE_ZONE_FOLDERS=(src test docs)                 # a plain library
#   BLUE_ZONE_FOLDERS=(app lib spec)                  # a Rails app
#   BLUE_ZONE_FOLDERS=(cmd internal pkg)              # a Go service
BLUE_ZONE_FOLDERS=(src ios android)

# ── Individual root-level files copied into the blue zone ─────────────────────
# Single files (given as repo-relative paths) staged into the blue zone alongside
# the folders, each mounted at /workspace/<path>. Unlike a raw docker-compose bind
# mount, these go through the SAME pipeline as folders: the content denylist drops
# any that contain a forbidden string, the validator scans them for secrets, they
# are recorded in the snapshot, synced back on exit, and listed in the manifest.
# Use for reviewable manifests/config like package.json or tsconfig.json. A file
# that doesn't exist in the repo is skipped with a warning. Do NOT list secrets
# here — `.env*` files are refused, and anything secret belongs in the red zone.
BLUE_ZONE_ROOT_FILES=(package.json tsconfig.json)

# ── Exclusions applied to EVERY folder ───────────────────────────────────────
# rsync --exclude patterns stripped from every folder before it is staged.
# Keep secrets and installed dependencies out no matter which folder they're in.
BLUE_ZONE_COMMON_EXCLUDES=(
  ".env*"
  "node_modules/"
)

# ── Per-folder exclusions ────────────────────────────────────────────────────
# Echo one rsync --exclude pattern per line for the given folder name. Folders
# with no special rules fall through the case and inherit only the common
# excludes above. Add a new `case` arm when you add a folder that needs its own
# red-zone rules.
blue_zone_excludes_for() {
  case "$1" in
    src)
      # JS/TS app code — strip API/service/client implementation files that
      # carry endpoints and server details. Contracts live in src/types/.
      cat <<'PATTERNS'
*-api.ts
*-api.js
*Api.ts
*Api.js
*Service.ts
*Service.js
*Client.ts
*Client.js
*client.ts
*client.js
api/
services/
*.graphql
*.gql
PATTERNS
      ;;
    ios)
      # Swift/ObjC source only — strip signing material, secret build config,
      # Firebase config, pods and build artifacts.
      cat <<'PATTERNS'
*.p12
*.cer
*.mobileprovision
*.provisionprofile
GoogleService-Info.plist
**/GoogleService-Info.plist
*.xcconfig
Pods/
build/
DerivedData/
*.xcworkspace/xcuserdata/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
*.pbxuser
*.mode1v3
*.mode2v3
*.perspectivev3
xcuserdata/
*.hmap
*.ipa
*.dSYM.zip
*.dSYM
PATTERNS
      ;;
    android)
      # Kotlin/Java source only — strip signing keys, Firebase config, local
      # build properties, gradle cache and build artifacts.
      cat <<'PATTERNS'
*.jks
*.keystore
google-services.json
**/google-services.json
release.properties
keystore.properties
signing.properties
.gradle/
build/
**/build/
.idea/
local.properties
gradle.properties
AndroidManifest.xml
network_security_config.xml
*.apk
*.aab
*.so
*.aar
PATTERNS
      ;;
    *)
      # No folder-specific rules — common excludes still apply.
      : ;;
  esac
}

# ── Content denylist ─────────────────────────────────────────────────────────
# In addition to the filename exclusions above, any staged file whose CONTENT
# contains one of these forbidden strings is dropped from the blue zone before
# it is mounted — so it never reaches the container. Provide the strings in a
# separate plain-text file, one per line (`#` comments and blank lines ignored).
# Matching is case-insensitive, fixed-string (substring), and applied to every
# file in every configured folder.
#
# Point this at your own list; the shipped blue-zone-insecure-strings.txt is a
# commented template that removes nothing until you add entries.
BLUE_ZONE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUE_ZONE_DENYLIST_FILE="${BLUE_ZONE_DENYLIST_FILE:-$BLUE_ZONE_CONFIG_DIR/blue-zone-insecure-strings.txt}"

# ── Allow marker (reviewed exceptions) ───────────────────────────────────────
# A line that contains this marker is treated as an intentional, human-reviewed
# exception: it is exempt from BOTH the content denylist (the file is not
# dropped on account of that line) AND the hardcoded-secret scan (the line is
# not reported as a violation). Use it to keep deliberate strings such as a
# `password=` example or a fixture token in the blue zone, e.g.:
#
#     const sample = "password=hunter2"; // fine-for-claude
#     endpoint: "https://192.168.1.10"   # fine-for-claude
#
# The exemption is per-LINE, not per-file: only occurrences on a marked line
# are allowed through, so an unmarked secret elsewhere in the same file is still
# caught. Matching is case-insensitive, fixed-string (substring). Set to empty
# to disable the allow mechanism entirely (nothing is ever exempted). Uses a
# single-dash default so an explicit empty value really disables it; only an
# unset variable falls back to the default marker.
BLUE_ZONE_ALLOW_MARKER="${BLUE_ZONE_ALLOW_MARKER-fine-for-claude}"

# ── Derived helpers (do not usually need editing) ────────────────────────────

# Root of the staged blue zone on the host. Only the folders in
# BLUE_ZONE_FOLDERS are mounted from here into the container; everything else
# under this root (the snapshot, generated compose file) stays host-side.
BLUE_ZONE_ROOT="${BLUE_ZONE_ROOT:-/tmp/blue-zone}"

# Generated compose file holding the per-folder mounts. prepare-blue-zone.sh
# writes it; start-cli.sh / run-headless.sh layer it on top of the base
# docker-compose.yml via COMPOSE_FILE. Regenerated every prepare run.
BLUE_ZONE_COMPOSE_FILE="${BLUE_ZONE_COMPOSE_FILE:-docker-compose.blue-zone.yml}"

# Blue zone manifest — a Claude-readable inventory that prepare-blue-zone.sh
# writes at the blue zone root and mounts read-only into the container at
# /workspace/<name>. It records which files were STRIPPED (exist on the host but
# are deliberately absent from the workspace) so Claude knows the true shape of
# the project without ever seeing red-zone contents. It lives at the root — not
# inside a mounted folder — so sync-back never carries it back into the repo, and
# it is mounted read-only so Claude cannot alter it.
BLUE_ZONE_MANIFEST_FILE="${BLUE_ZONE_MANIFEST_FILE:-BLUE_ZONE_MANIFEST.md}"

# Build the rsync --exclude argument array for a folder into the named array.
# Usage: blue_zone_build_excludes <folder> <out_array_name>
# (bash 3.2 compatible — writes into the caller's array via eval, no name-refs.)
blue_zone_build_excludes() {
  local folder="$1" outname="$2" p
  eval "$outname=()"
  for p in "${BLUE_ZONE_COMMON_EXCLUDES[@]}"; do
    eval "$outname+=(--exclude=\"\$p\")"
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    eval "$outname+=(--exclude=\"\$p\")"
  done < <(blue_zone_excludes_for "$folder")
}

# Emit every exclusion pattern (common + folder-specific) for a folder, one per
# line, with no --exclude prefix. Used by validate-blue-zone.sh to confirm none
# of them leaked into the staged copy.
blue_zone_all_patterns_for() {
  local p
  for p in "${BLUE_ZONE_COMMON_EXCLUDES[@]}"; do
    printf '%s\n' "$p"
  done
  blue_zone_excludes_for "$1"
}

# Emit the active content-denylist strings (comments + blank lines stripped),
# one per line. Empty output means no content filtering is configured. Used by
# both prepare-blue-zone.sh (to drop matching files) and validate-blue-zone.sh
# (to confirm none survived).
blue_zone_denylist_strings() {
  [ -f "$BLUE_ZONE_DENYLIST_FILE" ] || return 0
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$BLUE_ZONE_DENYLIST_FILE" || true
}

# Filter for stdin: drop any line carrying the allow marker, pass the rest
# through unchanged. When no marker is configured every line passes through.
# Used by the secret scan to discount reviewed exceptions before deciding
# whether a pattern really leaked.
blue_zone_strip_allow_marked() {
  if [ -n "${BLUE_ZONE_ALLOW_MARKER:-}" ]; then
    grep -viF -- "$BLUE_ZONE_ALLOW_MARKER" || true
  else
    cat
  fi
}

# Emit the lines of <file> that contain a denylist string (from <pattern_file>)
# but are NOT annotated with the allow marker. Empty output means every hit in
# the file is a reviewed exception, so the file may stay in the blue zone.
# Usage: blue_zone_unmarked_denylist_hits <pattern_file> <file>
blue_zone_unmarked_denylist_hits() {
  local pattern_file="$1" file="$2"
  grep -aiFf "$pattern_file" -- "$file" 2>/dev/null | blue_zone_strip_allow_marked
}
