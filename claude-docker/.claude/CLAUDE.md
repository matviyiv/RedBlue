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

If you need to understand how data is fetched, reference only
TypeScript interface/type definitions in `src/types/` instead.

## Code Style
- TypeScript strict mode
- Functional components + hooks only (no class components)
- ESLint + Prettier enforced
- Swift: follow Apple HIG and Swift API design guidelines
- Kotlin: follow Android Kotlin style guide
