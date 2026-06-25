  # Implementation Plan: Deterministic Approval Watcher

  **Date:** 2026-06-23
  **Status:** Ready to implement (gated on a live-Linear smoke test before enabling the schedule)
  **Revision:** rev. 2 — incorporates external review: two-phase state write, fail-closed project scoping, list pagination, `--task-id` enqueue-rejection fallback, fail-closed on unknown state version, required live-doc fixes.
**Revision:** rev. 3 — smoke test mirrors the script's fetch (`--limit 500 --json` + truncation check); the ad-hoc enqueue fallback is envelope-aware (`--json` + `.ok`).
  **Verified against:** Animus CLI `0.5.21`, `animus-subject-linear` `0.1.8`.

  ## Goal

  Replace the scheduled `approval-watcher` **agent** phase with a deterministic
  **command** phase backed by `scripts/approval-watch.sh`. The phase's only job is
  an exact, idempotent gate: detect Linear issues a human moved to `in-progress`
  (the approval) and dispatch `blog-from-ticket` exactly once. There is no
  judgment in it, so it should be tested shell code, not a recurring LLM call that
  can drift and double-dispatch.

  ## Why this is worth doing

  - **Idempotency must be exact.** LLM drift on the dedup key risks duplicate blog
    generation (wasted cost + duplicate Linear comments) or missed approvals.
  - **Cost.** The schedule polls every 15 min (~96×/day), almost always a no-op.
    A command phase costs zero model tokens on the no-op path.
  - **Testability.** Deterministic logic gets a `bats` suite (same pattern as
    `scripts/register-post.sh` + `scripts/test/register-post.bats`).

  ## Current state (post-split)

  - The `approval-watcher` **phase** now lives in
    `.animus/workflows/workflow-approval-watch.yaml` (it was moved out of
    `custom.yaml` during the per-workflow split).
  - The `approval-watcher` **agent definition** remains in `custom.yaml`.
  - The `approval-watch` schedule is `enabled: false`.
  - It currently creates a local `blogtask` wrapper, enqueues `blog-from-ticket`,
    and writes `.animus/state/approval-seen.json`.

  ## Verified contracts this plan depends on

  | Fact | Source | Consequence for the script |
  |---|---|---|
  | Normalized status is **`in-progress`** (hyphen) | `subject/schema` `status_values` | match `in-progress`, never `in_progress` |
  | CLI emits an **envelope** `{schema, ok, data\|error}` | `subject create --help`; observed `subject list` error | check `.ok`, iterate `.data[]`, read `.error.code` |
  | `subject/list` **is supported** by the linear backend | plugin `capabilities` | list-all is the path; no per-status fallback needed |
  | `subject list` has **no `--project` flag** | `subject list --help` | scope by **post-filter** on `project_id` |
  | No `state_updated_at` in schema (`custom_fields` = priority, linear_state_name, linear_state_type, linear_uuid) | `subject/schema` | `transition_ts` is usually `null` → re-approval rides the **last-seen-status** branch |
  | sqlite `blogtask` create works under `ANIMUS_SQLITE_KINDS=blogtask` | `subject/schema` on sqlite | wrapper create needs that env; keep an ad-hoc fallback |
  | `.animus/state/` is **gitignored** | `git check-ignore` | state is NOT in worktrees → phase must run with `worktree: skip` |

  ## Design decisions (the corrections that make it actually work)

  1. **`worktree: skip` is mandatory.** Command phases default to a fresh per-run
    git worktree, and `.animus/state/` is gitignored so it isn't present in a
    worktree. Writing `approval-seen.json` inside a worktree means it's discarded
    every run → the seen-set is always empty → every poll re-dispatches every
    approval. `worktree: skip` runs the phase in the stable project root so state
    persists. **This is the single most important correction.**
  2. **Status compares to `in-progress`.**
  3. **Envelope-aware:** branch on `.ok`; iterate `.data[]`; on `.ok == false`
    **fail loud** (exit nonzero) with `.error.code` in stderr. No per-status
    fallback — the linear backend supports `subject/list`, and a fallback would
    only mask the real "backend unavailable" failure.
  4. **Re-approval without timestamps:** record the **last-seen status of every
    subject**, not just in-progress ones, so a subject that leaves and re-enters
    `in-progress` is detected even when `transition_ts` is null.
  5. **`blogtask` resilience:** try the sqlite wrapper; if create fails (e.g.
    `ANIMUS_SQLITE_KINDS` unset, or `--task-id` rejects the kind), fall back to
    ad-hoc `queue enqueue --title`. Build all `--input-json` with `jq -n` (no
    string interpolation).
  6. **Missing `project_id`: fail closed.** If an in-progress subject has no
    resolvable `project_id`, do NOT enqueue — exit nonzero with an actionable
    error ("project_id absent and backend scoping unconfirmed; set
    APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED=1 if your backend scopes
    subject/list by config.project_id"). Opt in to keeping such subjects only via
    that env flag. This prevents a fork from dispatching unrelated Linear issues.
    (The smoke test determines whether `project_id` is reliably present; if it is,
    this branch never fires.)
  7. **State write semantics — two-phase, atomic.** Keep ONE in-memory state
    object and mutate it for both (a) observed `last_status` of non-in-progress
    subjects and (b) post-enqueue approval records. Persist atomically
    (temp+rename) **after each successful enqueue AND once at the end of the run**.
    Invariant: `approval_key`/`enqueued_at` are written only on enqueue success;
    bare `last_status` observations carry neither. The end-of-run write is what
    makes the no-timestamp re-approval path work — without it, "left in-progress"
    observations are never persisted. (This corrects a contradiction in rev. 1,
    which said state is written *only* after enqueue.)
  8. **Stale-lock reclaim:** an unattended 15-min job must not wedge forever if a
    crash leaves the lock dir behind.

  ## Files

  - **Add** `scripts/approval-watch.sh`
  - **Add** `scripts/test/approval-watch.bats`
  - **Edit** `.animus/workflows/workflow-approval-watch.yaml` (phase → command)
  - **Keep** the `approval-watcher` agent definition in `custom.yaml` for one
    release as scaffolding (unused but harmless; remove once the script is proven)
  - **Edit (required)** `README.md` (~line 160) and `MCP-TOOLS.md` (~line 50): fix
    stale `in_progress` → `in-progress`, and note the deterministic gate in README.
  - **Stamp (don't rewrite)** the historical `docs/superpowers/{plans,specs}/2026-06-05-*`
    docs as superseded — they carry the now-false `in_progress` form (36 refs) AND a
    stale "Linear plugin has no `subject/create` until v0.2.0" claim (0.1.8 ships it,
    `supports_create: true`). A one-line superseded banner beats retro-editing history.
  - After the YAML edit: `animus workflow config compile`

  ## Workflow change

  In `.animus/workflows/workflow-approval-watch.yaml`, replace the
  `approval-watcher` agent phase with:

  ```yaml
  phases:
    approval-watcher:
      mode: command
      worktree: skip          # REQUIRED: .animus/state/ is gitignored; must run in project root
      directive: Poll Linear approvals deterministically and enqueue approved blog tickets
      command:
        program: bash
        args:
        - scripts/approval-watch.sh
        cwd_mode: task_root
        timeout_secs: 120
  ```

  Remove the old `capabilities` / `output_contract` / `decision_contract` blocks
  (command phases don't use the decision contract; nothing downstream consumes the
  phase result — `approval-watch` is a single-phase workflow). The workflow def
  and its `enabled: false` schedule are unchanged. Keep the schedule **disabled**
  until the live smoke test passes.

  ## State schema (`.animus/state/approval-seen.json`)

  A map keyed by subject id makes "last-seen status of every subject" natural:

  ```json
  {
    "version": 1,
    "updated_at": "<ISO8601 or null>",
    "subjects": {
      "<subject_id>": {
        "last_status": "in-progress",
        "approval_key": "subject:<id>:transition:<ts>  | subject:<id>:status:in-progress",
        "transition_ts": "<ts or null>",
        "enqueued_at": "<ISO8601 or null>"
      }
    }
  }
  ```

  On read:
  - **Missing file** → default to `{"version":1,"updated_at":null,"subjects":{}}`.
  - **Present but unparseable JSON, or an unrecognized `version`** → **fail closed**
    (exit nonzero with a clear migration error). Never reset a present-but-unknown
    file to empty — doing so would re-dispatch every currently-approved issue after
    a schema bump or partial corruption.

  ## Script behavior (`scripts/approval-watch.sh`)

  ```text
  1.  set -euo pipefail
  2.  Require LINEAR_DISCOVERY_PROJECT_ID (else: stderr + exit 2).
  3.  mkdir -p .animus/state
  4.  LOCK=.animus/state/approval-watch.lock
      - mkdir "$LOCK"; on failure: if the lock dir is older than 10 min
        (find "$LOCK" -maxdepth 0 -mmin +10), reclaim it (rm -rf + remake);
        otherwise exit 75 (EX_TEMPFAIL) "another run holds the lock".
      - trap 'rm -rf "$LOCK"' EXIT.
  5.  Load state (default empty per schema above).
  6.  Fetch with an explicit high limit (the default CLI limit is unconfirmed; a
      small default would silently miss approvals AND left-in-progress observations):
        resp=$(animus subject list --kind issue --limit 500 --json)
        ok=$(jq -r .ok <<<"$resp")
      - if ok != "true": echo "subject list failed: $(jq -r .error.code <<<"$resp")"
        >&2; exit 1.  (No per-status fallback — the backend supports subject/list.)
      - If the envelope exposes a pagination cursor, loop fetching pages until
        exhausted before processing. Resolve the cursor field + the real default
        limit in the smoke test, and assert "result count < limit" so silent
        truncation is visible.
  7.  For each subject in (jq -c '.data[]?' <<<"$resp"), normalize with tolerant
      aliases:
        id     = .subject_id // .id
        title  = .title
        status = .status                          # expected: ready|in-progress|blocked|done|cancelled
        pid    = .project_id // .projectId // .custom.project_id // empty
        ts     = .state_updated_at // .stateUpdatedAt // .status_updated_at // null
  8.  Project filter:
        - if pid non-empty and pid == LINEAR_DISCOVERY_PROJECT_ID: keep.
        - if pid non-empty and pid != LINEAR_DISCOVERY_PROJECT_ID: skip.
        - if pid empty:
            * APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED=1 → keep (log once).
            * else → FAIL CLOSED: actionable error to stderr, exit 1. (Missing
              project_id is an environment/contract signal — it's absent for all
              subjects or none — so failing the run is correct, not per-subject.)
  9.  If status != "in-progress":
        - in the in-memory state, set subjects[id].last_status = status (no enqueue,
          no approval_key/enqueued_at); continue. Persisted by the end-of-run write.
  10. Malformed guard: if status == in-progress but id or title is empty:
        echo to stderr, exit 1 (fail loud; do not enqueue; leave state untouched).
  11. approval_key = ts ? "subject:<id>:transition:<ts>" : "subject:<id>:status:in-progress"
  12. prev = state.subjects[id]
      Enqueue when:
        - prev is absent, OR
        - prev.approval_key != approval_key, OR
        - prev.last_status != "in-progress"
      Otherwise skip (already enqueued for this approval episode).
  13. Dispatch (only for enqueue-eligible):
        input=$(jq -nc --arg id "$id" '{linear_subject_id:$id}')
        task=$(animus subject create --kind blogtask --title "Blog: $title" \
                --body "Wraps Linear subject $id for blog-from-ticket" \
                --status ready --json)
        if task.ok:
          TASK_ID=$(jq -r .data.id <<<"$task")
          q=$(animus queue enqueue --task-id "$TASK_ID" \
                --workflow-ref blog-from-ticket --input-json "$input" --json)
          - q.ok                         → success.
          - q.error is a clean KIND/TASK rejection (nothing enqueued — a single
            transactional enqueue rejection leaves no entry, so retry is safe)
                                          → ad-hoc enqueue (below).
          - any other q.error            → enqueue failure (do NOT update state).
        else (create failed — e.g. ANIMUS_SQLITE_KINDS unset):
          ad-hoc enqueue (envelope-aware — mirror the task-id path):
            q=$(animus queue enqueue --title "Blog: $title" \
              --description "Linear subject: $id" \
              --workflow-ref blog-from-ticket --input-json "$input" --json)
            - q.ok → success;  else → enqueue failure (do NOT update state).
        - On ANY enqueue failure (including the ad-hoc path): do NOT update state
          for this subject; record the failure; exit nonzero at end. (Never retry
          ad-hoc after a non-rejection error — only after a clean kind rejection —
          to avoid a double dispatch.)
  14. On enqueue success: set state.subjects[id] = {last_status:"in-progress",
      approval_key, transition_ts:ts, enqueued_at:now}; set updated_at=now;
      persist state atomically (tmp + mv) immediately.
  15. After the loop: persist state atomically once more, so the non-in-progress
      last_status observations from step 9 are saved even when nothing was enqueued.
  16. Final stdout (last line):
        - nothing enqueued: {"status":"skip","reason":"no_approvals","enqueued":[]}
        - else:             {"status":"ok","enqueued":[{"subject_id":"...","approval_key":"..."}]}
  ```

  `now` = `date -u +%Y-%m-%dT%H:%M:%SZ`. Atomic write = `jq ... > "$TMP" && mv "$TMP" "$STATE"`.

  ## Failure rules

  - Missing `LINEAR_DISCOVERY_PROJECT_ID` → exit 2, clear stderr.
  - `subject list` returns `ok:false` (e.g. `unavailable` / no backend) → exit 1,
    clear stderr. Never silently skip.
  - In-progress subject missing `id` or `title` → exit 1 (fail loud).
  - Enqueue failure for a subject → that subject's seen entry is **not** updated
    (so it retries next run); script exits nonzero overall.
  - Lock held by a live run → exit 75. Stale lock (>10 min) → reclaimed, proceed.
  - Missing `project_id` and `APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED` unset → exit 1 (fail closed).
  - `approval-seen.json` present but unparseable / unknown `version` → exit nonzero (never auto-reset).
  - State is written only via temp+rename. A subject's `approval_key`/`enqueued_at`
    are persisted only after that subject's enqueue succeeds; non-in-progress
    `last_status` observations are persisted by the end-of-run write.

  ## Tests (`scripts/test/approval-watch.bats`)

  Harness: a fake `animus` executable placed in a temp dir prepended to `PATH`.
  It dispatches on `"$1 $2"` (`subject list`, `subject create`, `queue enqueue`),
  returns canned envelopes selected by a `FIXTURE` env var, and appends each
  invocation to `$CALL_LOG` so tests can assert call counts. Each test runs in an
  isolated `BATS_TEST_TMPDIR` with its own `.animus/state/`.

  Cases:

  1. missing `approval-seen.json` → first in-progress enqueues once; state created.
  2. no in-progress subjects → `skip/no_approvals`; zero enqueues; last_status recorded.
  3. first approval → exactly one `subject create` + one `queue enqueue`.
  4. duplicate run (same state, same in-progress, same key) → zero new enqueues.
  5. newer `transition_ts` present → re-enqueues (key changed).
  6. left `in-progress` (last_status=done) then returns, **no** ts → re-enqueues.
  7. wrong `project_id` → ignored (zero enqueues).
  8. `project_id` absent, flag unset → **nonzero exit; zero enqueues** (fail closed).
  8b. `project_id` absent, `APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED=1` → kept (enqueues).
  9. malformed in-progress subject (no id/title) → nonzero exit; zero enqueues; state unchanged.
  10. `subject list` `ok:false` (unavailable) → nonzero exit; zero enqueues; state unchanged.
  11. enqueue fails → state for that subject unchanged (previous preserved).
  12. `blogtask` create fails (simulate no `ANIMUS_SQLITE_KINDS`) → ad-hoc `--title` fallback enqueue used.
  13. `subject create` OK but `queue enqueue --task-id` returns a kind rejection → ad-hoc fallback used, **single** enqueue (no duplicate).
  14. fresh lock present → exit 75 (no work done).
  15. stale lock (mtime >10 min) → reclaimed; run proceeds.
  16. unknown / unparseable `approval-seen.json` version → nonzero exit; zero enqueues; file untouched.
  17. **End-of-run persistence:** a non-in-progress subject's `last_status` is written even with zero enqueues (regression test for the two-phase state-write fix; underpins case 6).
  18. status value is exactly `in-progress` (hyphen): assert `in_progress` (underscore) does **not** match.

  Follow TDD: write the bats first, watch them fail, then implement the script.

  ## Acceptance criteria

  - `approval-watch` phase runs `mode: command` with `worktree: skip`; no agent invoked.
  - Script is idempotent across repeated runs (case 4) and survives leave/return (case 6).
  - A subject's approval record updates only after a successful enqueue (cases 3, 11);
    non-in-progress `last_status` observations persist via the end-of-run write (cases 6, 17).
  - State persists across runs (proven by `worktree: skip` + case 4 in a shared dir).
  - Missing `project_id` fails closed unless the assume-scoped flag is set (cases 8, 8b).
  - Unknown/corrupt state version fails closed — never auto-reset (case 16).
  - README + MCP-TOOLS use `in-progress`; no `in_progress` remains in live reference docs.
  - No-op poll costs zero model tokens.
  - All bats cases pass locally.
  - `animus workflow config compile` is clean after the YAML change.

  ## Rollout & verification gate (do NOT enable the schedule until)

  The bats suite validates *logic* with a stubbed `animus`. Before flipping
  `approval-watch` to `enabled: true`, run a **live smoke test** with a real
  `LINEAR_API_TOKEN`, `LINEAR_DISCOVERY_PROJECT_ID`, `ANIMUS_SQLITE_KINDS=blogtask`
  in the daemon's shell and the daemon running:

  1. `animus subject list --kind issue --limit 500 --json` (mirror the script's
    fetch) — confirm the real envelope: that `.data[]` items expose `status` as
    `in-progress`, whether `project_id` is present, and whether any
    `*_updated_at` transition field exists. Also check `.data | length`: if it
    equals the limit, the result is capped — resolve/confirm the pagination
    cursor and add a follow-up loop before enabling.
  2. Move one test Linear issue to In Progress; run `scripts/approval-watch.sh`
    manually once → confirm exactly one `blog-from-ticket` dispatch.
  3. Run it again immediately → confirm **no** second dispatch (idempotent).
  4. Only then set the `approval-watch` schedule `enabled: true`.

  If step 1 reveals different field names than the tolerant aliases cover, widen
  the normalize jq and re-run the suite before proceeding.

  ## Rollback

  Revert `workflow-approval-watch.yaml` to the agent phase (the `approval-watcher`
  agent definition is retained in `custom.yaml`), run
  `animus workflow config compile`, and keep the schedule disabled.
