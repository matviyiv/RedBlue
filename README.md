# RedBlue — Secure AI Code Review for React Native

Run Claude Code inside a Docker container that can **only see what you allow**.
No secrets. No signing keys. No internal endpoints. Just the code you want reviewed.

---

## The Problem

AI coding assistants are powerful, but feeding them your full repository means
exposing things you probably don't want to share:

- `.env` files with real API URLs and tokens
- iOS signing certificates and provisioning profiles
- Android keystores and `google-services.json`
- Internal service endpoints, Jitsi servers, auth secrets
- CI/CD configuration

Most teams either avoid AI review entirely, or paste code manually and hope they
didn't include anything sensitive. This project gives a third option.

---

## The Idea: Red Zone / Blue Zone

Divide your repository into two zones before Claude ever sees a byte of it.

```
RED ZONE                          BLUE ZONE
(stays on your machine)           (safe to hand to AI)

src/api/auth-api.ts    ✗          src/components/       ✓
src/services/*.ts      ✗          src/screens/          ✓
src/utils/httpClient   ✗          src/types/            ✓  ← API contracts
.env.local             ✗          .env.example          ✓  ← var names only
.env.production        ✗
ios/*.p12              ✗          ios/*.swift           ✓
ios/*.mobileprovision  ✗          ios/*.xcodeproj       ✓
ios/GoogleService-Info ✗
android/*.jks          ✗          android/*.kt          ✓
android/google-services✗          android/src/          ✓
android/keystore.props ✗
```

A shell script (`prepare-blue-zone.sh`) uses `rsync` to copy only the blue zone
into a staging directory. A second script (`validate-blue-zone.sh`) scans it for
any leaked secrets before Docker ever starts. Claude Code then runs in a container
that mounts the staging directory **writable** with `network_mode: none` — Claude
can create and edit files, but writes land in the staging copy at
`/tmp/blue-zone/<project>/`, never directly in your repo. The staging root is
namespaced per project, so you can run a session for several projects at once
(one terminal each) without them clobbering each other. When the session ends,
`sync-back.sh` automatically copies the changes into your repo, refusing to touch
red-zone paths.

