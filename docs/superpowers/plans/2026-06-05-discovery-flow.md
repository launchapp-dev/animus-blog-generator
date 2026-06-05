# Discovery Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an upstream `idea-discovery → human-review-in-Linear → approval-watch → blog-from-ticket` pipeline to `.ao/workflows/custom.yaml`, with a `content/manifest.json` for local dedup.

**Architecture:** Three new workflows, four new agents, eight new phases, two extended phases on existing agents, one new shell/jq script (`register-post`). All YAML lives in the single existing `.ao/workflows/custom.yaml`. The script lives at `scripts/register-post.sh`. State files live in `.ao/state/` (gitignored). Per-spec: `docs/superpowers/specs/2026-06-05-discovery-flow-design.md`.

**Linear integration via the Animus `linear-pack` connector-pack** (`launchapp-dev/linear-pack`), which bundles the `@anthropic-ai/linear-mcp@latest` MCP server plus an `issue-management` skill and Linear-aware agents. Installed via `animus pack install` (not `animus plugin install` — different subcommand; packs are workflow bundles, plugins are STDIO binaries).

**Tech Stack:** Animus v0.4.2 (workflow runner, MCP server proxy, queue, pack manager), YAML for declarative pipeline, Bash + `jq` + `yq` for `register-post`, `bats-core` for shell tests, `@anthropic-ai/linear-mcp` for Linear, the linear-pack for Linear skill + agent guidance.

---

## File Structure

**Created:**
- `scripts/register-post.sh` — appends post entry to `content/manifest.json`
- `scripts/test/register-post.bats` — bats tests for the script
- `content/manifest.json` — canonical index of generated posts (committed; bootstraps to `{"version": 1, "posts": []}`)

**Modified:**
- `.ao/workflows/custom.yaml` — new MCP servers, agents, phases, workflows, schedules; extended existing agents and `blog-production` phase list
- `.env.example` — new env vars for Krisp, Linear, content-library, Linear state IDs
- `.gitignore` — add `.ao/state/`
- `MCP-TOOLS.md` — document the three new MCP servers
- `README.md` — document the new workflows

**Runtime-created (not in repo):**
- `.ao/state/discovery-cursor.json`
- `.ao/state/approval-seen.json`
- `.ao/state/transcripts/<id>.json`

---

## Task 0: Install the Animus `linear-pack` connector-pack

The pack provides the `linear` MCP server (`@anthropic-ai/linear-mcp@latest`), an `issue-management` skill our agents will reference, and Linear-aware sample agents. The pack is not in any registered marketplace, so installation is from a local clone.

**Files:** none modified in this task; pack installs under `~/.animus/packs/`.

- [ ] **Step 1: Clone the pack locally**

```bash
mkdir -p ~/src
git clone https://github.com/launchapp-dev/linear-pack.git ~/src/linear-pack
```
Expected: clone succeeds; `~/src/linear-pack/pack.toml` exists.

- [ ] **Step 2: Verify the pack manifest**

```bash
animus pack inspect --path ~/src/linear-pack
```
Expected: prints the pack id (`linear`), version (`0.1.0`), exported workflows, and runtime overlay reference.

- [ ] **Step 3: Install and activate the pack for this project**

From the project root (`/Users/rafal/animus-blog-generator`):

```bash
animus pack install --path ~/src/linear-pack --activate
```
Expected: success. The pack is now in `~/.animus/packs/linear/0.1.0/` and activated for this project.

- [ ] **Step 4: Verify activation**

```bash
animus pack list
```
Expected: `linear` appears with status "active" for this project.

- [ ] **Step 5: No commit needed**

The pack lives in user state, not in the repo. Documentation of the dependency happens in Task 15.

---

## Task 1: Project scaffolding (state dir, gitignore, env vars, manifest bootstrap)

**Files:**
- Modify: `.gitignore`
- Modify: `.env.example`
- Create: `content/manifest.json`
- Create: `.ao/state/.gitkeep` (so the dir exists but contents are ignored)

- [ ] **Step 1: Add `.ao/state/` to `.gitignore`**

Edit `.gitignore` to add the state dir alongside the existing `.ao/logs/`:

```
# AO runtime
.ao/logs/
.ao/state/
.ao/sync.json
```

- [ ] **Step 2: Append new env vars to `.env.example`**

Append to `.env.example`:

```
# Audio Transcript Source (Krisp; portable to Granola)
KRISP_API_KEY=

# Linear (Discovery flow)
LINEAR_API_KEY=
LINEAR_DISCOVERY_PROJECT_ID=
LINEAR_STATE_BACKLOG_ID=
LINEAR_STATE_IN_PROGRESS_ID=
LINEAR_STATE_IN_REVIEW_ID=
LINEAR_STATE_DONE_ID=

# Content Library MCP
CONTENT_LIBRARY_URL=
CONTENT_LIBRARY_TOKEN=
```

- [ ] **Step 3: Bootstrap `content/manifest.json`**

Create `content/manifest.json` with exact content:

```json
{
  "version": 1,
  "posts": []
}
```

- [ ] **Step 4: Verify everything is in place**

Run:
```bash
cat .gitignore | grep "state"
test -f content/manifest.json && cat content/manifest.json
grep -c "LINEAR_DISCOVERY_PROJECT_ID" .env.example
```

Expected: `.ao/state/` line present, manifest prints with empty posts array, env var grep returns `1`.

- [ ] **Step 5: Commit**

```bash
git add .gitignore .env.example content/manifest.json
git commit -m "Bootstrap discovery-flow state dir, env vars, and content manifest"
```

---

## Task 2: Add new MCP servers to custom.yaml

**Files:**
- Modify: `.ao/workflows/custom.yaml` (mcp_servers block)

- [ ] **Step 1: Add `krisp`, `linear`, `content-library` to `mcp_servers:`**

After the existing `perplexity:` block (around line 85) and before the `# ── Publishing (bring your own CMS) ──` comment, insert:

