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
can create and edit files, but writes land in the staging copy at `/tmp/blue-zone/`,
never directly in your repo. When the session ends, `sync-back.sh` automatically
copies the changes into your repo, refusing to touch red-zone paths.

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
You copy it into your own project (or let `generate-test-project.sh` do it for
the example project). Nothing is hand-maintained in two places.

```
RedBlue/
├── claude-docker/                  # ← The tool (single source of truth)
│   ├── .claude/CLAUDE.md           # Template rules: what Claude can/cannot do
│   ├── blue-zone.config.sh         # Which folders are blue zone + exclusion rules
│   ├── blue-zone-insecure-strings.txt  # Content denylist (strings that must never leak)
│   ├── scripts/
│   │   ├── init.sh                 # One-time setup (prerequisites + Docker build)
│   │   ├── prepare-blue-zone.sh    # rsync filter → /tmp/blue-zone/
│   │   ├── validate-blue-zone.sh   # Secret leak scanner (run before Docker)
│   │   ├── start-cli.sh            # Interactive Claude session (local dev)
│   │   ├── run-headless.sh         # Single-prompt headless run (CI)
│   │   └── sync-back.sh            # Copy Claude's changes back into the repo
│   ├── proxy/                      # Egress allowlist proxy (interactive sessions)
│   │   ├── Dockerfile              #   tinyproxy on alpine
│   │   ├── tinyproxy.conf          #   default-deny forward proxy
│   │   └── filter                  #   allowlist: Anthropic + GitHub domains
│   ├── Dockerfile                  # node:22-alpine + Claude Code CLI, non-root user
│   ├── docker-compose.yml          # Network isolation, resource caps
│   └── .gitlab-ci.yml              # Full pipeline: build → validate → review
│
├── generate-test-project.sh        # Scaffold a realistic test RN project AND
│                                   #   copy the claude-docker tooling into it
│
└── MyBluezoneTest/                 # Example RN project (blue + red zone files)
    ├── .claude/CLAUDE.md           # Project-specific Claude rules
    ├── src/
    │   ├── types/                  # ← Blue zone API contracts (interfaces only)
    │   │   ├── auth.types.ts       #   IAuthApi, LoginRequest, LoginResponse
    │   │   ├── jitsi.types.ts      #   IJitsiService, JitsiRoomOptions
    │   │   ├── http.types.ts       #   ApiResponse<T>, HttpClientInstance
    │   │   └── index.ts            #   re-exports
    │   ├── api/                    # RED — stripped by prepare-blue-zone.sh
    │   ├── services/               # RED — stripped
    │   └── utils/httpClient.ts     # RED — stripped
    └── scripts/, proxy/, …         # Tooling copied in from claude-docker/
                                    #   (git-ignored — materialized, not source)
```

---

## How It Works

```
1. prepare-blue-zone.sh
   rsync src/ ios/ android/ → /tmp/blue-zone/
   with red zone exclusions              auto-generate BLUE_ZONE_MANIFEST.md

2. validate-blue-zone.sh
   scan /tmp/blue-zone/ for:
   • configured red-zone patterns that leaked (API/service, signing artifacts)
   • hardcoded secrets (regex patterns; test files excluded)
   • .env files and non-placeholder .env.example values
   • content-denylist strings
   exit 1 if any violation found

3. docker compose run claude-code
   mounts:
     /tmp/blue-zone/src     → /workspace/src     (writable)
     /tmp/blue-zone/ios     → /workspace/ios     (writable)
     /tmp/blue-zone/android → /workspace/android (writable)
     BLUE_ZONE_MANIFEST.md  → /workspace/        (read-only)
   network isolation:
     • headless (claude-code):  network_mode: none — no network at all
     • interactive (claude-cli): internal network + egress-proxy allowlist —
       can reach Anthropic (API/auth) and GitHub, but NOT your LAN
   runs: claude -p "..." --allowedTools Read,Write,Edit

4. sync-back.sh  (automatic when the session ends)
   copies Claude's changes from /tmp/blue-zone back into the repo:
     • updates only files Claude was allowed to see
     • blocks new files that collide with stripped red-zone paths
     • deletes files Claude removed (only ones that were in the blue zone)
   disable with SYNC_BACK=0; preview with ./scripts/sync-back.sh --dry-run
```

---

## Using This in Your Own Project

