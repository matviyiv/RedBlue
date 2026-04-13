# Claude Code - Project Context

## Scope
You are working on a **React Native application**.
Your working directory is `/workspace`.
You have access to three directories:
- `/workspace/src` - JavaScript/TypeScript app code
- `/workspace/ios` - Swift/Objective-C native iOS source
- `/workspace/android` - Kotlin/Java native Android source

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
- Write or update test files
- Reference `/workspace/.env.example` for environment variable **names only**

## What you MUST NOT do
- Read, reference, or request any `.env` file contents (values are secrets)
- Access or suggest changes to CI/CD configuration
- Reference internal IP addresses, hostnames, or API endpoints
- Ask for actual secret values - use `.env.example` as schema reference only
- Attempt to read files outside `/workspace`

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
