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
BLUE_ZONE_BROWSER_ORIGINS=()
BLUE_ZONE_BROWSER_DEV_PORTS=()
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
# Browser settings carried over from an existing install, so re-running to add
# one folder never silently turns the browser on — or drops its allowlist.
[ "${BLUE_ZONE_BROWSER_ENABLED:-0}" = "1" ] && DEFAULT_BROWSER="y" || DEFAULT_BROWSER="n"
if [ "${#BLUE_ZONE_BROWSER_ORIGINS[@]}" -gt 0 ]; then
  DEFAULT_BROWSER_ORIGINS="${BLUE_ZONE_BROWSER_ORIGINS[*]}"
else
  DEFAULT_BROWSER_ORIGINS=""
fi
if [ "${#BLUE_ZONE_BROWSER_DEV_PORTS[@]}" -gt 0 ]; then
  DEFAULT_BROWSER_DEV_PORTS="${BLUE_ZONE_BROWSER_DEV_PORTS[*]}"
else
  DEFAULT_BROWSER_DEV_PORTS=""
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

mkdir -p "$TARGET_DIR/ai-proxy" "$TARGET_DIR/ai-playwright"
cp -R "$SETUP_SRC/ai-scripts" "$TARGET_DIR/"
cp    "$SETUP_SRC/Dockerfile.ai-sandbox" "$TARGET_DIR/"
cp    "$SETUP_SRC/docker-compose.ai-sandbox.yml" "$TARGET_DIR/"
cp    "$SETUP_SRC/ai-proxy/Dockerfile" "$TARGET_DIR/ai-proxy/"
cp    "$SETUP_SRC/ai-proxy/tinyproxy.conf" "$TARGET_DIR/ai-proxy/"
# Build context for the optional Playwright browser. Copied unconditionally so
# enabling the browser later is a config edit, not a re-deploy — it builds
# nothing and costs nothing while BLUE_ZONE_BROWSER_ENABLED=0.
cp    "$SETUP_SRC/ai-playwright/Dockerfile" "$TARGET_DIR/ai-playwright/"
# Shared agents/skills. This is team-owned content once it lands in a project —
# an agent someone tuned must survive a tooling update — so each file is copied
# only when it is absent, never over the top of an existing one.
SHARED_NEW=0
SHARED_KEPT=0
if [ -d "$SETUP_SRC/.claude-blue-zone" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "$TARGET_DIR/.claude-blue-zone/$rel" ]; then
      SHARED_KEPT=$((SHARED_KEPT + 1))
      continue
    fi
    mkdir -p "$(dirname "$TARGET_DIR/.claude-blue-zone/$rel")"
    cp "$SETUP_SRC/.claude-blue-zone/$rel" "$TARGET_DIR/.claude-blue-zone/$rel"
    SHARED_NEW=$((SHARED_NEW + 1))
  done < <(cd "$SETUP_SRC/.claude-blue-zone" && find . -type f | sed 's|^\./||' | sort)
fi

