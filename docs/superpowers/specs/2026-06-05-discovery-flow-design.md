# Discovery Flow — Design Spec

**Date:** 2026-06-05 (revised after v0.5.4 upgrade)
**Branch:** `feature/discovery-flow`
**Author:** Rafal + Claude

## Summary

Extend the existing blog generator (`.ao/workflows/custom.yaml`) with an upstream **idea-discovery → human-review → approved-ticket → blog-production** pipeline. New workflows poll an audio-transcript MCP (Krisp; portable to Granola), synthesize blog ideas grounded in business context and external SEO research, file them as **Linear-backed Animus subjects** in a dedicated Linear project for human review, then detect approval and hand off to a variant of the existing blog pipeline.

**Architectural note (revised):** Linear is integrated as an **Animus subject backend** via the `animus-subject-linear` plugin (v0.1.4+, requires Animus v0.4.0+; this project is on v0.5.4). Linear is **not** treated as a generic MCP server. This makes Linear issues first-class Animus subjects that the queue, task, and workflow systems route over natively, eliminating the need for hand-written GraphQL queries or MCP shim layers.

**Approval semantics:** the `animus-subject-linear` plugin auto-maps Linear's `WorkflowState.type` to the five Animus subject statuses (`Ready / InProgress / Blocked / Done / Cancelled`). The human-review gate is therefore: subjects are created at `status = Ready` (Linear state-type `backlog`); a human moves the issue to any Linear state with type `started` (e.g. "In Progress", "Todo+", "Reviewing") → plugin reports `status = InProgress` → approval-watcher enqueues. Linear states with type `cancelled` (Canceled, Won't-do, Duplicate) become Animus `Cancelled` and are explicitly filtered out — they are not approvals. Linear team-side state renames don't break the loop because the `type` field is stable.

## Goals

1. **Transcript-grounded discovery** — blog ideas come from real conversations recorded in Krisp, not arbitrary topic mining.
2. **Pre-validated proposals** — every Linear-backed subject already carries Search Console viability data, competitive landscape, and pre-identified citable sources, so human review is meaningful.
3. **Closed-loop Linear status** — the Linear board is the visible system-of-record for blog state; status transitions are observed by Animus through the subject backend, not via custom polling code.
4. **Local content manifest** — `content/manifest.json` records every published post; consumed by the strategist for local dedup and by the writer/SEO agents for real internal-link selection.
5. **Reuse existing pipeline** — research, write, SEO, asset, social, push phases are reused unchanged; only a new `ticket-to-brief` phase replaces today's `topic-research`.

## Non-goals

