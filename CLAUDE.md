# Project Instructions

## Task Management

Persistent task files in `.claude/tasks/` survive context compression. Use the `task-planner` agent for all task CRUD operations.

### Auto-management rules

1. At the **start of each user prompt**, delegate to the `task-planner` agent (in background) with `list` to check for pending/in-progress tasks. If tasks exist, briefly mention them before proceeding.
2. If the user's request implies **new work** (feature, bug fix, multi-step task), delegate to `task-planner` agent with `create` before starting.
3. As you **complete work**, delegate to `task-planner` agent with `done {ID}` to mark tasks complete.
4. If new TODOs **emerge during work** (discovered issues, follow-ups, deferred items), delegate to `task-planner` agent with `create` to capture them immediately.
5. At **natural milestones** (before commit, before PR, end of a major task), report task status to the user.
6. When done tasks accumulate (5+), delegate to `task-planner` agent with `archive` to clean up.

### Task file schema

- Location: `.claude/tasks/{NNN}-{slug}.md`
- Frontmatter: `id`, `title`, `status` (pending/in_progress/done/cancelled), `priority` (high/medium/low), `created_at`, `updated_at`
- Body: description, acceptance criteria, notes
- Files are gitignored (`.claude/*` rule) — they are per-developer session state

### When NOT to create tasks

- Trivial one-shot requests (single file edit, quick question)
- Tasks that will be completed within the current response
- Only create tasks for work that spans multiple steps or might be interrupted by context compression

### Capturing implicit TODOs

Even in trivial one-shot requests, **scan for forward-looking language** ("等等", "之後", "later", "btw", "下次", "TODO", "remember to"). If the user mentions future work — even casually — create a `pending` task for it immediately. The cost of a spurious task file is near zero; the cost of forgetting is high.

### Stale task review

When the `task-planner` agent reports **3+ pending tasks**, or any task has been `pending` for **3+ days**, proactively ask the user:

> "You have N pending tasks. Want to review them?"

Then for each stale/pending task, ask:
- **Continue** — keep as pending or start working on it
- **Cancel** — mark as cancelled and archive
- **Defer** — keep but lower priority

This prevents unbounded task accumulation and keeps the list actionable.

## Blog Post Conventions

### Tags

When creating or updating a blog post, always include comprehensive `tags:` in frontmatter (aim for 5-8 tags). The blog page auto-generates a tag list with counts from `site.tags` — no manual config update is needed.

- **Reuse existing tags** — check with: `grep -h '^tags:' _posts/**/*.md`
- **Avoid synonyms** — use the established form (e.g. `automation` not `automated`)
- **Cover key topics** — tools, frameworks, patterns, and domains mentioned in the post
