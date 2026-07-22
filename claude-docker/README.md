# Claude Code - Blue Zone Docker Setup

Isolates Claude Code to a filtered blue zone only.
Red zone files are either not mounted or stripped by rsync before mounting.

📊 Diagrams:
[docs/dev-setup-flow.md](docs/dev-setup-flow.md) — new-developer local setup;
[docs/blue-zone-flow.md](docs/blue-zone-flow.md) — how files move from the repo,
through staging and the container, and back.

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

## Blue zone manifest

`prepare-blue-zone.sh` writes a **`BLUE_ZONE_MANIFEST.md`** at the blue zone root
and mounts it **read-only** into the container at `/workspace/BLUE_ZONE_MANIFEST.md`.
It is a Claude-readable record of what was **stripped** — the files that exist on
the host but are deliberately absent from the workspace (red zone) — together
with the filename rules and content denylist that removed them.

Its purpose is to give Claude the true shape of the project without leaking any
red-zone *contents*: Claude can see that, say, `src/api/auth-api.ts` exists (so it
codes against the contract in `src/types/` instead of recreating the file) while
never being able to read it. Because it lives at the blue zone root — not inside a
mounted folder — `sync-back.sh` never copies it back into the repo, and the
read-only mount means Claude cannot alter it. Change the filename via
`BLUE_ZONE_MANIFEST_FILE` in `blue-zone.config.sh`.

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

# Individual root-level files, staged and validated like the folders.
BLUE_ZONE_ROOT_FILES=(package.json tsconfig.json)

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

### Adding individual files (`BLUE_ZONE_ROOT_FILES`)

To expose a single file (e.g. `package.json`, `tsconfig.json`), list it in
**`BLUE_ZONE_ROOT_FILES`** rather than bind-mounting it in `docker-compose.yml`.
Unlike a raw mount, a file listed here goes through the **same pipeline as the
folders**: it is staged into the blue zone, dropped if the content denylist finds
a forbidden string, scanned for secrets by `validate-blue-zone.sh`, recorded in
the snapshot, synced back on exit, and listed in the manifest. Each file is
mounted at `/workspace/<path>` (writable, like folders).

```bash
BLUE_ZONE_ROOT_FILES=(package.json tsconfig.json babel.config.js)
```

- Paths are repo-relative; a file that doesn't exist is skipped with a warning.
- `.env*` files are **refused** — secrets belong in the red zone, not here.
- A listed file that contains a denylisted string is dropped and shows up in the
  manifest as *not available*, exactly like a stripped folder file.

The only files still bind-mounted directly in `docker-compose.yml` are
`.env.example` (schema reference, value-less, validated separately) and
`.claude/CLAUDE.md` (Claude's guidance) — everything reviewable goes through
`BLUE_ZONE_ROOT_FILES`.

## Content denylist (insecure strings)

Filename patterns can't catch a secret hiding *inside* an otherwise-innocuous
file. For that, list forbidden strings — one per line — in
**`blue-zone-insecure-strings.txt`**. During `prepare-blue-zone.sh`, any staged
file whose content contains one of them is **dropped before the blue zone is
mounted**, so it never reaches the container (and, being absent from the
prepare-time snapshot, is never re-added by `sync-back.sh`).

```text
# blue-zone-insecure-strings.txt   (# comments and blank lines ignored)
BEGIN RSA PRIVATE KEY
api.internal.mycorp.com
AKIA
password=
```

- Matching is **case-insensitive** and **substring** (fixed string, not regex).
- Applies to every file in every configured folder.
- The shipped file is a commented template — it removes nothing until you add
  entries. Point elsewhere with `BLUE_ZONE_DENYLIST_FILE=/path/to/list`.
- `validate-blue-zone.sh` re-scans the staged zone and **fails** if any
  denylisted string slipped through, so the guarantee is checked, not assumed.

### Reviewed exceptions (`fine-for-claude`)

Sometimes a match is intentional — a `password=` example in a comment, a fixture
token, a documented sample. Rather than loosen the denylist for everyone, mark
the specific line with the **allow marker** and it stays in the blue zone:

```ts
const sample = "password=hunter2"; // fine-for-claude
const url    = "http://192.168.1.10:3000"; // fine-for-claude
```

A line carrying the marker is exempt from **both** the content denylist (its
file is not dropped) **and** the hardcoded-secret scan (it is not flagged). The
exemption is **per line** — an unmarked secret elsewhere in the same file is
still removed/flagged, so the marker can't be used to wave a whole file through.

- Configure the marker via `BLUE_ZONE_ALLOW_MARKER` in `blue-zone.config.sh`
  (default `fine-for-claude`). Matching is case-insensitive substring.
- Set `BLUE_ZONE_ALLOW_MARKER=""` to disable the mechanism entirely — nothing
  is ever exempted.

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
│   ├── auth.sh                    <- Auth resolution (token / login)
│   ├── prepare-blue-zone.sh       <- rsync filter into /tmp/blue-zone/
│   ├── validate-blue-zone.sh      <- Secret leak scanner
│   ├── start-cli.sh               <- Interactive session (local dev)
│   ├── run-headless.sh            <- Headless prompt runner
│   ├── sync-back.sh               <- Auto-syncs Claude's changes to the repo
│   └── diagnose-egress.sh         <- Probe the egress proxy allowlist
├── blue-zone.config.sh            <- Folder list + exclusion rules (edit this)
├── blue-zone-insecure-strings.txt <- Content denylist (forbidden strings)
├── Dockerfile
├── docker-compose.yml             <- Base compose (no folder mounts hardcoded)
├── docker-compose.blue-zone.yml   <- Generated per-folder mounts (git-ignored)
└── .gitlab-ci.yml
```

## Authentication

A token is **optional**. Auth is resolved in this order:

| Priority | Method | How |
|----------|--------|-----|
| 1 | Subscription token | `claude setup-token` on the host (Claude Pro/Max), then `export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat...` |
| 2 | Persisted login | Run `./scripts/start-cli.sh` once and log in via `/login` — credentials are stored in the `claude-home` Docker volume and reused by later runs (including headless) |

Headless runs (`run-headless.sh`, CI) need one of the two already in place;
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
./scripts/start-cli.sh --clear    # removes all named volumes (claude-home + node-modules)
```

## Dependencies (node_modules cache)

`node_modules` is **red-zone-excluded** from the blue zone (never copied from the
host), but a persistent **`node-modules`** Docker volume is mounted at
`/workspace/node_modules`, so installed packages **survive between runs**. The
first `npm install` populates it; later runs are incremental. npm's download
cache (`~/.npm`) persists too, inside the `claude-home` volume.

The **interactive** container can reach the npm and yarn registries (added to the
egress allowlist in `proxy/filter`), so `npm install` / `yarn install` work there.
The **headless** container has no network by design — it reuses whatever the
persistent `node-modules` volume already holds, so run an install interactively
once and headless/CI runs pick it up.

```bash
docker compose down -v            # clears node_modules (and claude-home) volumes
```

## Quick Start

```bash
# One-time setup
./scripts/init.sh

# Interactive session (local dev) — with a subscription token...
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat...
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

Set:

| Key | Masked | Protected |
|-----|--------|-----------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Yes |