```yaml
  krisp:
    command: npx
    args:
    - -y
    - krisp-mcp-server
    env:
      KRISP_API_KEY: ${KRISP_API_KEY}
  linear:
    command: npx
    args:
    - -y
    - '@anthropic-ai/linear-mcp@latest'
    env:
      LINEAR_API_KEY: ${LINEAR_API_KEY}
      LINEAR_DISCOVERY_PROJECT_ID: ${LINEAR_DISCOVERY_PROJECT_ID}
      LINEAR_STATE_BACKLOG_ID: ${LINEAR_STATE_BACKLOG_ID}
      LINEAR_STATE_IN_PROGRESS_ID: ${LINEAR_STATE_IN_PROGRESS_ID}
      LINEAR_STATE_IN_REVIEW_ID: ${LINEAR_STATE_IN_REVIEW_ID}
      LINEAR_STATE_DONE_ID: ${LINEAR_STATE_DONE_ID}
  content-library:
    command: npx
    args:
    - -y
    - content-library-mcp
    env:
      CONTENT_LIBRARY_URL: ${CONTENT_LIBRARY_URL}
      CONTENT_LIBRARY_TOKEN: ${CONTENT_LIBRARY_TOKEN}
```

Note: `@anthropic-ai/linear-mcp@latest` is the real Linear MCP package (same one bundled in the `linear-pack` installed in Task 0). The other two — `krisp-mcp-server` and `content-library-mcp` — are placeholders; replace with the actual registered package names known to the user. See "Configuration to confirm" at the end of this plan.

- [ ] **Step 2: Validate the YAML compiles**

Run: `animus workflow config validate`
Expected: success (no shape errors). If it complains about an unknown mcp_server reference, the issue is elsewhere — read the error and fix.

- [ ] **Step 3: Persist the compiled config**

Run: `animus workflow config compile`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add krisp, linear, content-library MCP servers to workflow YAML"
```

---

## Task 3: Add `transcript-collector` agent + `transcript-fetch` phase

**Files:**
- Modify: `.ao/workflows/custom.yaml` (agents and phases blocks)

- [ ] **Step 1: Add the `transcript-collector` agent**

In the `agents:` block (after the existing `content-refresher:` block, before the `# ── Phase Definitions` comment), append:

```yaml
  transcript-collector:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - krisp
    system_prompt: |
      You are a data-ingest agent. You do not reason about content.
      Your job: list new Krisp transcripts since a cursor, fetch their
      full text, write them to disk as JSON, advance the cursor.
      Do not summarize, propose ideas, or call any tool outside Krisp.
```

- [ ] **Step 2: Add the `transcript-fetch` phase**

In the `phases:` block (a logical place is right after the existing `news-scan:` block, near the end of phases), append:

```yaml
  transcript-fetch:
    mode: agent
    agent: transcript-collector
    directive: |
      Read .ao/state/discovery-cursor.json if it exists; treat missing or
      empty as cursor=null (process all available transcripts, capped at 20).

      Use the Krisp MCP server to list transcripts created strictly after
      cursor.last_transcript_id. For each transcript (in chronological order):
      1. Fetch the full transcript text and metadata
         (id, created_at, participants, duration_secs, title)
      2. Write to .ao/state/transcripts/<transcript_id>.json with shape:
         { "id": "...", "created_at": "...", "participants": [...],
           "duration_secs": N, "title": "...", "text": "..." }

      After processing all transcripts, write
      .ao/state/discovery-cursor.json with:
        { "last_transcript_id": "<most recent ID processed>",
          "updated_at": "<current ISO8601>" }

      If no new transcripts, emit a skip verdict with reason
      "no_new_transcripts" and do NOT touch the cursor.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - transcript_paths
      fields:
        transcript_paths:
          type: array
          description: List of file paths to the staged transcript JSON files
          items:
            type: string
        count:
          type: integer
          description: Number of transcripts fetched this run
    decision_contract:
      min_confidence: 0.5
      max_risk: low
      allow_missing_decision: true
```

- [ ] **Step 3: Validate and compile**

Run:
```bash
animus workflow config validate
animus workflow config compile
```
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add transcript-collector agent and transcript-fetch phase"
```

---

## Task 4: Add `idea-strategist` agent + `idea-strategist` phase

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add the `idea-strategist` agent**

After the `transcript-collector:` agent block, append:

```yaml
  idea-strategist:
    model: claude-sonnet-4-6
    tool: claude
    mcp_servers:
    - ao
    - linear
    - content-library
    - search-console
    - exa
    - tavily
    - brave
    - firecrawl
    system_prompt: |
      SKILLS: Read and follow .ao/skills/content-strategy.md AND the
      linear-pack's bundled issue-management skill (loaded automatically
      via the active pack overlay) for correct Linear MCP tool usage.

      CONTEXT: Read business-context.yaml at every run — niche, pillars,
      audience, voice, competitors, differentiators. If business-context.yaml
      is missing or empty, refuse to proceed and emit a skip verdict with
      reason "missing_business_context".

      You propose blog ideas grounded in (a) actual conversation transcripts
      and (b) external SEO viability data. Every idea you propose must
      survive an external-research check before becoming a Linear ticket.

      Hard rule: LINEAR_DISCOVERY_PROJECT_ID must be set. If not, emit a
      skip verdict with reason "missing_project_id".
