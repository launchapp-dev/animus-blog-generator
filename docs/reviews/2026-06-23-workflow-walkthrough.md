# Workflow Walkthrough & Failure-Mode Audit

**Date:** 2026-06-23
**Verified against:** Animus CLI `0.5.21`, `animus-subject-linear` `0.1.8`,
`animus-subject-sqlite` `0.1.4`. Subject: `.animus/workflows/custom.yaml`
(compiles clean: 10 workflows, 21 phases, 12 agents, 0 errors).

This is a structural + runtime walkthrough of all seven workflows: where each
can fail and why. Findings are grouped into **cross-cutting gates** (affect many
workflows), a **per-workflow trace**, and **assumptions that need a live Linear
token to confirm**. Severity reflects likelihood × blast radius at this scale
(solo operator, a few posts/week, manual approval gate).

## Environment facts established this pass

| Check | Result |
|---|---|
| git `origin` | Real: `github.com/launchapp-dev/animus-blog-generator` → `push-branch`/`image-push` push for real |
| `subject create` flags | `--kind --title --status --priority --labels --body --json` (no `--project`) |
| `subject list` flags | `--kind --status --json --limit --project-root` (**no `--project`**) |
| `subject update` flags | `--kind --id --status --json` only (**no comment/body** → comments must use `plugin call`) |
| `queue enqueue` flags | `--task-id` / `--requirement-id` / `--title`+`--description`, `--workflow-ref`, `--input-json` (task-id mutually exclusive) |
| linear schema | `status_values` hyphenated; `supports_create: true` (0.1.8); `supports_watch: false`; `supports_delete: false`; `supports_pagination: true` |
| sqlite `blogtask` | `supports_create: true` under `ANIMUS_SQLITE_KINDS=blogtask` |
| `content/`, `assets/` | Both tracked via `.gitkeep` → always present in fresh worktrees |
| `yq`, `jq` | Present (`/opt/homebrew/bin/yq`, `/usr/bin/jq`) |

---

## Cross-cutting gates (these dominate everything)

### G1 — All external MCP secrets are `UNSET` (HIGH)
`exa, tavily, brave, firecrawl, google-maps, search-console, replicate,
perplexity` all interpolate `${X:-UNSET}`. Any phase that calls these will fail
or silently degrade (the MCP server starts but every API call 401s). This gates
**every content workflow**, not just discovery.
**Fix:** populate `.env` and start the daemon with those vars in its parent
shell (the daemon does **not** auto-load `.env`).

### G2 — `content-library` is stubbed *and* wired into 4 agents (HIGH, fixable now)
The MCP server is `command: "true"` (exits immediately), and its own TODO says
*"do not wire it into those agents yet."* But it **is** listed in the
`mcp_servers` of `content-strategist` (L105), `content-writer` (L141),
`seo-optimizer` (L175), and `idea-strategist` (L266). On daemon start those
agents will try to MCP-handshake a server that exits instantly. Best case the
daemon logs a dead-server warning and the agent runs without those tools; worst
case it stalls/fails the phase.
**Fix now:** remove `content-library` from those four agents until the real
server exists (the directives already treat manifest.json as the fallback
source), OR replace the stub with a server that stays alive but no-ops.

### G3 — Four schedules are `enabled: true` against unconfigured secrets (HIGH, operational)
`blog-primary` (Tue 08:00), `blog-secondary` (Thu 08:00), `refresh` (Wed 08:00),
`news` (daily 06:00) are all enabled. The moment the daemon runs, these fire and
fail (G1/G2). Only `discovery` and `approval-watch` are correctly gated to
`false`.
**Fix:** set the four content schedules to `enabled: false` until `.env` is
populated, mirroring the discovery/approval pattern — or only start the daemon
once secrets are in.

### G4 — Required env must live in the daemon's parent shell (operational)
Beyond MCP keys: `LINEAR_API_TOKEN`, `LINEAR_TEAM_ID`,
`LINEAR_DISCOVERY_PROJECT_ID`, `LINEAR_FINALIZE_TRANSITION` (optional), and
`ANIMUS_SQLITE_KINDS=blogtask` (without this, the `blogtask` kind never
registers and the approval-watcher wrapper-create fails into its ad-hoc
fallback). All are in `.env.example`.

