# Project Instructions

## Git Commits

Keep commit messages concise and descriptive. No AI co-author attribution.

## Animus Workflow

This project runs on **Animus** (CLI: `animus`, formerly `ao` — both binaries exist as a backwards-compat symlink, prefer `animus`). Project state lives under `.ao/` (on-disk path was not renamed); CLI invocations use `animus`.

After ANY change to `.ao/workflows/custom.yaml`, you MUST run:

```bash
animus workflow config compile
```

The daemon compiles YAML in-memory on startup, but the runner needs the persisted compiled config on disk. Without this step, workflows fail with "no workflow found for subject".

## Animus Skills

When authoring or modifying workflows, agents, phases, or MCP integrations in this project, consult the installed Animus skills via the `Skill` tool. Most relevant for this codebase:

- `animus-workflow-authoring` — workflow/agent/phase YAML structure, schedules, cron, MCP servers
- `animus-workflow-patterns` — common multi-phase patterns (queue handoff, gating, retries)
- `animus-mcp-setup` — wiring MCP servers into agents and per-agent allowlists
- `animus-task-management` — `animus_task_*` MCP tools and task lifecycle
- `animus-queue-management` — `animus_queue_*` MCP tools and enqueue semantics
- `animus-skills` — how the per-project `.ao/skills/*.md` files are loaded by agents
- `animus-troubleshooting` — daemon, runner, and workflow failure modes

MCP tool names in the `ao` server use the `animus_` prefix (e.g. `animus_task_create`, `animus_queue_enqueue`) — these replace the older `ao.task.create` / `ao.queue.enqueue` shorthand still found in legacy phase directives.