# The tooling docs (how to run prepare/sync-in/sync-back/validate, the manifest,
# configuring blue-zone folders, …) live in claude-docker/README.md. It isn't
# project-specific like CLAUDE.md, so it's copied verbatim alongside the scripts
# it documents, inside ai-scripts/ where a developer looking at that folder will
# find it.
cp    "$SETUP_SRC/README.md" "$TARGET_DIR/ai-scripts/README.md"
chmod +x "$TARGET_DIR"/ai-scripts/*.sh
echo -e "${GREEN}  ai-scripts/{,README.md}, ai-proxy/{Dockerfile,tinyproxy.conf}, ai-playwright/Dockerfile, Dockerfile.ai-sandbox, docker-compose.ai-sandbox.yml${RESET}"
if [ "$SHARED_NEW" -gt 0 ] || [ "$SHARED_KEPT" -gt 0 ]; then
  echo -e "${GREEN}  .claude-blue-zone/: $SHARED_NEW new file(s)$([ "$SHARED_KEPT" -gt 0 ] && echo ", $SHARED_KEPT kept as-is")${RESET}"
fi

# ── Step 3: the questions ────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/5] A few questions (Enter accepts the default)...${RESET}\n"

ANS_FOLDERS="$(ask "Blue zone folders (space/comma separated — top-level dirs Claude may see)" "$DEFAULT_FOLDERS")"
ANS_ROOT_FILES="$(ask "Root files to stage alongside them (may be empty)" "$DEFAULT_ROOT_FILES")"
ANS_EXTRA_EXCLUDES="$(ask "Additional exclude patterns to append, beyond '$DEFAULT_EXCLUDES' (may be empty)" "")"
ANS_EXTRA_DENYLIST="$(ask "Additional insecure/denylist strings to append (may be empty)" "")"
ANS_EXTRA_DOMAINS="$(ask "Additional egress-allowed domains to append, e.g. api.example.com (may be empty)" "")"
# The browser is a separate, narrower allowlist from the session's own egress —
# so it is a separate question, and the default is off.
ANS_BROWSER="$(ask "Enable the Playwright browser for interactive sessions? (y/n)" "$DEFAULT_BROWSER")"
ANS_BROWSER_ORIGINS=""
ANS_BROWSER_DEV_PORTS=""
case "$ANS_BROWSER" in
  [Yy]*)
    echo    "    If Claude will run a dev server (webpack/vite/…) inside the sandbox and"
    echo    "    open it in the browser, give its port(s). This needs no egress at all."
    ANS_BROWSER_DEV_PORTS="$(ask "  Dev server port(s) Claude runs in the sandbox" "$DEFAULT_BROWSER_DEV_PORTS")"
    echo    "    Beyond that, the browser can reach ONLY the origins you list here"
    echo    "    (scheme://host[:port]). Leave empty if the dev server is all you need."
    echo    "    Example: http://host.docker.internal:8081 https://staging.example.com"
    ANS_BROWSER_ORIGINS="$(ask "  Browser-allowed external origins" "$DEFAULT_BROWSER_ORIGINS")"
    ;;
esac
ANS_DESCRIPTION="$(ask "One-line project description for ai-scripts/CLAUDE.md" "a software project")"

# Normalize comma-separated input to space-separated.
ANS_FOLDERS="${ANS_FOLDERS//,/ }"
ANS_ROOT_FILES="${ANS_ROOT_FILES//,/ }"
ANS_EXTRA_EXCLUDES="${ANS_EXTRA_EXCLUDES//,/ }"
ANS_EXTRA_DENYLIST="${ANS_EXTRA_DENYLIST//,/ }"
ANS_EXTRA_DOMAINS="${ANS_EXTRA_DOMAINS//,/ }"
ANS_BROWSER_ORIGINS="${ANS_BROWSER_ORIGINS//,/ }"
ANS_BROWSER_DEV_PORTS="${ANS_BROWSER_DEV_PORTS//,/ }"

# Pre-declared so a zero-field `read -ra` still leaves a defined (if empty)
# array under `set -u` — on bash 3.2 (macOS /bin/bash) `read -ra arr <<< ""`
# leaves `arr` completely unset rather than empty, unlike bash 4+.
FOLDERS_ARR=()
ROOT_FILES_ARR=()
EXCLUDES_ARR=()
BROWSER_ORIGINS_ARR=()
BROWSER_DEV_PORTS_ARR=()
read -ra FOLDERS_ARR <<< "$ANS_FOLDERS"
read -ra ROOT_FILES_ARR <<< "$ANS_ROOT_FILES"
read -ra EXCLUDES_ARR <<< "$DEFAULT_EXCLUDES $ANS_EXTRA_EXCLUDES"
read -ra BROWSER_ORIGINS_ARR <<< "$ANS_BROWSER_ORIGINS"
read -ra BROWSER_DEV_PORTS_ARR <<< "$ANS_BROWSER_DEV_PORTS"

case "$ANS_BROWSER" in [Yy]*) BROWSER_ENABLED_VAL=1 ;; *) BROWSER_ENABLED_VAL=0 ;; esac
# An origin reaching the host needs an explicit acknowledgement, in the config
# and in the validator. Set it here when the answers imply it, so the wizard
# doesn't produce a config that refuses its own origins on first run.
BROWSER_HOSTGW_VAL=0
for o in ${BROWSER_ORIGINS_ARR[@]+"${BROWSER_ORIGINS_ARR[@]}"}; do
  case "$o" in *//host.docker.internal*|*//gateway.docker.internal*) BROWSER_HOSTGW_VAL=1 ;; esac