### G5 — Daemon restart required for plugin 0.1.8 (operational)
`plugins.lock` changed when we installed 0.1.8. A YAML hot-reload won't pick up a
new plugin binary; `animus daemon restart` (or first start) will. Daemon is
currently stopped, so next start is sufficient.

### G6 — Pushes are real (medium, operational)
`push-branch` / `image-push` run `git push -u origin HEAD` against the real
GitHub remote. The daemon's environment needs git/gh credentials with push
rights to this repo, and every successful run pushes a branch. Confirm this is
intended for autonomous cron runs.

---

## Per-workflow trace

### 1. `idea-discovery` (transcript-fetch → idea-strategist) — schedule disabled
- **transcript-fetch** (`krisp` MCP = stub): fails fast by design — the stub
  exits, so the phase errors instead of silently producing nothing. Correct
  until Krisp is wired.
- **idea-strategist**: `animus subject create --kind issue` now **works** (0.1.8
  `supports_create: true`) — this was broken on 0.1.7. Residual risks: needs
  `LINEAR_API_TOKEN` + `LINEAR_DISCOVERY_PROJECT_ID` (G4); `content-library`
  dedup is a no-op while stubbed (G2) so it falls back to `manifest.json` only;
  created issues rely on the backend's `subjects.linear-discovery.project_id`
  config to land in the right project (there's no `--project` on `create` —
  see assumption A4). Cursor write is atomic and only after full processing —
  sound.

### 2. `approval-watch` (approval-watcher) — schedule disabled
- Status filter is now correct (`in-progress`, fixed this session).
- `supports_watch: false` confirms polling is the only option — design is right.
- **No `--project` on `subject list`** → scoping is post-filter only; this
  depends on `subject list --json` actually returning `project_id` per subject
  (assumption A2).
- Wrapper create: `--kind blogtask` needs `ANIMUS_SQLITE_KINDS=blogtask` (G4);
  `queue enqueue --task-id <blogtask id>` may be rejected if `--task-id` only
  accepts `task` kind — the directive's ad-hoc `--title` fallback covers this
  (assumption A3).
- Idempotency via `approval_key` + seen-set is robust **if** a real transition
  timestamp exists; otherwise it falls back to status-history, which is weaker
  (a comment-only update that flips list ordering won't mislead it, but a
  manual out→in bounce with no transition ts relies on the last-seen-status
  branch). Acceptable.

### 3. `blog-from-ticket` (the human-approved path)
- **ticket-acknowledge**: posts a Linear comment via
  `plugin call subject/update --params '{...patch:{comment:...}}'`. This is the
  **single most important unverified assumption** (A1) — the generic CLI can't
  post comments, so everything depends on the plugin's `subject/update`
  accepting a `comment` patch field. Cancellation guard (status != in-progress)
  is now correct. JSON built with `jq -n` — injection-safe.
- **ticket-to-brief**: re-fetch + cancellation guard (good, defense in depth);
  `content-library` for internal links is a no-op while stubbed (G2);
  `search-console` keyword refine needs creds (G1). `mutates_state: false` is
  correct.
- **research-collection**: firecrawl/exa/tavily/brave/google-maps all gated by
  G1.
- **content-writing**: `content-library` stub (G2); writes `content/<slug>.md`;
  emits required `slug`. Model `claude-opus-4-6` is valid.
- **commit-draft**: `git add content/ assets/` is **safe** because both dirs are
  tracked via `.gitkeep`. Note: removing the `.gitkeep`s would reintroduce a
  bug — `git add` errors (exit 128) and stages **nothing** if either pathspec is
  missing, so the draft would silently not commit. Keep the `.gitkeep`s.
- **seo-review**: search-console/firecrawl/content-library gated (G1/G2); slug
  threaded + emitted (fixed earlier). `schema_recommendation` fallback is sound.
- **asset-generation**: `replicate` gated by G1 → image generation fails without
  the token. WebP validation logic is good once it runs.