- Replacing or rewriting the existing `blog-production`, `refresh-cycle`, `image-refresh`, or `news-monitor` workflows.
- Building a custom webhook receiver. Status detection is implemented as a polling workflow on a 15-minute cron (the plugin's roadmap includes webhooks; until shipped, we poll).
- Auto-merging the generated branch into `main`. Merge is a human action in Linear/GitHub.
- Implementing the `content-library` MCP server itself — this design assumes it is already registered and exposes search/list/get over the org's content + artifact database.
- Granular Linear-state-name transitions from `linear-finalize` — the subject API only exposes the 5 normalized statuses. The default is to leave the issue at `InProgress` after finalize and let the human move it to their team's preferred "In Review" / "QA" / etc. state; an opt-in flag allows automatic transition to `Done`.

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
│                     │     - lists subjects of kind=linear, project=DISCOVERY
│                     │     - filters by Animus status == InProgress
│                     │     - skips Cancelled / Done / Blocked
│                     │     - enqueues blog-from-ticket with {subject_id} only
└─────────────────────┘

         ↓ (queue handoff via animus_queue_enqueue, kind=linear, id=<subject_id>)

┌─────────────────────┐
│  blog-from-ticket   │   triggered per approved subject
│                     │
│   1. ticket-acknowledge   ← linear-coordinator: post "started" comment
│   2. ticket-to-brief      ← content-strategist: re-fetch subject + body,
│                                                  derive topic_brief
│   3. research-collection  ← content-researcher (reused)
│   4. content-writing      ← content-writer (extended: content-library)
│   5. commit-draft         ← command (reused)
│   6. seo-review           ← seo-optimizer (extended: content-library)
│   7. asset-generation     ← asset-generator (reused)
│   8. social-excerpts      ← asset-generator (reused)
│   9. push-branch          ← command (reused)
│  10. register-post        ← agent: append content/manifest.json (post is now
│                                    complete + pushed; manifest represents
│                                    "post artifact on origin")
│  11. linear-finalize      ← linear-coordinator: rich completion comment;
│                                                  status transition opt-in
└─────────────────────┘

Shared state (.ao/state/, gitignored entirely; no .gitkeep — phases mkdir on demand):
  discovery-cursor.json    last *processed* transcript (advanced by idea-strategist,
                           NOT by transcript-fetch — fail-safe against partial runs)
  approval-seen.json       Animus subject IDs already enqueued
  transcripts/<id>.json    fetched transcript staging files

Tracked in repo:
  content/manifest.json    canonical list of all generated posts (committed at the
                           register-post step, AFTER push-branch — the manifest
                           represents posts that exist on origin)
```

`blog-production` is retrofitted with a single new `register-post` phase, inserted as the new step 9 (between `push-branch` and the end, i.e., last phase). No other change to existing workflows.

## Subject backend (Linear)

**Plugin:** `launchapp-dev/animus-subject-linear` v0.1.4+, installed via `animus plugin install launchapp-dev/animus-subject-linear`.

**Status mapping (auto, no team-side configuration required):**

| Linear `WorkflowState.type` | Animus subject status | Meaning in this workflow |
|---|---|---|
| `triage`, `backlog`, `unstarted` | `Ready` | initial state — created by strategist, awaiting human review |
| `started` | `InProgress` | **approval signal** — human picked this idea |
| `completed` | `Done` | blog published / merged (optional terminal transition) |
| `cancelled` | `Cancelled` | rejected; never treated as approval |

`LINEAR_STATUS_MAP` env override is available if the team's Linear states don't fit the type-based map (e.g. a custom "Code Review" state that should count as `Done` rather than `InProgress`).

**Workflow YAML declaration:**

```yaml
subjects:
  linear-discovery:
    plugin: animus-subject-linear
    config:
      api_token_env: LINEAR_API_TOKEN
      team: ${LINEAR_TEAM}
      project_id: ${LINEAR_DISCOVERY_PROJECT_ID}
```

The local alias `linear-discovery` is what workflow phases reference (rather than the global plugin name) — this lets a single Animus instance host multiple Linear subject types for different projects/teams.

**How agents interact with subjects:** the exact tool surface (whether `animus_subject_create` / `animus_subject_list` / etc. exist as MCP tools, or whether dispatch happens via `animus plugin call --name animus-subject-linear ...` from Bash) is **the first thing the preflight task verifies before any YAML changes are written**. The plan documents both paths and lets the preflight pick the right one. See the implementation plan for details.

## MCP servers (non-Linear)

Linear is no longer in this list — it's a subject backend, not an MCP server. The two new MCP servers below are added to the `mcp_servers:` block in `.ao/workflows/custom.yaml`.

| Server | Purpose | Used by |
|---|---|---|
| `krisp` | Pull recent meeting transcripts | `transcript-collector` only |
| `content-library` | Search org content + artifact database | `idea-strategist`, `content-strategist` (ticket-to-brief), `content-writer`, `seo-optimizer` |

Krisp is the primary; the design works equally with Granola if `krisp` is swapped for `granola` in the workflow YAML — the `transcript-collector` directive is written in terms of "list new transcripts since cursor, fetch full text," not Krisp-specific tool names.

## New agents

### `transcript-collector` (new)

- **Model:** `claude-haiku-4-5` (fetch-only, no synthesis)
- **mcp_servers:** `krisp`
- **System prompt:** none beyond defaults; the directive is fully prescriptive
- **Per-run directive:** read `.ao/state/discovery-cursor.json` to determine cutoff (treat missing as "process all available, cap 20"). List Krisp transcripts created strictly after `cursor.last_processed_at`. For each, fetch full text and metadata, write as `.ao/state/transcripts/<transcript_id>.json` (mkdir parent if needed). **Does NOT update the cursor** — that responsibility moves to `idea-strategist` so the cursor reflects what was actually *processed* not just *fetched*. Emit phase result with the list of file paths.
- **Output contract:** `phase_result` with required field `transcript_paths: array<string>`

### `idea-strategist` (new)

- **Model:** `claude-sonnet-4-6`
- **mcp_servers:** `ao`, `content-library`, `search-console`, `exa`, `tavily`, `brave`, `firecrawl`
- **System prompt:** reads `.ao/skills/content-strategy.md`; reads `business-context.yaml` as mandatory context (refuses to proceed without it). Hard rule: requires `LINEAR_DISCOVERY_PROJECT_ID` set; emits skip with reason `missing_project_id` otherwise.
- **Per-run directive:**
  1. Read business context, manifest (`content/manifest.json`), query `content-library` for org-wide topic fingerprints.
  2. For each transcript file in input: extract 3–5 candidate angles grounded in specific quoted moments.
  3. External validation per candidate angle:
     - Search Console: keyword viability (volume, current rank, striking distance)
     - Exa / Tavily / Brave: competitive landscape — depth, gap, saturation
     - Firecrawl: spot-scrape top 1–2 ranking pages for what's covered and 2–3 citable sources
  4. Filter/refine angles based on research; drop dupes against `content/manifest.json` + content-library results.
  5. For each surviving angle, create a Linear-backed subject via the subject API (see "Subject backend" section for dispatch path):
     - kind: `linear-discovery` (the local subject alias)
     - title: punchy headline
     - body: structured markdown (source transcript ref, quote, suggested keyword + GSC stats, competitive landscape, pre-identified sources, suggested pillar, dedup notes, **idempotency key** `discovery:<transcript_id>:<angle_hash>` in body)
     - Before creating, query existing subjects in the project for any with matching idempotency key in body; skip if present.
  6. **After successfully processing each transcript file**, advance `.ao/state/discovery-cursor.json` to that transcript's ID + timestamp. Failure on transcript N leaves cursor at transcript N-1 — N is retried next run.
- **Capabilities:** `mutates_state: true`
- **Output contract:** `phase_result` with required field `issues_created: array<{subject_id, title, transcript_id}>`

### `approval-watcher` (new)

- **Model:** `claude-haiku-4-5`
- **mcp_servers:** `ao`
- **Per-run directive:**
  1. Read `.ao/state/approval-seen.json` (list of subject IDs already enqueued).
  2. List subjects of kind `linear-discovery`, scoped to `LINEAR_DISCOVERY_PROJECT_ID`, with `status == InProgress`. Explicitly do NOT include `Cancelled` (rejected), `Done` (already processed), or `Blocked`. The `Ready` filter is implicit (no transition yet, no approval).
  3. Subtract the seen set.
  4. For each new approval, call `animus_queue_enqueue` with:
     ```
     workflow_ref: blog-from-ticket
     input: { subject_id: "<id>", subject_kind: "linear-discovery" }
     ```
     Only the subject ID is enqueued — the body, title, labels, etc. are re-fetched fresh in `ticket-to-brief`. This handles two cases the original design didn't: (a) humans editing the ticket body between approval and processing, (b) queue input shape uncertainty.
  5. Append IDs to `approval-seen.json` (atomic write — tmpfile + rename).
  6. If nothing newly approved, emit skip with reason `no_approvals`.
- **Output contract:** `phase_result` with required field `enqueued: array<{subject_id, queue_id}>`

### `linear-coordinator` (new, used in two phases)

- **Model:** `claude-haiku-4-5`
- **mcp_servers:** `ao`
- **Used in:**
  - `ticket-acknowledge` (first phase of `blog-from-ticket`) — receives `subject_id`, posts a "🤖 generation started" comment with the Animus run ID and branch name. **Does NOT transition status** — the human already did that by approving.
  - `linear-finalize` (last phase) — posts a rich completion comment (branch URL, slug, word count, image embed, SEO summary). **Status transition is opt-in via the `LINEAR_FINALIZE_TRANSITION` env var:** unset (default) = no transition (the human moves the issue to their team's preferred review/QA state); set to `Done` = mark complete (plugin picks the lowest-position `completed` state). Granular states like "In Review" can't be set through the subject abstraction; if those are required, use `animus plugin call --name animus-subject-linear ...` directly.
- **Failure path:** if invoked via the workflow's failure hook (verified during preflight), posts an error comment. Does not auto-revert status — the human chooses how to handle.

## Extended (existing) agents

### `content-strategist`

- **Add to `mcp_servers`:** `content-library` (Linear access moves through subject API, not MCP)
- **New use:** runs `ticket-to-brief`. Receives `subject_id` from the queue payload. Fetches the latest subject (title, body, status, comments) via subject API — re-fetch is mandatory because humans may edit between approval and processing. Reads `business-context.yaml`. Threads pre-identified sources from body into the brief, refines target keyword via Search Console, emits the same `topic_brief` contract today's `topic-research` produces.
- **Existing use (`topic-research`):** unchanged.

### `content-writer`

- **Add to `mcp_servers`:** `content-library`
- **Behavior change:** queries `content-library` MCP and `content/manifest.json` for real internal-link candidates.

### `seo-optimizer`

- **Add to `mcp_servers`:** `content-library`
- **Behavior change:** verifies internal-link slugs against `content-library` and `content/manifest.json`.

## New phases

### `transcript-fetch` (in `idea-discovery`)

Mode: agent. Agent: `transcript-collector`. Capabilities: `mutates_state: true`. **Does not advance the cursor.**

### `idea-strategist` (in `idea-discovery`)

Mode: agent. Agent: `idea-strategist`. Receives transcript paths from prior phase. Capabilities: `mutates_state: true`. **Advances cursor per-transcript on success.**

### `approval-watcher` (in `approval-watch`)

Mode: agent. Agent: `approval-watcher`. Capabilities: `mutates_state: true`.

### `ticket-acknowledge` (in `blog-from-ticket`, first phase)

Mode: agent. Agent: `linear-coordinator`, mode `acknowledge`. Receives `{subject_id}` from queue payload. Capabilities: `mutates_state: true`.

### `ticket-to-brief` (in `blog-from-ticket`, second phase)

Mode: agent. Agent: `content-strategist`. Receives `{subject_id}` from prior phase. **Re-fetches the latest subject body before building the brief** (per feedback point 6). Emits same `topic_brief` contract as `topic-research`.

### `register-post` (in `blog-from-ticket` AND retrofitted into `blog-production`)

**Mode: agent** (not command — feedback point 7). A tiny agent (`claude-haiku-4-5`, no MCPs) that:
1. Reads `slug` from the prior phase's output (the `seo-review` phase emits a slug-bearing phase result)
2. Optionally reads `linear_issue_id` / `source_transcript_id` from the workflow input
3. Invokes `scripts/register-post.sh <slug>` via Bash with those as env vars
4. Returns the commit_message from the script's stdout

This sidesteps the question of whether a command phase can receive prior-phase outputs as env vars (which would require Animus-version-specific verification).

**Position in pipeline (revised per feedback point 8): AFTER `push-branch`, BEFORE `linear-finalize`.** The manifest now represents "post artifact on origin" — entries only appear when the post has been committed to origin, image generated (or attempted), social excerpts written, and pushed. `linear-finalize` reads from a manifest that's guaranteed to be current.

### `linear-finalize` (in `blog-from-ticket`, last phase)

Mode: agent. Agent: `linear-coordinator`, mode `finalize`. Reads slug + branch + commit_message from prior phases; reads `content/manifest.json` entry for additional metadata. Capabilities: `mutates_state: true`.

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
  description: Poll Linear-backed subjects for InProgress status and enqueue blog-from-ticket
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
  - push-branch
  - register-post       # ← new placement: AFTER push-branch
  - linear-finalize
```

`blog-production` gets `register-post` inserted as its last phase (after `push-branch`). Other existing workflows unchanged.

## Schedules

Added to the `schedules:` block. Existing schedules unchanged.

```yaml
- id: discovery
  cron: "0 7 * * *"        # daily 7am, before existing 8am blog runs
  workflow_ref: idea-discovery
  enabled: true

- id: approval-watch
  cron: "*/15 * * * *"     # every 15 min
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
      "linear_subject_id": "linear-discovery:BLG-42",
      "source_transcript_id": "krisp-2026-04-10-product-meeting",
      "branch": "feature/blog-rental-yields-2026"
    }
  ]
}
```

Bootstrapping: committed as `{"version": 1, "posts": []}` on initial setup.

### `.ao/state/discovery-cursor.json`

```json
{
  "last_processed_id": "krisp-2026-06-03-abc123",
  "last_processed_at": "2026-06-03T14:22:00Z",
  "updated_at": "2026-06-04T07:00:12Z"
}
```

Storing both ID and timestamp protects against Krisp's listing-order semantics (if IDs aren't sortable, we fall back to `last_processed_at` for cutoff). Advanced **only** by `idea-strategist` per transcript on success.

