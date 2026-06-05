# Discovery Flow — Design Spec

**Date:** 2026-06-05
**Branch:** `feature/discovery-flow`
**Author:** Rafal + Claude

## Summary

Extend the existing blog generator (`.ao/workflows/custom.yaml`) with an upstream **idea-discovery → human-review → approved-ticket → blog-production** pipeline. New workflows poll an audio-transcript MCP (Krisp; portable to Granola), synthesize blog ideas grounded in business context and external SEO research, file them as Linear tickets in a dedicated project for human review, then detect approval and hand off to a variant of the existing blog pipeline.

The human-review gate lives in Linear: tickets begin in a **configured Linear project's Backlog** (e.g., a "Blog Content" or "Editorial" project — exact name set in `.env` / business-context as `LINEAR_DISCOVERY_PROJECT_ID`) with a `Discovery` label, and moving out of `Backlog` *within that project* is the approval signal. Scoping to a specific project prevents unrelated team activity from polluting either side of the loop and lets the editorial workflow have its own custom states without interfering with engineering/product Linear usage.

## Goals

1. **Transcript-grounded discovery** — blog ideas come from real conversations recorded in Krisp, not arbitrary topic mining.
2. **Pre-validated proposals** — every Linear ticket already carries Search Console viability data, competitive landscape, and pre-identified citable sources, so human review is meaningful.
3. **Closed-loop Linear status** — the Linear board is the system of record for blog state (`Backlog` = idea, `In Progress` = generating, `In Review` = branch ready, `Done` = merged).
4. **Local content manifest** — `content/manifest.json` records every published post; consumed by the strategist for local dedup and by the writer/SEO agents for real internal-link selection.
5. **Reuse existing pipeline** — research, write, SEO, asset, social, push phases are reused unchanged; only a new `ticket-to-brief` phase replaces today's `topic-research`.

## Non-goals

- Replacing or rewriting the existing `blog-production`, `refresh-cycle`, `image-refresh`, or `news-monitor` workflows.
- Building a custom webhook receiver. Linear status detection is implemented as a polling workflow on a 15-minute cron.
- Auto-merging the generated branch into `main`. Merge is a human action in Linear/GitHub.
- Implementing the `content-library` MCP server itself — this design assumes it is already registered and exposes search/list/get over the org's content + artifact database.

## Architecture overview

Three new workflows, two shared state files, one new manifest:

```
┌─────────────────────┐   cron: 0 7 * * *   (daily 7am)
│  idea-discovery     │
│                     │   phase 1: transcript-fetch
│                     │   phase 2: idea-strategist (creates Linear issues)
└─────────────────────┘

         ↓ (human reviews Linear backlog, moves chosen tickets out of Backlog)

┌─────────────────────┐   cron: */15 * * * * (every 15 min)
│  approval-watch     │
│                     │   phase 1: approval-watcher (enqueues blog-from-ticket
│                     │              for each newly-approved ticket)
└─────────────────────┘

         ↓ (queue handoff via animus_queue_enqueue)

┌─────────────────────┐
│  blog-from-ticket   │   triggered per approved ticket
│                     │
│   1. ticket-acknowledge   ← linear-coordinator: comment + state → In Progress
│   2. ticket-to-brief      ← content-strategist: Linear → topic_brief
│   3. research-collection  ← content-researcher (reused)
│   4. content-writing      ← content-writer (extended: content-library)
│   5. commit-draft         ← command (reused)
│   6. seo-review           ← seo-optimizer (extended: content-library)
│   7. register-post        ← command: append content/manifest.json
│   8. asset-generation     ← asset-generator (reused)
│   9. social-excerpts      ← asset-generator (reused)
│  10. push-branch          ← command (reused)
│  11. linear-finalize      ← linear-coordinator: comment + state → In Review
└─────────────────────┘

Shared state (.ao/state/, gitignored):
  discovery-cursor.json    last-processed Krisp transcript ID
  approval-seen.json       Linear issue IDs already enqueued
  transcripts/<id>.json    fetched transcript staging files

Tracked in repo:
  content/manifest.json    canonical list of all generated posts
```

`blog-production` is retrofitted with a single new phase (`register-post`, inserted between `seo-review` and `asset-generation`) so cron-originated posts also appear in the manifest. No other change to existing workflows.

## New MCP servers

Added to the `mcp_servers:` block in `.ao/workflows/custom.yaml`. Names are placeholders for the actual registered server identifiers in `.mcp.json`.