done

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
BROWSER_ORIGINS_LINE="$(q_array BLUE_ZONE_BROWSER_ORIGINS ${BROWSER_ORIGINS_ARR[@]+"${BROWSER_ORIGINS_ARR[@]}"})"
BROWSER_DEV_PORTS_LINE="$(q_array BLUE_ZONE_BROWSER_DEV_PORTS ${BROWSER_DEV_PORTS_ARR[@]+"${BROWSER_DEV_PORTS_ARR[@]}"})"
BROWSER_ENABLED_LINE="BLUE_ZONE_BROWSER_ENABLED=\"\${BLUE_ZONE_BROWSER_ENABLED:-$BROWSER_ENABLED_VAL}\""
BROWSER_HOSTGW_LINE="BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY=\"\${BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY:-$BROWSER_HOSTGW_VAL}\""

# Selected folders the shipped template doesn't already have a case arm for
# (currently src/ios/android) get a visible stub arm instead of silently
# falling through the `*)` wildcard — otherwise a custom folder name looks
# configured but gets zero folder-specific filtering, with nothing in the
# file itself hinting at that.
EXISTING_ARMS="$(awk '
  /^blue_zone_excludes_for\(\)/ { infn = 1 }
  infn && /^    [A-Za-z0-9_.-]+\)[[:space:]]*$/ {
    label = $0
    sub(/^ */, "", label)
    sub(/\).*/, "", label)
    if (label != "*") print label
  }
  infn && /^}/ { infn = 0 }
' "$SETUP_SRC/blue-zone.config.sh")"

# Space-joined (not newline-joined) so the `case ... in *" $f "*` substring
# check below matches correctly.
EXISTING_ARMS_SP=" $(printf '%s ' $EXISTING_ARMS) "

# Written to a temp file rather than passed as an `awk -v` value — a -v
# assignment containing raw embedded newlines is not portable (behavior
# differs across awk implementations, e.g. macOS's bundled awk vs. gawk/mawk),
# so the stub arms are read back in via getline instead.
STUB_ARMS_FILE="$(mktemp)"
for f in ${FOLDERS_ARR[@]+"${FOLDERS_ARR[@]}"}; do
  case "$EXISTING_ARMS_SP" in *" $f "*) continue ;; esac
  {
    printf '    %s)\n' "$f"
    printf '      # No folder-specific red-zone rules configured yet for "%s" — only\n' "$f"
    printf '      # the common excludes above apply. Add rsync --exclude patterns here\n'
    printf '      # (see src/ios/android above for examples) for anything in %s/ that\n' "$f"
    printf '      # must never reach Claude.\n'
    printf '      : ;;\n'
  } >> "$STUB_ARMS_FILE"
done

awk -v folders_line="$FOLDERS_LINE" -v rootfiles_line="$ROOTFILES_LINE" -v excludes_line="$EXCLUDES_LINE" -v stub_arms_file="$STUB_ARMS_FILE" -v browser_origins_line="$BROWSER_ORIGINS_LINE" -v browser_dev_ports_line="$BROWSER_DEV_PORTS_LINE" -v browser_enabled_line="$BROWSER_ENABLED_LINE" -v browser_hostgw_line="$BROWSER_HOSTGW_LINE" '
  /^BLUE_ZONE_FOLDERS=/ { print folders_line; next }
  /^BLUE_ZONE_ROOT_FILES=/ { print rootfiles_line; next }
  /^BLUE_ZONE_BROWSER_ENABLED=/ { print browser_enabled_line; next }
  /^BLUE_ZONE_BROWSER_ALLOW_HOST_GATEWAY=/ { print browser_hostgw_line; next }
  /^BLUE_ZONE_BROWSER_ORIGINS=\(/ {
    print browser_origins_line
    if ($0 !~ /\)[[:space:]]*$/) in_browser_origins = 1
    next
  }
  in_browser_origins { if ($0 ~ /^\)/) in_browser_origins = 0; next }
  /^BLUE_ZONE_BROWSER_DEV_PORTS=\(/ {
    print browser_dev_ports_line
    if ($0 !~ /\)[[:space:]]*$/) in_browser_dev_ports = 1
    next
  }
  in_browser_dev_ports { if ($0 ~ /^\)/) in_browser_dev_ports = 0; next }
  /^BLUE_ZONE_COMMON_EXCLUDES=\(/ {
    print excludes_line
    if ($0 !~ /\)[[:space:]]*$/) in_excludes = 1
    next
  }
  in_excludes { if ($0 ~ /^\)/) in_excludes = 0; next }
  /^    \*\)/ {
    while ((getline stub_line < stub_arms_file) > 0) print stub_line
    close(stub_arms_file)
  }
  { print }
