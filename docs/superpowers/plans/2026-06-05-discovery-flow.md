# Discovery Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an upstream `idea-discovery → human-review-in-Linear → approval-watch → blog-from-ticket` pipeline to `.ao/workflows/custom.yaml`, with Linear integrated as an **Animus subject backend** (via `animus-subject-linear` plugin) and `content/manifest.json` as the local post index.

**Architecture (revised):** Three new workflows, four new agents, eight new phases, two extended phases on existing agents, one new shell/jq script (`register-post`). Linear is **not** treated as a generic MCP server; it is a first-class Animus subject backend. The `animus_subject_*` tool surface (or `animus plugin call` dispatch path) is verified during the dependency preflight before any YAML changes happen.

**Tech Stack:** Animus v0.5.4 (workflow runner, MCP server proxy, queue, plugin system, subject backends), `animus-subject-linear` v0.1.4+, YAML for declarative pipeline, Bash + `jq` + `yq` for `register-post`, `bats-core` for shell tests.

---

## File Structure

**Created:**
- `scripts/register-post.sh` — appends post entry to `content/manifest.json`
- `scripts/test/register-post.bats` — bats tests for the script
- `content/manifest.json` — canonical index of generated posts (committed; bootstraps to `{"version": 1, "posts": []}`)

**Modified:**
- `.ao/workflows/custom.yaml` — new MCP servers (`krisp`, `content-library` — NOT `linear`), new `subjects:` block, new agents, new phases, new workflows, new schedules; extended existing agents; retrofitted `blog-production`
- `.env.example` — new env vars for Krisp, Linear subject backend, content-library
- `.gitignore` — add `.ao/state/`
- `MCP-TOOLS.md` — document the two new MCP servers + the Linear subject backend
- `README.md` — document the new workflows

**Runtime-created (not in repo):**
- `.ao/state/discovery-cursor.json`
- `.ao/state/approval-seen.json`
- `.ao/state/transcripts/<id>.json`

---

## Task -1: Dependency preflight (BEFORE any YAML work)

This task establishes ground truth for the API surface, install paths, and queue semantics that the rest of the plan depends on. **No YAML changes happen until this task is fully green.** If any step here surfaces an unexpected behavior, the plan revises before proceeding.

**Files:** none modified.

- [ ] **Step 1: Confirm Animus version**

```bash
animus --version
```
Expected: `animus 0.5.4` or higher.

- [ ] **Step 2: Install `animus-subject-linear`**

```bash
animus plugin install launchapp-dev/animus-subject-linear
```
Expected: a release asset is downloaded, manifest check passes, and the plugin binary lands in `~/.animus/plugins/`. Note the version installed.

- [ ] **Step 3: Verify the plugin is discovered**

```bash
animus plugin list
```
Expected: output JSON includes `animus-subject-linear` with `plugin_kind = "subject_backend"`.

- [ ] **Step 4: Inspect the plugin's manifest + capabilities**

```bash
animus plugin info --name animus-subject-linear
```
Expected: prints the manifest (schema, version, plugin_kind=subject_backend, capabilities) and lists the JSON-RPC methods exposed (likely `subject.list`, `subject.get`, `subject.create`, `subject.update`, `subject.comment` — verify the exact method names from the output).

- [ ] **Step 5: Ping the plugin**

```bash
LINEAR_API_TOKEN="$LINEAR_API_TOKEN" animus plugin ping --name animus-subject-linear
```
Expected: handshake completes and ping succeeds. If it fails on missing env, you'll know which env var the plugin actually wants (`LINEAR_API_TOKEN` vs `LINEAR_API_KEY` — match what shows up).

- [ ] **Step 6: Verify a read-only list call works**

```bash
animus plugin call --name animus-subject-linear --method subject.list \
  --params '{"team": "<YOUR_TEAM_KEY>", "limit": 5}'
```
Expected: returns a list of subjects (possibly empty) without auth errors. Adapt method name + param shape to match what `plugin info` showed in step 4. Record the exact method names and param shapes for use in agent directives later.

- [ ] **Step 7: Determine whether `animus_subject_*` MCP tools are exposed**

```bash
# Start a temporary ao MCP serve and inspect the tool list
animus mcp serve --help        # confirm subcommand exists
# In another terminal or via tool listing helpers:
animus plugin list --include-system-path
```
What we're checking: does the `ao` MCP server (which agents already use) expose subject CRUD as `animus_subject_*` tools, or do agents need to invoke `animus plugin call` from Bash to interact with Linear?

If the MCP tools exist: agent directives reference them directly.
If they don't: agent directives invoke via Bash (`animus plugin call --name animus-subject-linear --method subject.create --params '...'`).

**Record which path applies — every agent directive that touches Linear is written against that path.**

- [ ] **Step 8: Verify queue input propagation with a disposable workflow**

Create a throwaway test workflow that proves `animus_queue_enqueue`'s `input` field reaches the dispatched workflow's first phase as accessible state. Steps:

1. Write a one-phase workflow `phase-input-probe` whose single phase prints `{{input}}` (or the equivalent template variable) and exits.
2. Add it to a scratch YAML, compile.
3. Enqueue it with a known input: `animus queue enqueue --workflow-ref phase-input-probe --input-json '{"probe":"hello"}'`
4. Wait for it to run; check the phase output. Confirm the input was reachable.
5. Document the exact variable/template syntax the first phase used to read the input — this is what `blog-from-ticket`'s `ticket-acknowledge` will use.

Expected outcome: input flows through, OR you discover the limitation and the plan adapts (e.g., persists the input to a state file rather than queue payload).

Clean up the disposable workflow at the end of this step.

- [ ] **Step 9: Determine subject wire-ID semantics**

Use the plugin's list call to fetch a real subject. Observe whether the ID format is `linear:<id>`, `linear-discovery:<id>` (the local alias), bare Linear UUID, or something else. This is what the queue payload's `subject_id` field will carry.