| Server | Purpose | Used by |
|---|---|---|
| `krisp` | Pull recent meeting transcripts | `transcript-collector` only |
| `linear` | Issue create/read/update + state transitions | `idea-strategist`, `approval-watcher`, `content-strategist` (ticket-to-brief), `linear-coordinator` |
| `content-library` | Search org content + artifact database | `idea-strategist`, `content-strategist`, `content-writer`, `seo-optimizer` |

Krisp is the primary; the design works equally with Granola if `krisp` is swapped for `granola` in the workflow YAML — the `transcript-collector` directive is written in terms of "list new transcripts since cursor, fetch full text," not Krisp-specific tool names.

## New agents

### `transcript-collector` (new)

- **Model:** `claude-haiku-4-5` (fetch-only, no synthesis)
- **mcp_servers:** `krisp`
- **System prompt:** none beyond defaults; the directive is fully prescriptive
- **Per-run directive:** read `.ao/state/discovery-cursor.json`, list Krisp transcripts created after the cursor, fetch full text and metadata for each, write each as `.ao/state/transcripts/<transcript_id>.json`, update the cursor to the most recent transcript ID. Emit phase result listing the file paths.
- **Output contract:** `phase_result` with required field `transcript_paths: array<string>`

### `idea-strategist` (new)

- **Model:** `claude-sonnet-4-6`
- **mcp_servers:** `ao`, `linear`, `content-library`, `search-console`, `exa`, `tavily`, `brave`, `firecrawl`
- **System prompt:** reads `.ao/skills/content-strategy.md`; reads `business-context.yaml` as mandatory context (refuses to proceed without it)
- **Per-run directive:**
  1. Read business context, manifest (`content/manifest.json`), and query `content-library` MCP for org-wide topic fingerprints.
  2. For each transcript file in input: extract 3–5 candidate angles grounded in specific quoted moments.
  3. For each candidate angle, run external validation:
     - Search Console: target keyword viability (volume, current rank, striking distance)
     - Exa / Tavily / Brave: competitive landscape — who covers this, how deep, what's the gap
     - Firecrawl: spot-scrape top 1–2 ranking pages for what's already said and 2–3 citable authoritative sources
  4. Filter or refine angles based on research: drop dead keywords, re-angle saturated SERPs, drop dupes against manifest + content-library.
  5. For each surviving angle, call Linear MCP to create an issue:
     - **Project: `LINEAR_DISCOVERY_PROJECT_ID`** (configured — must be set; strategist refuses to proceed if missing)
     - Team: derived from the project (Linear projects belong to a team)
     - Label: `Discovery`
     - State: `Backlog` *within the configured project*
     - Body: structured markdown — source transcript ref + timestamp, the inspiring quote, suggested target keyword + GSC stats, competitive landscape (top 3 URLs + gap), pre-identified citable sources, suggested pillar, dedup notes
     - Idempotency: include a client dedup key `discovery:<transcript_id>:<angle_hash>` in the body so retries don't double-create
- **Capabilities:** `mutates_state: true`
- **Output contract:** `phase_result` with required field `issues_created: array<{id, title, transcript_id}>`

### `approval-watcher` (new)

- **Model:** `claude-haiku-4-5`
- **mcp_servers:** `ao`, `linear`
- **Per-run directive:**
  1. Read `.ao/state/approval-seen.json` (list of already-handled issue IDs).
  2. Linear GraphQL query, **scoped to the configured project**:
     `issues where project.id = LINEAR_DISCOVERY_PROJECT_ID AND label.name = "Discovery" AND state.type != "backlog"`.
     The project scope is mandatory — without it the watcher would respond to status changes anywhere in the workspace.
  3. Subtract the seen set.
  4. For each newly-approved issue, call `animus_queue_enqueue` with:
     ```
     workflow_ref: blog-from-ticket
     input: {linear_issue_id, title, body, labels, suggested_pillar, suggested_keyword, pre_identified_sources}
     ```
  5. Append the IDs to `approval-seen.json` (atomic write).
  6. If nothing new, emit `skip` verdict — no noisy task creation.
- **Output contract:** `phase_result` with required field `enqueued: array<{issue_id, queue_id}>`

### `linear-coordinator` (new, used in two phases)

- **Model:** `claude-haiku-4-5`
- **mcp_servers:** `linear`
- **Used in two phases of `blog-from-ticket`:**
  - `ticket-acknowledge` (first phase) — receives `linear_issue_id`, posts a "🤖 generation started" comment with the Animus run ID and branch name, transitions state to `In Progress`.
  - `linear-finalize` (last phase) — receives outputs from prior phases (slug, branch, commit SHA, image path, SEO summary), posts a final comment with the branch URL, featured image, final slug, word count, and SEO fixes summary, transitions state to `In Review`.
