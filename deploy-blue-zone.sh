#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-blue-zone.sh — install the blue-zone tooling into an existing repo.
#
# Copies the reusable tooling from claude-docker/ into a target project
# directory, then asks a short set of interactive questions (with sensible
# defaults — press Enter to accept) to produce a project-specific
# blue-zone.config.sh, blue-zone-insecure-strings.txt, ai-proxy/filter and
# ai-scripts/CLAUDE.md.
#
# Every path this script writes at the target's root is uniquely named
# (ai-scripts/, ai-proxy/, Dockerfile.ai-sandbox, docker-compose.ai-sandbox.yml)
# so it never collides with files a real project already has — most
# importantly, it never touches the target's own `.claude/` directory, which
# is that repo's real (non-sandboxed) Claude Code project config.
#
# Safe to re-run on a repo that already has the tooling installed: existing
# answers are picked up as the new defaults, and denylist/allowlist entries
# are only ever appended (deduplicated), never replaced.
#
# Usage:
#   ./deploy-blue-zone.sh [target-dir] [-y|--yes]
#     target-dir   Where to install (created if missing). Prompted if omitted.
#     -y, --yes    Accept every default without prompting (CI / scripted use).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SRC="$REPO_ROOT/claude-docker"

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

YES=false
TARGET_DIR=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    *) TARGET_DIR="$arg" ;;
  esac
done

echo -e "${BOLD}${CYAN}Blue Zone installer${RESET}"
echo -e "Source: $SETUP_SRC\n"

[ -d "$SETUP_SRC" ] || { echo -e "${RED}claude-docker/ not found at $SETUP_SRC — run this from the RedBlue repo root.${RESET}" >&2; exit 1; }

# ── Resolve target ────────────────────────────────────────────────────────────
if [ -z "$TARGET_DIR" ]; then
  if $YES; then
    TARGET_DIR="."
  else
    echo -en "${BOLD}Target project directory${RESET} ${YELLOW}[.]${RESET}: "
    read -r TARGET_DIR
    TARGET_DIR="${TARGET_DIR:-.}"
  fi
fi
mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
echo -e "Installing into: ${BOLD}$TARGET_DIR${RESET}\n"

# ── Prompt helpers ────────────────────────────────────────────────────────────
# ask <label> <default>  -> prints the answer to stdout (Enter accepts default,
# always the default under -y).
ask() {
  local label="$1" default="$2" ans
  if $YES; then
    printf '%s' "$default"
    return
  fi
  echo -e "${BOLD}${label}${RESET} ${YELLOW}[${default:-none}]${RESET}" >&2
  read -r ans
  printf '%s' "${ans:-$default}"
}

# confirm <label> <default: y|n>  -> exit status 0 = yes
confirm() {
  local label="$1" default="$2" hint ans
  if $YES; then
    [ "$default" = "y" ]
    return
  fi
  hint="y/N"; [ "$default" = "y" ] && hint="Y/n"
  echo -en "${BOLD}${label}${RESET} [${hint}]: " >&2
  read -r ans
  ans="${ans:-$default}"
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# ── Step 1: detect an existing install (the "roll on top" path) ─────────────
BLUE_ZONE_FOLDERS=()
BLUE_ZONE_ROOT_FILES=()
BLUE_ZONE_COMMON_EXCLUDES=()
EXISTING_INSTALL=false
if [ -f "$TARGET_DIR/blue-zone.config.sh" ]; then
  EXISTING_INSTALL=true
  echo -e "${YELLOW}Existing blue-zone.config.sh found — using its values as defaults.${RESET}"
  # shellcheck disable=SC1090,SC1091
  source "$TARGET_DIR/blue-zone.config.sh"
fi

NOISE_DIRS=" .git node_modules dist build .next vendor .venv __pycache__ target ai-scripts ai-proxy .idea .vscode coverage tmp "
KNOWN_FOLDERS=" src ios android app lib pkg cmd internal test tests docs spec "
ROOT_FILE_CANDIDATES="package.json tsconfig.json go.mod Cargo.toml pyproject.toml requirements.txt Gemfile"

detect_folders() {
  local dir="$1" d name found=()
  for d in "$dir"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$NOISE_DIRS" in *" $name "*) continue ;; esac
    case "$KNOWN_FOLDERS" in *" $name "*) found+=("$name") ;; esac
  done
  printf '%s' "${found[*]:-}"
}

