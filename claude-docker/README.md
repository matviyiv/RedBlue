# Claude Code - Blue Zone Docker Setup

Isolates Claude Code to a filtered blue zone only.
Red zone files are either not mounted or stripped by rsync before mounting.

📊 See [docs/blue-zone-flow.md](docs/blue-zone-flow.md) for a diagram of how
files move from the repo, through staging and the container, and back.

The blue zone mounts are **writable**: Claude can create and edit files inside
the configured folders (by default `/workspace/src`, `/workspace/ios`, and
`/workspace/android` — see [Configuring blue-zone folders](#configuring-blue-zone-folders)).
Writes go to the
staging copy at `/tmp/blue-zone/` on the host, and `sync-back.sh` copies them
into your repo **automatically when the session ends** (interactive and
headless). Set `SYNC_BACK=0` to disable, or run it by hand:

```bash
./scripts/sync-back.sh --dry-run   # preview what would be copied back
./scripts/sync-back.sh             # apply
```

Sync-back safety rules (enforced via a snapshot taken at prepare time):

- Only files that were visible to Claude get updated in place.
- A new file whose path collides with a stripped **red-zone** file is
  **blocked** — it will never overwrite the real one; you get a warning instead.
- Files Claude removed are deleted from the repo too, but only if they were in
  the blue zone at prepare time — red-zone paths are never in the snapshot, so
  they can never be deleted by sync-back.

## Configuring blue-zone folders

Which top-level folders are staged into the blue zone — and what gets stripped
out of each — is defined in one place: **`blue-zone.config.sh`**. Nothing else
is hardcoded, so adapting this setup to a non-React-Native project is a one-file
edit.

```bash
# blue-zone.config.sh

# The only directories mounted into the container, each at /workspace/<folder>.
# A folder that doesn't exist in the repo is skipped with a warning.
BLUE_ZONE_FOLDERS=(src ios android)      # e.g. (cmd internal pkg) for a Go svc,
                                         #      (app lib spec)     for Rails, …

# Stripped from every folder, whatever the project:
BLUE_ZONE_COMMON_EXCLUDES=(".env*" "node_modules/")

# Per-folder red-zone rules live in blue_zone_excludes_for() — add a `case`
# arm when a new folder needs its own exclusions.
```

Edit `BLUE_ZONE_FOLDERS`, then run any of the scripts — `prepare-blue-zone.sh`
stages exactly those folders, generates the matching docker-compose mounts
(`docker-compose.blue-zone.yml`, layered on via `COMPOSE_FILE`), and
`validate-blue-zone.sh` verifies every configured exclusion actually held. You
do **not** touch `docker-compose.yml` or any script to add or remove a folder.

## Blue Zone Contents

With the default `BLUE_ZONE_FOLDERS=(src ios android)`:

| Folder | What's included | What's excluded (red) |
|--------|----------------|----------------------|
| `src/` | All TS/JS/TSX/JSX, hooks, components, screens, types | `*-api.ts`, `*Service.ts`, `*Client.ts`, `api/`, `services/`, `.graphql` |
| `ios/` | Swift, ObjC, xcodeproj structure, Info.plist | `*.p12`, `*.mobileprovision`, `GoogleService-Info.plist`, `*.xcconfig`, `Pods/`, `build/` |
| `android/` | Kotlin, Java, AndroidManifest.xml, res/ | `*.jks`, `*.keystore`, `google-services.json`, `*.properties`, `build/`, `.gradle/` |

## File Structure

```
your-rn-project/
├── .claude/
│   └── CLAUDE.md                  <- Claude's scope and constraints
├── scripts/
│   ├── init.sh                    <- One-time setup
│   ├── auth.sh                    <- Auth resolution (API key / token / login)
│   ├── prepare-blue-zone.sh       <- rsync filter into /tmp/blue-zone/
│   ├── validate-blue-zone.sh      <- Secret leak scanner
│   ├── start-cli.sh               <- Interactive session (local dev)
│   ├── run-headless.sh            <- Headless prompt runner
│   └── sync-back.sh               <- Auto-syncs Claude's changes to the repo
├── blue-zone.config.sh            <- Folder list + exclusion rules (edit this)
├── Dockerfile
├── docker-compose.yml             <- Base compose (no folder mounts hardcoded)
├── docker-compose.blue-zone.yml   <- Generated per-folder mounts (git-ignored)
└── .gitlab-ci.yml
```

## Authentication

An API key is **optional**. Auth is resolved in this order:

| Priority | Method | How |
|----------|--------|-----|
| 1 | API key | `export ANTHROPIC_API_KEY=sk-ant-...` |
| 2 | Subscription token | `claude setup-token` on the host (Claude Pro/Max), then `export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat...` |
| 3 | Persisted login | Run `./scripts/start-cli.sh` once and log in via `/login` — credentials are stored in the `claude-home` Docker volume and reused by later runs (including headless) |

Headless runs (`run-headless.sh`, CI) need one of the three already in place;
interactive sessions can always start and log in on the spot.

## Persistent Sessions

The container's entire home directory lives in the `claude-home` Docker
volume, so **everything survives between runs**: login credentials,
onboarding answers (theme, trust dialog — stored in `~/.claude.json`),
settings, and session history. You go through Claude's setup exactly once.

Past conversations can be resumed inside a new session with `claude
--continue` / `--resume` (the history is in the persisted home).

To wipe it and start fresh:

```bash
./scripts/start-cli.sh --clear    # removes the claude-home volume
```

## Quick Start

```bash
# One-time setup
./scripts/init.sh

# Interactive session (local dev) — with an API key...
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/start-cli.sh

# ...or without one: just start it and log in with /login (persists)
./scripts/start-cli.sh

# Headless run
./scripts/run-headless.sh "Review ios/ native modules for memory leaks"
./scripts/run-headless.sh "Check android/ Kotlin bridge code" --output-format json

# Validate only (no Docker)
./scripts/validate-blue-zone.sh --strict
```

## Flow

```
Host repo                    /tmp/blue-zone/          Container
src/
  userAuth-api.ts  --x
  jitsiService.ts  --x
  components/      -----> src/components/   ----> /workspace/src/
ios/
  *.p12            --x
  Pods/            --x
  *.swift          -----> ios/*.swift        ----> /workspace/ios/
android/
  *.jks            --x
  build/           --x
  *.kt             -----> android/*.kt       ----> /workspace/android/
```

## GitLab CI Variables

Set **one** of:

| Key | Masked | Protected |
|-----|--------|-----------|
| `ANTHROPIC_API_KEY` | Yes | Yes |
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Yes |