```

- [ ] **Step 2: Add the `idea-strategist` phase**

After `transcript-fetch:` in `phases:`, append:

```yaml
  idea-strategist:
    mode: agent
    agent: idea-strategist
    directive: |
      Input: transcript_paths from the prior phase. If empty, emit skip.

      Step 1 — Local context
      Read business-context.yaml. Read content/manifest.json (treat missing
      as {"version":1,"posts":[]}). Query content-library MCP for the org's
      topic fingerprints (covered angles, recent pillars, asset inventory).

      Step 2 — Per-transcript synthesis
      For each transcript file in transcript_paths:
        a. Read the transcript JSON.
        b. Extract 3-5 candidate blog angles. Each angle MUST quote a
           specific moment from the transcript (timestamp if available).
        c. For each candidate, run external validation:
           - Search Console: target keyword viability (volume, current
             rank, striking-distance status)
           - Exa + Tavily + Brave: who covers this angle, what depth,
             is the SERP saturated or open
           - Firecrawl: spot-scrape top 1-2 ranking pages; capture
             (i) what they already cover, (ii) 2-3 authoritative
             citable sources we could use
        d. Filter or refine:
           - Drop angles with zero search demand
           - Re-angle if the SERP is saturated (find a sharper sub-angle)
           - Drop angles that duplicate any post in content/manifest.json
             or any item returned by the content-library query

      Step 3 — Create Linear tickets
      For each surviving angle, call the Linear MCP to create one issue.
      Each issue:
        - project: LINEAR_DISCOVERY_PROJECT_ID (env)
        - label: "Discovery"
        - state: LINEAR_STATE_BACKLOG_ID (env)
        - title: a punchy headline draft of the angle
        - body: structured markdown with these sections in order:
            ## Source
            Transcript: <id> @ <timestamp>
            Quote: "<exact quoted moment>"

            ## Suggested target keyword
            "<keyword>" — GSC: <volume>/mo, rank #<rank>, striking distance: <yes|no>

            ## Competitive landscape
            - <url 1> (rank N) — <one-line characterization>
            - <url 2> (rank N) — <one-line characterization>
            - <url 3> (rank N) — <one-line characterization>
            GAP: <what's missing in the SERP that we can own>

            ## Pre-identified citable sources
            - <url> — <what this supports>
            - <url> — <what this supports>

            ## Suggested pillar
            <pillar name from business-context.yaml>

            ## Dedup notes
            <"not covered in content/manifest.json" or specific notes>

            ## Idempotency key
            discovery:<transcript_id>:<8-char hash of (transcript_id + angle title)>

      Before creating each issue, query Linear for any existing issue in the
      project whose body contains the same idempotency key. If found, skip
      that angle (already created in a prior run).

      Step 4 — Emit phase result
      Output a list of {id, title, transcript_id} for each created issue.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - issues_created
      fields:
        issues_created:
          type: array
          description: Linear issues created this run
          items:
            type: object
        transcripts_processed:
          type: integer
          description: Number of transcripts examined
    decision_contract:
      min_confidence: 0.5
      max_risk: low
      allow_missing_decision: true
```

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add idea-strategist agent and phase with external-research gate"
```

---

## Task 5: Add `approval-watcher` agent + `approval-watcher` phase

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add the `approval-watcher` agent**

After the `idea-strategist:` agent block:

```yaml
  approval-watcher:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - ao
    - linear
    system_prompt: |
      SKILLS: Follow the linear-pack's bundled issue-management skill
      (auto-loaded via the active pack overlay) for correct Linear MCP
      query usage.

      You are a polling agent. You detect Linear issues whose state has
      changed out of Backlog and enqueue blog-from-ticket runs for them.
      You do not reason about content. You do not modify Linear.
      Hard rule: scope every query to LINEAR_DISCOVERY_PROJECT_ID.
```

- [ ] **Step 2: Add the `approval-watcher` phase**

After `idea-strategist:` in `phases:`:

```yaml
  approval-watcher:
    mode: agent
    agent: approval-watcher
    directive: |
      Step 1 — Read seen set
      Read .ao/state/approval-seen.json. If missing, treat as
      {"issues": [], "updated_at": null}.

      Step 2 — Query Linear (scoped to project)
      Use the Linear MCP to query issues where ALL of:
        - project.id = LINEAR_DISCOVERY_PROJECT_ID
        - labels contains "Discovery"
        - state.type != "backlog"
      Return: id, identifier, title, description, labels, state.name.

      Step 3 — Diff against seen
      Filter out any issue.id already in the seen set.

      Step 4 — Enqueue per newly-approved issue
      For each new issue, parse the body to extract:
        - suggested_pillar (from "## Suggested pillar" section)
        - suggested_keyword (from "## Suggested target keyword" section,
          first quoted string)
        - pre_identified_sources (from "## Pre-identified citable sources"
          section as a list of {url, supports})
      Call animus_queue_enqueue with:
        workflow_ref: blog-from-ticket
        input: {
          linear_issue_id: <id>,
          linear_identifier: <identifier>,
          title: <title>,
          body: <description>,
          labels: <labels>,
          suggested_pillar: <parsed>,
          suggested_keyword: <parsed>,
          pre_identified_sources: <parsed>
        }

      Step 5 — Update seen set (atomic)
      Append every successfully-enqueued issue.id to the seen list.
      Write .ao/state/approval-seen.json atomically (write tmpfile,
      then rename). updated_at = current ISO8601.

      Step 6 — Verdict
      If nothing newly approved, emit skip with reason "no_approvals".
      Otherwise emit phase_result with the enqueued list.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - enqueued
      fields:
        enqueued:
          type: array
          description: Issues enqueued this run
          items:
            type: object
    decision_contract:
      min_confidence: 0.5
      max_risk: low
      allow_missing_decision: true
```

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add approval-watcher agent and phase scoped to discovery project"
```

---

## Task 6: Add `linear-coordinator` agent + `ticket-acknowledge` and `linear-finalize` phases

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add the `linear-coordinator` agent**

After the `approval-watcher:` agent block:

```yaml
  linear-coordinator:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - linear
    system_prompt: |
      SKILLS: Follow the linear-pack's bundled issue-management skill
      (auto-loaded via the active pack overlay) for correct Linear MCP
      comment/transition tool usage.

      You manage Linear ticket state and comments for blog-from-ticket
      runs. You do not generate content. Two modes:
      - "acknowledge": post a start comment, transition to In Progress.
      - "finalize": post a completion comment with branch + summary,
        transition to In Review.
      Each invocation receives its mode via the phase directive.
