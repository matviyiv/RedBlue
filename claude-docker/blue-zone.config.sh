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

# ── Shared agents and skills (.claude-blue-zone) ─────────────────────────────
# A folder in your repo — committed, reviewed and shared like any other source
# — holding the Claude Code agents and skills your team wants every blue-zone
# session to have. Each listed subdirectory is mounted READ-ONLY at
# /workspace/.claude/<subdir>, which is where Claude Code looks for them.
#
#     .claude-blue-zone/
#     ├── agents/            -> /workspace/.claude/agents   (subagent definitions)
#     └── skills/            -> /workspace/.claude/skills   (skill directories)
#
# It is deliberately NOT your project's own `.claude/` directory: the tooling
# never touches that. This folder holds only what you are happy to hand to a
# sandboxed session, and its contents are mounted read-only so a session cannot
# rewrite the agents that review it.
#
# Unlike the blue-zone folders, this is mounted straight from the repo rather
# than staged — it is tooling input, not code under review, so nothing is
# filtered out of it. That is exactly why validate-blue-zone.sh scans it for
# secrets and denylisted strings before anything starts: whatever is in here
# reaches the container verbatim.
#
# Set to an empty string to disable the mount entirely. Uses a single-dash
# default (like BLUE_ZONE_ALLOW_MARKER below) so an explicitly empty value
# really disables it; only an unset variable falls back to the default folder.
BLUE_ZONE_CLAUDE_DIR="${BLUE_ZONE_CLAUDE_DIR-.claude-blue-zone}"

# Which subdirectories of the folder above are mounted. Claude Code also reads
# `commands/` (slash commands) and `output-styles/` from a project `.claude/`
# directory — add them here if your team shares those too. A subdirectory that
# doesn't exist in the repo is skipped silently, so listing one is always safe.
#
# `settings.json` is deliberately not mountable through this mechanism: a
# committed settings file could widen tool permissions inside the sandbox, and
# that decision belongs to whoever starts the session, not to the repo.
BLUE_ZONE_CLAUDE_SUBDIRS=(agents skills)

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

# ── Browser automation (Playwright MCP) — OFF by default ─────────────────────
# An optional, opt-in browser for the INTERACTIVE session only. The Playwright
# MCP server does NOT run inside the Claude sandbox image: it runs in its own
# `playwright-mcp` container that never sees the blue zone, and its Chromium is
# forced through a second, separate allowlist proxy (`browser-proxy`). Claude
# reaches it over an internal Docker network and can only drive the browser
# through MCP tool calls — it gets no network of its own from this.
#
# The headless / CI service (run-headless.sh) never gets the browser: it keeps
# `network_mode: none`.
#
# Turn it on here (or export BLUE_ZONE_BROWSER_ENABLED=1 for one session).
BLUE_ZONE_BROWSER_ENABLED="${BLUE_ZONE_BROWSER_ENABLED:-0}"

# ── The browser egress allowlist — THE security control ──────────────────────
# Default-deny: the browser can reach an origin ONLY if it is listed here.
# Everything else — every other site, every LAN address, your host — is refused
# by the proxy before a connection is made. Each entry is a full origin:
#
#     scheme://host[:port]     scheme is http or https; no path, no credentials
#
# Examples:
#     BLUE_ZONE_BROWSER_ORIGINS=(
#       http://host.docker.internal:8081     # a dev server on YOUR machine
#       https://staging.example.com          # a staging deployment
#       https://playwright.dev               # docs the session may need
#     )
#
# Keep this as short as the task needs. Every origin you add is somewhere the
# session could send workspace content, one navigation at a time. Leave it empty
# when the browser only has to reach a dev server Claude runs itself (see
# BLUE_ZONE_BROWSER_DEV_PORTS below) — that is the safest configuration there is.
BLUE_ZONE_BROWSER_ORIGINS=()

# ── A dev server Claude runs INSIDE the sandbox ──────────────────────────────
# Ports that a dev server (webpack, vite, next, …) will listen on inside the
# Claude container, so the browser can open what Claude just built.
#
#     BLUE_ZONE_BROWSER_DEV_PORTS=(8080)
#
# This is the tightest way to use the browser: the dev server is in the sandbox,
# the browser is in the sandbox, and traffic between them never leaves the
# internal Docker network — no host route, no egress, no allowlist involved. A
# session that only needs this can leave BLUE_ZONE_BROWSER_ORIGINS empty.
#
# Claude must bind the server to 0.0.0.0 (not localhost — that would only be
# reachable inside its own container) and accept the container's hostname. For
# webpack-dev-server that means:
#
#     webpack serve --host 0.0.0.0        # and in the config:
#     devServer: { allowedHosts: 'all' }  # or ['devserver']
#
# The browser reaches it at http://<BLUE_ZONE_BROWSER_DEV_HOST>:<port>, and
# ai-scripts/CLAUDE.md tells Claude exactly that.
BLUE_ZONE_BROWSER_DEV_PORTS=()