- **social-excerpts**: pure LLM text generation (no Replicate API call) → works
  without external secrets; only depends on the post existing.
- **register-post**: runs `scripts/register-post.sh`; deps present locally, but
  the **daemon's PATH must include `/opt/homebrew/bin`** for `yq` (assumption
  A5). `content/manifest.json` exists.
- **push-branch**: G6.
- **linear-finalize**: same comment-posting assumption as ticket-acknowledge
  (A1); optional `done` transition via `subject update --status done` (generic
  CLI supports `--status` ✓).

### 4. `blog-production` (cron, ENABLED) — topic-research → … → push-branch
- **topic-research**: handles `preferred_topic` (news-triggered) vs generic
  discovery with a staleness guard — well wired to `news-scan`'s output. Gated by
  search-console/exa (G1). Then identical content pipeline as above (G1/G2 on
  every external phase). **Because the schedule is enabled (G3), this fails
  weekly until secrets land.**

### 5. `refresh-cycle` (cron, ENABLED)
- **performance-analysis**: `decision_contract.allow_missing_decision: false` →
  if the analyst can't produce a decision (e.g. search-console down per G1), the
  phase **fails hard** rather than skipping. Highest-friction decision contract
  in the file. Gated by search-console + perplexity (G1).
- content-refresh-write / refresh-seo-review / push-branch: G1 / G6.

### 6. `image-refresh` (manual)
- **image-regen**: `replicate` gated by G1. WebP validation good.
- **image-push**: G6.

### 7. `news-monitor` (cron, ENABLED)
- **news-scan**: brave/exa gated by G1; `decision_contract.allow_missing_decision: false`.
  On a material event, creates a task + enqueues `blog-production` with a
  structured `input_json` (`preferred_topic`, `event_date`, `urgency_reason`,
  `source_urls`, `preferred_pillar`) — correctly consumed by topic-research.

---

## Assumptions that need a live Linear token to confirm

These can't be verified from the static schema; they're the highest-value things
to test the moment a token exists:

- **A1 (HIGH):** `animus-subject-linear` `subject/update` accepts a
  `patch.comment` field and posts it as a Linear comment. **Both**
  `ticket-acknowledge` and `linear-finalize` depend on this; if the plugin
  expects comments via a different method/field, both fail. *Test:*
  `animus plugin call --name animus-subject-linear --method subject/update --params '{"id":"<real>","patch":{"comment":"test"}}'`.
- **A2 (MED):** `subject list --kind issue --status in-progress --json` returns
  `project_id` per subject (the approval-watcher post-filter needs it) and a
  status-transition timestamp (`state_updated_at`/equiv) for the strong
  idempotency path.
- **A3 (LOW):** `queue enqueue --task-id <blogtask-id>` accepts a non-`task`
  kind. If not, the ad-hoc `--title` fallback fires (already authored).
- **A4 (MED):** `subject create --kind issue` (no `--project` flag) lands the
  issue in `LINEAR_DISCOVERY_PROJECT_ID` via the `subjects.linear-discovery`
  backend config. If creation ignores that config, discovery issues land in the
  wrong/no project.
- **A5 (LOW):** the daemon's `PATH` includes `yq` (`/opt/homebrew/bin`) for
  `register-post.sh`.

---

## Go-live readiness checklist

**Fixable in YAML now (no secrets needed):**
1. Remove `content-library` from the 4 agents' `mcp_servers` until the real
   server exists (G2).
2. Set `blog-primary`/`blog-secondary`/`refresh`/`news` to `enabled: false`
   until `.env` is populated (G3).

**Before first real run:**
3. Populate `.env` with all MCP keys + Linear vars + `ANIMUS_SQLITE_KINDS=blogtask`,
   source it into the daemon's shell (G1/G4).
4. `animus daemon restart` to load plugin 0.1.8 (G5).
5. Confirm daemon git/gh push credentials (G6).

**First live smoke test (with token):**
6. Verify A1 (comment posting) and A4 (issue→project) — these are the two that
   silently break the human-in-the-loop flow.
7. Enable `discovery` + `approval-watch`, file one test idea end-to-end through
   `blog-from-ticket`.
