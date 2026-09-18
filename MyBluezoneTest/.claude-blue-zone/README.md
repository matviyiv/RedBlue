# `.claude-blue-zone/` — agents and skills your team shares

Claude Code agents and skills that every blue-zone session should have. This is
ordinary repository content: commit it, review it in merge requests, and evolve
it like any other source. A developer who improves the review agent improves it
for everyone on the next session.

```
.claude-blue-zone/
├── agents/     -> mounted read-only at /workspace/.claude/agents
└── skills/     -> mounted read-only at /workspace/.claude/skills
```

Those are the paths Claude Code looks in, so anything valid here is picked up
automatically when the session starts. The mounts are generated from
`BLUE_ZONE_CLAUDE_DIR` and `BLUE_ZONE_CLAUDE_SUBDIRS` in
[`blue-zone.config.sh`](../blue-zone.config.sh) — add `commands/` or
`output-styles/` to that list if your team shares those too.

## This is not your project's `.claude/`

The blue-zone tooling never touches the `.claude/` directory your repository
already has — that stays yours, for sessions on your own machine with the whole
codebase in view. This folder is the separate, deliberate set of things you are
willing to hand to a *sandboxed* session that can only see filtered code.

## Two rules the tooling enforces

**Read-only in the container.** A session cannot edit the agents that review
it, or add one for itself. Changes happen here, in the repo, through review.

**Scanned before it is mounted.** Unlike the blue-zone folders, nothing here is
filtered on the way in — what you commit reaches the container verbatim. That
makes this the one place a secret could ride in unnoticed, so
`validate-blue-zone.sh` check 8 scans every file with the same secret patterns
and content denylist used everywhere else, and refuses to start on a hit.

`settings.json` is deliberately not mountable. A committed settings file could
widen tool permissions inside the sandbox, and that decision belongs to whoever
starts the session, not to the repository.

## What ships here

| Agent | When it runs |
|---|---|
| [`change-reviewer`](agents/change-reviewer.md) | When a task is finished, before the session reports it done. Reviews correctness, consistency, test coverage, and that the change stayed targeted. Read-only — it reports, the session fixes. |

`ai-scripts/CLAUDE.md` tells Claude to invoke it as the last step of any task,
and its `description` marks it for proactive use, so it runs without anyone
remembering to ask.

## Adding an agent

Drop a Markdown file in `agents/` with YAML frontmatter:

```markdown
---
name: my-agent
description: What it does, and when Claude should reach for it. Be specific —
  this text is how Claude decides to invoke it.
tools: Read, Grep, Glob
model: inherit
---

The agent's instructions, in the second person.
```

Keep `tools` as narrow as the job allows. An agent that only needs to read
should not be able to write.

## Adding a skill

Each skill is a directory containing `SKILL.md`:

```
skills/
└── my-skill/
    └── SKILL.md
```

```markdown
---
name: my-skill
description: When this skill applies. Claude reads only this line until it
  decides the skill is relevant, so make it precise.
---

The instructions, loaded when the skill triggers.
```

Supporting files can live alongside `SKILL.md` and be referenced from it.