- **Failure path:** if invoked via the workflow's failure hook (`on_failure`, pending v0.4.2 support verification), posts an error comment and moves the ticket back to `Backlog`. If `on_failure` is not supported in v0.4.2, the daemon's run history is the failure surface and the human re-approves manually.

## Extended (existing) agents

### `content-strategist`

- **Add to `mcp_servers`:** `linear`, `content-library`
- **New use:** runs the new `ticket-to-brief` phase. Reads `business-context.yaml`, fetches the Linear issue (humans may have edited the body during review), threads the pre-identified sources from the issue body into the brief, refines the target keyword via Search Console, emits the same `topic_brief` contract today's `topic-research` produces.
- **Existing use (`topic-research` in `blog-production`):** unchanged.

### `content-writer`

- **Add to `mcp_servers`:** `content-library`
- **Behavior change:** when picking 2–3 internal links, queries `content-library` MCP and `content/manifest.json` for related published posts rather than guessing slugs.
- **Otherwise unchanged.**

### `seo-optimizer`

- **Add to `mcp_servers`:** `content-library`
- **Behavior change:** verifies that internal-link slugs the writer chose actually exist (via `content-library` lookup and `content/manifest.json` cross-check).
- **Otherwise unchanged.**

## New phases

### `transcript-fetch` (in `idea-discovery`)

Mode: agent. Agent: `transcript-collector`. Directive as above. Capabilities: `mutates_state: true` (writes to `.ao/state/`).

### `idea-strategist` (in `idea-discovery`)

Mode: agent. Agent: `idea-strategist`. Receives transcript paths from prior phase. Capabilities: `mutates_state: true` (creates Linear issues).

### `approval-watcher` (in `approval-watch`)

Mode: agent. Agent: `approval-watcher`. Capabilities: `mutates_state: true` (enqueues + writes seen file).

### `ticket-acknowledge` (in `blog-from-ticket`, first phase)

Mode: agent. Agent: `linear-coordinator`. Receives full input payload from queue. Capabilities: `mutates_state: true` (Linear state transition).

### `ticket-to-brief` (in `blog-from-ticket`, second phase)

Mode: agent. Agent: `content-strategist`. Receives `linear_issue_id` + payload from prior phase. Emits the same `topic_brief` output contract that `topic-research` does today, so downstream phases work unchanged.

### `register-post` (in `blog-from-ticket` AND retrofitted into `blog-production`)

Mode: `command`. No agent. Implemented as a small script (Bash + jq or a Node one-liner) that:
1. Parses YAML frontmatter from `content/<slug>.md`
2. Reads existing `content/manifest.json` (creates `{"version": 1, "posts": []}` if missing)
3. Appends a new entry (see manifest schema below)
4. Writes atomically (tmpfile + rename)
5. `git add content/manifest.json && git commit -m "Register <slug> in manifest"`

Capabilities: `mutates_state: true`. Animus serializes this phase across concurrent runs via the runner mutex.

### `linear-finalize` (in `blog-from-ticket`, last phase)

Mode: agent. Agent: `linear-coordinator`. Capabilities: `mutates_state: true`.

## Workflows

```yaml
- id: idea-discovery
  name: Transcript-Driven Idea Discovery
  description: Poll Krisp transcripts, propose blog ideas as Linear tickets
  phases:
  - transcript-fetch
  - idea-strategist

- id: approval-watch
  name: Linear Approval Watcher
  description: Poll Linear for tickets that left Backlog, enqueue blog-from-ticket
  phases:
  - approval-watcher

- id: blog-from-ticket
  name: Blog Generation from Approved Linear Ticket
  description: Generate a blog post from a human-approved Linear discovery ticket
  phases:
  - ticket-acknowledge
  - ticket-to-brief
  - research-collection
  - content-writing
  - commit-draft
  - seo-review
  - register-post
  - asset-generation
  - social-excerpts
  - push-branch
  - linear-finalize
```