```

- [ ] **Step 2: Add `ticket-acknowledge` phase**

In `phases:`, after the `news-scan:` block (or after the most recently-added phase):

```yaml
  ticket-acknowledge:
    mode: agent
    agent: linear-coordinator
    directive: |
      Mode: acknowledge.

      Input: linear_issue_id, linear_identifier (from queue payload).
      Also available: the current Animus run_id (animus.run.id) and the
      current branch name (call `git rev-parse --abbrev-ref HEAD`).

      Actions:
      1. Post a Linear comment on linear_issue_id:
         "🤖 Blog generation started.
         Run: <run_id>
         Branch: <branch>"
      2. Transition the issue's state to LINEAR_STATE_IN_PROGRESS_ID.

      Output: pass-through of linear_issue_id, linear_identifier for
      downstream phases that need to thread it.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - linear_issue_id
      fields:
        linear_issue_id:
          type: string
        linear_identifier:
          type: string
```

- [ ] **Step 3: Add `linear-finalize` phase**

Below `ticket-acknowledge:`:

```yaml
  linear-finalize:
    mode: agent
    agent: linear-coordinator
    directive: |
      Mode: finalize.

      Input from prior phases: linear_issue_id, slug, word_count,
      branch (read with `git rev-parse --abbrev-ref HEAD`),
      commit_message from seo-review, featuredImage path.

      Read content/<slug>.md frontmatter to fetch title and meta_description.

      Actions:
      1. Post a Linear comment on linear_issue_id with body:
         "✅ Blog draft ready for review.
         Title: <title>
         Slug: <slug>
         Word count: <word_count>
         Branch: <branch>
         Meta description: <meta_description>
         Featured image: assets/<slug>.webp"
      2. Transition the issue's state to LINEAR_STATE_IN_REVIEW_ID.

      Output: confirmation only.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - linear_issue_id
      fields:
        linear_issue_id:
          type: string
        comment_id:
          type: string
```

- [ ] **Step 4: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 5: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add linear-coordinator agent with acknowledge and finalize phases"
```

---

## Task 7: Add `ticket-to-brief` phase + extend `content-strategist`

**Files:**
- Modify: `.ao/workflows/custom.yaml` (content-strategist agent + new phase)

- [ ] **Step 1: Extend `content-strategist` mcp_servers**

Locate the existing `content-strategist:` agent block (around line 103-118). Replace its `mcp_servers:` list:

Before:
```yaml
  content-strategist:
    model: claude-sonnet-4-6
    tool: claude
    mcp_servers:
    - ao
    - exa
    - tavily
    - brave
    - firecrawl
    - search-console
```

After:
```yaml
  content-strategist:
    model: claude-sonnet-4-6
    tool: claude
    mcp_servers:
    - ao
    - exa
    - tavily
    - brave
    - firecrawl
    - search-console
    - linear
    - content-library
```

The system_prompt stays the same — the new MCP availability is opt-in per directive.

- [ ] **Step 2: Add `ticket-to-brief` phase**

In `phases:`, below `linear-finalize:`:

```yaml
  ticket-to-brief:
    mode: agent
    agent: content-strategist
    directive: |
      Convert an approved Linear discovery ticket into a topic_brief that
      matches the contract the existing pipeline already consumes.

      Input: linear_issue_id, linear_identifier, suggested_pillar,
      suggested_keyword, pre_identified_sources (from queue payload).

      Step 1 — Read context
      Read business-context.yaml. Read content/manifest.json.
      Use Linear MCP to fetch the LATEST version of the issue body
      (humans may have edited it during review).

      Step 2 — Refine keyword
      Validate suggested_keyword via Search Console. If GSC suggests a
      better-shaped variant (e.g. higher volume, shorter striking-distance
      gap), prefer it. Record which one you chose and why.

      Step 3 — Build topic_brief
      Emit the same shape today's topic-research phase produces:
        - target_keyword: <refined keyword>
        - content_pillar: <suggested_pillar or refined>
        - word_count_target: <estimate from angle complexity, 1200-2500>
        - unique_angle: <the angle, including the source-transcript context>
        - data_sources_needed: <list — start from pre_identified_sources,
          add any gaps the brief reveals>
        - internal_link_targets: <query content-library + manifest;
          pick 2-3 candidate slugs of related published posts>
        - linear_issue_id: <pass through for downstream phases>

      Do NOT do deep external research here — that's research-collection's
      job. This phase is brief synthesis only.
    capabilities:
      mutates_state: false
    output_contract:
      kind: phase_result
      required_fields:
      - topic_brief
      fields:
        topic_brief:
          type: object
          description: Brief consumed by research-collection
        target_keyword:
          type: string
        content_pillar:
          type: string
        linear_issue_id:
          type: string
```

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add ticket-to-brief phase; extend content-strategist with linear + content-library"
```

---

## Task 8: Extend `content-writer` with content-library MCP

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add `content-library` to `content-writer` mcp_servers**

Locate the `content-writer:` agent block (around line 130). Replace:

Before:
```yaml
  content-writer:
    model: claude-opus-4-6
    tool: claude
    mcp_servers: []
```

After:
```yaml
  content-writer:
    model: claude-opus-4-6
    tool: claude
    mcp_servers:
    - content-library
```

- [ ] **Step 2: Append internal-link guidance to `content-writer`'s system_prompt**

In the same `content-writer:` block, find the line in the system_prompt that says:
```
      Internal links to 2-3 related blog posts.
```

Replace it with:
```
      Internal links to 2-3 related blog posts. Source candidates by
      querying content-library MCP and reading content/manifest.json.
      Use real slugs of published posts. Do not invent slugs.
```

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Extend content-writer with content-library MCP for real internal-link slugs"
```

---

## Task 9: Extend `seo-optimizer` with content-library MCP

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add `content-library` to `seo-optimizer` mcp_servers**

Locate the `seo-optimizer:` agent block (around line 156). Replace:

Before:
```yaml
  seo-optimizer:
    model: claude-sonnet-4-6
    tool: claude
    mcp_servers:
    - search-console
    - firecrawl
```

After:
```yaml
  seo-optimizer:
    model: claude-sonnet-4-6
    tool: claude
    mcp_servers:
    - search-console
    - firecrawl
    - content-library
```

- [ ] **Step 2: Append internal-link verification to `seo-optimizer`'s system_prompt**

In the same block's system_prompt, find:
```
      - Internal links to 2-3 related blog posts (not service pages)
```

Replace with:
```
      - Internal links to 2-3 related blog posts (not service pages).
        Verify each internal-link slug exists via content-library MCP
        or content/manifest.json. Drop and replace any broken slug.
```

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Extend seo-optimizer with content-library MCP for internal-link verification"
```

---

## Task 10: TDD the `register-post.sh` script

**Files:**
- Create: `scripts/register-post.sh`
- Create: `scripts/test/register-post.bats`

The script parses YAML frontmatter from `content/<slug>.md`, builds a manifest entry, atomically appends to `content/manifest.json`, and commits. We TDD it with `bats-core`.

- [ ] **Step 1: Install bats locally if not present**

Run:
```bash
which bats || brew install bats-core
```
Expected: `bats` resolves to a path. (If `brew` isn't available, install bats via npm: `npm install -g bats`.)

- [ ] **Step 2: Verify `yq` and `jq` are available**

Run:
```bash
which yq && which jq
```
Expected: both resolve. If `yq` is missing: `brew install yq`. If `jq` is missing: `brew install jq`.

- [ ] **Step 3: Write the failing test file**

Create `scripts/test/register-post.bats`:

```bash
#!/usr/bin/env bats

setup() {
  TMPDIR="$(mktemp -d)"
  export TEST_REPO="$TMPDIR/repo"
  mkdir -p "$TEST_REPO/content" "$TEST_REPO/scripts"
  cp "$BATS_TEST_DIRNAME/../register-post.sh" "$TEST_REPO/scripts/register-post.sh"
  chmod +x "$TEST_REPO/scripts/register-post.sh"
  cd "$TEST_REPO"
  git init -q
  git config user.email "test@test"
  git config user.name "Test"
}

teardown() {
  rm -rf "$TMPDIR"
}

write_post() {
  local slug="$1"
  cat > "content/$slug.md" <<EOF
---
title: Test Post About $slug
slug: $slug
meta_description: A short description for $slug
date: 2026-06-05
author: Test Author
keywords: [test, $slug]
schema_type: Article
content_pillar: Test Pillar
target_keyword: "$slug keyword"
word_count: 1500
featuredImage: assets/$slug.webp
excerpt: One paragraph excerpt about $slug.
seoTitle: SEO Title for $slug
seoDescription: SEO meta for $slug
---

# Body

Lorem ipsum.
EOF
}