# The hostname the browser uses for the dev server. It is attached to the Claude
# container as a network alias, so it resolves from the browser container and
# nowhere else. Change it only if it collides with something in your setup —
# it also has to appear in the dev server's allowed-hosts list.
BLUE_ZONE_BROWSER_DEV_HOST="${BLUE_ZONE_BROWSER_DEV_HOST:-devserver}"

# Reaching a server on YOUR machine (host.docker.internal) is a real hole in the
# container boundary: the proxy gets a route to the host, and from the host to
# whatever the host can reach. Required — and refused unless set to 1 — before
# any host.docker.internal origin above is accepted.
BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY="${BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY:-0}"

# Literal private/LAN addresses (10.x, 192.168.x, 172.16-31.x, *.local, …) are
# refused outright: allowing one points the browser at your internal network.
# Set to 1 only if you have decided, deliberately, that a specific internal host
# is in scope — and keep the origin list to exactly that host.
BLUE_ZONE_BROWSER_ALLOW_PRIVATE_IPS="${BLUE_ZONE_BROWSER_ALLOW_PRIVATE_IPS:-0}"

# Playwright MCP tools pre-approved without an interactive permission prompt.
# Empty (the default) means Claude asks you before every browser action — the
# safe setting, and the reason this is interactive-only. Narrow, read-only
# example: "mcp__playwright__browser_navigate,mcp__playwright__browser_snapshot"
BLUE_ZONE_BROWSER_TOOLS="${BLUE_ZONE_BROWSER_TOOLS:-}"

# Images/versions for the browser container. Pin these — an unpinned browser
# stack is a supply-chain hole in exactly the place you least want one. Bump
# deliberately, and prefer a digest (image@sha256:...) over a tag for the base.
BLUE_ZONE_BROWSER_IMAGE="${BLUE_ZONE_BROWSER_IMAGE:-mcr.microsoft.com/playwright:v1.55.0-noble}"
BLUE_ZONE_BROWSER_MCP_VERSION="${BLUE_ZONE_BROWSER_MCP_VERSION:-0.0.81}"

# Memory cap for the browser container (Chromium is hungry; it is not the
# Claude container, so this is separate from CLAUDE_MEMORY).
BLUE_ZONE_BROWSER_MEMORY="${BLUE_ZONE_BROWSER_MEMORY:-2g}"

# ── Derived helpers (do not usually need editing) ────────────────────────────

# Project name used to namespace the staging root, so several projects can each
# run their own blue-zone session at the same time (a terminal per project)
# without clobbering each other's staged files or sync-back snapshot. Defaults to
# the basename of this config's directory — i.e. the project root — sanitised to a
# filesystem-safe slug. Override by exporting BLUE_ZONE_PROJECT before running any
# script (e.g. two checkouts of the same repo that would otherwise share a name).
BLUE_ZONE_PROJECT="${BLUE_ZONE_PROJECT:-$(basename "$BLUE_ZONE_CONFIG_DIR")}"
BLUE_ZONE_PROJECT="$(printf '%s' "$BLUE_ZONE_PROJECT" | tr -c 'A-Za-z0-9._-' '-')"
[ -n "$BLUE_ZONE_PROJECT" ] || BLUE_ZONE_PROJECT="project"

# Root of the staged blue zone on the host. Per-project by default
# (/tmp/blue-zone/<project>) so concurrent sessions for different projects stay
# isolated. Only the folders in BLUE_ZONE_FOLDERS are mounted from here into the
# container; everything else under this root (the snapshot) stays host-side. Set
# BLUE_ZONE_ROOT explicitly to override the whole path at once.
BLUE_ZONE_ROOT="${BLUE_ZONE_ROOT:-/tmp/blue-zone/$BLUE_ZONE_PROJECT}"

# Generated compose file holding the per-folder mounts. prepare-blue-zone.sh
# writes it; start-cli.sh / run-headless.sh layer it on top of the base
# docker-compose.ai-sandbox.yml via COMPOSE_FILE. Regenerated every prepare run.
BLUE_ZONE_COMPOSE_FILE="${BLUE_ZONE_COMPOSE_FILE:-docker-compose.blue-zone.yml}"

# Blue zone manifest — a Claude-readable inventory that prepare-blue-zone.sh
# writes at the blue zone root and mounts read-only into the container at
# /workspace/<name>. It records which files were STRIPPED (exist on the host but
# are deliberately absent from the workspace) so Claude knows the true shape of
# the project without ever seeing red-zone contents. It lives at the root — not
# inside a mounted folder — so sync-back never carries it back into the repo, and
# it is mounted read-only so Claude cannot alter it.
BLUE_ZONE_MANIFEST_FILE="${BLUE_ZONE_MANIFEST_FILE:-BLUE_ZONE_MANIFEST.md}"

# Generated compose overlay holding the browser services (playwright-mcp +
# browser-proxy) and the MCP config mount. Written by lib/blue-zone-browser.sh
# only when BLUE_ZONE_BROWSER_ENABLED=1, layered on top of the base compose file
# by start-cli.sh. Regenerated every run — never committed, never hand-edited.
BLUE_ZONE_BROWSER_COMPOSE_FILE="${BLUE_ZONE_BROWSER_COMPOSE_FILE:-docker-compose.browser.yml}"

