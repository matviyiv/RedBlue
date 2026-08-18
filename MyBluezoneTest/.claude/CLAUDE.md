# Claude Code - Project Context

## Scope
You are working on a **React Native application**.
Your working directory is `/workspace`.
You have access to these directories:
- `/workspace/src` - JavaScript/TypeScript app code
- `/workspace/ios` - Swift/Objective-C native iOS source
- `/workspace/android` - Kotlin/Java native Android source
- `/workspace/__tests__` - Jest test suites

You can also read and edit the package manifests:
- `/workspace/package.json` - scripts and dependencies (writable — update libs here)
- `/workspace/yarn.lock` - resolved dependency lockfile (writable — kept in sync by yarn)

## Stack
- React Native (TypeScript)
- Redux / Redux Toolkit
- React Navigation
- Jest for testing
- Swift / Objective-C (iOS native modules)
- Kotlin / Java (Android native modules)

## What you CAN do
- Read and analyze files inside `/workspace/src`, `/workspace/ios`, `/workspace/android`
- Suggest code improvements, bug fixes, refactors across JS and native layers
- Review native module bridge code (Swift <-> RN, Kotlin <-> RN)
- Write or update test files in `/workspace/__tests__`
- Run the test suite (`yarn test`) and linter (`yarn lint`)
- Update dependencies in `package.json` and let yarn update `yarn.lock`
- Reference `/workspace/.env.example` for environment variable **names only**

## What you MUST NOT do
- Read, reference, or request any `.env` file contents (values are secrets)
- Access or suggest changes to CI/CD configuration
- Reference internal IP addresses, hostnames, or API endpoints
- Ask for actual secret values - use `.env.example` as schema reference only
- Attempt to read files outside `/workspace`
- Run `git` commands (or any VCS command) — `/workspace` is NOT a git repository

## File operations — use the file system, not git

`/workspace` is a filtered staging copy of the repo, **not a git checkout**.
There is no `.git` directory here, so git commands will fail or behave
unexpectedly. Never use `git` to inspect, stage, move, or remove files.

Use plain file system commands (or the Read/Write/Edit tools) instead:

| Goal | Use this | Not this |
|------|----------|----------|
| Delete a file | `rm path/to/file.ts` | `git rm ...` |
| Rename / move a file | `mv old.ts new.ts` | `git mv ...` |
| Create a directory | `mkdir -p dir/` | — |
| See what changed | Re-read the files | `git status` / `git diff` |

When you delete a file with `rm`, that deletion is carried back into the real
repository by `sync-back.sh` after the session ends — so deleting is a real,
propagated action. Deleting a file you were only meant to edit will remove it
from the repo, so delete deliberately.

## The workspace can change under you — and may contain conflict markers

You are not the only one working on this project. The developer keeps editing
the real repository while you work here, and can pull their changes into your
workspace mid-session. So a file you read ten minutes ago may have new content
now — re-read before you rely on it.

Those refreshes are merged, not overwritten: your edits are kept. But when you
and the developer changed **the same lines** of the same file, the merge cannot
decide, and the file is left with standard conflict markers:

```
<<<<<<< HEAD
const timeout = 5000;      // ← YOUR version, what you wrote in this workspace
=======
const timeout = 30000;     // ← THEIR version, from the developer's repo
>>>>>>> blue-base
```

`HEAD` is always your side. `blue-base` is always the developer's side.

**Resolve them by editing the file**: pick one side, or combine them into
something that satisfies both intents, then delete all three marker lines. Do
not run `git` — there is no git here, and the tooling that carries your work
back does not need it.

Until the markers are gone the file is stuck: `sync-back.sh` refuses to copy a
file containing conflict markers into the real repository, so leaving them in
place means that file's changes — yours included — never land. If you are unsure
which side should win, say so in your response rather than guessing silently;
the developer can decide.

## Intentionally excluded files (do NOT ask for these)
The following are red zone and do not exist in your workspace:

**src/ exclusions** (API/endpoint files):
- `*-api.ts`, `*-api.js` - API client files
- `*Api.ts`, `*Api.js` - API class files
- `*Service.ts`, `*Service.js` - service layer files
- `*Client.ts`, `*Client.js` - HTTP client files
- `api/`, `services/` directories
- `*.graphql`, `*.gql` files

**ios/ exclusions** (signing & build artifacts):
- `*.p12`, `*.cer`, `*.mobileprovision` - signing certs
- `GoogleService-Info.plist` - Firebase config
- `*.xcconfig` - build config with secrets
- `Pods/`, `build/`, `DerivedData/` - build artifacts

**android/ exclusions** (signing & build artifacts):
- `*.jks`, `*.keystore` - signing keystores
- `google-services.json` - Firebase config
- `*.properties` files (keystore.properties, signing.properties)
- `build/`, `.gradle/` - build artifacts

## API / Service Layer Contracts

The API, service, and HTTP client implementation files are red zone and do not
exist in your workspace. Their TypeScript interfaces are in `src/types/` — use
these to write correct code without guessing at endpoint shapes or function signatures.

### Available type files

**`src/types/auth.types.ts`** — Authentication layer
- Interfaces: `LoginRequest`, `LoginResponse`, `AuthError`, `AuthSession`
- Contract: `IAuthApi` with `login()`, `logout()`, `refreshSession()`
- Import: `import type { LoginRequest, IAuthApi } from '../types/auth.types';`

**`src/types/jitsi.types.ts`** — Video conferencing service
- Interfaces: `JitsiRoomOptions`, `JitsiParticipant`, `JitsiRoomState`
- Contract: `IJitsiService` with `joinRoom()`, `leaveRoom()`, `toggleAudio()`, `toggleVideo()`
- Import: `import type { JitsiRoomOptions, IJitsiService } from '../types/jitsi.types';`

**`src/types/http.types.ts`** — HTTP client layer
- Generic envelopes: `ApiResponse<T>`, `PaginatedResponse<T>`, `ApiErrorResponse`
- Contract: `HttpClientInstance` describing the pre-configured client API
- Import: `import type { ApiResponse, ApiErrorResponse } from '../types/http.types';`

**`src/types/index.ts`** — re-exports all of the above for convenience.

### Rules for working with the API layer

- DO use the interfaces in `src/types/` to type props, state, hooks, and test fixtures
- DO write Jest tests that mock `IAuthApi`, `IJitsiService` using the shapes in `src/types/`
- DO NOT invent endpoint paths — they are red zone and not accessible here
- DO NOT import from `../api/`, `../services/`, or `../utils/httpClient` — those files do not exist in your workspace
- When wiring a component to the API, accept the service as a prop typed against the interface (dependency injection), rather than importing the concrete module

### BLUE_ZONE_MANIFEST.md

`/workspace/BLUE_ZONE_MANIFEST.md` lists every file that was stripped from `src/`
before this workspace was mounted. Read it to see what exists on the host but is
not visible here. Do not edit it — it is auto-generated on each run.

## Code Style
- TypeScript strict mode
- Functional components + hooks only (no class components)
- ESLint + Prettier enforced
- Swift: follow Apple HIG and Swift API design guidelines
- Kotlin: follow Android Kotlin style guide
