# Discovery Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an upstream `idea-discovery → human-review-in-Linear → approval-watch → blog-from-ticket` pipeline targeting **`.animus/workflows/custom.yaml`** (the canonical v0.5.4 workflow path), with Linear integrated as an **Animus subject backend** and `content/manifest.json` as the local post index.

**Architecture (revised after reviewer P0/P1 findings):** Two preflight tasks (`Task -2` migrates the existing blog pipeline from `.ao/workflows/custom.yaml` to `.animus/workflows/custom.yaml`; `Task -1` verifies plugin, subject, queue, and CLI shapes) precede all YAML changes. All status filter values use Animus's **lowercase snake_case** API form (`ready`, `in_progress`, `done`, `cancelled`, `blocked`). The subject backend is declared as a **YAML list** (`subjects: - id: ... backend: ... config: ...`), not a mapping. Queue handoff uses `--task-id` + `--input-json`, not arbitrary `input:` fields. `register-post` runs **before** `push-branch` so the single push covers the manifest commit; the script emits `commit_message` to stdout to satisfy its phase contract. `ticket-acknowledge` and `ticket-to-brief` re-check subject status to abort cleanly if the human cancelled after approval.

**Tech Stack:** Animus v0.5.4, `animus-subject-linear` v0.1.4+, YAML for declarative pipeline, Bash + `jq` + `yq` for `register-post`, `bats-core` for shell tests.

---

## File Structure

**Created:**
- `scripts/register-post.sh` — appends post entry to `content/manifest.json`; emits commit_message to stdout
- `scripts/test/register-post.bats` — bats tests for the script
- `content/manifest.json` — canonical index of generated posts (committed; bootstraps to `{"version": 1, "posts": []}`)

**Modified:**
- `.animus/workflows/custom.yaml` — **CANONICAL** v0.5.4 workflow file. Receives both the migrated blog pipeline (Task -2) and the discovery additions (Tasks 1–12).
- `.env.example` — env vars for Krisp, Linear subject backend, content-library
- `.gitignore` — add `.ao/state/`
- `CLAUDE.md` — update the `animus workflow config compile` instruction to point at `.animus/workflows/custom.yaml`
- `MCP-TOOLS.md` — document the two new MCP servers + the Linear subject backend
- `README.md` — document the new workflows and the daemon-env loading discipline

**Deleted:**
- `.ao/workflows/custom.yaml` — dormant in v0.5.4 after migration completes
- `.ao/workflows/standard-workflow.yaml` — superseded by Animus's bundled standard-workflow

**Runtime-created (not in repo):**
- `.ao/state/discovery-cursor.json`
- `.ao/state/approval-seen.json`
- `.ao/state/transcripts/<id>.json`

---

## Task -2: Migrate the blog pipeline to `.animus/workflows/custom.yaml`

The active config path resolved by `animus workflow config get` is `.animus/workflows/` (verifiable via `animus workflow config get --json | jq -r .data.path`). The existing blog pipeline lives at `.ao/workflows/custom.yaml`, a legacy v0.4.x path that the v0.5.4 daemon does not load. Migration is a precondition.

