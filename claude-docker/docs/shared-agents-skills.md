# Shared agents and skills — `.claude-blue-zone/`

How a team ships Claude Code agents and skills to every blue-zone session, as
ordinary committed source. Driven by `BLUE_ZONE_CLAUDE_DIR` and
`BLUE_ZONE_CLAUDE_SUBDIRS` in [`blue-zone.config.sh`](../blue-zone.config.sh).

---

## The problem

Agents and skills are the difference between a session that knows how your team
works and one that guesses. But the obvious place to keep them — the project's
own `.claude/` directory — is the wrong place here, for two reasons:

1. **The tooling promises never to touch it.** `.claude/` is the developer's
   own Claude Code config, for sessions on the real, unfiltered repository. A
   sandbox that mounted it would be reaching into something it does not own.
2. **Not everything there belongs in a sandbox.** It may reference red-zone
   paths, internal hosts, or local machine layout — none of which a filtered
   session should see.

So the shared set is a separate, deliberate folder: `.claude-blue-zone/`. It is
committed, reviewed in merge requests, and evolves like any other source. A
developer who improves the review agent improves it for everyone's next session.

---

## How it is mounted

```
your-repo/.claude-blue-zone/agents/  ──ro──>  /workspace/.claude/agents
your-repo/.claude-blue-zone/skills/  ──ro──>  /workspace/.claude/skills
```

Those are the paths Claude Code searches, so anything valid in the folder is
picked up when the session starts — no registration step, no flag to pass. The
mounts are generated into `docker-compose.blue-zone.yml` alongside the
blue-zone folder mounts, for both the interactive and headless services.

Add `commands/` or `output-styles/` to `BLUE_ZONE_CLAUDE_SUBDIRS` if your team
shares those too; a subdirectory that doesn't exist is skipped, so listing one
early is harmless.

### Straight from the repo, not staged

Every other mount goes through `prepare-blue-zone.sh`, which filters it. This
one does not: it is tooling input, not code under review, and filtering an
agent definition would just quietly break it.

That is a deliberate exception, and it has a cost — **whatever is committed here
reaches the container verbatim**, making it the one place a secret could ride in
unnoticed. So `validate-blue-zone.sh` check 8 scans the whole folder with the
same secret patterns and content denylist used everywhere else, across every
file type (agents and skills are Markdown, which the main secret scan skips),
and the session refuses to start on a hit. The `fine-for-claude` allow marker
works here exactly as it does elsewhere.

### Read-only, on purpose

A session cannot edit the agents that review it, or add one for itself. Changes
happen in the repository, through review, like any other change to how the team
works.

`settings.json` is not mountable through this mechanism at all. A committed
settings file could widen tool permissions inside the sandbox, and that decision
belongs to whoever starts the session, not to the repository. If one is found in
the folder, validation warns rather than letting anyone believe it took effect.

---

## The shipped agent: `change-reviewer`

A read-only reviewer that runs when a task is finished, before the session
reports it done. It has `Read`, `Grep` and `Glob` — no edit tools — so it
reports findings and the main session decides what to fix.

That restriction is the point. A reviewer with edit rights is exactly how a
targeted change turns into a widespread one: it "just fixes" what it finds, and
the diff it was meant to be narrowing grows instead.

It checks four things, in this order of weight:

| | What it looks for |
|---|---|
| **Scope** | Files touched that the task never implied; drive-by refactors, renames and reformatting; unrelated bugs fixed in passing; abstractions built for one call site. Also the opposite — the task left half-done. |
| **Correctness** | Logic that doesn't match the task, unhandled errors, null paths, leaks, debug leftovers, hardcoded values. |
| **Consistency** | Reuse of existing helpers and types rather than reinvention; naming, structure, error handling and logging matching the surrounding code. |
| **Test coverage** | A test that would fail without the change; assertions on outcomes; edge cases; and loudly, any existing test weakened, skipped or deleted to make something pass. |

It also knows this workspace's shape: absent red-zone files are not findings
(it reads `BLUE_ZONE_MANIFEST.md` first), there is no git, and `src/types/`
contracts without implementations are the design. Two things specific to the
setup *are* findings — unresolved conflict markers, and new files colliding with
stripped red-zone paths, both of which would silently fail on the way back out.

### How it gets triggered

Two mechanisms, deliberately belt-and-braces:

1. Its `description` marks it for proactive use after completing a task, which
   is how Claude Code decides to delegate.
2. `ai-scripts/CLAUDE.md` makes it an explicit rule: invoke `change-reviewer`
   before reporting a task done, and act on the findings — with the specific
   instruction that a scope finding is usually answered by reverting that part,
   not justifying it.

### What you must pass it

The reviewer cannot discover the change set itself. `/workspace` is a filtered
copy with no git history, so `git diff` does not exist and the host-side shadow
repository is not mounted. The invoking session must give it:

1. one line on what the task actually was, and
2. the list of files created, modified, or deleted.

The agent is instructed to ask for both and review nothing without them —
reviewing files it merely suspects were touched produces confident nonsense.

---

## Adding your own

Agents are Markdown with YAML frontmatter in `agents/`:

```markdown
---
name: my-agent
description: What it does and when Claude should reach for it — this text is
  how Claude decides to invoke it, so be specific.
tools: Read, Grep, Glob
model: inherit
---

Instructions, in the second person.
```

Keep `tools` as narrow as the job allows; an agent that only reads should not be
able to write.

Skills are directories containing `SKILL.md`:

```
skills/my-skill/SKILL.md
```

Supporting files live alongside `SKILL.md` and are referenced from it.

---

## Deploying updates

`deploy-blue-zone.sh` copies the folder into a project **file by file, and only
when a file is absent**. An agent someone tuned for their project survives a
tooling update; a new agent added upstream still arrives. Nothing here is ever
overwritten, and the summary says how many files were added and how many were
left alone.
