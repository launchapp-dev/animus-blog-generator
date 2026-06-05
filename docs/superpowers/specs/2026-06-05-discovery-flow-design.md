# Discovery Flow — Design Spec

**Date:** 2026-06-05 (revised after reviewer P0/P1 findings; v0.5.4)
**Branch:** `feature/discovery-flow`
**Author:** Rafal + Claude

## Summary

Extend the existing blog generator with an upstream **idea-discovery → human-review → approved-ticket → blog-production** pipeline. New workflows poll an audio-transcript MCP (Krisp; portable to Granola), synthesize blog ideas grounded in business context and external SEO research, file them as **Linear-backed Animus subjects** in a dedicated Linear project for human review, then detect approval and hand off to a variant of the existing blog pipeline.

**Canonical workflow path (v0.5.4):** All YAML changes target **`.animus/workflows/custom.yaml`**, not `.ao/workflows/custom.yaml`. The latter is dormant — `animus workflow config get` resolves to `.animus/workflows/` and `animus workflow list` does not surface anything from `.ao/workflows/`. A migration step relocates the existing blog pipeline before any discovery-flow additions land.

**Linear integration:** via the `animus-subject-linear` plugin (v0.1.4+, requires Animus v0.4.0+; we are on v0.5.4). Linear is **not** treated as a generic MCP server. Linear issues are first-class Animus subjects of kind `linear`.