(`animus workflow definitions list` would also surface the gap — it shows only the bundled standard/hotfix/research workflows pre-migration, none of the project's blog workflows. The `config get` path resolution is the more direct evidence.)

**Files:**
- Move/overwrite: `.animus/workflows/custom.yaml` (currently a 5-line stub)
- Delete: `.ao/workflows/custom.yaml`, `.ao/workflows/standard-workflow.yaml`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Snapshot the current `.animus/workflows/custom.yaml`**

```bash
cat .animus/workflows/custom.yaml
```
Expected: 5-line stub:
```yaml
default_workflow_ref: standard-workflow

tools_allowlist:
  - cargo
```

**Decisions about what to preserve from the stub:**
- `default_workflow_ref: standard-workflow` — **preserve**. It only matters for ad-hoc `animus workflow run` calls without an explicit `--workflow-ref`; harmless for the blog pipeline which dispatches via cron schedules with explicit refs.
- `tools_allowlist: [cargo]` — **drop**. Clearly a Rust-template artifact (this is not a Rust project). The migrated `.ao/workflows/custom.yaml` brings its own `tools_allowlist: [git, gh, bash, WebSearch, WebFetch]` which is the correct set for this project.

- [ ] **Step 2: Copy the blog pipeline into `.animus/workflows/custom.yaml`, preserving `default_workflow_ref`**

```bash
# Copy the blog pipeline
cp .ao/workflows/custom.yaml .animus/workflows/custom.yaml
```

Then prepend `default_workflow_ref: standard-workflow` if it isn't already in the .ao copy. Verify via:

```bash
grep -c "default_workflow_ref:" .animus/workflows/custom.yaml
```

If the count is 0, add the line at the very top of the file (above the existing comment header):
```yaml
default_workflow_ref: standard-workflow

# ──────────────────────────────────────────────────────────────
# blog-engine.yaml — Automated SEO blog pipeline
# ...
```

If the count is 1+, the line is already there from the .ao source; no action.

**Note:** the `tools_allowlist: [cargo]` from the stub is intentionally NOT preserved — the blog pipeline's own allowlist supersedes it.

- [ ] **Step 3: Compile and verify**

```bash
animus workflow config compile
animus workflow definitions list
```
Expected: compile succeeds; `animus workflow definitions list` now includes `blog-production`, `refresh-cycle`, `image-refresh`, `news-monitor`.

(Note: `animus workflow list` lists *runtime workflow runs*, not definitions — use `animus workflow definitions list` for the definition check.)

If validation fails because the v0.4-era YAML uses constructs v0.5.4 no longer accepts: read the error, consult the `animus-workflow-authoring` skill, and patch in place. Common likely issues:
- `tools_allowlist:` at top level (verify still supported in v0.5.4)
- `mcp_servers:` shape (verify still mapping vs list)
- `decision_contract:` field shape

- [ ] **Step 4: Delete the stale `.ao/workflows/` content**

Only after Step 3 succeeds:

```bash
git rm .ao/workflows/custom.yaml .ao/workflows/standard-workflow.yaml
rmdir .ao/workflows 2>/dev/null || true
```

`.ao/skills/`, `.ao/config/`, and `.ao/state/` (runtime) are NOT deleted — they remain the project-local skill / config / state surface.

- [ ] **Step 5: Update `CLAUDE.md`**

Find:
```
After ANY change to `.ao/workflows/custom.yaml`, you MUST run:

```bash
animus workflow config compile
```
```

Replace `.ao/workflows/custom.yaml` with `.animus/workflows/custom.yaml`. Also remove any other `.ao/workflows/` references and replace with `.animus/workflows/`.

- [ ] **Step 6: Verify the workflows still resolve**

```bash
animus workflow definitions list
animus workflow get --id blog-production
```
Expected: definitions list includes the migrated workflows; `blog-production` resolves with its full phase list intact.

- [ ] **Step 7: Commit**

```bash
git add .animus/workflows/custom.yaml CLAUDE.md
git add -u .ao/workflows/   # picks up the deletions
git commit -m "Migrate blog pipeline from .ao/workflows to .animus/workflows (v0.5.4 canonical path)"
```

---

## Task -1: Dependency preflight (BEFORE any discovery-flow YAML work)

Establishes ground truth for plugin, subject API, queue contract, CLI commands. **No discovery-flow YAML changes happen until every step here is green.**

**Files:** none modified in the repo; plugin installs to `~/.animus/plugins/`; outcomes recorded to a local note.

- [ ] **Step 1: Confirm Animus version**

```bash
animus --version
```
Expected: `animus 0.5.4` or higher.

- [ ] **Step 2: Install `animus-subject-linear`**

```bash
animus plugin install launchapp-dev/animus-subject-linear
```
Expected: success; binary lands in `~/.animus/plugins/`.

- [ ] **Step 3: Verify discovery and ping**

```bash
animus plugin list
animus plugin info --name animus-subject-linear
LINEAR_API_TOKEN="$LINEAR_API_TOKEN" animus plugin ping --name animus-subject-linear
```
Expected: list includes the plugin with `plugin_kind = "subject_backend"`; info prints exposed JSON-RPC methods; ping handshake completes. Note the exact method names from `plugin info`.

- [ ] **Step 4: Confirm the subject CLI surface works**

```bash
animus subject list --kind linear --status ready --limit 5
```
Expected: returns a list (possibly empty) without auth errors. If the CLI doesn't expose `--kind linear` directly, fall back to `animus plugin call --name animus-subject-linear --method subject.list --params '{...}'` and record the exact method/param names.

**Record:** the working invocation form (CLI `animus subject` vs `animus plugin call`) — every directive in Tasks 3–6 substitutes it as `<SUBJECT_LIST>` / `<SUBJECT_CREATE>` / `<SUBJECT_GET>` / `<SUBJECT_UPDATE>` / `<SUBJECT_COMMENT>`.

- [ ] **Step 5: Confirm status casing**

```bash
animus subject list --kind linear --status in_progress --limit 5
animus subject list --kind linear --status cancelled --limit 5
```
Expected: both accepted (no schema errors on the filter value). Verify: `ready`, `in_progress`, `blocked`, `done`, `cancelled` all parse. **All directives in this plan use these lowercase values.**

- [ ] **Step 6: Verify the queue dispatch contract**

The plan's approval-watcher needs to enqueue `blog-from-ticket` carrying `linear_subject_id`. The queue accepts task / requirement / ad-hoc subjects only — not Linear-backed subjects directly. Pick one shape:

**Important:** there is no `animus task` subcommand in v0.5.4. Tasks are subjects of kind `task` — created via `animus subject create --kind task ...`. Verified flag: `--body` (not `--description`).

**Probe A (task-subject wrapper):**
```bash
# Create a throwaway task-subject and enqueue with input-json
TASK_ID=$(animus subject create \
  --kind task \
  --title "queue probe" \
  --body "queue propagation test" \
  --status ready \
  --json | jq -r '.data.id')
animus queue enqueue --task-id "$TASK_ID" --workflow-ref hotfix-workflow --input-json '{"probe":"hello"}'
```
Watch the dispatched workflow's phase prompts. Confirm the input-json reached the run: render the first phase prompt and look for "probe":
```bash
animus workflow prompt render --workflow-id <new_id> --phase implementation
```
Clean up: `animus subject status --kind task --id "$TASK_ID" --status cancelled`

**Probe B (ad-hoc title — no wrapper subject):**
```bash
animus queue enqueue --title "queue probe" --description "queue propagation test" --workflow-ref hotfix-workflow --input-json '{"probe":"hello"}'
```
Same prompt-render verification. Note: `animus queue enqueue` does use `--description` (CLI-verified), unlike `animus subject create` which uses `--body`. The two CLIs have different flag names — substitute correctly in each context.

**Record:** which probe propagates `input_json` cleanly. The approval-watcher directive uses that shape. If neither works, fall back to encoding the `linear_subject_id` in the subject body / description and having `ticket-acknowledge` parse it.

- [ ] **Step 6.5: Verify Linear project scoping + state-transition timestamp**

The generic `animus subject list` CLI exposes `--kind / --status / --limit` but no project filter. Verify whether the plugin's backend `config.project_id` actually scopes results, and what timestamp field is available for state-transition dedup:

```bash
# List linear subjects with kind+status; inspect the JSON to confirm
# every result belongs to LINEAR_DISCOVERY_PROJECT_ID, and capture
# the exact timestamp field names available.
animus subject list --kind linear --status ready --limit 50 --json | tee /tmp/linear-probe.json

# Check the JSON shape:
jq '.data[] | {id, status, project_id, updated_at, state_updated_at, stateUpdatedAt}' /tmp/linear-probe.json
```

Record:
- **Project scoping:** are ALL returned subjects in the configured project? If yes, backend filtering is active and no post-filter needed. If results leak from other projects, the watcher MUST post-filter by `project_id`. Document the field name as it appears (`project_id`, `projectId`, etc.).
- **Transition timestamp:** which of these fields actually appears in the JSON: `state_updated_at`, `stateUpdatedAt`, `updated_at`, `updatedAt`. The watcher's dedup keys on the most state-specific one available.
- If no transition-specific timestamp exists, fall back to subject-level `updated_at` and accept the duplicate-on-body-edit caveat (downstream idempotency makes this safe).

If the post-filter route is needed and the plugin does NOT scope by config, alternative is to use the explicit plugin-call form:
```bash
animus plugin call --name animus-subject-linear --method subject.list \
  --params '{"project_id":"'"$LINEAR_DISCOVERY_PROJECT_ID"'","status":"in_progress"}'
```
Record whether this method shape works.

- [ ] **Step 7: Verify the `subjects:` YAML schema is accepted**

Write a throwaway `.animus/workflows/scratch.yaml` containing only:

```yaml
subjects:
  - id: linear-discovery-probe
    backend: linear
    config:
      team_id: ${LINEAR_TEAM_ID:-probe-team}
      project_id: ${LINEAR_DISCOVERY_PROJECT_ID:-probe-project}
```

Run `animus workflow config validate`. Expected: succeeds. Then delete the scratch file. (We confirm shape now to avoid breaking the real custom.yaml in Task 1.)

- [ ] **Step 8: Verify `on_failure` hook support (best-effort)**

Check the `animus-workflow-authoring` skill via:
```bash
grep -i "on_failure\|failure_hook" ~/.claude/skills/animus-workflow-authoring/SKILL.md
```
Record whether failure hooks are documented. If yes, `linear-coordinator` will register one in Task 5. If no, the plan falls back to daemon logs being the failure surface.

- [ ] **Step 9: Inventory existing Krisp + content-library MCP configuration (non-blocking)**

Per the project constraint, we are **not** installing new MCP servers as part of this work. Krisp is "already loaded" elsewhere and content-library is assumed to exist as a custom server the user maintains. The task here is to inventory what's already configured, not to discover packages.

Check existing config locations in priority order:

```bash
# 1. The current .mcp.json (session-level Claude config)
jq '.mcpServers | keys[]' .mcp.json

# 2. The migrated .animus/workflows/custom.yaml (post-Task -2)
grep -E "^\s+(krisp|content-library|granola):" .animus/workflows/custom.yaml

# 3. Any user-level Animus daemon config
find ~/.animus -name "*.yaml" -o -name "*.json" 2>/dev/null \
  | xargs grep -l "krisp\|content-library" 2>/dev/null
```

Record:
- **Krisp:** `<command + args + env from wherever it's already configured>` OR `not yet configured — Task 1 leaves a TODO stub`
- **Content-library:** same

**Decision matrix from this step's outcomes:**

| Krisp config status | Content-library config status | Plan path |
|---|---|---|
| real | real | Full plan: Tasks -2 through 14 |
| stubbed / not configured | real | Full plan; `idea-discovery`'s scheduled runs no-op until Krisp is wired |
| any | stubbed / not configured | **Stop after Task 3.** Tasks 4–14 are deferred. Discovery + subject backend ship; nothing in `blog-from-ticket` is built (avoids the YAML-validation failure of a workflow that references undefined phases) |

If pre-configured, copy the working `command` / `args` / `env` block into Task 1's `mcp_servers:` declarations. If not, use the TODO stub form for Krisp only — `content-library` does not get a stub because a stub there would break the running `blog-production` cron, and the deferred-rollout path skips its declaration entirely.

- [ ] **Step 10: Record preflight outcomes**

Create a local note `~/.animus-blog-generator-preflight.md` (outside the repo to avoid accidental commit) containing:
- Animus version
- `animus-subject-linear` version installed
- Working subject invocation form (CLI / plugin call / MCP tool)
- Method names + param shapes from Step 3
- Working queue dispatch probe (A or B)
- Confirmed status casing values
- **Project scoping behavior (Step 6.5): backend-filtered vs needs post-filter**
- **Transition timestamp field name (Step 6.5): `state_updated_at` / `updatedAt` / fallback to `updated_at`**
- Subject YAML schema confirmed
- `on_failure` hook support: yes / no
- Krisp MCP: existing `command` / `args` / `env` block (if pre-configured) OR `"not configured"`
- Content-library MCP: existing `command` / `args` / `env` block (if pre-configured) OR `"not configured"` (note: Tasks 6–8 require this to be real, not stubbed — Krisp can be stubbed but content-library is production-critical)

This note is referenced by every subsequent task that needs to substitute a real invocation.

- [ ] **Step 11: No commit needed** — preflight modifies user state, not the repo.

---

## Task 0: Project scaffolding (state dir, gitignore, env vars, manifest bootstrap)

**Files:**
- Modify: `.gitignore`
- Modify: `.env.example`
- Create: `content/manifest.json`

- [ ] **Step 1: Add `.ao/state/` to `.gitignore`**

Edit `.gitignore`:

```
# AO runtime
.ao/logs/
.ao/state/
.ao/sync.json
```

**No `.gitkeep`.** Phases mkdir on demand.

- [ ] **Step 2: Append env vars to `.env.example`**

```
# Audio Transcript Source (Krisp; portable to Granola)
KRISP_API_KEY=

# Linear (via animus-subject-linear plugin)
LINEAR_API_TOKEN=
LINEAR_TEAM_ID=                        # Linear team UUID
LINEAR_DISCOVERY_PROJECT_ID=           # Linear project UUID for blog ideas
LINEAR_STATUS_MAP=                     # Optional JSON override; see plugin README
LINEAR_FINALIZE_TRANSITION=            # Optional: set to "done" to auto-complete on finalize

# Content Library MCP
CONTENT_LIBRARY_URL=
CONTENT_LIBRARY_TOKEN=
```

Do NOT add granular per-state IDs (`LINEAR_STATE_BACKLOG_ID` / `IN_PROGRESS_ID` / etc.) — the plugin auto-maps `WorkflowState.type`.

- [ ] **Step 3: Bootstrap `content/manifest.json`**

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
grep -c "LINEAR_TEAM_ID" .env.example
grep -c "LINEAR_STATE_BACKLOG_ID" .env.example
```
Expected: state line present, manifest empty array, team_id grep = 1, state_backlog grep = 0.

- [ ] **Step 5: Commit**

```bash
git add .gitignore .env.example content/manifest.json
git commit -m "Bootstrap discovery-flow state dir, env vars, manifest"
```

---

## Task 1: Add Krisp + content-library MCP servers and the `subjects:` block

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Add `krisp` and `content-library` to `mcp_servers:` (using existing config if available; TODO stubs otherwise)**

In `.animus/workflows/custom.yaml`'s existing `mcp_servers:` block, after the `perplexity:` entry, insert one of two forms based on preflight Step 9 outcome:

**Form A — pre-configured elsewhere:** copy the verified `command` / `args` / `env` block:

```yaml
  krisp:
    command: <verified command, e.g. npx>
    args:
    - <verified args>
    env:
      <verified env keys/values>
  content-library:
    command: <verified command>
    args:
    - <verified args>
    env:
      <verified env keys/values>
```

**Form B — not yet configured (TODO stubs):** install MCPs are not part of this work, but the YAML still declares the names so workflows that reference them compile cleanly. Stub form:

```yaml
  krisp:
    # TODO: replace with actual krisp MCP command/args/env once configured.
    # Discovery workflow phases will skip at runtime until this is real.
    command: "true"     # placeholder that always exits 0; phases referencing this MCP will fail-fast clearly
    args: []
    env: {}
  content-library:
    # TODO: same — replace with actual content-library MCP command/args/env.
    command: "true"
    args: []
    env: {}
```

**Do NOT add a `linear:` MCP server.** Linear access is via the subject backend.

**Rationale and gating — the two MCPs are NOT equivalent:**

- **`krisp` — stubable on either rollout path.** Only the `transcript-fetch` phase consumes it. With a TODO stub, the discovery workflow's scheduled runs no-op; everything downstream of human approval still ships and runs.

- **`content-library` — hard precondition for Tasks 4–14.** It's added to `content-strategist`, `content-writer`, and `seo-optimizer` in Tasks 6, 7, 8, and those agents run in `topic-research`, `ticket-to-brief`, `content-writing`, and `seo-review` across both `blog-production` and `blog-from-ticket`. If the MCP is stubbed:
  - The production agents fail at the point they try to query it.
  - This breaks the existing cron-driven `blog-production` flow that's running today, not just the new pipeline.

  Worse: skipping Tasks 6–8 to avoid that breakage leaves `blog-from-ticket`'s phase list (Task 11) referencing `ticket-to-brief`, which only gets defined in Task 6. A workflow that references a phase that doesn't exist is a YAML-validation failure.

  **Therefore the gate is binary:**
  - **content-library REAL** → full plan runs through Task 14.
  - **content-library "not configured"** → **stop after Task 3**. Idea-discovery + subject backend + the discovery schedule still ship (the strategist runs manifest-only dedup); no part of `blog-from-ticket` is built; Tasks 4–14 become a follow-up effort once the MCP exists. The user gets discovery tickets in Linear; humans can review them; the blog generation phase waits.

**Document the choice taken** in the commit message for this task: `"krisp <stub|real> + content-library <real|deferred>"`. The deferred path is a clean halt point, not a partial build.

- [ ] **Step 2: Add the `subjects:` block (verified list shape with `backend:`)**

Add at the top level (after `mcp_servers:`, before `agents:`):

```yaml
subjects:
  - id: linear-discovery
    backend: linear
    config:
      team_id: ${LINEAR_TEAM_ID:?set LINEAR_TEAM_ID}
      project_id: ${LINEAR_DISCOVERY_PROJECT_ID:?set LINEAR_DISCOVERY_PROJECT_ID}
```

The `${VAR:?msg}` form makes the daemon refuse to start without the required vars set.

- [ ] **Step 3: Validate and compile**

```bash
animus workflow config validate
animus workflow config compile
```
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add .animus/workflows/custom.yaml
git commit -m "Add krisp + content-library MCP servers and linear-discovery subject backend"
```

---

## Task 2: Add `transcript-collector` agent + `transcript-fetch` phase

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Add agent**

```yaml
  transcript-collector:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - krisp
    system_prompt: |
      You are a data-ingest agent. List new Krisp transcripts since a cursor
      and stage them to disk. You do NOT advance the cursor — the next phase
      does, only after successful processing.
```

- [ ] **Step 2: Add phase**

```yaml
  transcript-fetch:
    mode: agent
    agent: transcript-collector
    directive: |
      Read .ao/state/discovery-cursor.json. Use cursor.last_processed_at as
      the timestamp cutoff. If the cursor file is missing, treat as null and
      cap fetch at 20.

      mkdir -p .ao/state/transcripts

      List Krisp transcripts created strictly after the cutoff. For each (in
      chronological order):
        - Fetch full text + metadata (id, created_at, participants,
          duration_secs, title)
        - Write to .ao/state/transcripts/<id>.json with:
          { "id":"...", "created_at":"<ISO8601>", "participants":[...],
            "duration_secs":N, "title":"...", "text":"..." }

      DO NOT touch .ao/state/discovery-cursor.json. idea-strategist owns it.

      If no new transcripts, emit skip with reason "no_new_transcripts".
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - transcript_paths
      fields:
        transcript_paths:
          type: array
          items:
            type: string
        count:
          type: integer
    decision_contract:
      min_confidence: 0.5
      max_risk: low
      allow_missing_decision: true
```

- [ ] **Step 3: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Add transcript-collector agent and transcript-fetch phase (cursor advance deferred)"
```

---

## Task 3: Add `idea-strategist` agent + phase

**Files:**
- Modify: `.animus/workflows/custom.yaml`

Directive uses `<SUBJECT_CREATE>` and `<SUBJECT_LIST>` placeholders — substitute from preflight Step 4.

- [ ] **Step 1: Add agent**

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
      animus-subject-operations skill (auto-loaded) for correct subject
      API usage.

      CONTEXT: Read business-context.yaml at every run — niche, pillars,
      audience, voice, competitors, differentiators. Refuse if missing
      (skip reason "missing_business_context").

      Propose blog ideas grounded in transcripts and external SEO viability.
      Hard rule: LINEAR_DISCOVERY_PROJECT_ID must be set (skip reason
      "missing_project_id" otherwise).

      Cursor discipline: advance .ao/state/discovery-cursor.json ONLY after
      a transcript is fully processed (every surviving angle has either
      become a subject or been confirmed-duplicate). Fail mid-transcript
      leaves cursor at the previous transcript.
```

- [ ] **Step 2: Add phase**

```yaml
  idea-strategist:
    mode: agent
    agent: idea-strategist
    directive: |
      Input: transcript_paths from prior phase. If empty, emit skip.

      Step 1 — Local context
      Read business-context.yaml. Read content/manifest.json (treat missing
      as {"version":1,"posts":[]}). Query content-library MCP for topic
      fingerprints.

      Step 2 — Per-transcript synthesis
      For each transcript file in transcript_paths IN ORDER:
        a. Read transcript JSON.
        b. Extract 3-5 candidate blog angles. Each MUST quote a specific
           transcript moment with timestamp.
        c. External validation per candidate:
           - Search Console: keyword viability (volume, rank, striking distance)
           - Exa + Tavily + Brave: competitive landscape
           - Firecrawl: spot-scrape top 1-2 SERP pages for what's covered
             + 2-3 citable sources
        d. Filter/refine: drop dead-keyword angles, re-angle saturated
           SERPs, drop dupes against content/manifest.json AND content-library.
        e. For each surviving angle:
           i.   Compute idempotency key:
                "discovery:<transcript_id>:<8-char hash of (transcript_id + angle title)>"
           ii.  Check for existing subject:
                <SUBJECT_LIST> --kind linear (scoped to project) filtering
                description for the idempotency key.
                If found, skip (created in a prior run).
           iii. Create the subject (note: CLI flag is --body, NOT --description):
                <SUBJECT_CREATE> --kind linear --title "<headline>" \
                  --body "<structured markdown body with sections:
                    ## Source / Transcript: <id> @ <ts> / Quote: '<quote>'
                    ## Suggested target keyword / '<keyword>' GSC stats
                    ## Competitive landscape / top 3 URLs + gap
                    ## Pre-identified citable sources / 2-3 URLs
                    ## Suggested pillar / <pillar>
                    ## Dedup notes / <notes>
                    ## Idempotency key / <key>
                    >"
                Subjects are created at status=ready by default (the
                plugin auto-maps Linear's backlog state-type).
        f. AFTER all surviving angles for this transcript have been
           created-or-confirmed-duplicate, atomically write
           .ao/state/discovery-cursor.json:
             { "last_processed_id":"<transcript id>",
               "last_processed_at":"<transcript created_at>",
               "updated_at":"<current ISO8601>" }

      Step 3 — Emit phase result
      Output: list of {subject_id, title, transcript_id}.
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

- [ ] **Step 3: Substitute the verified subject invocations**

Replace `<SUBJECT_CREATE>` and `<SUBJECT_LIST>` with the form recorded in preflight Step 4.

- [ ] **Step 4: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Add idea-strategist agent and phase; cursor advances per-transcript"
```

---

## Task 4: Add `approval-watcher` agent + phase

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Add agent**

```yaml
  approval-watcher:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - ao
    system_prompt: |
      SKILLS: animus-subject-operations + animus-queue-management +
      animus-task-management.

      Polling agent. Detects Linear-backed subjects whose Animus status
      became in_progress (the approval signal) and dispatches blog-from-ticket
      runs for them.

      Filter rules (use exact lowercase values):
        - Include: status == in_progress
        - Exclude: status in {cancelled, done, blocked, ready}

      Scope every query to LINEAR_DISCOVERY_PROJECT_ID.
```

- [ ] **Step 2: Add phase**

The exact enqueue invocation depends on preflight Step 6 outcome (probe A = task wrapper; probe B = ad-hoc title). Below is the task-wrapper form; substitute with probe B form if that was what worked.

```yaml
  approval-watcher:
    mode: agent
    agent: approval-watcher
    directive: |
      Step 1 — Read seen set
      mkdir -p .ao/state
      Read .ao/state/approval-seen.json. If missing, treat as
      {"issues":[], "updated_at":null}.
      Schema reminder: each entry is
        { "subject_id": "...", "last_approved_at": "ISO8601" }.
      Keying by (subject_id, last_approved_at) — NOT subject_id alone —
      so re-approvals after a failed run can be re-enqueued.

      Step 2 — List Linear-backed subjects with status=in_progress
      <SUBJECT_LIST> --kind linear --status in_progress --json
      Capture for each: subject_id, title, body, project_id, AND the
      transition timestamp field identified in preflight Step 6.5
      (call it <TRANSITION_TS_FIELD> — typically state_updated_at,
      stateUpdatedAt, or fallback updated_at).

      Step 3 — Post-filter by project (per preflight Step 6.5 outcome)
      If preflight determined the backend does NOT scope by project_id
      via config alone, filter the returned list:
        keep only subjects where project_id == LINEAR_DISCOVERY_PROJECT_ID.
      If preflight confirmed backend scoping, skip this filter.

      Step 4 — Diff against seen using (subject_id, transition_ts)
      For each candidate subject:
        - Look up entry in approval-seen.json where subject_id matches.
        - If no entry exists: this is a new approval → enqueue.
        - If entry exists and entry.last_approved_at < subject.<TRANSITION_TS_FIELD>:
          this is a re-approval after the prior run → enqueue and overwrite.
        - If entry exists and entry.last_approved_at >= subject.<TRANSITION_TS_FIELD>:
          already enqueued for this approval → skip.

      Step 5 — Dispatch each enqueue-eligible subject
      (Use the form verified in preflight Step 6. There is NO `animus task`
      subcommand — tasks are subjects of kind=task. CLI flag for the
      task-subject body is --body. CLI flag for ad-hoc queue enqueue
      is --description.)

      [Task-subject wrapper form, if Probe A worked]
        TASK_ID=$(animus subject create \
          --kind task \
          --title "Blog: <subject title>" \
          --body "Wraps Linear subject <subject_id> for blog-from-ticket" \
          --status ready \
          --json | jq -r '.data.id')
        animus queue enqueue \
          --task-id "$TASK_ID" \
          --workflow-ref blog-from-ticket \
          --input-json "{\"linear_subject_id\":\"<subject_id>\"}"

      [Ad-hoc form, if Probe B was the working one]
        animus queue enqueue \
          --title "Blog: <subject title>" \
          --description "Linear subject: <subject_id>" \
          --workflow-ref blog-from-ticket \
          --input-json "{\"linear_subject_id\":\"<subject_id>\"}"

      Step 6 — Update seen set (atomic tmpfile + rename)
      For every successfully-enqueued subject:
        If subject_id was already in issues[], overwrite its
          last_approved_at with subject.<TRANSITION_TS_FIELD>.
        Otherwise append { subject_id, last_approved_at: subject.<TRANSITION_TS_FIELD> }.
      Set top-level updated_at = current ISO8601.
      Write via tmpfile + rename.

      Step 7 — Verdict
      If nothing newly approved, emit skip with reason "no_approvals".
      Else emit phase_result with enqueued list.
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

- [ ] **Step 3: Substitute the verified `<SUBJECT_LIST>` form and dispatch form**

Per preflight Steps 4 and 6.

- [ ] **Step 4: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Add approval-watcher: status=in_progress filter, task-wrapped queue dispatch"
```

---

## Task 5: Add `linear-coordinator` agent + `ticket-acknowledge` and `linear-finalize` phases (with cancellation guards)

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Add agent**

```yaml
  linear-coordinator:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers:
    - ao
    system_prompt: |
      SKILLS: animus-subject-operations (auto-loaded) for correct subject
      API usage.

      Manages Linear ticket comments (and optionally status) for
      blog-from-ticket runs. Two modes:
      - "acknowledge": re-check status; if still in_progress, post start
        comment; if not in_progress, abort cleanly.
      - "finalize": post rich completion comment; optionally transition
        to done if LINEAR_FINALIZE_TRANSITION=done.
```

- [ ] **Step 2: Add `ticket-acknowledge` phase (with cancellation guard)**

```yaml
  ticket-acknowledge:
    mode: agent
    agent: linear-coordinator
    directive: |
      Mode: acknowledge.

      Input: linear_subject_id (from --input-json of the queue dispatch).

      Step 1 — Cancellation guard
      <SUBJECT_GET> --kind linear --id <linear_subject_id>
      If status != "in_progress", emit FAIL with reason
      "subject_no_longer_in_progress". Do not post any comment.
      (Handles the race where a human cancels post-approval, before run starts.)

      Step 2 — Post start comment
      Read animus run_id from runtime context.
      Read branch: `git rev-parse --abbrev-ref HEAD`.
      <SUBJECT_COMMENT> --kind linear --id <linear_subject_id> --body "
        🤖 Blog generation started.
        Run: <run_id>
        Branch: <branch>"

      Step 3 — Pass through
      Output: linear_subject_id for downstream phases.

      Do NOT transition status. The human already moved to in_progress.
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - linear_subject_id
      fields:
        linear_subject_id:
          type: string
```

- [ ] **Step 3: Add `linear-finalize` phase**

```yaml
  linear-finalize:
    mode: agent
    agent: linear-coordinator
    directive: |
      Mode: finalize.

      Inputs from prior phases:
        - linear_subject_id (threaded through ticket-acknowledge → ticket-to-brief → … → register-post → linear-finalize)
        - slug (threaded through content-writing → seo-review → register-post)
        - branch (`git rev-parse --abbrev-ref HEAD`)
        - commit_message (from register-post stdout)

      Read content/<slug>.md frontmatter for title + meta_description.
      Read content/manifest.json entry for this slug (register-post just wrote it).

      Step 1 — Post completion comment
      <SUBJECT_COMMENT> --kind linear --id <linear_subject_id> --body "
        ✅ Blog draft ready for review.
        Title: <title>
        Slug: <slug>
        Word count: <word_count from manifest>
        Branch: <branch>
        Meta description: <meta_description>
        Featured image: assets/<slug>.webp"

      Step 2 — Optional status transition
      If LINEAR_FINALIZE_TRANSITION == "done":
        <SUBJECT_UPDATE> --kind linear --id <linear_subject_id> --status done
      Else:
        Leave status alone (human moves to their team's In Review state).

      Note: granular Linear state-name transitions (e.g. "In Review") are
      not expressible through the subject abstraction's 5 statuses. For
      that, use `animus plugin call --name animus-subject-linear ...` with
      the plugin's native set-state method (verify availability in
      preflight Step 3).
    capabilities:
      mutates_state: true
    output_contract:
      kind: phase_result
      required_fields:
      - linear_subject_id
      fields:
        linear_subject_id:
          type: string
        comment_id:
          type: string
```

- [ ] **Step 4: Substitute `<SUBJECT_GET>` / `<SUBJECT_COMMENT>` / `<SUBJECT_UPDATE>`**

From preflight Step 4.

- [ ] **Step 5: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Add linear-coordinator: ack guard against cancellation; finalize transition opt-in"
```

---

## Task 6: Add `ticket-to-brief` phase + extend `content-strategist` (with cancellation guard)

> **On the full plan path only** (`content-library` real, per Task 1's gate). On the deferred path the plan stopped at Task 3 and never reached here.

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Extend `content-strategist` mcp_servers**

In the existing `content-strategist:` agent block, replace its `mcp_servers:` list:

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

After:
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
      Convert an approved Linear-backed subject into a topic_brief.

      Input: linear_subject_id (threaded from ticket-acknowledge).

      Step 1 — Re-fetch the subject (mandatory)
      <SUBJECT_GET> --kind linear --id <linear_subject_id>
      Capture: title, description, status, comments.

      Step 2 — Cancellation guard
      If status != "in_progress", emit FAIL with reason
      "subject_no_longer_in_progress". (Defense in depth: even though
      ticket-acknowledge already checked, the human may have cancelled
      between phases.)

      Read business-context.yaml. Read content/manifest.json.

      Step 3 — Parse the description
      Extract from the body sections (which humans may have edited):
        - suggested_pillar (from "## Suggested pillar")
        - suggested_keyword (from "## Suggested target keyword",
          first quoted string)
        - pre_identified_sources (from "## Pre-identified citable sources")
        - source_transcript_id (from "## Source")

      Step 4 — Refine keyword
      Validate suggested_keyword via Search Console; prefer a better-shaped
      variant if found.

      Step 5 — Build topic_brief (same shape topic-research produces)
        - target_keyword: <refined>
        - content_pillar: <suggested_pillar or refined>
        - word_count_target: <1200-2500 by complexity>
        - unique_angle: <angle including transcript context>
        - data_sources_needed: <list — start from pre_identified_sources>
        - internal_link_targets: <from content-library + manifest; 2-3 slugs>
        - linear_subject_id: <pass through>
        - source_transcript_id: <pass through>
        - slug_hint: <kebab-case from title — content-writing may refine>

      Do NOT do deep external research here.
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
        linear_subject_id:
          type: string
        source_transcript_id:
          type: string
        slug_hint:
          type: string
```

- [ ] **Step 3: Substitute `<SUBJECT_GET>`**

- [ ] **Step 4: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Add ticket-to-brief with re-fetch + cancellation guard; extend content-strategist"
```

---

## Task 7: Extend `content-writer` (content-library MCP + slug pass-through)

> **On the full plan path only** (per Task 1's gate).

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Add `content-library` to `mcp_servers`**

```yaml
  content-writer:
    model: claude-opus-4-6
    tool: claude
    mcp_servers:
    - content-library
```

- [ ] **Step 2: Update internal-link guidance + slug threading in system_prompt**

Find:
```
      Internal links to 2-3 related blog posts.
```

Replace with:
```
      Internal links to 2-3 related blog posts. Source candidates from
      content-library MCP and content/manifest.json. Use real slugs of
      published posts. Do not invent slugs.

      Output contract reminder: slug is required and must be emitted
      verbatim — downstream register-post and linear-finalize phases
      depend on it.
```

- [ ] **Step 3: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Extend content-writer: content-library MCP + slug emission"
```

---

## Task 8: Extend `seo-optimizer` (content-library MCP + slug pass-through in output contract)

> **On the full plan path only** (per Task 1's gate).

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Add `content-library` to `mcp_servers`**

```yaml
    mcp_servers:
    - search-console
    - firecrawl
    - content-library
```

- [ ] **Step 2: Update internal-link verification line**

Find:
```
      - Internal links to 2-3 related blog posts (not service pages)
```

Replace with:
```
      - Internal links to 2-3 related blog posts (not service pages).
        Verify each slug via content-library MCP or content/manifest.json.
        Drop and replace any broken slug.
```

- [ ] **Step 3: Add slug to seo-review's output_contract**

In the existing `seo-review:` phase block, the output_contract is currently:
```yaml
    output_contract:
      kind: implementation_result
      required_fields:
      - commit_message
      fields:
        seo_score:
          type: integer
          description: SEO quality score 0-100 after fixes
        fixes_applied:
          type: array
```

Replace with:
```yaml
    output_contract:
      kind: implementation_result
      required_fields:
      - commit_message
      - slug
      fields:
        commit_message:
          type: string
        slug:
          type: string
          description: Post slug threaded from content-writing
        seo_score:
          type: integer
          description: SEO quality score 0-100 after fixes
        fixes_applied:
          type: array
```

Update the directive in `seo-review:` to explicitly thread slug:
```
      Read the slug from content-writing's output and include it in your
      phase result (required field). Downstream register-post depends on
      receiving the slug.
```

- [ ] **Step 4: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Extend seo-optimizer: content-library MCP + thread slug to output"
```

---

## Task 9: TDD `register-post.sh` (emits commit_message to stdout)

**Files:**
- Create: `scripts/register-post.sh`
- Create: `scripts/test/register-post.bats`

The change from prior plan revision: **the script emits its commit message to stdout** so the phase contract's `commit_message` field can be populated.

- [ ] **Step 1: Install bats / yq / jq if missing**

```bash
which bats || brew install bats-core
which yq && which jq
```

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
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "appends a second post" {
  write_post "first-post"
  ./scripts/register-post.sh first-post
  write_post "second-post"
  run ./scripts/register-post.sh second-post
  [ "$status" -eq 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "2" ]
}

@test "extracts required frontmatter fields" {
  write_post "fields-test"
  ./scripts/register-post.sh fields-test
  run jq -r '.posts[0].title' content/manifest.json
  [ "$output" = "Test Post About fields-test" ]
  run jq -r '.posts[0].pillar' content/manifest.json
  [ "$output" = "Test Pillar" ]
  run jq -r '.posts[0].word_count' content/manifest.json
  [ "$output" = "1500" ]
}

@test "is idempotent for the same slug" {
  write_post "idem-post"
  ./scripts/register-post.sh idem-post
  run ./scripts/register-post.sh idem-post
  [ "$status" -eq 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "fails on broken frontmatter without corrupting manifest" {
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

@test "emits commit_message to stdout in a parseable form" {
  write_post "stdout-post"
  run ./scripts/register-post.sh stdout-post
  [ "$status" -eq 0 ]
  # The script's last stdout line must contain the commit message so the
  # phase can capture it as the output contract's `commit_message` field.
  [[ "$output" == *"Register stdout-post in content manifest"* ]]
}

@test "honors LINEAR_SUBJECT_ID and SOURCE_TRANSCRIPT_ID env" {
  write_post "env-post"
  LINEAR_SUBJECT_ID="BLG-42" SOURCE_TRANSCRIPT_ID="krisp-xyz" \
    ./scripts/register-post.sh env-post
  run jq -r '.posts[0].linear_subject_id' content/manifest.json
  [ "$output" = "BLG-42" ]
  run jq -r '.posts[0].source_transcript_id' content/manifest.json
  [ "$output" = "krisp-xyz" ]
}
```

- [ ] **Step 3: Verify tests fail (script doesn't exist)**

```bash
bats scripts/test/register-post.bats
```
Expected: all 8 tests fail.

- [ ] **Step 4: Write the script (emits commit_message to stdout)**

Create `scripts/register-post.sh`:

```bash
#!/usr/bin/env bash
# register-post.sh — Append a post entry to content/manifest.json
#
# Usage: ./scripts/register-post.sh <slug>
# Optional env: LINEAR_SUBJECT_ID, SOURCE_TRANSCRIPT_ID, BRANCH
# Stdout (last line): the commit message — captured by the calling phase
# to satisfy its commit_message output contract field.

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
COMMIT_MSG="Register ${SLUG} in content manifest"
if [ "$existing" -gt 0 ]; then
  # Idempotent: same slug already present. Emit the commit message anyway
  # so the calling phase's output contract is satisfied; no git activity.
  echo "manifest already contains slug: $SLUG (skipping)" >&2
  echo "$COMMIT_MSG (no-op — already registered)"
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
git commit -m "$COMMIT_MSG" --quiet

# Final stdout line: the commit message (parsed by the calling phase).
echo "$COMMIT_MSG"
```

- [ ] **Step 5: Rerun tests**

```bash
chmod +x scripts/register-post.sh
bats scripts/test/register-post.bats
```
Expected: all 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/register-post.sh scripts/test/register-post.bats
git commit -m "Add register-post.sh + bats tests; script emits commit_message on stdout"
```

---

## Task 10: Add `register-post` phase as an agent that reads `slug` from `seo-review` output

**Files:**
- Modify: `.animus/workflows/custom.yaml`

The phase reads `slug` from the most recent phase that emits it (now `seo-review`, per Task 8's output contract change). It also reads `linear_subject_id` and `source_transcript_id` from the run input / earlier phase outputs.

- [ ] **Step 1: Add `register-post-runner` agent**

```yaml
  register-post-runner:
    model: claude-haiku-4-5
    tool: claude
    mcp_servers: []
    system_prompt: |
      You are a one-shot script runner. Read slug from prior phase output
      (seo-review's output_contract emits it). Read linear_subject_id and
      source_transcript_id from the run input / topic_brief phase if
      available. Run scripts/register-post.sh with those as env vars.
      Capture the last stdout line as commit_message.
```

- [ ] **Step 2: Add `register-post` phase**

```yaml
  register-post:
    mode: agent
    agent: register-post-runner
    directive: |
      Read inputs:
        - slug: from seo-review's phase result (required)
        - linear_subject_id: from the run input (`linear_subject_id` in
          the workflow's input_json) — empty string if not present (used
          for cron-driven blog-production runs)
        - source_transcript_id: from ticket-to-brief's topic_brief (if
          this is a blog-from-ticket run) — empty string otherwise

      Run via Bash:
        env LINEAR_SUBJECT_ID="<linear_subject_id or empty>" \
            SOURCE_TRANSCRIPT_ID="<source_transcript_id or empty>" \
            bash scripts/register-post.sh "<slug>"

      Parse the last non-empty stdout line as `commit_message`.

      Output:
        - slug (pass-through for linear-finalize)
        - linear_subject_id (pass-through for linear-finalize)
        - commit_message
    capabilities:
      mutates_state: true
    output_contract:
      kind: implementation_result
      required_fields:
      - commit_message
      - slug
      fields:
        commit_message:
          type: string
        slug:
          type: string
        linear_subject_id:
          type: string
```

- [ ] **Step 3: Validate, compile, commit**

```bash
animus workflow config validate
animus workflow config compile
git add .animus/workflows/custom.yaml
git commit -m "Add register-post agent phase; reads slug from seo-review, emits via stdout"
```

---

## Task 11: Define workflows; insert `register-post` BEFORE `push-branch`

**Files:**
- Modify: `.animus/workflows/custom.yaml` (workflows block)

- [ ] **Step 1: Retrofit `register-post` into `blog-production` BEFORE `push-branch`**

Replace the existing `blog-production` workflow's phases list:

Before:
```yaml
- id: blog-production
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
  phases:
  - topic-research
  - research-collection
  - content-writing
  - commit-draft
  - seo-review
  - asset-generation
  - social-excerpts
  - register-post           # BEFORE push-branch — single push ships everything
  - push-branch
```

- [ ] **Step 2: Add the three new workflows**

After `news-monitor`:

```yaml
- id: idea-discovery
  name: Transcript-Driven Idea Discovery
  description: Poll Krisp transcripts and propose blog ideas as Linear-backed subjects
  phases:
  - transcript-fetch
  - idea-strategist

- id: approval-watch
  name: Linear Approval Watcher
  description: Poll Linear-backed subjects for in_progress status and dispatch blog-from-ticket
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
  - register-post           # BEFORE push-branch
  - push-branch
  - linear-finalize
```

- [ ] **Step 3: Validate, compile, list**

```bash
animus workflow config validate
animus workflow config compile
animus workflow definitions list
```
Expected: 7 workflow definitions total. `animus workflow get --id blog-from-ticket` returns the 11-phase pipeline.

(`workflow definitions list` shows YAML-defined workflows; `workflow list` shows runtime *runs* — use definitions for static verification.)

- [ ] **Step 4: Commit**

```bash
git add .animus/workflows/custom.yaml
git commit -m "Define discovery + approval-watch + blog-from-ticket workflows; register-post before push-branch"
```

---

## Task 12: Add schedules

**Files:**
- Modify: `.animus/workflows/custom.yaml`

- [ ] **Step 1: Add schedules**

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
git add .animus/workflows/custom.yaml
git commit -m "Schedule discovery (daily 7am) + approval-watch (every 15 min)"
```

---

## Task 13: Smoke tests (verified CLI commands only)

**Files:** none modified.

- [ ] **Step 1: Compile**

```bash
animus workflow config compile
```

- [ ] **Step 2: Render strategist phase prompt**

```bash
animus workflow prompt render \
  --workflow-ref idea-discovery \
  --phase idea-strategist
```
Expected: full prompt with no raw template placeholders.

- [ ] **Step 3: Render every phase of `blog-from-ticket`**

```bash
animus workflow prompt render \
  --workflow-ref blog-from-ticket \
  --all-phases
```
Expected phase order:
```
1. ticket-acknowledge
2. ticket-to-brief
3. research-collection
4. content-writing
5. commit-draft
6. seo-review
7. asset-generation
8. social-excerpts
9. register-post
10. push-branch
11. linear-finalize
```

- [ ] **Step 4: Definitions list + get blog-production**

```bash
animus workflow definitions list
animus workflow get --id blog-production
```
Expected: definitions list shows all 7; `get --id blog-production` reveals `register-post` between `social-excerpts` and `push-branch`.

- [ ] **Step 5: Ping plugin**

```bash
animus plugin ping --name animus-subject-linear
```

- [ ] **Step 6: Confirm grep invariants**

```bash
grep -E "^\s+(krisp|content-library):" .animus/workflows/custom.yaml
grep -E "^subjects:" .animus/workflows/custom.yaml
grep -c "^\s*- id: linear-discovery$" .animus/workflows/custom.yaml
# Confirm we did NOT add a linear MCP server:
grep -cE "^\s+linear:\s*$" .animus/workflows/custom.yaml | tee /tmp/lin_mcp.txt
```
Expected: krisp / content-library each once; subjects: top-level present; `linear-discovery` id appears; `linear:` under mcp_servers does NOT appear.

- [ ] **Step 7: State dir fully ignored**

```bash
git check-ignore .ao/state/anything
test -f .ao/state/.gitkeep && echo "BUG: gitkeep present" || echo "OK: no gitkeep"
```

- [ ] **Step 8: No commit**

---

## Task 14: Update docs (CLAUDE.md done in Task -2; here: README + MCP-TOOLS)

**Files:**
- Modify: `MCP-TOOLS.md`
- Modify: `README.md`

- [ ] **Step 1: Update `MCP-TOOLS.md`**

Above the existing "## Which Agents Use What" code block, insert:

```markdown
## Discovery Loop

| Server | Package | What It Does |
|--------|---------|--------------|
| **Krisp** | (in workflow YAML) | Audio transcript ingest |
| **Content Library** | (in workflow YAML) | Org-wide content + artifact database |

## Subject Backends

Linear is integrated as an **Animus subject backend** (not an MCP server).
The `animus-subject-linear` plugin auto-maps Linear's `WorkflowState.type`
to Animus's normalized lowercase statuses (`ready / in_progress / blocked
/ done / cancelled`).

| Backend | Plugin | What It Does |
|---|---|---|
| **Linear** | `launchapp-dev/animus-subject-linear` | Linear issues as Animus subjects: CRUD + status + comments |

One-time install:
```bash
animus plugin install launchapp-dev/animus-subject-linear
```
```

Replace the existing "Which Agents Use What" block with:

```
Strategist           → ao, exa, tavily, brave, firecrawl, search-console, content-library
Researcher           → firecrawl, exa, tavily, brave, google-maps
Writer               → content-library
SEO Optimizer        → search-console, firecrawl, content-library
Asset Generator      → replicate
Performance Analyst  → ao, search-console, exa, perplexity
Content Refresher    → firecrawl
Transcript Collector → krisp
Idea Strategist      → ao, exa, tavily, brave, firecrawl, search-console, content-library
Approval Watcher     → ao
Linear Coordinator   → ao
Register Post Runner → (local script only)
```

- [ ] **Step 2: Add Discovery Flow + daemon-env section to `README.md`**

```markdown
## Discovery Flow (transcript-driven)

In addition to the cron-driven `blog-production` pipeline, this generator
supports a transcript-driven discovery loop with a human-review gate in
Linear (integrated as an Animus subject backend).

**Daily 7am — `idea-discovery`**
Polls Krisp for new transcripts. The strategist proposes 3–5 angles per
transcript, each pre-validated with Search Console + competitor scan +
spot-scraped citable sources. Surviving angles become Linear issues
(Animus subjects) at status `ready`.

**Every 15 min — `approval-watch`**
Polls Linear-backed subjects for `status == in_progress` (the human-approval
signal — a Linear state-type `started` transition). Each newly-approved
subject is dispatched to `blog-from-ticket` via the queue. Cancelled,
Done, and Blocked subjects are filtered out.

**Per approved ticket — `blog-from-ticket`**
A variant of blog-production using the Linear ticket as topic brief.
`ticket-acknowledge` and `ticket-to-brief` both re-check the subject's
status; if the human cancelled after approval, the run aborts cleanly
without further side effects. `register-post` runs before `push-branch`
so the manifest commit ships with the final push. Last phase posts a
completion comment; status transition is opt-in via
`LINEAR_FINALIZE_TRANSITION=done`.

### One-time setup

```bash
# Install the Linear subject backend plugin (host-wide)
animus plugin install launchapp-dev/animus-subject-linear

# Verify
animus plugin list
animus plugin ping --name animus-subject-linear
```

### Daemon environment (.env is NOT auto-loaded)

The Animus daemon does **not** auto-load `.env`. Source it into the daemon's
parent shell before starting, or pass secrets inline:

```bash
# Pattern A: source the env file then start the daemon
set -a; source .env; set +a
animus daemon start --autonomous

# Pattern B: inline (good for one-shot runs)
LINEAR_API_TOKEN=lin_api_... KRISP_API_KEY=... CONTENT_LIBRARY_TOKEN=... \
  animus daemon start --autonomous
```

The workflow YAML's `subjects:` block uses `${LINEAR_TEAM_ID:?set LINEAR_TEAM_ID}`
so the daemon **refuses to start** if required vars are missing — early
failure beats mysterious runtime errors.

### Required `.env` values

- `KRISP_API_KEY`
- `LINEAR_API_TOKEN`, `LINEAR_TEAM_ID`, `LINEAR_DISCOVERY_PROJECT_ID`
- `CONTENT_LIBRARY_URL`, `CONTENT_LIBRARY_TOKEN`

### Optional

- `LINEAR_STATUS_MAP` — JSON override of the default `WorkflowState.type` mapping
- `LINEAR_FINALIZE_TRANSITION=done` — auto-mark complete on finalize

### State

Gitignored runtime state (`.ao/state/`):
- `discovery-cursor.json` — last *processed* Krisp transcript
- `approval-seen.json` — already-enqueued Linear subject IDs
- `transcripts/<id>.json` — staged transcripts

Tracked in repo (`content/manifest.json`):
- Canonical list of every post this generator produced; written by
  `register-post` and consumed by the strategist for local dedup +
  the writer / SEO for real internal-link slugs.
```

- [ ] **Step 3: Commit**

```bash
git add MCP-TOOLS.md README.md
git commit -m "Document discovery flow + animus-subject-linear setup + daemon-env discipline"
```

---

## Review history

Per-round reviewer findings and their resolutions are in [2026-06-05-discovery-flow-review-history.md](./2026-06-05-discovery-flow-review-history.md). Keeping this plan focused on the forward state.

## Self-Review

**Spec coverage:** every spec section maps to a task. Path migration (Task -2), preflight (Task -1), scaffolding (Task 0), MCP + subjects (Task 1), discovery workflow (Tasks 2-3) — **gate** — approval workflow (Task 4), blog-from-ticket workflow (Tasks 5-6, 10), extensions (Tasks 7-8), script (Task 9), workflow definitions (Task 11), schedules (Task 12), smoke tests (Task 13), docs (Task 14).

**Conditional rollout gate:** Tasks 4–14 require `content-library` to be a real MCP server (not the `command: "true"` stub form). If preflight Step 9 reports `content-library = "not configured"`, the plan halts after Task 3. Idea-discovery + the subject backend + the cron schedule for discovery still ship — the strategist runs with manifest-only dedup. Nothing in `blog-from-ticket` is built because Task 11's workflow definition would reference phases (`ticket-to-brief`) that only exist if Task 6 ran. Krisp can be a stub even on the full path — only the `transcript-fetch` phase consumes it.

**Placeholder scan:** the only placeholders are `<SUBJECT_LIST>` / `<SUBJECT_CREATE>` / `<SUBJECT_GET>` / `<SUBJECT_UPDATE>` / `<SUBJECT_COMMENT>` (resolved by preflight Step 4). MCP wiring in Task 1 is a two-branch decision per preflight Step 9: copy verified `command` / `args` / `env` (Form A) OR TODO stub (Form B). Content-library must be Form A to proceed past Task 3; Krisp may take either form.

**Type consistency:**
- `linear_subject_id` flows: input_json → ticket-acknowledge → ticket-to-brief.topic_brief → register-post (env) → linear-finalize ✓
- `slug` flows: content-writing → seo-review (now required in contract per Task 8) → register-post → linear-finalize ✓
- `source_transcript_id` flows: idea-strategist writes to subject description → ticket-to-brief parses → topic_brief → register-post (env) ✓
- Status filter values are lowercase everywhere ✓
- Subject CLI uses `--kind linear` (not `--kind linear-discovery`) ✓
- Workflow file path is `.animus/workflows/custom.yaml` everywhere ✓