detect_root_files() {
  local dir="$1" f found=()
  for f in $ROOT_FILE_CANDIDATES; do
    [ -f "$dir/$f" ] && found+=("$f")
  done
  printf '%s' "${found[*]:-}"
}

if [ "${#BLUE_ZONE_FOLDERS[@]}" -gt 0 ]; then
  DEFAULT_FOLDERS="${BLUE_ZONE_FOLDERS[*]}"
else
  DEFAULT_FOLDERS="$(detect_folders "$TARGET_DIR")"
fi
if [ "${#BLUE_ZONE_ROOT_FILES[@]}" -gt 0 ]; then
  DEFAULT_ROOT_FILES="${BLUE_ZONE_ROOT_FILES[*]}"
else
  DEFAULT_ROOT_FILES="$(detect_root_files "$TARGET_DIR")"
fi
if [ "${#BLUE_ZONE_COMMON_EXCLUDES[@]}" -gt 0 ]; then
  DEFAULT_EXCLUDES="${BLUE_ZONE_COMMON_EXCLUDES[*]}"
else
  DEFAULT_EXCLUDES=".env* node_modules/"
fi

# ── Step 2: copy pure tooling verbatim (always safe — materialized, not source) ─
echo -e "${BOLD}[1/5] Copying tooling...${RESET}"

# Preserve a hand-edited CLAUDE.md across the blanket ai-scripts/ copy below —
# it's decided further down, never silently clobbered.
PRIOR_CLAUDE_MD=""
if [ -f "$TARGET_DIR/ai-scripts/CLAUDE.md" ]; then
  PRIOR_CLAUDE_MD="$(mktemp)"
  cp "$TARGET_DIR/ai-scripts/CLAUDE.md" "$PRIOR_CLAUDE_MD"
fi