# Host-side directory for the generated browser runtime config (the browser
# proxy's tinyproxy.conf + filter, and the .mcp.json mounted into the session).
# It sits at the blue zone ROOT, not inside a mounted folder, so it is never
# part of the workspace, never scanned as project content, and never synced back.
BLUE_ZONE_BROWSER_DIR="${BLUE_ZONE_BROWSER_DIR:-$BLUE_ZONE_ROOT/.browser}"

# ── Two-way sync (shadow git repo) ───────────────────────────────────────────
# The blue zone is tracked by a private "shadow" git repo so the repo and the
# staging copy can be merged in BOTH directions instead of one overwriting the
# other. It lets you keep editing the repo while Claude works in the container:
#   repo → zone   ./ai-scripts/sync-in.sh    (three-way merge into the staging copy)
#   zone → repo   ./ai-scripts/sync-back.sh  (three-way merge into your working tree)
#
# The shadow repo lives in a SIBLING of the staging root, never inside it, for
# three reasons: BLUE_ZONE_ROOT is chmod'ed and file-counted by prepare, it is
# scanned end-to-end by validate-blue-zone.sh, and only paths under it are ever
# bind-mounted. Keeping the git data outside means Claude can never see a .git
# directory and the validator never mistakes git objects for project content.
BLUE_ZONE_STATE_DIR="${BLUE_ZONE_STATE_DIR:-${BLUE_ZONE_ROOT}.gitsync}"

# The shadow repo's git directory. Its work tree is BLUE_ZONE_ROOT, passed
# explicitly per command (git --git-dir=… --work-tree=…), so no .git exists
# anywhere near the mounted folders.
BLUE_ZONE_SHADOW_GIT="${BLUE_ZONE_SHADOW_GIT:-$BLUE_ZONE_STATE_DIR/shadow.git}"

# Scratch work tree holding the pure projection of the repo (what prepare would
# stage). Committed to BLUE_ZONE_BASE_REF without ever checking anything out in
# the live staging tree, so bind mounts are never disturbed.
BLUE_ZONE_BASE_DIR="${BLUE_ZONE_BASE_DIR:-$BLUE_ZONE_STATE_DIR/base}"

# The two branches of the shadow repo:
#   base — the repo as seen through the red-zone filter ("what the host has")
#   work — the live staging tree, including everything Claude changed
# Every sync is a diff or a merge between these two.
BLUE_ZONE_BASE_REF="${BLUE_ZONE_BASE_REF:-blue-base}"
BLUE_ZONE_WORK_REF="${BLUE_ZONE_WORK_REF:-blue-work}"

# Sync engine:
#   git    — three-way merge in both directions (default; needs git on the host)
#   legacy — the original one-way set-arithmetic copy, no merging, no sync-in
# Set to legacy only if the host has no usable git binary.
BLUE_ZONE_SYNC_MODE="${BLUE_ZONE_SYNC_MODE:-git}"

# Identity used for the shadow repo's commits. These never leave the host — the
# shadow repo has no remote — but git refuses to commit without them, so they
# are set locally rather than relying on a global git config.
BLUE_ZONE_GIT_AUTHOR="${BLUE_ZONE_GIT_AUTHOR:-blue-zone sync}"
BLUE_ZONE_GIT_EMAIL="${BLUE_ZONE_GIT_EMAIL:-blue-zone-sync@localhost}"

# ── Merge request integration (sync-back --mr) ───────────────────────────────
# Opt-in: `./ai-scripts/sync-back.sh --mr` commits the synced paths to a branch and
# opens a merge request with the GitLab CLI. Plain `sync-back.sh` stops at your
# working tree and touches git not at all. Runs host-side only — the container's
# egress allowlist does not include GitLab.
BLUE_ZONE_MR_BRANCH_PREFIX="${BLUE_ZONE_MR_BRANCH_PREFIX:-ai/blue-zone}"

# Target branch for the MR. Empty means "whatever branch is checked out when
# sync-back runs", which is almost always what you want.
BLUE_ZONE_MR_TARGET="${BLUE_ZONE_MR_TARGET:-}"

# The GitLab CLI binary. Override to pin a path or wrap it.
BLUE_ZONE_GLAB="${BLUE_ZONE_GLAB:-glab}"

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
# but are NOT annotated with the allow marker, prefixed "lineno:content" (grep
# -n) so callers can report where the hit was found, not just which file.
# Empty output means every hit in the file is a reviewed exception, so the
# file may stay in the blue zone.
# Usage: blue_zone_unmarked_denylist_hits <pattern_file> <file>
blue_zone_unmarked_denylist_hits() {
  local pattern_file="$1" file="$2"
  grep -naiFf "$pattern_file" -- "$file" 2>/dev/null | blue_zone_strip_allow_marked
}
