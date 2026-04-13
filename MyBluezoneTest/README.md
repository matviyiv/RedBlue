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
│   ├── prepare-blue-zone.sh       <- rsync filter into /tmp/blue-zone/
│   ├── validate-blue-zone.sh      <- Secret leak scanner
│   ├── start-cli.sh               <- Interactive session (local dev)
│   └── run-headless.sh            <- Headless prompt runner
├── Dockerfile
├── docker-compose.yml
└── .gitlab-ci.yml
```

## Quick Start

```bash
# One-time setup
./scripts/init.sh

# Interactive session (local dev)
export ANTHROPIC_API_KEY=sk-ant-...
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

| Key | Masked | Protected |
|-----|--------|-----------|
| `ANTHROPIC_API_KEY` | Yes | Yes |
