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
that mounts the staging directory **read-only** with `network_mode: none`.

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

```
RedBlue/
├── generate-test-project.sh        # Scaffold a realistic test RN project
│
└── MyBluezoneTest/                 # Example project with the full setup
    ├── .claude/
    │   └── CLAUDE.md               # Claude's rules: what it can/cannot do
    ├── scripts/
    │   ├── init.sh                 # One-time setup (prerequisites + Docker build)
    │   ├── prepare-blue-zone.sh    # rsync filter → /tmp/blue-zone/
    │   ├── validate-blue-zone.sh   # Secret leak scanner (run before Docker)
    │   ├── start-cli.sh            # Interactive Claude session (local dev)
    │   └── run-headless.sh         # Single-prompt headless run (CI)
    ├── src/
    │   ├── types/                  # ← Blue zone API contracts (interfaces only)
    │   │   ├── auth.types.ts       #   IAuthApi, LoginRequest, LoginResponse
    │   │   ├── jitsi.types.ts      #   IJitsiService, JitsiRoomOptions
    │   │   ├── http.types.ts       #   ApiResponse<T>, HttpClientInstance
    │   │   └── index.ts            #   re-exports
    │   ├── api/                    # RED — stripped by prepare-blue-zone.sh
    │   ├── services/               # RED — stripped
    │   └── utils/httpClient.ts     # RED — stripped
    ├── Dockerfile                  # node:22-alpine + Claude Code CLI, non-root user
    ├── docker-compose.yml          # Blue zone mounts, network_mode: none, 512 MB cap
    └── .gitlab-ci.yml              # Full pipeline: build → validate → review
```

---

## How It Works

```
1. prepare-blue-zone.sh
   rsync src/ ios/ android/ → /tmp/blue-zone/
   with red zone exclusions              auto-generate BLUE_ZONE_MANIFEST.md

2. validate-blue-zone.sh
   scan /tmp/blue-zone/ for:
   • API/service/client file leaks
   • iOS/Android signing artifacts
   • Hardcoded secrets (regex patterns)
   • .env files
   exit 1 if any violation found

3. docker compose run claude-code
   mounts:
     /tmp/blue-zone/src     → /workspace/src     (read-only)
     /tmp/blue-zone/ios     → /workspace/ios     (read-only)
     /tmp/blue-zone/android → /workspace/android (read-only)
     BLUE_ZONE_MANIFEST.md  → /workspace/        (read-only)
   network_mode: none  ← no outbound calls from inside the container
   runs: claude -p "..." --allowedTools Read
```

---

## Using This in Your Own Project

### 1. Copy the docker setup into your RN project root

```bash
cp -r MyBluezoneTest/.claude       your-project/
cp -r MyBluezoneTest/scripts/      your-project/
cp    MyBluezoneTest/Dockerfile    your-project/
cp    MyBluezoneTest/docker-compose.yml your-project/
```

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

# Interactive session — opens Claude Code CLI inside the container
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/start-cli.sh

# Headless prompt (CI-friendly)
./scripts/run-headless.sh "Review src/ for TypeScript errors and suggest fixes"
./scripts/run-headless.sh "Check ios/ native modules for memory leaks" --output-format json
```

### 5. Validate without running Claude

```bash
./scripts/validate-blue-zone.sh --strict
```

All 6 checks must pass before Docker starts:

| Check | What it looks for |
|-------|------------------|
| 1 | API / service / client files in `src/` |
| 2 | iOS signing artifacts (`.p12`, `.mobileprovision`, `GoogleService-Info.plist`) |
| 3 | Android signing artifacts (`.jks`, `google-services.json`, `keystore.properties`) |
| 4 | Hardcoded secrets (regex: `password=`, `api_key=`, `sk-ant-`, AWS key patterns) |
| 5 | `.env` files anywhere in the blue zone |
| 6 | `.env.example` has no real values |

---

## Customising the Red Zone

Edit the `sync_zone` calls in `scripts/prepare-blue-zone.sh` to match your
project's naming conventions:

```bash
# Add exclusions for your own patterns
sync_zone "./src" "$BLUE_ZONE_ROOT/src" "src" \
  --exclude="*-api.ts"      \   # auth-api.ts, payments-api.ts …
  --exclude="*Api.ts"       \   # AuthApi.ts, PaymentsApi.ts …
  --exclude="*Service.ts"   \   # UserService.ts, JitsiService.ts …
  --exclude="*Client.ts"    \   # HttpClient.ts, GraphQLClient.ts …
  --exclude="api/"          \   # entire api/ directory
  --exclude="services/"     \   # entire services/ directory
  --exclude="*.graphql"         # GraphQL query files
```

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

Required CI/CD variable: `ANTHROPIC_API_KEY` (masked + protected).

---

## Security Properties

| Property | How it's enforced |
|----------|------------------|
| Red zone files never reach Claude | `rsync` exclusions before Docker starts |
| Blue zone is verified clean | `validate-blue-zone.sh` exits 1 on any violation |
| Container can't phone home | `network_mode: none` in docker-compose |
| Filesystem is read-only | All volume mounts use `:ro` |
| No root inside container | Non-root `claude` user in Dockerfile |
| Memory bounded | `deploy.resources.limits.memory: 512m` |

---

## Testing the Setup

`generate-test-project.sh` scaffolds a complete test project with realistic red
and blue zone files so you can verify the pipeline end-to-end without using your
real codebase:

```bash
bash generate-test-project.sh
cd MyBluezoneTest
./scripts/prepare-blue-zone.sh   # should show red zone exclusions
./scripts/validate-blue-zone.sh  # should pass all 6 checks
```
