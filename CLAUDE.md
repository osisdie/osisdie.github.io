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