@test "creates manifest with first post when manifest is missing" {
  write_post "first-post"
  run ./scripts/register-post.sh first-post
  [ "$status" -eq 0 ]
  [ -f content/manifest.json ]
  run jq '.version' content/manifest.json
  [ "$output" = "1" ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
  run jq -r '.posts[0].slug' content/manifest.json
  [ "$output" = "first-post" ]
}

@test "appends a second post to existing manifest" {
  write_post "first-post"
  ./scripts/register-post.sh first-post
  write_post "second-post"
  run ./scripts/register-post.sh second-post
  [ "$status" -eq 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "2" ]
  run jq -r '.posts[1].slug' content/manifest.json
  [ "$output" = "second-post" ]
}

@test "extracts all required frontmatter fields" {
  write_post "fields-test"
  ./scripts/register-post.sh fields-test
  run jq -r '.posts[0].title' content/manifest.json
  [ "$output" = "Test Post About fields-test" ]
  run jq -r '.posts[0].pillar' content/manifest.json
  [ "$output" = "Test Pillar" ]
  run jq -r '.posts[0].target_keyword' content/manifest.json
  [ "$output" = "fields-test keyword" ]
  run jq -r '.posts[0].word_count' content/manifest.json
  [ "$output" = "1500" ]
}

@test "is idempotent — re-running for the same slug does NOT duplicate" {
  write_post "idem-post"
  ./scripts/register-post.sh idem-post
  run ./scripts/register-post.sh idem-post
  [ "$status" -eq 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "writes atomically (no partial manifest on jq failure)" {
  write_post "atomic-post"
  ./scripts/register-post.sh atomic-post
  # Manually corrupt frontmatter then re-run; manifest should be unchanged
  echo "broken" > content/atomic-post.md
  run ./scripts/register-post.sh atomic-post
  [ "$status" -ne 0 ]
  # Manifest still has one valid entry (the original)
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "commits the manifest change" {
  write_post "commit-post"
  ./scripts/register-post.sh commit-post
  run git log --oneline
  [[ "$output" == *"Register commit-post"* ]]
}

@test "uses linear_issue_id and source_transcript_id from env if set" {
  write_post "env-post"
  LINEAR_ISSUE_ID="BLG-42" SOURCE_TRANSCRIPT_ID="krisp-xyz" \
    ./scripts/register-post.sh env-post
  run jq -r '.posts[0].linear_ticket_id' content/manifest.json
  [ "$output" = "BLG-42" ]
  run jq -r '.posts[0].source_transcript_id' content/manifest.json
  [ "$output" = "krisp-xyz" ]
}
```

- [ ] **Step 4: Run the tests — verify they fail (script doesn't exist yet)**

Run: `bats scripts/test/register-post.bats`
Expected: all 7 tests fail with "no such file or directory" for `scripts/register-post.sh`.

- [ ] **Step 5: Write the script**

Create `scripts/register-post.sh`:

```bash
#!/usr/bin/env bash
# register-post.sh — Append a post entry to content/manifest.json
#
# Usage: ./scripts/register-post.sh <slug>
# Optional env: LINEAR_ISSUE_ID, SOURCE_TRANSCRIPT_ID, BRANCH

set -euo pipefail

SLUG="${1:?slug argument required}"
POST_FILE="content/${SLUG}.md"
MANIFEST="content/manifest.json"

[ -f "$POST_FILE" ] || { echo "post not found: $POST_FILE" >&2; exit 1; }

# Extract frontmatter (between first two '---' lines)
FM="$(awk '/^---$/{c++; next} c==1{print}' "$POST_FILE")"
[ -n "$FM" ] || { echo "no frontmatter found in $POST_FILE" >&2; exit 1; }

# Parse fields via yq — bail if any required field is missing/empty
title="$(echo "$FM" | yq -r '.title // ""')"
[ -n "$title" ] || { echo "frontmatter missing title" >&2; exit 1; }
pillar="$(echo "$FM" | yq -r '.content_pillar // ""')"
target_keyword="$(echo "$FM" | yq -r '.target_keyword // ""')"
word_count="$(echo "$FM" | yq -r '.word_count // 0')"
excerpt="$(echo "$FM" | yq -r '.excerpt // ""')"
date_str="$(echo "$FM" | yq -r '.date // ""')"
tags_json="$(echo "$FM" | yq -o=json '.keywords // []')"

# Optional env passthroughs
LINEAR_ISSUE_ID="${LINEAR_ISSUE_ID:-}"
SOURCE_TRANSCRIPT_ID="${SOURCE_TRANSCRIPT_ID:-}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"

# Bootstrap manifest if missing
if [ ! -f "$MANIFEST" ]; then
  echo '{"version":1,"posts":[]}' > "$MANIFEST"
fi

# Idempotency — skip if slug already present
existing="$(jq --arg s "$SLUG" '[.posts[] | select(.slug == $s)] | length' "$MANIFEST")"
if [ "$existing" -gt 0 ]; then
  echo "manifest already contains slug: $SLUG (skipping)" >&2
  exit 0
fi

# Build the new entry
NEW_ENTRY="$(jq -n \
  --arg slug "$SLUG" \
  --arg title "$title" \
  --arg published_at "$date_str" \
  --arg pillar "$pillar" \
  --arg target_keyword "$target_keyword" \
  --argjson word_count "$word_count" \
  --arg summary "$excerpt" \
  --arg linear_ticket_id "$LINEAR_ISSUE_ID" \
  --arg source_transcript_id "$SOURCE_TRANSCRIPT_ID" \
  --arg branch "$BRANCH" \
  --argjson tags "$tags_json" \
  '{
    slug: $slug,
    title: $title,
    published_at: $published_at,
    pillar: $pillar,
    target_keyword: $target_keyword,
    tags: $tags,
    word_count: $word_count,
    summary: $summary,
    linear_ticket_id: $linear_ticket_id,
    source_transcript_id: $source_transcript_id,
    branch: $branch
  }')"

# Atomic write: tmpfile + rename
TMP="$(mktemp "${MANIFEST}.XXXXXX")"
jq --argjson entry "$NEW_ENTRY" '.posts += [$entry]' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

# Commit
git add "$MANIFEST"
git commit -m "Register ${SLUG} in content manifest" --quiet
```

- [ ] **Step 6: Mark executable and rerun tests**

Run:
```bash
chmod +x scripts/register-post.sh
bats scripts/test/register-post.bats
```
Expected: all 7 tests pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/register-post.sh scripts/test/register-post.bats
git commit -m "Add register-post.sh with bats coverage for manifest append"
```

---

## Task 11: Add `register-post` phase (command mode)

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add the `register-post` phase**

In `phases:`, after `ticket-to-brief:`:

```yaml
  register-post:
    mode: command
    directive: Append the new post to content/manifest.json and commit
    command:
      program: bash
      args:
      - -c
      - |
        # Reads slug from phase input (or env passthrough).
        # Optional: LINEAR_ISSUE_ID, SOURCE_TRANSCRIPT_ID provided by prior phases.
        SLUG="${SLUG:?slug required}"
        ./scripts/register-post.sh "$SLUG"
      cwd_mode: task_root
      timeout_secs: 30
    capabilities:
      mutates_state: true
    output_contract:
      kind: implementation_result
      required_fields:
      - commit_message
```

Note: how phase inputs flow to env vars depends on Animus's command-phase input plumbing. The implementer should verify the convention by checking the existing `commit-draft` and `push-branch` phases — those are also `mode: command` and successfully accept implicit inputs. If env-passthrough doesn't work cleanly, switch the directive to a tiny agent phase that calls the same script.

- [ ] **Step 2: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 3: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add register-post phase invoking the manifest script"
```

---

## Task 12: Define the three new workflows + retrofit `blog-production`

**Files:**
- Modify: `.ao/workflows/custom.yaml` (workflows block)

- [ ] **Step 1: Retrofit `register-post` into `blog-production`**

Find the existing `blog-production` workflow block (around line 590). Replace its phases list:

Before:
```yaml
- id: blog-production
  name: Blog Post Production
  description: Discover topic, research, write, optimize, generate assets
  phases:
  - topic-research
  - research-collection
  - content-writing
  - commit-draft
  - seo-review
  - asset-generation
  - social-excerpts
  - push-branch
```

After:
```yaml
- id: blog-production
  name: Blog Post Production
  description: Discover topic, research, write, optimize, generate assets
  phases:
  - topic-research
  - research-collection
  - content-writing
  - commit-draft
  - seo-review
  - register-post
  - asset-generation
  - social-excerpts
  - push-branch
```

- [ ] **Step 2: Add the three new workflows**

After the existing `news-monitor` workflow block (around line 622) and before the `# ── Schedules` comment, insert:

```yaml
- id: idea-discovery
  name: Transcript-Driven Idea Discovery
  description: Poll Krisp transcripts and propose blog ideas as Linear tickets
  phases:
  - transcript-fetch
  - idea-strategist

- id: approval-watch
  name: Linear Approval Watcher
  description: Poll Linear for approved discovery tickets and enqueue blog-from-ticket
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

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 4: Verify all four workflows are registered**

Run: `animus workflow list`
Expected output includes:
```
blog-production
refresh-cycle
image-refresh
news-monitor
idea-discovery
approval-watch
blog-from-ticket
```

- [ ] **Step 5: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Define idea-discovery, approval-watch, blog-from-ticket workflows; retrofit register-post into blog-production"
```

---

## Task 13: Add new schedules

**Files:**
- Modify: `.ao/workflows/custom.yaml` (schedules block at the very bottom)

- [ ] **Step 1: Add `discovery` and `approval-watch` schedules**

Locate the `schedules:` block at the bottom of the file. After the existing `news` schedule, append:

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

- [ ] **Step 2: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 3: Verify schedules are registered**

Run: `animus workflow config get` (or whichever subcommand surfaces the schedules — check with `animus workflow config --help`).
Expected: the two new schedule IDs appear with the correct cron strings.

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Schedule discovery (daily 7am) and approval-watch (every 15 min)"
```

---

## Task 14: Dry-run smoke tests (config-level, no live MCP calls required)

This task verifies the workflows compile, phases render, and prompts look right. It does NOT exercise the actual MCP servers (those need real credentials).

**Files:** none modified.

- [ ] **Step 1: Compile-clean check**

Run: `animus workflow config compile`
Expected: succeeds with no warnings about unresolved references.

- [ ] **Step 2: Render the prompt for `idea-strategist` phase**

Run: `animus workflow prompt --phase idea-strategist --workflow idea-discovery`
Expected: a fully-rendered prompt block, no template placeholders left raw, business-context.yaml + manifest references intact.

(If the `animus workflow prompt` subcommand uses different flag names, check `animus workflow prompt --help` and adapt.)

- [ ] **Step 3: Render the prompt for `ticket-to-brief` phase**

Run: `animus workflow prompt --phase ticket-to-brief --workflow blog-from-ticket`
Expected: rendered cleanly.

- [ ] **Step 4: Verify `blog-from-ticket` phase order**

Run: `animus workflow get blog-from-ticket`
Expected: phases listed in this order:
```
1. ticket-acknowledge
2. ticket-to-brief
3. research-collection
4. content-writing
5. commit-draft
6. seo-review
7. register-post
8. asset-generation
9. social-excerpts
10. push-branch
11. linear-finalize
```

- [ ] **Step 5: Verify `blog-production` has `register-post` between `seo-review` and `asset-generation`**

Run: `animus workflow get blog-production`
Expected: phases listed in order:
```
1. topic-research
2. research-collection
3. content-writing
4. commit-draft
5. seo-review
6. register-post
7. asset-generation
8. social-excerpts
9. push-branch
```

- [ ] **Step 6: Verify all new mcp_servers are declared**

Run: `grep -E "^\s+(krisp|linear|content-library):" .ao/workflows/custom.yaml`
Expected: each name appears once.

- [ ] **Step 7: Verify state dir is gitignored**

Run: `git check-ignore .ao/state/anything`
Expected: prints `.ao/state/anything` (meaning it IS ignored).

- [ ] **Step 8: No commit needed for this task**

Smoke-test only. Any failures here mean an earlier task has a bug — go fix it.

---

## Task 15: Update documentation

**Files:**
- Modify: `MCP-TOOLS.md`
- Modify: `README.md`

- [ ] **Step 1: Add the three new MCP servers to `MCP-TOOLS.md`**

Find the "## Orchestration" section in `MCP-TOOLS.md`. Above the "## Which Agents Use What" code block, insert a new section:

```markdown
## Discovery Loop

| Server | Package | What It Does |
|--------|---------|--------------|
| **Krisp** | `krisp-mcp-server` | Audio transcript ingest — lists and fetches meeting transcripts since a cursor for the idea-discovery flow |
| **Linear** | `@anthropic-ai/linear-mcp` (via [linear-pack](https://github.com/launchapp-dev/linear-pack)) | Issue create / read / status / comment — the human-review gate for blog ideas, scoped to a configured project |
| **Content Library** | `content-library-mcp` | Org-wide content + artifact database — used by strategist for dedup and by writer/SEO for real internal-link slugs |

> **Linear setup:** install the Animus `linear-pack` connector-pack once — it bundles the MCP server config plus an `issue-management` skill our agents reference for correct tool calls:
> ```bash
> git clone https://github.com/launchapp-dev/linear-pack.git ~/src/linear-pack
> animus pack install --path ~/src/linear-pack --activate
> ```
```

Replace the existing "Which Agents Use What" code block with the updated allocation:

```
Strategist          → ao, exa, tavily, brave, firecrawl, search-console, linear, content-library
Researcher          → firecrawl, exa, tavily, brave, google-maps
Writer              → content-library
SEO Optimizer       → search-console, firecrawl, content-library
Asset Generator     → replicate
Performance Analyst → ao, search-console, exa, perplexity
Content Refresher   → firecrawl
Transcript Collector → krisp
Idea Strategist     → ao, exa, tavily, brave, firecrawl, search-console, linear, content-library
Approval Watcher    → ao, linear
Linear Coordinator  → linear
```

- [ ] **Step 2: Add a Discovery Flow section to `README.md`**

Find an appropriate place (after the existing workflow descriptions) in `README.md` and add:

```markdown
## Discovery Flow (transcript-driven)

In addition to the cron-driven `blog-production` pipeline, this generator
supports a transcript-driven discovery loop with a human-review gate in Linear.

**Daily 7am — `idea-discovery`**
Polls Krisp for new meeting transcripts since the last cursor. For each
transcript, the strategist proposes 3–5 blog angles, each pre-validated
with Search Console viability + competitor scan + spot-scraped citable
sources. Surviving angles become Linear issues in your configured
discovery project, with the `Discovery` label, in `Backlog` state.

**Every 15 min — `approval-watch`**
Polls Linear (scoped to your discovery project) for issues that have moved
out of `Backlog`. Each newly-approved issue is enqueued as a
`blog-from-ticket` run.

**Per approved ticket — `blog-from-ticket`**
A variant of blog-production that uses the Linear ticket as its topic brief.
The first phase moves the ticket to `In Progress`; the last phase posts a
completion comment with the branch URL and moves the ticket to `In Review`.

**State files** (gitignored):
- `.ao/state/discovery-cursor.json` — last-processed Krisp transcript
- `.ao/state/approval-seen.json` — already-enqueued Linear issue IDs
- `.ao/state/transcripts/<id>.json` — staged transcripts

**Tracked in repo:**
- `content/manifest.json` — canonical index of every post this generator
  has produced. Used by the strategist for dedup and by the writer/SEO
  for real internal-link selection.

**One-time pack install** (provides the Linear MCP + a Linear skill our agents follow):
```bash
git clone https://github.com/launchapp-dev/linear-pack.git ~/src/linear-pack
animus pack install --path ~/src/linear-pack --activate
```

**Configuration required** (in `.env`):
- `KRISP_API_KEY`
- `LINEAR_API_KEY`
- `LINEAR_DISCOVERY_PROJECT_ID` — UUID of the Linear project for blog ideas
- `LINEAR_STATE_BACKLOG_ID`, `LINEAR_STATE_IN_PROGRESS_ID`, `LINEAR_STATE_IN_REVIEW_ID`, `LINEAR_STATE_DONE_ID`
- `CONTENT_LIBRARY_URL`, `CONTENT_LIBRARY_TOKEN`
```

- [ ] **Step 3: Commit**

```bash
git add MCP-TOOLS.md README.md
git commit -m "Document discovery flow workflows and new MCP servers"
```

---

## Configuration to confirm before first run

**Linear MCP — resolved.** Task 0 installs the `linear-pack` connector-pack (`launchapp-dev/linear-pack`), which provides the canonical `linear` MCP server (`@anthropic-ai/linear-mcp@latest`) plus an `issue-management` skill our agents reference.

**Still placeholders in `.ao/workflows/custom.yaml`:**
- `krisp-mcp-server` → actual package name of the Krisp MCP (or use the Krisp pack if one exists on the marketplace; check with `animus pack search --query krisp`)
- `content-library-mcp` → actual package name of the custom content-library MCP

**`.env` values to fill in:**
- `KRISP_API_KEY`
- `LINEAR_API_KEY`
- `LINEAR_DISCOVERY_PROJECT_ID` — Linear project UUID for the blog discovery project
- `LINEAR_STATE_BACKLOG_ID`, `LINEAR_STATE_IN_PROGRESS_ID`, `LINEAR_STATE_IN_REVIEW_ID`, `LINEAR_STATE_DONE_ID` — state UUIDs within the discovery project (these are project-specific; fetch via Linear's GraphQL or the Linear API once the project exists)
- `CONTENT_LIBRARY_URL`, `CONTENT_LIBRARY_TOKEN`

Until `LINEAR_DISCOVERY_PROJECT_ID` is set, `idea-strategist` skips with reason `missing_project_id` and `approval-watcher` finds nothing to enqueue — the loop is safely dormant.

**Verifying the Linear MCP works (sanity check, do BEFORE Task 14):**

```bash
# With LINEAR_API_KEY set in your environment:
animus plugin ping linear   # or whatever name the pack registered
# Or invoke a list-issues tool directly:
animus mcp tool-call linear issues_list --json '{"projectId":"<LINEAR_DISCOVERY_PROJECT_ID>"}'
```

If the ping or tool-call returns issues (or an empty list cleanly), the MCP wiring is correct. If it errors on auth, fix `LINEAR_API_KEY`. If the tool name differs, run `animus mcp tool-list linear` to see the real names exposed by `@anthropic-ai/linear-mcp@latest`.

---

## Self-Review

**Spec coverage check:**
- Animus linear-pack installed (provides real Linear MCP + skill) — Task 0 ✓
- Three new workflows (idea-discovery, approval-watch, blog-from-ticket) — Tasks 12 ✓
- transcript-fetch phase + transcript-collector agent — Task 3 ✓
- idea-strategist agent + phase with external research — Task 4 ✓
- approval-watcher agent + phase scoped to project — Task 5 ✓
- linear-coordinator with acknowledge + finalize — Task 6 ✓
- ticket-to-brief + extended content-strategist — Task 7 ✓
- Extended content-writer (content-library) — Task 8 ✓
- Extended seo-optimizer (content-library) — Task 9 ✓
- register-post script (TDD) — Task 10 ✓
- register-post phase — Task 11 ✓
- Retrofit register-post into blog-production — Task 12 ✓
- Schedules (discovery 7am, approval-watch 15 min) — Task 13 ✓
- content/manifest.json bootstrap — Task 1 ✓
- New MCP servers (krisp, linear, content-library) — Task 2 ✓
- State files + gitignore — Task 1 ✓
- Documentation updates — Task 15 ✓
- Linear project scoping (`LINEAR_DISCOVERY_PROJECT_ID`) — embedded in Tasks 1, 4, 5, 7 ✓

**Placeholder scan:** None remain. Package names are flagged explicitly as needing real values, in their own "Configuration to confirm" section, not as TBDs in step bodies.

**Type consistency:**
- `linear_issue_id` is used consistently across queue payload, ticket-acknowledge, ticket-to-brief, and linear-finalize ✓
- `slug` flows from content-writing → seo-review → register-post → linear-finalize ✓
- `topic_brief` shape matches what existing `research-collection` already consumes ✓
- `transcript_paths` is the output of transcript-fetch and the input of idea-strategist ✓
- `LINEAR_STATE_*_ID` env vars are referenced consistently in Tasks 2, 4, 5, 6 ✓