**Decision point:** based on whether the wire ID embeds the kind prefix:
- If it embeds `linear-discovery:<id>` → queue payload is `{subject_id: "linear-discovery:LIN-123"}` and approval-watcher only needs to query its single subject alias.
- If wire IDs are bare → queue payload is `{subject_id: "LIN-123", subject_kind: "linear-discovery"}` and downstream phases use both fields.

Document which path applies.

- [ ] **Step 10: Verify Krisp and content-library MCP server names**

Ask the user (or check `.mcp.json` / configuration notes) for the actual registered package names for the Krisp MCP and the custom content-library MCP. If unknown, mark them as **external prerequisites** that must be resolved before Task 2.

- [ ] **Step 11: Record preflight outcomes**

Create `.ao/state/preflight-discovery-flow.md` (gitignored — it's a local note) containing:
- Animus version
- `animus-subject-linear` version installed
- Method names + param shapes recorded from steps 4 and 6
- MCP tool path vs `animus plugin call` path decision from step 7
- Queue input syntax from step 8
- Wire ID format from step 9
- Krisp / content-library package name resolution

This document is referenced by every subsequent task that needs to know the exact API call shape.

- [ ] **Step 12: No commit needed for preflight**

The preflight changes user state (`~/.animus/plugins/`) but not the repo. Outcomes feed into the rest of the plan.

---

## Task 0: Project scaffolding (state dir, gitignore, env vars, manifest bootstrap)

**Files:**
- Modify: `.gitignore`
- Modify: `.env.example`
- Create: `content/manifest.json`

- [ ] **Step 1: Add `.ao/state/` to `.gitignore`**

Edit `.gitignore` to add (alongside the existing `.ao/logs/`):

```
# AO runtime
.ao/logs/
.ao/state/
.ao/sync.json
```

**No `.gitkeep`.** Phases that need the directory will `mkdir -p` it. This avoids the "ignored dir + tracked gitkeep" trap.

- [ ] **Step 2: Append new env vars to `.env.example`**

Append:

```
# Audio Transcript Source (Krisp; portable to Granola)
KRISP_API_KEY=

# Linear (via animus-subject-linear plugin)
LINEAR_API_TOKEN=
LINEAR_TEAM=                           # Linear team key (e.g. ENG, BLG)
LINEAR_DISCOVERY_PROJECT_ID=           # Project UUID for blog ideas
LINEAR_STATUS_MAP=                     # Optional JSON override (see plugin README)
LINEAR_FINALIZE_TRANSITION=            # Optional: set to "Done" to auto-complete on finalize; unset = no transition

# Content Library MCP
CONTENT_LIBRARY_URL=
CONTENT_LIBRARY_TOKEN=
```

**Note** what's NOT in the env list: granular per-state IDs (`LINEAR_STATE_BACKLOG_ID` / `IN_PROGRESS_ID` / `IN_REVIEW_ID` / `DONE_ID`). The subject plugin auto-maps by `WorkflowState.type`, so the granular UUIDs are unnecessary. Override only via `LINEAR_STATUS_MAP` if needed.

- [ ] **Step 3: Bootstrap `content/manifest.json`**

Create `content/manifest.json` with exact content:

```json
{
  "version": 1,
  "posts": []
}
```

- [ ] **Step 4: Verify**

```bash
grep "state" .gitignore
test -f content/manifest.json && cat content/manifest.json
grep -c "LINEAR_DISCOVERY_PROJECT_ID" .env.example
grep -c "LINEAR_STATE_BACKLOG_ID" .env.example
```
Expected: state line present, manifest prints with empty posts array, project_id grep returns `1`, state_backlog grep returns `0` (we did NOT add per-state IDs).

- [ ] **Step 5: Commit**

```bash
git add .gitignore .env.example content/manifest.json
git commit -m "Bootstrap discovery-flow state dir, env vars, and content manifest"
```

---

## Task 1: Add Krisp + content-library MCP servers (no Linear MCP)

**Files:**
- Modify: `.ao/workflows/custom.yaml` (mcp_servers block)

- [ ] **Step 1: Add `krisp` and `content-library` to `mcp_servers:`**

After the existing `perplexity:` block and before the `# ── Publishing (bring your own CMS)` comment, insert:

```yaml
  krisp:
    command: npx
    args:
    - -y
    - <KRISP_PACKAGE_NAME>           # from preflight Step 10
    env:
      KRISP_API_KEY: ${KRISP_API_KEY}
  content-library:
    command: npx
    args:
    - -y
    - <CONTENT_LIBRARY_PACKAGE_NAME>  # from preflight Step 10
    env:
      CONTENT_LIBRARY_URL: ${CONTENT_LIBRARY_URL}
      CONTENT_LIBRARY_TOKEN: ${CONTENT_LIBRARY_TOKEN}
```

**Linear is intentionally NOT added here.** It's a subject backend, declared in the next step.

- [ ] **Step 2: Add the `subjects:` block declaring the Linear subject backend**

If the YAML doesn't already have a top-level `subjects:` block, add it after `mcp_servers:` and before `agents:`:

```yaml
subjects:
  linear-discovery:
    plugin: animus-subject-linear
    config:
      api_token_env: LINEAR_API_TOKEN
      team: ${LINEAR_TEAM}
      project_id: ${LINEAR_DISCOVERY_PROJECT_ID}
```

The local alias `linear-discovery` is what phases and queue payloads reference.

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```
Expected: both succeed. If the `subjects:` schema isn't recognized, check the `animus-workflow-authoring` skill for the exact key name in v0.5.4 (it may be `subject_backends:` or similar — adjust to match).

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add krisp + content-library MCP servers and linear-discovery subject backend"
```

---

## Task 2: Add `transcript-collector` agent + `transcript-fetch` phase

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add the `transcript-collector` agent**

In the `agents:` block, append:

```yaml
  transcript-collector:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - krisp
    system_prompt: |
      You are a data-ingest agent. You do not reason about content.
      Your job: list new Krisp transcripts since a cursor and stage them
      to disk. You do NOT advance the cursor — the next phase does, only
      after successful processing.
```

- [ ] **Step 2: Add the `transcript-fetch` phase**

In the `phases:` block:

```yaml
  transcript-fetch:
    mode: agent
    agent: transcript-collector
    directive: |
      Read .ao/state/discovery-cursor.json if it exists. Use
      cursor.last_processed_at as the timestamp cutoff (preferred over
      last_processed_id since Krisp IDs may not be sortable). If the
      cursor file is missing, treat as cutoff=null but cap fetch at 20.

      Ensure the staging directory exists:
        mkdir -p .ao/state/transcripts

      Use the Krisp MCP server to list transcripts created strictly
      after the cutoff. For each transcript (in chronological order):
      1. Fetch full transcript text and metadata
         (id, created_at, participants, duration_secs, title)
      2. Write to .ao/state/transcripts/<transcript_id>.json with shape:
         { "id": "...", "created_at": "<ISO8601>",
           "participants": [...], "duration_secs": N,
           "title": "...", "text": "..." }

      DO NOT touch .ao/state/discovery-cursor.json. The idea-strategist
      phase advances it per-transcript on successful processing.

      If no new transcripts, emit a skip verdict with reason
      "no_new_transcripts".
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
git commit -m "Add transcript-collector agent and transcript-fetch phase (cursor advance deferred)"
```

---

## Task 3: Add `idea-strategist` agent + phase (Linear via subject API)

**Files:**
- Modify: `.ao/workflows/custom.yaml`

**Note:** The directive below uses placeholder `<SUBJECT_CREATE_INVOCATION>` for the subject-create call. Replace it with one of:
- **If MCP path** (from preflight Step 7): `animus_subject_create` MCP tool with params `{kind: "linear-discovery", title, body}`
- **If plugin-call path**: `animus plugin call --name animus-subject-linear --method subject.create --params '{...}'` via Bash

Similarly for `<SUBJECT_LIST_INVOCATION>` (for idempotency check).

- [ ] **Step 1: Add the `idea-strategist` agent**

```yaml
  idea-strategist:
    model: claude-sonnet-4-6
    tool: claude
    mcp_servers:
    - ao
    - content-library
    - search-console
    - exa
    - tavily
    - brave
    - firecrawl
    system_prompt: |
      SKILLS: Read and follow .ao/skills/content-strategy.md AND the
      animus-subject-operations skill (loaded automatically) for correct
      subject API usage.

      CONTEXT: Read business-context.yaml at every run. If missing or
      empty, refuse and emit skip with reason "missing_business_context".

      You propose blog ideas grounded in (a) actual conversation
      transcripts and (b) external SEO viability data. Every idea you
      propose must survive an external-research check before becoming a
      Linear-backed subject.

      Hard rule: LINEAR_DISCOVERY_PROJECT_ID must be set. If not, emit
      skip with reason "missing_project_id".

      Cursor discipline: advance .ao/state/discovery-cursor.json ONLY
      after a transcript has been fully processed (every surviving angle
      has either become a subject or been confirmed-duplicate). On
      failure mid-transcript, leave cursor at the prior transcript so
      the failed one is retried.
```

- [ ] **Step 2: Add the `idea-strategist` phase**

```yaml
  idea-strategist:
    mode: agent
    agent: idea-strategist
    directive: |
      Input: transcript_paths from the prior phase. If empty, emit skip.

      Step 1 — Local context
      Read business-context.yaml. Read content/manifest.json (treat
      missing as {"version":1,"posts":[]}). Query content-library MCP
      for org-wide topic fingerprints.

      Step 2 — Per-transcript synthesis (iterate)
      For each transcript file in transcript_paths IN ORDER:
        a. Read the transcript JSON.
        b. Extract 3-5 candidate blog angles, each quoting a specific
           transcript moment with timestamp.
        c. External validation per candidate:
           - Search Console: keyword viability (volume, rank, striking distance)
           - Exa + Tavily + Brave: competitive landscape
           - Firecrawl: spot-scrape top 1-2 SERP pages for what's covered
             + 2-3 citable authoritative sources
        d. Filter/refine: drop dead-keyword angles, re-angle saturated
           SERPs, drop dupes vs content/manifest.json AND content-library.
        e. For each surviving angle:
           i.  Compute idempotency key:
               key = "discovery:<transcript_id>:<8-char hash of (transcript_id + angle title)>"
           ii. Check for an existing subject with this key:
               <SUBJECT_LIST_INVOCATION> filtered to project=LINEAR_DISCOVERY_PROJECT_ID,
               kind=linear-discovery, body contains key.
               If found, skip (already created in a prior run).
           iii. Create the subject:
               <SUBJECT_CREATE_INVOCATION> with:
                 kind: linear-discovery
                 title: punchy headline
                 body: structured markdown with these sections in order:
                   ## Source
                   Transcript: <id> @ <timestamp>
                   Quote: "<exact quoted moment>"

                   ## Suggested target keyword
                   "<keyword>" — GSC: <volume>/mo, rank #<rank>, striking distance: <yes|no>

                   ## Competitive landscape
                   - <url 1> (rank N) — <one-line characterization>
                   - <url 2> (rank N) — <one-line characterization>
                   - <url 3> (rank N) — <one-line characterization>
                   GAP: <what's missing in the SERP>

                   ## Pre-identified citable sources
                   - <url> — <what this supports>
                   - <url> — <what this supports>

                   ## Suggested pillar
                   <pillar from business-context.yaml>

                   ## Dedup notes
                   <"not covered in content/manifest.json" or specific notes>

                   ## Idempotency key
                   <key>
        f. AFTER all surviving angles for this transcript have been
           created-or-confirmed-duplicate, atomically write
           .ao/state/discovery-cursor.json with:
             { "last_processed_id": "<this transcript's id>",
               "last_processed_at": "<this transcript's created_at>",
               "updated_at": "<current ISO8601>" }

      Step 3 — Emit phase result
      Output: list of {subject_id, title, transcript_id} for each created
      subject; transcripts_processed: count.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - issues_created
      fields:
        issues_created:
          type: array
        transcripts_processed:
          type: integer
    decision_contract:
      min_confidence: 0.5
      max_risk: low
      allow_missing_decision: true
```

- [ ] **Step 3: Substitute the verified subject API path**

Find `<SUBJECT_CREATE_INVOCATION>` and `<SUBJECT_LIST_INVOCATION>` in the directive above and replace with the actual invocation form determined in preflight Step 7.

- [ ] **Step 4: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 5: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add idea-strategist agent and phase; cursor advances per-transcript"
```

---

## Task 4: Add `approval-watcher` agent + phase (filter by Animus subject status)

**Files:**
- Modify: `.ao/workflows/custom.yaml`

**Note:** `<SUBJECT_LIST_INVOCATION>` placeholder again — replace with verified path from preflight.

- [ ] **Step 1: Add the `approval-watcher` agent**

```yaml
  approval-watcher:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - ao
    system_prompt: |
      SKILLS: Follow the animus-subject-operations skill (auto-loaded)
      for correct subject API usage and animus-queue-management for
      enqueue semantics.

      You are a polling agent. You detect Linear-backed subjects whose
      Animus status has become InProgress (the approval signal) and
      enqueue blog-from-ticket runs for them. You do not reason about
      content. You do not modify subjects.

      Filter rules:
        - Include: status == InProgress
        - Exclude: status == Cancelled (rejected by human)
        - Exclude: status == Done (already processed)
        - Exclude: status == Blocked (human attention needed elsewhere)
        - Exclude: status == Ready (no transition yet)

      Hard rule: scope every query to project = LINEAR_DISCOVERY_PROJECT_ID.
```

- [ ] **Step 2: Add the `approval-watcher` phase**

```yaml
  approval-watcher:
    mode: agent
    agent: approval-watcher
    directive: |
      Step 1 — Read seen set
      mkdir -p .ao/state
      Read .ao/state/approval-seen.json. If missing, treat as
      {"subject_ids": [], "updated_at": null}.

      Step 2 — List subjects (scoped, filtered)
      <SUBJECT_LIST_INVOCATION> with:
        - kind: linear-discovery
        - project_id: LINEAR_DISCOVERY_PROJECT_ID
        - status: InProgress
      Return: subject_id, title.

      Step 3 — Diff against seen
      Filter out any subject_id already in the seen set.

      Step 4 — Enqueue per newly-approved subject
      For each, call animus_queue_enqueue with EXACTLY:
        workflow_ref: blog-from-ticket
        input: { subject_id: "<id>", subject_kind: "linear-discovery" }
      (Use the subject-id wire format determined in preflight Step 9.)
      No body / labels / pre-extracted fields — those are re-fetched in
      ticket-to-brief, so humans can edit the issue between approval
      and processing.

      Step 5 — Update seen set (atomic)
      Append every successfully-enqueued subject_id to the seen list.
      Write .ao/state/approval-seen.json via tmpfile + rename.
      updated_at = current ISO8601.

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
    decision_contract:
      min_confidence: 0.5
      max_risk: low
      allow_missing_decision: true
```

- [ ] **Step 3: Substitute the verified subject API path**

Replace `<SUBJECT_LIST_INVOCATION>`.

- [ ] **Step 4: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 5: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add approval-watcher filtering by Animus status==InProgress, enqueueing subject_id only"
```

---

## Task 5: Add `linear-coordinator` agent + `ticket-acknowledge` / `linear-finalize` phases

**Files:**
- Modify: `.ao/workflows/custom.yaml`

**Note:** uses `<SUBJECT_COMMENT_INVOCATION>` and `<SUBJECT_UPDATE_INVOCATION>` placeholders — replace from preflight.

- [ ] **Step 1: Add the `linear-coordinator` agent**

```yaml
  linear-coordinator:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - ao
    system_prompt: |
      SKILLS: Follow the animus-subject-operations skill (auto-loaded)
      for correct subject API usage.

      You manage Linear ticket comments (and optionally status) for
      blog-from-ticket runs. Two modes via the phase directive:
      - "acknowledge": post a start comment. DO NOT transition status
        — the human already moved to InProgress by approving.
      - "finalize": post a rich completion comment. Transition status
        only if LINEAR_FINALIZE_TRANSITION env var is set to "Done";
        otherwise leave status alone (the human moves to their
        team's preferred review state).
```

- [ ] **Step 2: Add `ticket-acknowledge` phase**

```yaml
  ticket-acknowledge:
    mode: agent
    agent: linear-coordinator
    directive: |
      Mode: acknowledge.

      Input from queue: subject_id (and subject_kind if separate).
      Read the Animus run_id from the runtime context. Read the current
      branch via `git rev-parse --abbrev-ref HEAD`.

      Action:
        <SUBJECT_COMMENT_INVOCATION> on subject_id with body:
          "🤖 Blog generation started.
           Run: <run_id>
           Branch: <branch>"

      DO NOT transition status. The human already did that.

      Output: pass-through of subject_id for downstream phases.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - subject_id
      fields:
        subject_id:
          type: string
```

- [ ] **Step 3: Add `linear-finalize` phase**

```yaml
  linear-finalize:
    mode: agent
    agent: linear-coordinator
    directive: |
      Mode: finalize.

      Input from prior phases:
        - subject_id
        - slug (from seo-review / content-writing)
        - branch (read via `git rev-parse --abbrev-ref HEAD`)
        - commit_message (from seo-review or register-post)

      Read content/<slug>.md frontmatter for title + meta_description.
      Read content/manifest.json's entry for this slug for any extra
      metadata (the entry was just written by register-post).

      Action 1 — Post completion comment:
        <SUBJECT_COMMENT_INVOCATION> on subject_id with body:
          "✅ Blog draft ready for review.
           Title: <title>
           Slug: <slug>
           Word count: <word_count from manifest>
           Branch: <branch>
           Meta description: <meta_description>
           Featured image: assets/<slug>.webp"

      Action 2 — Optional status transition:
        If env var LINEAR_FINALIZE_TRANSITION == "Done":
          <SUBJECT_UPDATE_INVOCATION> on subject_id with status=Done
        Else:
          Leave status untouched. The human moves the issue to their
          team's preferred In Review / QA / etc. state manually.

      Note: granular Linear-state-name transitions (e.g. "In Review"
      specifically) are NOT expressible through the subject API's
      5-status abstraction. If the team needs that, set
      LINEAR_FINALIZE_TRANSITION to a special value and have this
      phase call `animus plugin call --name animus-subject-linear
      --method subject.set_state_by_name ...` directly (verify whether
      the plugin exposes such a method during preflight).

      Output: confirmation.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - subject_id
      fields:
        subject_id:
          type: string
        comment_id:
          type: string
```

- [ ] **Step 4: Substitute the verified subject API paths**

Replace `<SUBJECT_COMMENT_INVOCATION>` and `<SUBJECT_UPDATE_INVOCATION>` in both phases.

- [ ] **Step 5: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 6: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add linear-coordinator with ack/finalize; finalize transition is opt-in"
```

---

## Task 6: Add `ticket-to-brief` phase + extend `content-strategist`

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Extend `content-strategist` mcp_servers**

Locate the existing `content-strategist:` agent block. Replace its `mcp_servers:` list:

Before:
```yaml
    mcp_servers:
    - ao
    - exa
    - tavily
    - brave
    - firecrawl
    - search-console
```

After (add `content-library`; **do NOT add `linear`** — subject access goes through `ao`):
```yaml
    mcp_servers:
    - ao
    - exa
    - tavily
    - brave
    - firecrawl
    - search-console
    - content-library
```

- [ ] **Step 2: Add `ticket-to-brief` phase**

```yaml
  ticket-to-brief:
    mode: agent
    agent: content-strategist
    directive: |
      Convert an approved Linear-backed subject into a topic_brief
      matching the contract today's research-collection consumes.

      Input from queue: subject_id (and subject_kind).

      Step 1 — Re-fetch the subject (mandatory)
      <SUBJECT_GET_INVOCATION> by subject_id to get the LATEST title,
      body, comments, status. Humans may have edited any of these
      between approval and now — re-fetch is non-negotiable.

      Read business-context.yaml. Read content/manifest.json.

      Step 2 — Parse the body
      Extract from the body sections (which the strategist wrote
      originally but humans may have edited):
        - suggested_pillar (from "## Suggested pillar")
        - suggested_keyword (from "## Suggested target keyword",
          first quoted string)
        - pre_identified_sources (from "## Pre-identified citable
          sources" as list of {url, supports})
        - source_transcript_id (from "## Source")

      Step 3 — Refine keyword
      Validate suggested_keyword via Search Console. If GSC suggests a
      better-shaped variant, prefer it; record why.

      Step 4 — Build topic_brief
      Emit the same shape today's topic-research produces:
        - target_keyword: <refined>
        - content_pillar: <suggested_pillar or refined>
        - word_count_target: <1200-2500 by angle complexity>
        - unique_angle: <the angle including transcript context>
        - data_sources_needed: <list — start from pre_identified_sources,
          add gaps>
        - internal_link_targets: <query content-library + manifest;
          2-3 candidate slugs>
        - subject_id: <pass through>
        - linear_issue_identifier: <Linear identifier like BLG-105
          for human-readable display in subsequent commit messages>
        - source_transcript_id: <pass through>

      Do NOT do deep external research here. research-collection's job.
    capabilities:
      mutates_state: false
    output_contract:
      kind: phase_result
      required_fields:
      - topic_brief
      fields:
        topic_brief:
          type: object
        target_keyword:
          type: string
        content_pillar:
          type: string
        subject_id:
          type: string
        source_transcript_id:
          type: string
```

- [ ] **Step 3: Substitute `<SUBJECT_GET_INVOCATION>`**

Replace with the verified subject-get path from preflight Step 7.

- [ ] **Step 4: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```

- [ ] **Step 5: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Add ticket-to-brief re-fetching subject body; extend content-strategist with content-library"
```

---

## Task 7: Extend `content-writer` with content-library MCP

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add `content-library` to `content-writer` mcp_servers**

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

- [ ] **Step 2: Update the internal-link guidance in the system_prompt**

Find:
```
      Internal links to 2-3 related blog posts.
```

Replace with:
```
      Internal links to 2-3 related blog posts. Source candidates by
      querying content-library MCP and reading content/manifest.json.
      Use real slugs of published posts. Do not invent slugs.
```

- [ ] **Step 3: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .ao/workflows/custom.yaml
git commit -m "Extend content-writer with content-library MCP for real internal-link slugs"
```

---

## Task 8: Extend `seo-optimizer` with content-library MCP

**Files:**
- Modify: `.ao/workflows/custom.yaml`

- [ ] **Step 1: Add `content-library` to `seo-optimizer` mcp_servers**

Before:
```yaml
    mcp_servers:
    - search-console
    - firecrawl
```

After:
```yaml
    mcp_servers:
    - search-console
    - firecrawl
    - content-library
```

- [ ] **Step 2: Update the internal-link verification line**

Find:
```
      - Internal links to 2-3 related blog posts (not service pages)
```

Replace with:
```
      - Internal links to 2-3 related blog posts (not service pages).
        Verify each slug exists via content-library MCP or
        content/manifest.json. Drop and replace any broken slug.
```

- [ ] **Step 3: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .ao/workflows/custom.yaml
git commit -m "Extend seo-optimizer with content-library MCP for internal-link verification"
```

---

## Task 9: TDD the `register-post.sh` script

**Files:**
- Create: `scripts/register-post.sh`
- Create: `scripts/test/register-post.bats`

The script parses YAML frontmatter from `content/<slug>.md`, builds a manifest entry, atomically appends to `content/manifest.json`, and commits. We TDD it with `bats-core`. Script-side behavior is unchanged from the prior plan revision — only the phase that *calls* it changes (Task 10).

- [ ] **Step 1: Install bats / yq / jq if missing**

```bash
which bats || brew install bats-core
which yq && which jq
```
Expected: all three resolve.

- [ ] **Step 2: Write the failing test file**

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

@test "writes atomically (no partial manifest on parse failure)" {
  write_post "atomic-post"
  ./scripts/register-post.sh atomic-post
  echo "broken" > content/atomic-post.md
  run ./scripts/register-post.sh atomic-post
  [ "$status" -ne 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "commits the manifest change" {
  write_post "commit-post"
  ./scripts/register-post.sh commit-post
  run git log --oneline
  [[ "$output" == *"Register commit-post"* ]]
}

@test "uses LINEAR_SUBJECT_ID and SOURCE_TRANSCRIPT_ID from env if set" {
  write_post "env-post"
  LINEAR_SUBJECT_ID="linear-discovery:BLG-42" SOURCE_TRANSCRIPT_ID="krisp-xyz" \
    ./scripts/register-post.sh env-post
  run jq -r '.posts[0].linear_subject_id' content/manifest.json
  [ "$output" = "linear-discovery:BLG-42" ]
  run jq -r '.posts[0].source_transcript_id' content/manifest.json
  [ "$output" = "krisp-xyz" ]
}
```

- [ ] **Step 3: Run the tests — verify they fail**

```bash
bats scripts/test/register-post.bats
```
Expected: all 7 tests fail (script doesn't exist).

- [ ] **Step 4: Write the script**

Create `scripts/register-post.sh`:

```bash
#!/usr/bin/env bash
# register-post.sh — Append a post entry to content/manifest.json
#
# Usage: ./scripts/register-post.sh <slug>
# Optional env: LINEAR_SUBJECT_ID, SOURCE_TRANSCRIPT_ID, BRANCH

set -euo pipefail

SLUG="${1:?slug argument required}"
POST_FILE="content/${SLUG}.md"
MANIFEST="content/manifest.json"

[ -f "$POST_FILE" ] || { echo "post not found: $POST_FILE" >&2; exit 1; }

FM="$(awk '/^---$/{c++; next} c==1{print}' "$POST_FILE")"
[ -n "$FM" ] || { echo "no frontmatter found in $POST_FILE" >&2; exit 1; }

title="$(echo "$FM" | yq -r '.title // ""')"
[ -n "$title" ] || { echo "frontmatter missing title" >&2; exit 1; }
pillar="$(echo "$FM" | yq -r '.content_pillar // ""')"
target_keyword="$(echo "$FM" | yq -r '.target_keyword // ""')"
word_count="$(echo "$FM" | yq -r '.word_count // 0')"
excerpt="$(echo "$FM" | yq -r '.excerpt // ""')"
date_str="$(echo "$FM" | yq -r '.date // ""')"
tags_json="$(echo "$FM" | yq -o=json '.keywords // []')"

LINEAR_SUBJECT_ID="${LINEAR_SUBJECT_ID:-}"
SOURCE_TRANSCRIPT_ID="${SOURCE_TRANSCRIPT_ID:-}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"

if [ ! -f "$MANIFEST" ]; then
  echo '{"version":1,"posts":[]}' > "$MANIFEST"
fi

existing="$(jq --arg s "$SLUG" '[.posts[] | select(.slug == $s)] | length' "$MANIFEST")"
if [ "$existing" -gt 0 ]; then
  echo "manifest already contains slug: $SLUG (skipping)" >&2
  exit 0
fi

NEW_ENTRY="$(jq -n \
  --arg slug "$SLUG" \
  --arg title "$title" \
  --arg published_at "$date_str" \
  --arg pillar "$pillar" \
  --arg target_keyword "$target_keyword" \
  --argjson word_count "$word_count" \
  --arg summary "$excerpt" \
  --arg linear_subject_id "$LINEAR_SUBJECT_ID" \
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
    linear_subject_id: $linear_subject_id,
    source_transcript_id: $source_transcript_id,
    branch: $branch
  }')"

TMP="$(mktemp "${MANIFEST}.XXXXXX")"
jq --argjson entry "$NEW_ENTRY" '.posts += [$entry]' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

git add "$MANIFEST"
git commit -m "Register ${SLUG} in content manifest" --quiet
```

- [ ] **Step 5: Rerun tests**

```bash
chmod +x scripts/register-post.sh
bats scripts/test/register-post.bats
```
Expected: all 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/register-post.sh scripts/test/register-post.bats
git commit -m "Add register-post.sh with bats coverage; env: LINEAR_SUBJECT_ID, SOURCE_TRANSCRIPT_ID"
```

---

## Task 10: Add `register-post` phase as an AGENT phase (not command)

**Files:**
- Modify: `.ao/workflows/custom.yaml`

The original plan made `register-post` a command phase relying on `SLUG` flowing in as an env var — which assumes Animus has a clean mechanism for env-passing into command phases (unverified). Switching to a tiny agent phase makes the input-reading explicit and matches how every other phase in this workflow reads prior phase outputs.

- [ ] **Step 1: Add the `register-post-runner` agent**

```yaml
  register-post-runner:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers: []
    system_prompt: |
      You are a one-shot script runner. Your only job: extract `slug`
      (and optionally `linear_subject_id`, `source_transcript_id`) from
      the prior phase's output, then run scripts/register-post.sh with
      those as env vars. Return the script's commit message.
```

- [ ] **Step 2: Add the `register-post` phase**

```yaml
  register-post:
    mode: agent
    agent: register-post-runner
    directive: |
      Read the prior phase's output to find:
        - slug (required; emitted by seo-review or content-writing)
        - linear_subject_id (optional; threaded from queue payload
          through ticket-to-brief's topic_brief)
        - source_transcript_id (optional; threaded from topic_brief)

      Run:
        env LINEAR_SUBJECT_ID="<linear_subject_id or empty>" \
            SOURCE_TRANSCRIPT_ID="<source_transcript_id or empty>" \
            bash scripts/register-post.sh "<slug>"

      Capture the commit message from stdout (the script logs it).
      Output: commit_message.
    capabilities:
      mutates_state: true
    output_contract:
      kind: implementation_result
      required_fields:
      - commit_message
      fields:
        commit_message:
          type: string
```

- [ ] **Step 3: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .ao/workflows/custom.yaml
git commit -m "Add register-post as agent phase (reads slug from prior output)"
```

---

## Task 11: Define the three new workflows + retrofit `blog-production` (with revised register-post placement)

**Files:**
- Modify: `.ao/workflows/custom.yaml` (workflows block)

- [ ] **Step 1: Retrofit `register-post` into `blog-production` as the LAST phase**

Locate `blog-production`. Replace its `phases:` list:

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
  - asset-generation
  - social-excerpts
  - push-branch
  - register-post           # ← inserted as LAST phase; manifest = post on origin
```

- [ ] **Step 2: Add the three new workflows**

After the existing `news-monitor` block:

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
  - register-post           # ← after push-branch, before finalize
  - linear-finalize
```

- [ ] **Step 3: Validate, compile, list**

```bash
animus workflow config validate
animus workflow config compile
animus workflow list
```
Expected: 7 workflows total (4 existing + 3 new).

- [ ] **Step 4: Commit**

```bash
git add .ao/workflows/custom.yaml
git commit -m "Define discovery + approval-watch + blog-from-ticket workflows; register-post is last phase in both blog workflows"
```

---

## Task 12: Add new schedules

**Files:**
- Modify: `.ao/workflows/custom.yaml` (schedules block)

- [ ] **Step 1: Add `discovery` and `approval-watch` schedules**

After the existing `news` schedule:

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

- [ ] **Step 2: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .ao/workflows/custom.yaml
git commit -m "Schedule discovery (daily 7am) and approval-watch (every 15 min)"
```

---

## Task 13: Smoke tests using verified CLI commands

**Files:** none modified.

- [ ] **Step 1: Compile-clean check**

```bash
animus workflow config compile
```
Expected: succeeds with no warnings.

- [ ] **Step 2: Render the `idea-strategist` phase prompt**

```bash
animus workflow prompt render \
  --workflow-ref idea-discovery \
  --phase idea-strategist
```
Expected: fully-rendered prompt block, no template placeholders left raw, business-context.yaml + manifest references intact.

- [ ] **Step 3: Render the `ticket-to-brief` phase prompt**

```bash
animus workflow prompt render \
  --workflow-ref blog-from-ticket \
  --phase ticket-to-brief
```

- [ ] **Step 4: Render every phase of `blog-from-ticket` to inspect order**

```bash
animus workflow prompt render \
  --workflow-ref blog-from-ticket \
  --all-phases
```
Expected: phases render in this order:
```
1. ticket-acknowledge
2. ticket-to-brief
3. research-collection
4. content-writing
5. commit-draft
6. seo-review
7. asset-generation
8. social-excerpts
9. push-branch
10. register-post
11. linear-finalize
```

- [ ] **Step 5: Confirm subject backend ping**

```bash
animus plugin ping --name animus-subject-linear
```
Expected: handshake + ping succeed.

- [ ] **Step 6: Confirm MCP server declarations**

```bash
grep -E "^\s+(krisp|content-library):" .ao/workflows/custom.yaml
```
Expected: each appears once. `linear:` should NOT appear under `mcp_servers:` (it's under `subjects:` now).

- [ ] **Step 7: Confirm `subjects:` block is present**

```bash
grep -A 5 "^subjects:" .ao/workflows/custom.yaml
```
Expected: prints the `linear-discovery` subject backend block.

- [ ] **Step 8: Confirm state dir is fully gitignored (no .gitkeep)**

```bash
git check-ignore .ao/state/anything
test -f .ao/state/.gitkeep && echo "BUG: gitkeep present" || echo "OK: no gitkeep"
```
Expected: `.ao/state/anything` ignored; no `.gitkeep`.

- [ ] **Step 9: No commit — smoke tests only**

---

## Task 14: Update documentation

**Files:**
- Modify: `MCP-TOOLS.md`
- Modify: `README.md`

- [ ] **Step 1: Update `MCP-TOOLS.md`**

Find the "## Orchestration" section. Above the "## Which Agents Use What" code block, insert:

```markdown
## Discovery Loop

| Server | Package | What It Does |
|--------|---------|--------------|
| **Krisp** | (configured in workflow YAML) | Audio transcript ingest — lists and fetches meeting transcripts since a cursor |
| **Content Library** | (configured in workflow YAML) | Org-wide content + artifact database |

## Subject Backends

Linear is integrated as an **Animus subject backend**, not an MCP server. The
`animus-subject-linear` plugin auto-maps Linear's `WorkflowState.type` to
Animus's 5 normalized statuses (`Ready / InProgress / Blocked / Done / Cancelled`),
so the human-review gate works even if your Linear team renames states.

| Backend | Plugin | What It Does |
|---|---|---|
| **Linear** | `launchapp-dev/animus-subject-linear` | Linear issues exposed as Animus subjects; CRUD + status + comments |

Install once per host:
```bash
animus plugin install launchapp-dev/animus-subject-linear
```
```

Replace the existing "Which Agents Use What" block with:

```
Strategist          → ao, exa, tavily, brave, firecrawl, search-console, content-library
Researcher          → firecrawl, exa, tavily, brave, google-maps
Writer              → content-library
SEO Optimizer       → search-console, firecrawl, content-library
Asset Generator     → replicate
Performance Analyst → ao, search-console, exa, perplexity
Content Refresher   → firecrawl
Transcript Collector → krisp
Idea Strategist     → ao, exa, tavily, brave, firecrawl, search-console, content-library
Approval Watcher    → ao
Linear Coordinator  → ao
Register Post Runner → (none — local script only)
```

Note: Linear access is via `ao` (subject API), not a `linear` MCP server.

- [ ] **Step 2: Update `README.md`**

Add a "Discovery Flow" section:

```markdown
## Discovery Flow (transcript-driven)

In addition to the cron-driven `blog-production` pipeline, this generator
supports a transcript-driven discovery loop with a human-review gate in
Linear (integrated as an Animus subject backend).

**Daily 7am — `idea-discovery`**
Polls Krisp for new meeting transcripts. For each, the strategist proposes
3–5 blog angles, each pre-validated with Search Console + competitor scan +
spot-scraped citable sources. Surviving angles become Linear issues
(Animus subjects) in your configured discovery project.

**Every 15 min — `approval-watch`**
Polls Linear-backed subjects for status `InProgress` (the human-approval
signal). Each newly-approved subject is enqueued as a `blog-from-ticket`
run. Canceled / Won't-do issues are auto-filtered.

**Per approved ticket — `blog-from-ticket`**
A variant of blog-production using the Linear ticket as topic brief.
- First phase posts a "started" comment.
- `ticket-to-brief` re-fetches the latest Linear body (humans may edit
  during review).
- Last two phases register the post in `content/manifest.json` and post
  a completion comment. Status transition on finalize is opt-in via
  `LINEAR_FINALIZE_TRANSITION`.

**One-time setup:**
```bash
animus plugin install launchapp-dev/animus-subject-linear
```
Then fill in `.env`:
- `KRISP_API_KEY`
- `LINEAR_API_TOKEN`, `LINEAR_TEAM`, `LINEAR_DISCOVERY_PROJECT_ID`
- (Optional) `LINEAR_STATUS_MAP`, `LINEAR_FINALIZE_TRANSITION`
- `CONTENT_LIBRARY_URL`, `CONTENT_LIBRARY_TOKEN`

**State files** (gitignored):
- `.ao/state/discovery-cursor.json` — last *processed* Krisp transcript
- `.ao/state/approval-seen.json` — already-enqueued subject IDs
- `.ao/state/transcripts/<id>.json` — staged transcripts

**Tracked:** `content/manifest.json` — every post this generator produced.
```

- [ ] **Step 3: Commit**

```bash
git add MCP-TOOLS.md README.md
git commit -m "Document discovery flow + animus-subject-linear plugin setup"
```

---

## Configuration to confirm before first run

Everything below has already been verified or has an explicit preflight step.

**Hardware-confirmed (preflight Task -1):**
- Animus 0.5.4 installed
- `animus-subject-linear` v0.1.4+ installed via `animus plugin install`
- Subject API surface (MCP tools vs `animus plugin call`) — verified path applied in agent directives
- Queue input propagation — verified shape applied in `approval-watcher`
- Wire ID format — verified format applied in queue payload
- Krisp + content-library MCP package names — resolved to real values

**Still depends on user config (in `.env`):**
- `KRISP_API_KEY`
- `LINEAR_API_TOKEN`
- `LINEAR_TEAM`
- `LINEAR_DISCOVERY_PROJECT_ID`
- `LINEAR_STATUS_MAP` (optional override)
- `LINEAR_FINALIZE_TRANSITION` (optional; default unset = don't auto-transition)
- `CONTENT_LIBRARY_URL`, `CONTENT_LIBRARY_TOKEN`

Until `LINEAR_DISCOVERY_PROJECT_ID` is set, `idea-strategist` skips with reason `missing_project_id` and `approval-watcher` finds nothing — loop is dormant.

---

## Self-Review

**Spec coverage check:**
- Preflight verifying all the assumptions — Task -1 ✓
- Project scaffolding (state dir, gitignore — no gitkeep, env vars, manifest bootstrap) — Task 0 ✓
- MCP servers (krisp, content-library only; no linear MCP) + subject backend declaration — Task 1 ✓
- transcript-fetch phase + cursor non-advancement — Task 2 ✓
- idea-strategist with external research + per-transcript cursor advancement — Task 3 ✓
- approval-watcher filtering by Animus status==InProgress, enqueueing subject_id only — Task 4 ✓
- linear-coordinator with ack (no transition) + finalize (opt-in transition) — Task 5 ✓
- ticket-to-brief re-fetching subject — Task 6 ✓
- Extended content-writer (content-library) — Task 7 ✓
- Extended seo-optimizer (content-library) — Task 8 ✓
- register-post script (TDD) — Task 9 ✓
- register-post phase as agent (not command, no env-magic) — Task 10 ✓
- Workflows defined + blog-production retrofitted with register-post as LAST phase — Task 11 ✓
- Schedules — Task 12 ✓
- Smoke tests using verified CLI (`animus workflow prompt render`, `animus workflow get --id`, `animus plugin ping --name`) — Task 13 ✓
- Documentation — Task 14 ✓

**All 10 feedback points addressed:**
1. linear-pack install dropped; animus-subject-linear installed in Task -1 ✓
2. Linear ops use subject API throughout (placeholders substituted from preflight) ✓
3. Dependency preflight is Task -1, before all YAML work ✓
4. Cursor advanced by idea-strategist per-transcript, not by transcript-fetch ✓
5. Approval = `status==InProgress`; Cancelled/Done/Blocked explicitly excluded ✓
6. Queue payload is `{subject_id, subject_kind}` only; ticket-to-brief re-fetches ✓
7. register-post is an agent phase, not command-with-env-magic ✓
8. register-post moved AFTER push-branch (manifest = post on origin) ✓
9. No .gitkeep; phases mkdir on demand; `.ao/state/` fully ignored ✓
10. Smoke tests use verified CLI commands; removed fictional `animus mcp tool-call` ✓

**Placeholder scan:** `<SUBJECT_*_INVOCATION>` placeholders in Tasks 3-6 are intentional — they're resolved by the preflight task and substituted in each task's "substitute the verified subject API path" step. `<KRISP_PACKAGE_NAME>` and `<CONTENT_LIBRARY_PACKAGE_NAME>` in Task 1 are flagged for preflight Step 10.

**Type consistency:**
- `subject_id` flows: queue payload → ticket-acknowledge → ticket-to-brief → topic_brief.subject_id → register-post (as LINEAR_SUBJECT_ID env) → linear-finalize ✓
- `slug` flows: content-writing → seo-review → register-post → linear-finalize ✓
- `transcript_paths` flows: transcript-fetch → idea-strategist ✓
- `source_transcript_id` flows: idea-strategist (writes to subject body) → ticket-to-brief (parses from body) → topic_brief → register-post (env) ✓