### `.ao/state/approval-seen.json`

```json
{
  "subject_ids": ["linear-discovery:BLG-101", "linear-discovery:BLG-105"],
  "updated_at": "2026-06-05T14:15:03Z"
}
```

### Queue input payload (approval-watcher → blog-from-ticket)

```json
{
  "subject_id": "linear-discovery:BLG-105",
  "subject_kind": "linear-discovery"
}
```

That's it. No body, no labels, no pre-extracted sources — all of that is re-fetched in `ticket-to-brief` from the (potentially-edited) Linear issue.

## External research allocation

Unchanged from prior revision — discovery does light external research (viability + sources); production does deep external research (research-collection).

| Phase | Agent | External MCPs | Research depth |
|---|---|---|---|
| transcript-fetch | transcript-collector | krisp | data ingest |
| idea-strategist | idea-strategist | search-console, exa, tavily, brave, firecrawl, content-library | light pass — viability + sources |
| ticket-to-brief | content-strategist | search-console, content-library | keyword refinement + source threading (Linear access via subject API, not MCP) |
| research-collection | content-researcher | firecrawl, exa, tavily, brave, google-maps | deep pass — amplify + extend |
| content-writing | content-writer | content-library | internal synthesis |
| seo-review | seo-optimizer | search-console, firecrawl, content-library | verification |

