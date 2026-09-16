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

If you need to understand how data is fetched, reference only
TypeScript interface/type definitions in `src/types/` instead.

## Blue zone manifest (`/workspace/BLUE_ZONE_MANIFEST.md`)

An auto-generated, read-only inventory lives at `/workspace/BLUE_ZONE_MANIFEST.md`.
It lists every file that was **stripped** from the project before this workspace
was mounted — the files that exist on the host but are deliberately absent here
(red zone) — plus the rules that removed them.

Treat it as authoritative:
- Use it to learn the true shape of the project: know that these files exist so
  you code against their contracts and do not recreate them.
- If a file appears there, it is red zone — do **not** ask for its contents.
- It is regenerated on every run and mounted read-only, so do not edit it.

## Browser automation (Playwright MCP) — only if it is available

Some sessions are started with a browser attached, exposed as `playwright`
MCP tools. If you do not see those tools, this section does not apply.

The browser is **not** general internet access. It can reach a short,
explicitly configured list of origins and nothing else — every other
destination, including the developer's machine and LAN, is refused by a proxy
before a connection is made. Requests that fail are usually policy, not bugs:
say which origin you needed and why, and let the developer decide whether to
add it. Never try to route around a refusal.

The blue zone exists so this workspace's contents stay here. A browser is the
one tool in the session that can carry them out, so:

- Do not put workspace content — file contents, paths, code snippets, values
  you read here — into a URL, query string, form field, or request body.
- Do not use the browser to "share", upload, paste, or publish anything from
  `/workspace`, however convenient it looks.
- Use it for what it is for: loading the app or docs, inspecting rendered
  pages, reproducing UI behaviour, and reading back what you see.

Each browser action asks the developer for permission unless they pre-approved
specific tools. Expect to be interrupted, and batch your intent into clear
steps rather than many small navigations.

## Finish every task with a review

Your team keeps shared agents and skills in `/workspace/.claude/` (mounted
read-only from the repository — you cannot change them, and you do not need
to). One of them is the `change-reviewer` agent.

**When you believe a task is finished, invoke `change-reviewer` before you tell
the developer you are done.** Give it two things:

1. one line on what the task actually was, and
2. the list of files you created, modified, or deleted.

It has no way to work those out for itself — this workspace is a filtered copy
with no git history — so a review without them is worthless.

Then act on what comes back:

- **blocking** findings: fix them, then say what you changed.
- **important** findings: fix them, or say plainly why you are not.
- **minor** findings: fix if cheap, otherwise mention them and move on.
- **scope** findings: take these seriously. If the reviewer says you changed
  something the task did not ask for, the right answer is almost always to
  revert that part, not to justify it. A change that does one thing gets
  reviewed and merged; a change that fixes everything sits.

Report the review's verdict to the developer along with your summary. If you
disagree with a finding, say so and explain — do not quietly skip it.

## Code Style
- TypeScript strict mode
- Functional components + hooks only (no class components)
- ESLint + Prettier enforced
- Swift: follow Apple HIG and Swift API design guidelines
- Kotlin: follow Android Kotlin style guide