`blog-production` gets `register-post` inserted between `seo-review` and `asset-generation`. Other existing workflows unchanged.

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
      "linear_ticket_id": "BLG-42",
      "source_transcript_id": "krisp-2026-04-10-product-meeting",
      "branch": "feature/blog-rental-yields-2026"
    }
  ]
}
```

Bootstrapping: if missing, `register-post` creates `{"version": 1, "posts": []}` on first run.

### `.ao/state/discovery-cursor.json`

```json
{ "last_transcript_id": "krisp-2026-06-03-abc123", "updated_at": "2026-06-04T07:00:12Z" }
```

### `.ao/state/approval-seen.json`

```json
{ "issues": ["BLG-101", "BLG-102", "BLG-105"], "updated_at": "2026-06-05T14:15:03Z" }
```

### Queue input payload (approval-watcher → blog-from-ticket)

```json
{
  "linear_issue_id": "BLG-105",
  "title": "Commuter Town Rental Yields 2026",
  "body": "...full markdown body as authored by strategist + edited by human...",
  "labels": ["Discovery", "Market Analysis"],
  "suggested_pillar": "Market Analysis",
  "suggested_keyword": "commuter town rental yields 2026",
  "pre_identified_sources": [
    {"url": "https://ons.gov.uk/...", "supports": "ONS rental index Q1 2026"},
    {"url": "https://hamptons.co.uk/...", "supports": "Hamptons quarterly market report"}
  ]
}
```

## External research allocation

| Phase | Agent | External MCPs | Research depth |
|---|---|---|---|
| transcript-fetch | transcript-collector | krisp | data ingest |
| idea-strategist | idea-strategist | search-console, exa, tavily, brave, firecrawl, content-library | light pass — viability + sources |
| ticket-to-brief | content-strategist | search-console, linear, content-library | keyword refinement + source threading |
| research-collection | content-researcher | firecrawl, exa, tavily, brave, google-maps | deep pass — amplify + extend |
| content-writing | content-writer | content-library | internal synthesis |
| seo-review | seo-optimizer | search-console, firecrawl, content-library | verification |

## Error handling and idempotency

| Failure | State | Recovery |
|---|---|---|
| Krisp outage | `transcript-fetch` fails, cursor unchanged | Retried next cron tick |
| Linear outage during discovery | Strategist fails after partial issue creation | Per-issue client dedup key prevents doubles; retry next tick |
| Linear outage during approval-watch | No tickets enqueued | Retried next tick (15 min) |
| `animus_queue_enqueue` failure | Issue stays absent from `approval-seen.json` | Retried next tick |
| Manifest write race (concurrent `blog-from-ticket` runs) | — | Animus runner mutex via `mutates_state: true` serializes |
| Workflow failure mid-`blog-from-ticket` | Ticket stuck in `In Progress` | `linear-coordinator` `on_failure` hook (if v0.4.2 supports it) moves to `Backlog` + error comment; otherwise human re-approves |
| Human edits ticket body before approval | — | `ticket-to-brief` reads the latest issue body at brief time, so edits flow through |

## Open questions / configuration to confirm at implementation time

1. The actual registered names of `krisp`, `linear`, `content-library` MCP servers in `.mcp.json`.
2. **`LINEAR_DISCOVERY_PROJECT_ID`** — the Linear project ID (UUID) where Discovery tickets live. Set in `.env` and referenced from the workflow YAML / agent directives. The project must exist before first run; the strategist and approval-watcher both refuse to proceed without it.
3. The exact Linear state names within that project: which state means "Backlog" (initial), which means "In Progress" (active), which means "In Review" (branch ready), which means "Done" (published). These may not match Linear defaults if the project has custom states. Configured as `LINEAR_STATE_BACKLOG_ID`, `LINEAR_STATE_IN_PROGRESS_ID`, `LINEAR_STATE_IN_REVIEW_ID`, `LINEAR_STATE_DONE_ID`.
4. Whether Animus v0.4.2 supports a phase-level or workflow-level `on_failure` hook for `linear-coordinator`'s error path. If not, the design degrades gracefully to human re-approval as the recovery path.
5. Whether `register-post` should also write to the `content-library` MCP (push), or whether the content-library is read-only from this repo's perspective and ingests from `content/` separately.

## Reference — relevant Animus skills

Implementation should consult, via the `Skill` tool:
- `animus-workflow-authoring` — workflow/agent/phase YAML structure, schedules, cron, MCP servers
- `animus-workflow-patterns` — queue handoff, gating, retries
- `animus-mcp-setup` — wiring MCP servers into agents and per-agent allowlists
- `animus-task-management` — `animus_task_*` MCP tools and task lifecycle
- `animus-queue-management` — `animus_queue_*` MCP tools and enqueue semantics
- `animus-skills` — how per-project `.ao/skills/*.md` files are loaded by agents
- `animus-troubleshooting` — daemon, runner, and workflow failure modes

After any change to `.ao/workflows/custom.yaml`, run `animus workflow config compile` (per project `CLAUDE.md`).