**Approval semantics:** the plugin auto-maps Linear's `WorkflowState.type` (stable, name-rename-proof) to Animus's normalized subject statuses. All status values used throughout this spec are **lowercase snake_case** matching the CLI / subject API: `ready`, `in_progress`, `blocked`, `done`, `cancelled`. The human-review gate is therefore: subjects are created at `status = ready` (Linear state-type `backlog`); a human moves the issue to any Linear state with `type = started` → plugin reports `status = in_progress` → approval-watcher enqueues. Linear states of type `cancelled` (Canceled, Won't-do, Duplicate) map to `cancelled` and are explicitly filtered out.

## Goals

1. **Transcript-grounded discovery** — blog ideas come from real conversations recorded in Krisp.
2. **Pre-validated proposals** — every Linear-backed subject carries Search Console viability data, competitive landscape, and pre-identified citable sources, so human review is meaningful.
3. **Closed-loop Linear status** — the Linear board is the visible system-of-record for blog state; transitions are observed via the subject backend, not custom polling code.
4. **Local content manifest** — `content/manifest.json` records every published post; consumed by the strategist for local dedup and by the writer / SEO agents for real internal-link selection.
5. **Reuse existing pipeline** — research, write, SEO, asset, social, push phases are reused unchanged; only a new `ticket-to-brief` phase replaces today's `topic-research`.

## Non-goals

- Replacing or rewriting the existing `blog-production`, `refresh-cycle`, `image-refresh`, or `news-monitor` workflows beyond the migration and the `register-post` insertion.
- Building a custom webhook receiver. Status detection is implemented as a polling workflow on a 15-minute cron (the subject plugin's roadmap includes webhooks; until shipped, we poll).
- Auto-merging the generated branch into `main`. Merge is a human action in Linear / GitHub.
- Implementing the `content-library` MCP server itself.
- Granular Linear-state-name transitions from `linear-finalize` — the subject API exposes only the 5 normalized statuses. Default leaves the issue at `in_progress` after finalize; opt-in via `LINEAR_FINALIZE_TRANSITION=done` to auto-complete.

## Architecture overview

Three new workflows, two shared state files, one new manifest:

```
┌─────────────────────┐   cron: 0 7 * * *   (daily 7am)
│  idea-discovery     │
│                     │   phase 1: transcript-fetch
│                     │   phase 2: idea-strategist (creates Linear-backed subjects)
└─────────────────────┘

         ↓ (human reviews Linear backlog, moves chosen issues to a "started" state)

┌─────────────────────┐   cron: */15 * * * *   (every 15 min)
│  approval-watch     │
│                     │   phase 1: approval-watcher
│                     │     - lists subjects of kind=linear, status=in_progress,
│                     │       scoped to LINEAR_DISCOVERY_PROJECT_ID
│                     │     - excludes cancelled / done / blocked / ready
│                     │     - enqueues blog-from-ticket via animus queue enqueue
│                     │       with a wrapper task carrying linear_subject_id
└─────────────────────┘

         ↓ (queue handoff: task subject with linear_subject_id in metadata)

┌─────────────────────┐
│  blog-from-ticket   │   triggered per approved subject
│                     │
│   1. ticket-acknowledge   ← linear-coordinator: post "started" comment;
│                             re-check status == in_progress, abort if not
│   2. ticket-to-brief      ← content-strategist: re-fetch subject body;
│                             re-check status guard; derive topic_brief
│   3. research-collection  ← content-researcher (reused)
│   4. content-writing      ← content-writer (extended: content-library)
│   5. commit-draft         ← command (reused)
│   6. seo-review           ← seo-optimizer (extended: content-library)
│   7. asset-generation     ← asset-generator (reused)
│   8. social-excerpts      ← asset-generator (reused)
│   9. register-post        ← agent: append content/manifest.json (post is
│                                    written + committed; manifest update
│                                    will ship with the next push)
│  10. push-branch          ← command (reused, single push covers all commits
│                             including the manifest entry)
│  11. linear-finalize      ← linear-coordinator: rich completion comment;
│                                                  status transition opt-in
└─────────────────────┘

Shared state (.ao/state/ — kept under .ao because it's project-local runtime
state, not a workflow definition; gitignored entirely, no .gitkeep):
  discovery-cursor.json    last *processed* transcript (advanced by
                           idea-strategist, NOT by transcript-fetch)
  approval-seen.json       Linear subject IDs already enqueued
  transcripts/<id>.json    fetched transcript staging files

Tracked in repo:
  content/manifest.json    canonical list of all generated posts (committed
                           at the register-post step BEFORE push-branch so
                           the single push covers it)
```

`blog-production` is retrofitted with `register-post` inserted between `social-excerpts` and `push-branch`. No other change to existing workflows.

## Subject backend (Linear)

**Plugin:** `launchapp-dev/animus-subject-linear` v0.1.4+, installed via `animus plugin install launchapp-dev/animus-subject-linear`.

**Status mapping (auto, no team-side configuration required):**

| Linear `WorkflowState.type` | Animus subject status (snake_case) | Meaning in this workflow |
|---|---|---|
| `triage`, `backlog`, `unstarted` | `ready` | initial state — created by strategist, awaiting human review |
| `started` | `in_progress` | **approval signal** — human picked this idea |
| `completed` | `done` | published / merged (optional terminal transition) |
| `cancelled` | `cancelled` | rejected; never treated as approval |

`LINEAR_STATUS_MAP` env override is available if the team's Linear states need non-default mapping.

**Workflow YAML declaration (verified shape — list, not mapping):**

```yaml
subjects:
  - id: linear-discovery
    backend: linear
    config:
      team_id: ${LINEAR_TEAM_ID:?set LINEAR_TEAM_ID}
      project_id: ${LINEAR_DISCOVERY_PROJECT_ID:?set LINEAR_DISCOVERY_PROJECT_ID}
```

- `id: linear-discovery` is the **local subject id** for this workspace — referenced by workflows.
- `backend: linear` is the plugin-claimed kind — referenced in `animus subject` CLI calls as `--kind linear`.
- The `${VAR:?msg}` interpolation makes the daemon refuse to start without the required vars set.

**Wire IDs.** Subject CLI calls use the form `animus subject create --kind linear --title "..." --description "..."` (with backend-specific options derived from config). The plugin emits IDs like Linear's `BLG-105`. Watcher queries filter via `--kind linear --status in_progress`. **Preflight resolves the exact subject CLI / MCP-tool / plugin-call invocation path** — directives substitute the verified form before commit.

## MCP servers (non-Linear)

Linear is a subject backend, not an MCP server. Two new MCP servers are added to `mcp_servers:` in `.animus/workflows/custom.yaml`.

| Server | Purpose | Used by |
|---|---|---|
| `krisp` | Pull recent meeting transcripts | `transcript-collector` only |
| `content-library` | Search org content + artifact database | `idea-strategist`, `content-strategist` (ticket-to-brief), `content-writer`, `seo-optimizer` |

## New agents

### `transcript-collector` (new)

- **Model:** `claude-haiku-4-5`
- **mcp_servers:** `krisp`
- **System prompt:** prescriptive; no synthesis
- **Per-run directive:** read `.ao/state/discovery-cursor.json` for cutoff; mkdir `.ao/state/transcripts/`; list Krisp transcripts created strictly after `cursor.last_processed_at`; write each as `.ao/state/transcripts/<transcript_id>.json`. **Does NOT update the cursor.** Emit phase result with file paths.
- **Output contract:** `phase_result` with required field `transcript_paths: array<string>`

### `idea-strategist` (new)

- **Model:** `claude-sonnet-4-6`
- **mcp_servers:** `ao`, `content-library`, `search-console`, `exa`, `tavily`, `brave`, `firecrawl`
- **System prompt:** mandatory `business-context.yaml`; refuses without `LINEAR_DISCOVERY_PROJECT_ID`
- **Per-run directive:** for each transcript: extract 3–5 angles → external-validate (Search Console + Exa/Tavily/Brave + Firecrawl spot-scrape) → filter dupes (manifest + content-library) → for each surviving angle: check for existing subject with matching idempotency key, else `animus subject create --kind linear --title "..." --description "<structured body with idempotency key>"`. **After all surviving angles for a transcript are created-or-confirmed-duplicate, advance `.ao/state/discovery-cursor.json` per-transcript.**

### `approval-watcher` (new)

- **Model:** `claude-haiku-4-5`
- **mcp_servers:** `ao`
- **Per-run directive:**
  1. Read `.ao/state/approval-seen.json`.
  2. `animus subject list --kind linear --status in_progress` (scoped to `LINEAR_DISCOVERY_PROJECT_ID` via the backend's project filter).
  3. Subtract seen set. Note: `cancelled`, `done`, `blocked`, `ready` are not even queried.
  4. **Queue handoff (verified contract):** for each newly-approved subject, the queue dispatches Animus tasks (or requirements, or custom-title subjects) — not Linear-backed subjects directly. Two viable shapes (preflight picks one):
     - **Shape A (task wrapper):** `animus task create --title "<title>" --description "<linear_subject_id stored in description>" ` → capture `task_id` → `animus queue enqueue --task-id <task_id> --workflow-ref blog-from-ticket --input-json '{"linear_subject_id": "<id>"}'`
     - **Shape B (ad-hoc):** `animus queue enqueue --title "<title>" --description "<linear_subject_id>" --workflow-ref blog-from-ticket --input-json '{"linear_subject_id": "<id>"}'`
     Preflight verifies which propagates `--input-json` through to the dispatched workflow's first phase.
  5. Append IDs to `.ao/state/approval-seen.json` atomically.
  6. If nothing new, emit `skip`.

### `linear-coordinator` (new, two phases)

- **Model:** `claude-haiku-4-5`
- **mcp_servers:** `ao`
- **`ticket-acknowledge` (first phase of `blog-from-ticket`):** receives `linear_subject_id` from `input_json`. **Re-check status guard:** `animus subject get --kind linear --id <linear_subject_id>` and abort with a clean failure if status is not `in_progress` (handles the race where a human cancels post-approval but before run starts). On `in_progress`: post a Linear comment with run ID + branch. Does NOT transition status (human already did that).
- **`linear-finalize` (last phase):** posts rich completion comment with branch, slug, word count, image embed. Transitions status only if `LINEAR_FINALIZE_TRANSITION=done`; otherwise leaves status alone.

## Extended (existing) agents

### `content-strategist`

- **Add to `mcp_servers`:** `content-library` (Linear access via subject API on `ao`, not a separate MCP)
- **New use:** runs `ticket-to-brief`. Receives `linear_subject_id` from workflow input. **Re-fetches the subject** (gets latest title/body/comments/status) and **re-checks status guard** — abort if no longer `in_progress`. Parses pre-identified sources from body. Refines target keyword via Search Console. Emits the same `topic_brief` contract today's `topic-research` produces, augmented with `slug_hint` (a slugified version of the title) for downstream phases.

### `content-writer`

- **Add to `mcp_servers`:** `content-library`
- **Behavior change:** queries `content-library` and `content/manifest.json` for real internal-link candidates.
- **Output contract addition:** must emit `slug` (already does — preserved verbatim).

### `seo-optimizer`

- **Add to `mcp_servers`:** `content-library`
- **Output contract addition:** must thread `slug` through (read from prior phase's output and pass through alongside `commit_message`). This makes `slug` reliably available to the downstream `register-post` and `linear-finalize` phases without phase-skipping reads.

## New phases

| Phase | Mode | Agent | Notes |
|---|---|---|---|
| `transcript-fetch` | agent | transcript-collector | does NOT advance cursor |
| `idea-strategist` | agent | idea-strategist | advances cursor per-transcript |
| `approval-watcher` | agent | approval-watcher | enqueues via verified queue path |
| `ticket-acknowledge` | agent | linear-coordinator | status re-check guard |
| `ticket-to-brief` | agent | content-strategist | re-fetch + status re-check guard |
| `register-post` | agent | register-post-runner (new tiny agent) | reads `slug` from prior phase output; runs `scripts/register-post.sh`; script emits commit_message to stdout |
| `linear-finalize` | agent | linear-coordinator | opt-in status transition |

## Workflows

```yaml
- id: idea-discovery
  name: Transcript-Driven Idea Discovery
  description: Poll Krisp transcripts and propose blog ideas as Linear-backed subjects
  phases:
  - transcript-fetch
  - idea-strategist

- id: approval-watch
  name: Linear Approval Watcher
  description: Poll Linear-backed subjects for in_progress status and enqueue blog-from-ticket
  phases:
  - approval-watcher

- id: blog-from-ticket
  name: Blog Generation from Approved Linear Subject
  description: Generate a blog post from a human-approved Linear discovery subject
  phases:
  - ticket-acknowledge
  - ticket-to-brief
  - research-collection
  - content-writing
  - commit-draft
  - seo-review
  - asset-generation
  - social-excerpts
  - register-post           # BEFORE push-branch: single push ships all commits
  - push-branch
  - linear-finalize
```

`blog-production` gets `register-post` inserted between `social-excerpts` and `push-branch`. Other existing workflows unchanged.

## Schedules

```yaml
- id: discovery
  cron: "0 7 * * *"
  workflow_ref: idea-discovery
  enabled: true
- id: approval-watch
  cron: "*/15 * * * *"
  workflow_ref: approval-watch
  enabled: true
```

## Data contracts

### `content/manifest.json` (tracked in repo)

```json
{
  "version": 1,
  "posts": [
    {
      "slug": "rental-yields-2026",
      "title": "Rental Yields in 2026 — What Investors Should Know",
      "published_at": "2026-04-15",
      "pillar": "Market Analysis",
      "target_keyword": "rental yields 2026",
      "tags": ["rental", "investment", "yields"],
      "word_count": 1850,
      "summary": "One-paragraph excerpt.",
      "linear_subject_id": "BLG-42",
      "source_transcript_id": "krisp-2026-04-10-product-meeting",
      "branch": "feature/blog-rental-yields-2026"
    }
  ]
}
```

### `.ao/state/discovery-cursor.json`

```json
{
  "last_processed_id": "krisp-2026-06-03-abc123",
  "last_processed_at": "2026-06-03T14:22:00Z",
  "updated_at": "2026-06-04T07:00:12Z"
}
```

### `.ao/state/approval-seen.json`

```json
{
  "subject_ids": ["BLG-101", "BLG-105"],
  "updated_at": "2026-06-05T14:15:03Z"
}
```

### Queue handoff payload

Approval-watcher creates either a task or ad-hoc subject (preflight decides) carrying `linear_subject_id` and dispatches via:

```
animus queue enqueue --task-id <task_id> \
  --workflow-ref blog-from-ticket \
  --input-json '{"linear_subject_id":"BLG-105"}'
```

`blog-from-ticket`'s first phase reads `linear_subject_id` from the run's input.

## External research allocation

| Phase | Agent | External MCPs | Research depth |
|---|---|---|---|
| transcript-fetch | transcript-collector | krisp | data ingest |
| idea-strategist | idea-strategist | search-console, exa, tavily, brave, firecrawl, content-library | light pass — viability + sources |
| ticket-to-brief | content-strategist | search-console, content-library | keyword refinement + source threading (Linear via subject API on `ao`) |
| research-collection | content-researcher | firecrawl, exa, tavily, brave, google-maps | deep pass — amplify + extend |
| content-writing | content-writer | content-library | internal synthesis |
| seo-review | seo-optimizer | search-console, firecrawl, content-library | verification |

## Error handling and idempotency

| Failure | State | Recovery |
|---|---|---|
| Krisp outage | `transcript-fetch` fails; cursor untouched | Retried next cron tick |
| Subject backend outage during discovery | Strategist fails partway; cursor advanced only for transcripts whose subjects were created | Idempotency key prevents duplicate subjects on retry |
| Subject backend outage during approval-watch | No subjects enqueued | Retried next tick |
| Queue enqueue failure | Subject stays absent from `approval-seen.json` | Retried next tick |
| Manifest write race | — | `register-post` is `mutates_state: true`; runner mutex serializes |
| Workflow failure mid-`blog-from-ticket` | Subject stays at `in_progress`; no terminal comment | Daemon logs surface failure; human re-runs by setting back to `ready` then approving again |
| **Human cancels ticket after approval** | Subject becomes `cancelled` mid-pipeline | **`ticket-acknowledge` and `ticket-to-brief` re-check status** and emit a clean abort with reason `subject_no_longer_in_progress`. No comment is posted to the cancelled ticket. Pipeline halts; queue dispatch task is marked failed. |
| Human edits ticket body between approval and processing | — | `ticket-to-brief` re-fetches at brief time |

## Daemon environment

The Animus daemon **does not auto-load `.env` files** (per the `animus-configuration` skill). Secrets must be in the daemon's parent shell environment. Setup pattern:

```bash
set -a; source .env; set +a
animus daemon start --autonomous
```

Or one-shot:

```bash
LINEAR_API_TOKEN=... KRISP_API_KEY=... CONTENT_LIBRARY_TOKEN=... \
  animus daemon start --autonomous
```

The workflow YAML's `subjects:` block uses `${LINEAR_TEAM_ID:?set LINEAR_TEAM_ID}` so the daemon **refuses to start** if required vars are missing — early failure beats mysterious runtime errors.

## Open questions / preflight-resolved

These are resolved during the dependency preflight task; none should be guessed.

1. **Subject API surface in agent directives** — `animus subject create` CLI / `animus_subject_*` MCP tool / `animus plugin call --name animus-subject-linear ...`. Preflight runs each form and the directives substitute the working one.
2. **Queue enqueue propagation** — does `--input-json` actually flow through to the dispatched workflow's first phase? Preflight runs a disposable probe workflow and documents the syntax for reading the input.
3. **Subject dispatch wrapper** — does the queue accept a Linear-backed subject directly, or do we wrap in a task / ad-hoc subject? Preflight verifies which path works.
4. **Krisp MCP package name + tool surface** — placeholder `krisp-mcp-server`; replace with real package.
5. **Content library MCP package name + tool surface** — placeholder `content-library-mcp`; replace with real package.
6. **`LINEAR_FINALIZE_TRANSITION` behavior** — default unset = no transition; `=done` = mark complete. If the team needs a granular "In Review" state, document the `animus plugin call --name animus-subject-linear` path for setting a specific Linear state by ID.
7. **`on_failure` hook support in v0.5.4** — if supported, `linear-coordinator` registers a failure path that posts an error comment.

## Reference — relevant Animus skills

- `animus-workflow-authoring` (top-level YAML surface)
- `animus-configuration` (subjects schema, env loading discipline)
- `animus-subject-operations` (subject API + status casing)
- `animus-queue-management` (enqueue semantics + input_json propagation)
- `animus-plugin-operations` (plugin install / inspect / ping / call)
- `animus-mcp-setup` (MCP server wiring)
- `animus-task-management` (task subject lifecycle)
- `animus-skills` (per-project `.ao/skills/*.md` loading)
- `animus-troubleshooting`

After any change to `.animus/workflows/custom.yaml`, run `animus workflow config compile`.
