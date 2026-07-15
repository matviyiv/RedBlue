# Claude Code - Blue Zone Docker Setup

Isolates Claude Code to a filtered blue zone only.
Red zone files are either not mounted or stripped by rsync before mounting.

## Blue Zone Contents

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
│   └── run-headless.sh            <- Headless prompt runner
├── Dockerfile
├── docker-compose.yml
└── .gitlab-ci.yml
```

## Authentication

An API key is **optional**. Auth is resolved in this order:

| Priority | Method | How |
|----------|--------|-----|
| 1 | API key | `export ANTHROPIC_API_KEY=sk-ant-...` |
| 2 | Subscription token | `claude setup-token` on the host (Claude Pro/Max), then `export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat...` |
| 3 | Persisted login | Run `./scripts/start-cli.sh` once and log in via `/login` — credentials are stored in the `claude-config` Docker volume and reused by later runs (including headless) |

Headless runs (`run-headless.sh`, CI) need one of the three already in place;
interactive sessions can always start and log in on the spot.

To clear a persisted login: `docker volume rm <project>_claude-config`.

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