### 1. Copy the docker setup into your RN project root

The tooling lives in `claude-docker/` — the single source of truth. Copy it into
your project root:

```bash
cp -R claude-docker/.claude                        your-project/   # customise CLAUDE.md after
cp -R claude-docker/scripts                         your-project/
cp -R claude-docker/proxy                           your-project/   # egress allowlist proxy
cp    claude-docker/blue-zone.config.sh             your-project/   # which folders are blue zone
cp    claude-docker/blue-zone-insecure-strings.txt  your-project/   # content denylist
cp    claude-docker/Dockerfile                       your-project/
cp    claude-docker/docker-compose.yml               your-project/
```

`scripts/` reads `blue-zone.config.sh` from the project root, and that reads
`blue-zone-insecure-strings.txt` next to it — so keep all three together. When a
new version of the tooling lands in `claude-docker/`, re-run the same copy to
update; there is no per-project fork to reconcile.

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
./scripts/init.sh

# Interactive session — opens Claude Code CLI inside the container.
# Authenticate with ONE of:
export ANTHROPIC_API_KEY=sk-ant-...           # a) API key
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat...  # b) `claude setup-token` (Pro/Max)
./scripts/start-cli.sh                        # c) no key at all — log in via
                                              #    /login once; credentials persist
                                              #    in the claude-home volume

# Claude state (login, onboarding, session history) persists between runs
# in the claude-home Docker volume. Wipe it to start fresh:
./scripts/start-cli.sh --clear

# Headless prompt (CI-friendly)
./scripts/run-headless.sh "Review src/ for TypeScript errors and suggest fixes"
./scripts/run-headless.sh "Check ios/ native modules for memory leaks" --output-format json
```

### 5. Validate without running Claude

```bash
./scripts/validate-blue-zone.sh --strict
```

All checks must pass before Docker starts:

| Check | What it looks for |
|-------|------------------|
| 1 | Any configured red-zone pattern (from `blue-zone.config.sh`) that leaked into a blue-zone folder — API/service files, iOS/Android signing artifacts, etc. |
| 2 | Hardcoded secrets (regex: `password=`, `api_key=`, `sk-ant-`, AWS key patterns). Test files (`*Tests.swift`, `*.test.*`, `*.spec.*`, `__tests__/`, …) are excluded, since fixtures legitimately contain fake credentials. |
| 3 | `.env` files anywhere in the blue zone |
| 4 | `.env.example` has no real values |
| 5 | Content-denylist strings (from `blue-zone-insecure-strings.txt`) that survived into the blue zone |

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

Required CI/CD variable (masked + protected), one of: `ANTHROPIC_API_KEY`
or `CLAUDE_CODE_OAUTH_TOKEN` (generated with `claude setup-token` from a
Claude Pro/Max subscription — no API key needed).

---

## Security Properties

| Property | How it's enforced |
|----------|------------------|
| Red zone files never reach Claude | `rsync` exclusions before Docker starts |
| Blue zone is verified clean | `validate-blue-zone.sh` exits 1 on any violation |
| Container can't phone home | Headless: `network_mode: none`. Interactive: attached only to an `internal` Docker network whose sole exit is an egress proxy that allowlists only Anthropic + GitHub domains — no LAN or arbitrary-internet access |
| Interactive session can't reach your LAN | `claude-cli` has no route off the `internal` network; the dual-homed `egress-proxy` denies every destination except the allowlisted public hosts in `proxy/filter` (Anthropic, GitHub) |
| Repo is never written directly | Writable mounts point at the `/tmp/blue-zone` staging copy; config mounts stay `:ro` |
| No root inside container | Non-root `claude` user in Dockerfile |
| Memory bounded | `deploy.resources.limits.memory: 512m` |

---

## Testing the Setup

`generate-test-project.sh` scaffolds a complete test project with realistic red
and blue zone files — and copies the `claude-docker/` tooling into it — so you
can verify the pipeline end-to-end without using your real codebase:

```bash
bash generate-test-project.sh    # scaffolds MyBluezoneTest/ + copies tooling in
cd MyBluezoneTest
./scripts/prepare-blue-zone.sh   # should show red zone exclusions
./scripts/validate-blue-zone.sh  # should pass all checks
```

Because the tooling is copied from `claude-docker/` on every run, the generated
project always reflects the current scripts — there is no stale duplicate to
drift out of sync.