## Error handling and idempotency

| Failure | State | Recovery |
|---|---|---|
| Krisp outage | `transcript-fetch` fails; cursor unchanged (never touched in this phase anyway) | Retried next cron tick |
| Subject backend outage during discovery | Strategist fails partway; cursor advanced only for transcripts whose subjects were successfully created | Next tick re-attempts unprocessed transcripts; idempotency key prevents duplicate subjects |
| Subject backend outage during approval-watch | No subjects enqueued | Retried next tick |
| `animus_queue_enqueue` failure | Subject stays absent from `approval-seen.json` | Retried next tick |
| Manifest write race (concurrent runs) | — | `register-post` is `mutates_state: true` → runner mutex serializes |
| Workflow failure mid-`blog-from-ticket` | Subject stays at `InProgress`; no terminal Linear comment | `linear-coordinator` failure path posts an error comment if `on_failure` is supported; human handles |
| Human edits ticket body between approval and processing | — | `ticket-to-brief` re-fetches at brief time, so edits flow through |
| Human cancels ticket after approval | Subject becomes `Cancelled` mid-pipeline | Pipeline continues (Animus doesn't auto-cancel runs on subject status change); finalize comment lands on a Cancelled ticket which is harmless |

## Open questions / configuration to confirm at implementation time

These are resolved during the **dependency preflight task** (the first task of the plan) — none should be guessed.

1. **Subject API surface** — does `animus_subject_create` / `animus_subject_list` / `animus_subject_update` exist as MCP tools in v0.5.4's `ao` server, or does dispatch happen via `animus plugin call --name animus-subject-linear ...` from Bash? Preflight: run `animus mcp serve` and list tools; if subject namespace is exposed, agents call directly; if not, agents invoke via Bash + plugin call.
2. **Queue input propagation** — does `animus_queue_enqueue`'s `input` field actually flow through to the dispatched workflow as accessible state? Preflight: enqueue a disposable workflow with a known input shape; verify the first phase can read it.
3. **Krisp MCP package name + tool surface** — placeholder `krisp-mcp-server`; replace with real package; verify list-transcripts and fetch-transcript tools exist.
4. **Content library MCP package name + tool surface** — placeholder `content-library-mcp`; replace with real package; verify search/list/get tools.
5. **`LINEAR_FINALIZE_TRANSITION`** — default unset (no transition); team chooses whether to set it to `Done`. If they want "In Review" specifically, plan documents the `animus plugin call` path.
6. **Animus `on_failure` hook support in v0.5.4** — if supported, `linear-coordinator` registers a failure path that posts an error comment; if not, daemon logs are the failure surface.

## Reference — relevant Animus skills

Implementation should consult, via the `Skill` tool:
- `animus-workflow-authoring` — workflow/agent/phase YAML structure, schedules, cron, MCP servers, **subjects**
- `animus-subject-operations` — subject creation, listing, status transitions (newly relevant given the architecture shift)
- `animus-workflow-patterns` — queue handoff, gating, retries
- `animus-mcp-setup` — wiring MCP servers into agents and per-agent allowlists
- `animus-task-management` — `animus_task_*` MCP tools and task lifecycle
- `animus-queue-management` — `animus_queue_*` MCP tools and enqueue semantics
- `animus-skills` — how per-project `.ao/skills/*.md` files are loaded by agents
- `animus-troubleshooting` — daemon, runner, and workflow failure modes
- `animus-plugin-operations` — plugin install, inspect, ping, dispatch (newly relevant)

After any change to `.ao/workflows/custom.yaml`, run `animus workflow config compile` (per project `CLAUDE.md`).