' "$SETUP_SRC/blue-zone.config.sh" > "$TARGET_DIR/blue-zone.config.sh"
rm -f "$STUB_ARMS_FILE"
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
  printf '# Regenerated by ai-scripts/ on every run — never committed.\ndocker-compose.blue-zone.yml\ndocker-compose.browser.yml\n' > "$TARGET_DIR/.gitignore"
else
  for gi in docker-compose.blue-zone.yml docker-compose.browser.yml; do
    grep -qxF "$gi" "$TARGET_DIR/.gitignore" && continue
    printf '\n# Regenerated by ai-scripts/ on every run — never committed.\n%s\n' "$gi" >> "$TARGET_DIR/.gitignore"
  done
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

  # Browser rules only when the browser is on — telling Claude about tools it
  # does not have is noise, and quietly implies a capability that isn't there.
  BROWSER_SECTION=""
  if [ "$BROWSER_ENABLED_VAL" = "1" ]; then
    BROWSER_SECTION="$(cat <<'BROWSERMD'
## Browser automation (Playwright MCP)

This session has a browser attached, exposed as `playwright` MCP tools. It is
**not** general internet access: it can reach a short, explicitly configured
list of origins and nothing else. Every other destination — including the
developer's machine and LAN — is refused by a proxy before a connection is
made. A blocked request is policy, not a bug: say which origin you needed and
why, and never try to route around a refusal.

The blue zone exists so this workspace's contents stay here, and the browser is
the one tool that can carry them out. So:

- Never put workspace content — file contents, paths, code snippets, values you
  read here — into a URL, query string, form field, or request body.
- Never use the browser to share, upload, paste, or publish anything from
  `/workspace`.
- Use it for loading the app or docs, inspecting rendered pages, reproducing UI
  behaviour, and reading back what you see.

BROWSERMD
)"
    # Command substitution eats trailing newlines; restore the blank line that
    # separates this section from the next heading.
    BROWSER_SECTION="$BROWSER_SECTION"$'\n'
  fi

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

${BROWSER_SECTION}
## Finish every task with a review

Your team keeps shared agents in \`/workspace/.claude/agents\` (mounted
read-only from the repository). One of them is \`change-reviewer\`.

**When you believe a task is finished, invoke \`change-reviewer\` before you
tell the developer you are done.** Give it one line on what the task was and
the list of files you created, modified, or deleted — it cannot work those out
for itself, since this workspace is a filtered copy with no git history.

Then act on what comes back: fix **blocking** and **important** findings, and
take **scope** findings seriously — if the reviewer says you changed something
the task did not ask for, the right answer is almost always to revert that
part. A change that does one thing gets merged; a change that fixes everything
sits. Report the verdict to the developer with your summary, and if you
disagree with a finding, say so rather than quietly skipping it.

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
echo -e "  ${BOLD}ai-proxy/filter${RESET}                — egress allowlist (the session's own)"
echo -e "  ${BOLD}BLUE_ZONE_BROWSER_ORIGINS${RESET}      — browser allowlist, if you enabled the browser"
echo -e "  ${BOLD}.claude-blue-zone/${RESET}             — shared agents/skills (committed, mounted read-only)"
echo -e "  ${BOLD}ai-scripts/CLAUDE.md${RESET}            — what Claude is told about this project"
echo ""
echo -e "Next steps (from $TARGET_DIR):"
echo -e "  ${GREEN}./ai-scripts/init.sh${RESET}                       one-time setup + image build"
echo -e "  ${GREEN}./ai-scripts/validate-blue-zone.sh --strict${RESET}  confirm the blue zone is clean"
echo -e "  ${GREEN}./ai-scripts/start-cli.sh${RESET}                  start an interactive session"