mkdir -p "$TARGET_DIR/ai-proxy"
cp -R "$SETUP_SRC/ai-scripts" "$TARGET_DIR/"
cp    "$SETUP_SRC/Dockerfile.ai-sandbox" "$TARGET_DIR/"
cp    "$SETUP_SRC/docker-compose.ai-sandbox.yml" "$TARGET_DIR/"
cp    "$SETUP_SRC/ai-proxy/Dockerfile" "$TARGET_DIR/ai-proxy/"
cp    "$SETUP_SRC/ai-proxy/tinyproxy.conf" "$TARGET_DIR/ai-proxy/"
chmod +x "$TARGET_DIR"/ai-scripts/*.sh
echo -e "${GREEN}  ai-scripts/, ai-proxy/{Dockerfile,tinyproxy.conf}, Dockerfile.ai-sandbox, docker-compose.ai-sandbox.yml${RESET}"

# ── Step 3: the questions ────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/5] A few questions (Enter accepts the default)...${RESET}\n"

ANS_FOLDERS="$(ask "Blue zone folders (space/comma separated — top-level dirs Claude may see)" "$DEFAULT_FOLDERS")"
ANS_ROOT_FILES="$(ask "Root files to stage alongside them (may be empty)" "$DEFAULT_ROOT_FILES")"
ANS_EXTRA_EXCLUDES="$(ask "Additional exclude patterns to append, beyond '$DEFAULT_EXCLUDES' (may be empty)" "")"
ANS_EXTRA_DENYLIST="$(ask "Additional insecure/denylist strings to append (may be empty)" "")"
ANS_EXTRA_DOMAINS="$(ask "Additional egress-allowed domains to append, e.g. api.example.com (may be empty)" "")"
ANS_DESCRIPTION="$(ask "One-line project description for ai-scripts/CLAUDE.md" "a software project")"

# Normalize comma-separated input to space-separated.
ANS_FOLDERS="${ANS_FOLDERS//,/ }"
ANS_ROOT_FILES="${ANS_ROOT_FILES//,/ }"
ANS_EXTRA_EXCLUDES="${ANS_EXTRA_EXCLUDES//,/ }"
ANS_EXTRA_DENYLIST="${ANS_EXTRA_DENYLIST//,/ }"
ANS_EXTRA_DOMAINS="${ANS_EXTRA_DOMAINS//,/ }"

# Pre-declared so a zero-field `read -ra` still leaves a defined (if empty)
# array under `set -u` — on bash 3.2 (macOS /bin/bash) `read -ra arr <<< ""`
# leaves `arr` completely unset rather than empty, unlike bash 4+.
FOLDERS_ARR=()
ROOT_FILES_ARR=()
EXCLUDES_ARR=()
read -ra FOLDERS_ARR <<< "$ANS_FOLDERS"
read -ra ROOT_FILES_ARR <<< "$ANS_ROOT_FILES"
read -ra EXCLUDES_ARR <<< "$DEFAULT_EXCLUDES $ANS_EXTRA_EXCLUDES"

# ── Step 4: write blue-zone.config.sh (base copied verbatim, three array
#    lines rewritten from the answers above) ─────────────────────────────────
echo -e "\n${BOLD}[3/5] Writing blue-zone.config.sh...${RESET}"

q_array() {
  local name="$1"; shift
  local out="${name}=(" first=1 v
  for v in "$@"; do
    [ -n "$v" ] || continue
    [ "$first" -eq 0 ] && out+=" "
    out+="$(printf '%q' "$v")"
    first=0
  done
  out+=")"
  printf '%s' "$out"
}

FOLDERS_LINE="$(q_array BLUE_ZONE_FOLDERS ${FOLDERS_ARR[@]+"${FOLDERS_ARR[@]}"})"
ROOTFILES_LINE="$(q_array BLUE_ZONE_ROOT_FILES ${ROOT_FILES_ARR[@]+"${ROOT_FILES_ARR[@]}"})"
EXCLUDES_LINE="$(q_array BLUE_ZONE_COMMON_EXCLUDES ${EXCLUDES_ARR[@]+"${EXCLUDES_ARR[@]}"})"

awk -v folders_line="$FOLDERS_LINE" -v rootfiles_line="$ROOTFILES_LINE" -v excludes_line="$EXCLUDES_LINE" '
  /^BLUE_ZONE_FOLDERS=/ { print folders_line; next }
  /^BLUE_ZONE_ROOT_FILES=/ { print rootfiles_line; next }
  /^BLUE_ZONE_COMMON_EXCLUDES=\(/ {
    print excludes_line
    if ($0 !~ /\)[[:space:]]*$/) in_excludes = 1
    next
  }
  in_excludes { if ($0 ~ /^\)/) in_excludes = 0; next }
  { print }
' "$SETUP_SRC/blue-zone.config.sh" > "$TARGET_DIR/blue-zone.config.sh"
echo -e "${GREEN}  BLUE_ZONE_FOLDERS=(${FOLDERS_ARR[*]:-})  BLUE_ZONE_ROOT_FILES=(${ROOT_FILES_ARR[*]:-})${RESET}"

# ── Step 5: denylist + egress allowlist — guarded copy (only on first
#    install) then append-only, deduplicated, so re-running never discards or
#    duplicates prior custom entries ──────────────────────────────────────────
echo -e "\n${BOLD}[4/5] Updating denylist and egress allowlist...${RESET}"

append_unique() {
  local file="$1" header="$2"; shift 2
  local added=0 v
  for v in "$@"; do
    [ -n "$v" ] || continue
    grep -qiF -- "$v" "$file" 2>/dev/null && continue
    if [ "$added" -eq 0 ]; then
      { echo ""; echo "# $header ($(date +%Y-%m-%d))"; } >> "$file"
    fi
    printf '%s\n' "$v" >> "$file"
    added=$((added + 1))
  done
  printf '%d' "$added"
}

domain_pattern() {
  local d="$1" esc
  esc="$(printf '%s' "$d" | sed 's/\./\\./g')"
  printf '(^|\\.)%s$' "$esc"
}

[ -f "$TARGET_DIR/blue-zone-insecure-strings.txt" ] || cp "$SETUP_SRC/blue-zone-insecure-strings.txt" "$TARGET_DIR/blue-zone-insecure-strings.txt"
N_DENY=$(append_unique "$TARGET_DIR/blue-zone-insecure-strings.txt" "Added by deploy-blue-zone.sh" $ANS_EXTRA_DENYLIST)
echo -e "${GREEN}  blue-zone-insecure-strings.txt: $N_DENY new entr$([ "$N_DENY" = 1 ] && echo y || echo ies)${RESET}"

[ -f "$TARGET_DIR/ai-proxy/filter" ] || cp "$SETUP_SRC/ai-proxy/filter" "$TARGET_DIR/ai-proxy/filter"
DOMAIN_PATTERNS=()
for d in $ANS_EXTRA_DOMAINS; do
  DOMAIN_PATTERNS+=("$(domain_pattern "$d")")
done
N_DOMAINS=$(append_unique "$TARGET_DIR/ai-proxy/filter" "Added by deploy-blue-zone.sh" ${DOMAIN_PATTERNS[@]+"${DOMAIN_PATTERNS[@]}"})
echo -e "${GREEN}  ai-proxy/filter: $N_DOMAINS new domain pattern(s)${RESET}"

# ── Step 6: .env.example (never overwrite one that already exists) ──────────
if [ ! -f "$TARGET_DIR/.env.example" ]; then
  ANS_ENV_VARS="$(ask "Env var names for .env.example, comma-separated (optional)" "")"
  ANS_ENV_VARS="${ANS_ENV_VARS//,/ }"
  if [ -n "$ANS_ENV_VARS" ]; then
    : > "$TARGET_DIR/.env.example"
    for v in $ANS_ENV_VARS; do
      printf '%s=\n' "$v" >> "$TARGET_DIR/.env.example"
    done
    echo -e "${GREEN}  wrote .env.example${RESET}"
  fi
else
  echo -e "${YELLOW}  .env.example already exists — left untouched${RESET}"
fi

# ── Step 7: .gitignore (append the generated-overlay entry if missing) ──────
if [ ! -f "$TARGET_DIR/.gitignore" ]; then
  printf '# Regenerated by ai-scripts/prepare-blue-zone.sh on every run — never committed.\ndocker-compose.blue-zone.yml\n' > "$TARGET_DIR/.gitignore"
elif ! grep -qxF "docker-compose.blue-zone.yml" "$TARGET_DIR/.gitignore"; then
  printf '\n# Regenerated by ai-scripts/prepare-blue-zone.sh on every run — never committed.\ndocker-compose.blue-zone.yml\n' >> "$TARGET_DIR/.gitignore"
fi

# ── Step 8: ai-scripts/CLAUDE.md — generated from the answers, never at
#    the target's own .claude/ (that's the repo's real Claude Code config) ──
echo -e "\n${BOLD}[5/5] Writing ai-scripts/CLAUDE.md...${RESET}"

REGEN_CLAUDE_MD=true
if [ -n "$PRIOR_CLAUDE_MD" ]; then
  if confirm "ai-scripts/CLAUDE.md already exists — regenerate it from these answers? (overwrites customizations)" "n"; then
    REGEN_CLAUDE_MD=true
  else
    REGEN_CLAUDE_MD=false
  fi
fi

if $REGEN_CLAUDE_MD; then
  FOLDER_BULLETS=""
  for f in ${FOLDERS_ARR[@]+"${FOLDERS_ARR[@]}"}; do
    FOLDER_BULLETS+="- \`/workspace/$f\`"$'\n'
  done
  [ -n "$FOLDER_BULLETS" ] || FOLDER_BULLETS="- (no folders configured yet — edit BLUE_ZONE_FOLDERS in blue-zone.config.sh)"$'\n'

  EXCLUSION_BULLETS="$(
    (
      # shellcheck disable=SC1090,SC1091
      source "$TARGET_DIR/blue-zone.config.sh"
      for f in "${BLUE_ZONE_FOLDERS[@]}"; do
        echo "**${f}/:**"
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          echo "- \`$p\`"
        done < <(blue_zone_all_patterns_for "$f")
        echo ""
      done
    )
  )"
  [ -n "$EXCLUSION_BULLETS" ] || EXCLUSION_BULLETS="(no folders configured)"$'\n'

  cat > "$TARGET_DIR/ai-scripts/CLAUDE.md" <<CLAUDEMD
# Claude Code - Project Context

## Scope
You are working on ${ANS_DESCRIPTION}.
Your working directory is \`/workspace\`. You have access to:
${FOLDER_BULLETS}
## What you CAN do
- Read and analyze files inside the directories above
- Suggest code improvements, bug fixes, and refactors
- Write or update test files
- Reference \`/workspace/.env.example\` for environment variable **names only**

## What you MUST NOT do
- Read, reference, or request any \`.env\` file contents (values are secrets)
- Access or suggest changes to CI/CD configuration
- Reference internal IP addresses, hostnames, or API endpoints
- Attempt to read files outside \`/workspace\`
- Run \`git\` commands (or any VCS command) — \`/workspace\` is NOT a git repository

## File operations — use the file system, not git

\`/workspace\` is a filtered staging copy of the repo, **not a git checkout**.
There is no \`.git\` directory here, so git commands will fail or behave
unexpectedly. Use plain file system commands (or the Read/Write/Edit tools)
instead of \`git rm\` / \`git mv\` / \`git status\`.

When you delete a file with \`rm\`, that deletion is carried back into the real
repository by \`sync-back.sh\` after the session ends — so deleting is a real,
propagated action. Delete deliberately.

## The workspace can change under you — and may contain conflict markers

The developer keeps editing the real repository while you work here, and can
pull their changes into your workspace mid-session with \`sync-in.sh\`. A file
you read earlier may have new content now — re-read before you rely on it.

Refreshes are merged, not overwritten. When you and the developer changed the
**same lines**, the file is left with standard conflict markers:

\`\`\`
<<<<<<< HEAD
your version
=======
their version
>>>>>>> blue-base
\`\`\`

\`HEAD\` is always your side, \`blue-base\` is always the developer's. Resolve by
editing the file — pick one side, or combine them — then delete the marker
lines. \`sync-back.sh\` refuses to export a file that still has markers.

## Intentionally excluded files (do NOT ask for these)

The following are red zone and do not exist in your workspace:

${EXCLUSION_BULLETS}
Additional strings configured in \`blue-zone-insecure-strings.txt\` are
stripped from file *contents* regardless of filename.

## Blue zone manifest (\`/workspace/BLUE_ZONE_MANIFEST.md\`)

An auto-generated, read-only inventory lists every file stripped before this
workspace was mounted — files that exist on the host but are deliberately
absent here. Use it to learn the true shape of the project without ever
seeing red-zone contents. It is regenerated every run; do not edit it.

## Code Style

Follow the existing conventions already used in this codebase.
CLAUDEMD
  echo -e "${GREEN}  wrote ai-scripts/CLAUDE.md${RESET}"
else
  cp "$PRIOR_CLAUDE_MD" "$TARGET_DIR/ai-scripts/CLAUDE.md"
  echo -e "${YELLOW}  kept your existing ai-scripts/CLAUDE.md${RESET}"
fi
[ -n "$PRIOR_CLAUDE_MD" ] && rm -f "$PRIOR_CLAUDE_MD"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}Done.${RESET} $([ "$EXISTING_INSTALL" = true ] && echo "Updated" || echo "Installed") blue-zone tooling in ${BOLD}$TARGET_DIR${RESET}\n"
echo -e "Review before your first real session:"
echo -e "  ${BOLD}blue-zone.config.sh${RESET}            — folders, root files, exclude patterns"
echo -e "  ${BOLD}blue-zone-insecure-strings.txt${RESET} — content denylist"
echo -e "  ${BOLD}ai-proxy/filter${RESET}                — egress allowlist"
echo -e "  ${BOLD}ai-scripts/CLAUDE.md${RESET}            — what Claude is told about this project"
echo ""
echo -e "Next steps (from $TARGET_DIR):"
echo -e "  ${GREEN}./ai-scripts/init.sh${RESET}                       one-time setup + image build"
echo -e "  ${GREEN}./ai-scripts/validate-blue-zone.sh --strict${RESET}  confirm the blue zone is clean"
echo -e "  ${GREEN}./ai-scripts/start-cli.sh${RESET}                  start an interactive session"