You don't have to stop working while Claude does: `sync-in.sh` merges your latest
repo changes into a live session, and `sync-back.sh` merges Claude's work back —
neither direction overwrites the other. See
[Working alongside Claude](#working-alongside-claude--two-way-sync).

---

## The Context Problem — and How It's Solved

Stripping API files creates a new problem: Claude doesn't know what functions
exist, so it either refuses to help or **hallucinates** function signatures,
endpoints, and response shapes.

The solution is a `src/types/` layer that ships only TypeScript **interfaces** —
no implementation, no URLs, no secret reads. Claude can see the shape of the API
without seeing how it's built or where it points.

```typescript
// src/types/auth.types.ts — in the blue zone
export interface IAuthApi {
  login(request: LoginRequest): Promise<LoginResponse>;
  logout(): Promise<void>;
  refreshSession(): Promise<LoginResponse>;
}
// The actual axios calls, base URL, and token handling live in the red zone.
```

On every run, `prepare-blue-zone.sh` also auto-generates a `BLUE_ZONE_MANIFEST.md`
that lists which files were stripped. Claude can read the manifest to know what
exists on the host without being able to see the content.

---

## Repository Layout

The reusable tooling lives in **`claude-docker/`** — the single source of truth.
`deploy-blue-zone.sh` installs it into a real project (see
[Using This in Your Own Project](#using-this-in-your-own-project)), and
`generate-test-project.sh` copies it into the example project below. Nothing
is hand-maintained in two places. Every path the tooling places at a
project's root is prefixed (`ai-scripts/`, `ai-proxy/`, `*.ai-sandbox*`)
rather than using generic names like `scripts/` or `Dockerfile`, so
installing it never collides with files a real project already has — and it
never touches that project's own `.claude/` directory.

```
RedBlue/
├── claude-docker/                  # ← The tool (single source of truth)
│   ├── ai-scripts/
│   │   ├── CLAUDE.md               # Template rules: what Claude can/cannot do
│   │   ├── init.sh                 # One-time setup (prerequisites + Docker build)
│   │   ├── prepare-blue-zone.sh    # rsync filter → /tmp/blue-zone/ (resets the zone)
│   │   ├── validate-blue-zone.sh   # Secret leak scanner (run before Docker)
│   │   ├── start-cli.sh            # Interactive Claude session (local dev)
│   │   ├── run-headless.sh         # Single-prompt headless run (CI)
│   │   ├── sync-in.sh              # Merge YOUR repo changes into a live blue zone
│   │   ├── sync-back.sh            # Merge Claude's changes back into the repo
│   │   └── lib/                    # Shared internals (sourced, not run)
│   │       ├── blue-zone-project.sh   #   the red-zone filter itself
│   │       ├── blue-zone-git.sh       #   shadow git repo behind two-way sync
│   │       └── blue-zone-manifest.sh  #   manifest + compose overlay writers
│   ├── blue-zone.config.sh         # Which folders are blue zone + exclusion rules
│   ├── blue-zone-insecure-strings.txt  # Content denylist (strings that must never leak)
│   ├── ai-proxy/                   # Egress allowlist proxy (interactive sessions)
│   │   ├── Dockerfile              #   tinyproxy on alpine
│   │   ├── tinyproxy.conf          #   default-deny forward proxy
│   │   └── filter                  #   allowlist: Anthropic + GitHub domains
│   ├── Dockerfile.ai-sandbox       # node:22-alpine + Claude Code CLI, non-root user
│   ├── docker-compose.ai-sandbox.yml  # Network isolation, resource caps
│   └── .gitlab-ci.yml              # Full pipeline: build → validate → review
│
├── deploy-blue-zone.sh             # Install the tooling into a real project —
│                                   #   copies it in and asks a few questions
│                                   #   (folders, excludes, denylist, egress domains)
│
├── generate-test-project.sh        # Scaffold a realistic test RN project AND
│                                   #   copy the claude-docker tooling into it
│
└── MyBluezoneTest/                 # Example RN project (blue + red zone files)
    ├── ai-scripts/CLAUDE.md        # Project-specific Claude rules
    ├── src/
    │   ├── types/                  # ← Blue zone API contracts (interfaces only)
    │   │   ├── auth.types.ts       #   IAuthApi, LoginRequest, LoginResponse
    │   │   ├── jitsi.types.ts      #   IJitsiService, JitsiRoomOptions
    │   │   ├── http.types.ts       #   ApiResponse<T>, HttpClientInstance
    │   │   └── index.ts            #   re-exports
    │   ├── api/                    # RED — stripped by prepare-blue-zone.sh
    │   ├── services/               # RED — stripped
    │   └── utils/httpClient.ts     # RED — stripped
    └── ai-scripts/, ai-proxy/, …   # Tooling copied in from claude-docker/
                                    #   (materialized, not source — regenerated
                                    #   by generate-test-project.sh on every run)
```

---

## How It Works

```
1. prepare-blue-zone.sh
   rsync src/ ios/ android/ → /tmp/blue-zone/<project>/
   with red zone exclusions              auto-generate BLUE_ZONE_MANIFEST.md
   (<project> defaults to the project dir name — namespaced so multiple
    projects can run at once; override with BLUE_ZONE_PROJECT)

2. validate-blue-zone.sh
   scan /tmp/blue-zone/<project>/ for:
   • configured red-zone patterns that leaked (API/service, signing artifacts)
   • hardcoded secrets (regex patterns; test files excluded)
   • .env files and non-placeholder .env.example values
   • content-denylist strings
   exit 1 if any violation found

3. docker compose run claude-code
   mounts (for a project named "app"):
     /tmp/blue-zone/app/src     → /workspace/src     (writable)
     /tmp/blue-zone/app/ios     → /workspace/ios     (writable)
     /tmp/blue-zone/app/android → /workspace/android (writable)
     BLUE_ZONE_MANIFEST.md      → /workspace/        (read-only)
   network isolation:
     • headless (claude-code):  network_mode: none — no network at all
     • interactive (claude-cli): internal network + egress-proxy allowlist —
       can reach Anthropic (API/auth) and GitHub, but NOT your LAN
   runs: claude -p "..." --allowedTools Read,Write,Edit

4. sync-back.sh  (automatic when the session ends)
   merges Claude's changes from /tmp/blue-zone/<project> back into the repo:
     • updates only files Claude was allowed to see
     • three-way merges files you edited too, instead of overwriting them
     • blocks new files that collide with stripped red-zone paths
     • deletes files Claude removed (only ones that were in the blue zone)
   disable with SYNC_BACK=0; preview with ./ai-scripts/sync-back.sh --dry-run
```

---

## Working alongside Claude — two-way sync

A session used to be exclusive: `prepare-blue-zone.sh` overwrote the staging
tree from your repo, `sync-back.sh` overwrote your repo from the staging tree,
and whoever ran last won. Editing the repo during a session meant losing one
side or the other.

Both directions are now **merges**, so you and Claude can work at the same time:

```bash
# Terminal 1 — the session
./ai-scripts/start-cli.sh

# Terminal 2 — you, still working in the repo
vim src/screens/HomeScreen.tsx
./ai-scripts/sync-in.sh              # push your changes into the live blue zone
./ai-scripts/sync-in.sh --dry-run    # …or see what would come in first
```

`sync-in.sh` rewrites only the files that actually changed on your side. Files
Claude is working on are left exactly as he left them, and the running container
picks the new content up live. When you have both edited the *same lines*, the
file gets ordinary conflict markers and Claude resolves them in-session — the
`CLAUDE.md` template teaches him how, and `sync-back.sh` refuses to export a
file whose markers are still there.

| Script | Direction | Effect |
|---|---|---|
| `prepare-blue-zone.sh` | repo → zone | **Reset.** Staging tree is made to match the repo; unsynced work in the zone is discarded. Use it to start a session. |
| `sync-in.sh` | repo → zone | **Merge.** Your changes come in, Claude's work stays. Use it during a session. |
| `sync-back.sh` | zone → repo | **Merge.** Claude's changes go out, your concurrent edits stay. |

### How it works

The staging tree is tracked by a private *shadow git repo* with two branches:
`blue-base` (your repo, seen through the red-zone filter) and `blue-work` (the
live staging tree). Every sync is a diff or a merge between them, which is what
lets the tooling tell "the host changed this" apart from "Claude changed this".

The shadow repo lives in a **sibling** of the staging root
(`/tmp/blue-zone/<project>.gitsync/`), never inside it. Only paths under
`/tmp/blue-zone/<project>/` are ever mounted, so there is no `.git` anywhere the
container can reach and the "never run git in `/workspace`" rule still holds.
It has no remote, is never pushed, and deleting it is always safe — the next
`prepare-blue-zone.sh` rebuilds it.

Going the other way, `sync-back.sh` merges with `git merge-file`, which needs no
object database. Your concurrent edit is merged correctly whether or not you
committed it, and even if the project isn't a git repository at all.

Set `BLUE_ZONE_SYNC_MODE=legacy` to fall back to the original one-way copy on a
host with no usable `git`. `sync-in.sh` is unavailable in that mode, and
sync-back cannot merge concurrent edits.

### Opening a merge request (`--mr`)

By default `sync-back.sh` stops at your working tree — the changes land in your
checkout and you review and commit them yourself. Git is only touched when you
ask for it:

```bash
./ai-scripts/sync-back.sh --mr                        # branch, commit, push, open an MR
./ai-scripts/sync-back.sh --mr --mr-branch ai/review-1 # name the branch yourself
./ai-scripts/sync-back.sh --mr --mr-target develop     # target a specific branch
./ai-scripts/sync-back.sh --merge                      # …and merge when the pipeline passes
./ai-scripts/sync-back.sh --mr --dry-run               # show the branch/target/body, change nothing
```

This commits **only the paths that were synced** — never `git add -A` — so
unrelated work in your tree stays out of the commit, and refuses to run at all
if your index already has staged changes. The MR body lists the change set and
states that Claude worked against a filtered copy, so reviewers know the
red-zone files were never visible to it.

It runs entirely on the host: the container's egress allowlist covers Anthropic,
GitHub and the npm registries — not GitLab — so this could not work from inside
the container even if we wanted it to. Every preflight failure degrades
gracefully (no `glab`, not authenticated, origin isn't GitLab, push rejected):
you get a clear message, and the changes are already in your working tree.

---

## Using This in Your Own Project

### 1. Install the tooling with `deploy-blue-zone.sh`

```bash
./deploy-blue-zone.sh /path/to/your-project
```

Copies the tooling in, then asks a short series of questions — blue-zone
folders, root files to stage, extra exclude patterns, insecure/denylist
strings, and egress-allowed domains — each with a sensible default shown in
brackets, so pressing Enter through all of them still produces a working
setup. It finishes by generating a project-specific `ai-scripts/CLAUDE.md`
from your answers.

```
Blue zone folders (space/comma separated — top-level dirs Claude may see) [src]:
Root files to stage alongside them (may be empty) [package.json tsconfig.json]:
Additional exclude patterns to append, beyond '.env* node_modules/' (may be empty):
Additional insecure/denylist strings to append (may be empty):
Additional egress-allowed domains to append, e.g. api.example.com (may be empty):
One-line project description for ai-scripts/CLAUDE.md [a software project]:
```

- `-y` / `--yes` accepts every default without prompting — for a scripted or
  CI reinstall.
- Every path it writes at your project's root is uniquely named
  (`ai-scripts/`, `ai-proxy/`, `Dockerfile.ai-sandbox`,
  `docker-compose.ai-sandbox.yml`) so it never collides with a `scripts/` or
  `Dockerfile` your project already has — and it never touches your
  project's own `.claude/` directory.
- **Safe to re-run.** On a project that already has the tooling installed,
  it reads the existing `blue-zone.config.sh` and uses those values as the
  new defaults, so re-running to add one folder or domain doesn't reset
  earlier answers. Denylist and egress-allowlist entries are only ever
  appended (deduplicated) — a repeated answer never produces a duplicate
  line — and an existing `.env.example` or hand-edited `ai-scripts/CLAUDE.md`
  is never overwritten without asking first.

`ai-scripts/` reads `blue-zone.config.sh` from the project root, and that
reads `blue-zone-insecure-strings.txt` next to it — so keep all three
together. Re-run `deploy-blue-zone.sh` whenever a new version of the tooling
lands in `claude-docker/`; there is no per-project fork to reconcile.

<details>
<summary>Advanced: manual copy (skip the wizard)</summary>

```bash
cp -R claude-docker/ai-scripts                      your-project/
cp -R claude-docker/ai-proxy                         your-project/   # egress allowlist proxy
cp    claude-docker/blue-zone.config.sh             your-project/   # which folders are blue zone
cp    claude-docker/blue-zone-insecure-strings.txt  your-project/   # content denylist
cp    claude-docker/Dockerfile.ai-sandbox            your-project/
cp    claude-docker/docker-compose.ai-sandbox.yml    your-project/
```

Edit `blue-zone.config.sh`, `blue-zone-insecure-strings.txt`, `ai-proxy/filter`
and `ai-scripts/CLAUDE.md` by hand afterward — this is exactly what
`deploy-blue-zone.sh` automates.

</details>

### 2. Add your API contracts to `src/types/`

For each file that `prepare-blue-zone.sh` will strip (API clients, services, HTTP
utils), create a corresponding `*.types.ts` file that exports only interfaces:

```typescript
// src/types/your-api.types.ts
export interface IYourApi {
  fetchUser(id: string): Promise<User>;
  updateProfile(data: ProfileUpdate): Promise<User>;
}
```

No `import axios`, no `process.env`, no URLs. Just the shape.

### 3. Create `.env.example` with variable names only

```bash
API_BASE_URL=
WEBSOCKET_URL=
SENTRY_DSN=
```

This goes into the blue zone so Claude knows which env vars exist without
seeing their values.

### 4. Run it

```bash
# One-time setup (checks prerequisites, builds Docker image)
./ai-scripts/init.sh

# Interactive session — opens Claude Code CLI inside the container.
# Authenticate with ONE of:
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat...  # a) `claude setup-token` (Pro/Max)
./ai-scripts/start-cli.sh                        # b) no token at all — log in via
                                              #    /login once; credentials persist
                                              #    in the claude-home volume

# Claude state (login, onboarding, session history) persists between runs
# in the claude-home Docker volume. Wipe it to start fresh:
./ai-scripts/start-cli.sh --clear

# Headless prompt (CI-friendly)
./ai-scripts/run-headless.sh "Review src/ for TypeScript errors and suggest fixes"
./ai-scripts/run-headless.sh "Check ios/ native modules for memory leaks" --output-format json
```

### 5. Validate without running Claude

```bash
./ai-scripts/validate-blue-zone.sh --strict
```

All checks must pass before Docker starts:

| Check | What it looks for |
|-------|------------------|
| 1 | Any configured red-zone pattern (from `blue-zone.config.sh`) that leaked into a blue-zone folder — API/service files, iOS/Android signing artifacts, etc. |
| 2 | Hardcoded secrets (regex: `password=`, `api_key=`, `sk-ant-`, AWS key patterns). Test files (`*Tests.swift`, `*.test.*`, `*.spec.*`, `__tests__/`, …) are excluded, since fixtures legitimately contain fake credentials. |
| 3 | `.env` files anywhere in the blue zone |
| 4 | `.env.example` has no real values |
| 5 | Content-denylist strings (from `blue-zone-insecure-strings.txt`) that survived into the blue zone |
| 6 | Unresolved merge conflict markers left by a `sync-in.sh` refresh (warning locally, violation under `--strict`) |

---

## Customising the Red Zone

All of it is driven by `blue-zone.config.sh` — you never edit the scripts. Set
which top-level folders are blue zone, and the per-folder red-zone patterns
stripped out of each:

```bash
# blue-zone.config.sh

# Which folders get copied into the blue zone (change for non-RN projects):
BLUE_ZONE_FOLDERS=(src ios android)

# Excludes applied to every folder:
BLUE_ZONE_COMMON_EXCLUDES=(".env*" "node_modules/")

# Per-folder red-zone patterns — add your own naming conventions here:
blue_zone_excludes_for() {
  case "$1" in
    src)
      cat <<'PATTERNS'
*-api.ts        # auth-api.ts, payments-api.ts …
*Service.ts     # UserService.ts, JitsiService.ts …
*Client.ts      # HttpClient.ts, GraphQLClient.ts …
api/            # entire api/ directory
services/       # entire services/ directory
*.graphql       # GraphQL query files
PATTERNS
      ;;
  esac
}
```

`validate-blue-zone.sh` reads the same config, so every pattern you add here is
automatically re-checked after staging — no second list to keep in sync.
Strings that must never appear anywhere go in `blue-zone-insecure-strings.txt`.

### Running several projects at once

The staging root is namespaced per project — `/tmp/blue-zone/<project>`, where
`<project>` defaults to the project directory's name. Because each project stages
into its own directory (and each project directory is its own `docker compose`
project), you can open a terminal per project and run sessions side by side
without them overwriting each other's staged files or sync-back snapshot. Two
checkouts that would resolve to the same name can be separated by exporting
`BLUE_ZONE_PROJECT=my-name` (or override the whole path with `BLUE_ZONE_ROOT`)
before running any script.

---

## GitLab CI

The included `.gitlab-ci.yml` runs three stages on every MR:

| Stage | Job | What it does |
|-------|-----|-------------|
| `build` | `build-claude-image` | Builds and caches the Docker image |
| `validate` | `prepare-blue-zone` | Runs rsync filter, saves blue zone as artifact |
| `validate` | `validate-blue-zone` | Scans for leaks in strict mode |
| `review` | `claude-security-review` | Runs Claude with a security audit prompt, fails on high severity |
| `review` | `claude-code-review` | Runs Claude diff review on MR changes |

Required CI/CD variable (masked + protected): `CLAUDE_CODE_OAUTH_TOKEN`
(generated with `claude setup-token` from a Claude Pro/Max subscription).

---

## Security Properties

| Property | How it's enforced |
|----------|------------------|
| Red zone files never reach Claude | `rsync` exclusions before Docker starts |
| Blue zone is verified clean | `validate-blue-zone.sh` exits 1 on any violation |
| Container can't phone home | Headless: `network_mode: none`. Interactive: attached only to an `internal` Docker network whose sole exit is an egress proxy that allowlists only Anthropic + GitHub domains — no LAN or arbitrary-internet access |
| Interactive session can't reach your LAN | `claude-cli` has no route off the `internal` network; the dual-homed `egress-proxy` denies every destination except the allowlisted public hosts in `ai-proxy/filter` (Anthropic, GitHub) |
| Repo is never written directly | Writable mounts point at the per-project `/tmp/blue-zone/<project>` staging copy; config mounts stay `:ro` |
| No root inside container | Non-root `claude` user in Dockerfile.ai-sandbox |
| Memory bounded | `deploy.resources.limits.memory: 512m` |

---

## Testing the Setup

`generate-test-project.sh` scaffolds a complete test project with realistic red
and blue zone files — and copies the `claude-docker/` tooling into it — so you
can verify the pipeline end-to-end without using your real codebase:

```bash
bash generate-test-project.sh    # scaffolds MyBluezoneTest/ + copies tooling in
cd MyBluezoneTest
./ai-scripts/prepare-blue-zone.sh   # should show red zone exclusions
./ai-scripts/validate-blue-zone.sh  # should pass all checks
```

Because the tooling is copied from `claude-docker/` on every run, the generated
project always reflects the current scripts — there is no stale duplicate to
drift out of sync.
