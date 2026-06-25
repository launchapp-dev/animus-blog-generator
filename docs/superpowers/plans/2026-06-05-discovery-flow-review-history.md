# Discovery Flow — Review History

> **⚠️ Historical (2026-06-25).** The `in_progress` status form referenced here is superseded by hyphenated `in-progress`, and `subject/create` is now available (plugin 0.1.8). See [`2026-06-23-deterministic-approval-watcher.md`](2026-06-23-deterministic-approval-watcher.md).

Companion to `2026-06-05-discovery-flow.md` and `2026-06-05-discovery-flow-design.md`. Each row links a reviewer finding to where it was fixed.

## Round 1 (P0/P1/P2)

| # | Finding | Resolution |
|---|---|---|
| P0-1 | `.ao/workflows/custom.yaml` is dormant | Task -2 migrates everything to `.animus/workflows/custom.yaml`, deletes the stale file, updates CLAUDE.md |
| P0-2 | `register-post` after `push-branch` leaves manifest commit unpushed | `register-post` moved BEFORE `push-branch` in both `blog-production` and `blog-from-ticket` |
| P1-1 | `subjects:` YAML shape unverified | Task 1 uses the verified list-with-`backend:` shape; Task -1 Step 7 validates it on a scratch file first |
| P1-2 | `kind: linear-discovery` likely invalid | `kind: linear` is used in all CLI calls; `linear-discovery` is only the workspace `id:` (local alias) |
| P1-3 | Capitalized statuses won't match the API | All statuses are lowercase snake_case: `ready / in_progress / blocked / done / cancelled` |
| P1-4 | `input: {...}` is the wrong queue field | Approval-watcher uses `--task-id` + `--input-json '{"linear_subject_id":"..."}'`; probe in Task -1 Step 6 picks the verified shape |
| P1-5 | `slug` can't be found by `register-post`; script doesn't emit commit_message | seo-review's output contract is extended to thread `slug` (Task 8 Step 3); script echoes commit_message on stdout (Task 9); register-post reads slug from seo-review (Task 10) |
| P2-1 | `.env` not auto-loaded by daemon | README + spec document the explicit `set -a; source .env; set +a` pattern (Task 14 Step 2); `subjects:` block uses `${VAR:?msg}` for fast-fail |
| P2-2 | Cancellation after approval treated as harmless | `ticket-acknowledge` and `ticket-to-brief` re-check `status == in_progress` and emit FAIL with reason `subject_no_longer_in_progress` (Tasks 5 and 6) |

## Round 2 (post-fix re-review)

| # | Finding | Resolution |
|---|---|---|
| R2-P1-1 | Task-wrapper used removed `animus task` commands | Replaced with `animus subject create --kind task --title ... --body ...` for wrapper creation and `animus subject status --kind task --id ... --status cancelled` for cleanup (Task -1 Step 6, Task 4 directive). Preflight probe updated. |
| R2-P1-2 | `approval-seen.json` blocked retries after failed runs | Schema changed: entries now `{ subject_id, last_approved_at }` keyed by `(subject_id, transition_timestamp)`. Re-approval (move back to `ready` then forward again) advances the timestamp → re-enqueued. |
| R2-P1-3 | Project scoping not actually enforced by generic CLI | Added preflight Step 6.5 to verify backend-config scoping and capture the available transition-timestamp field. Watcher post-filters by `project_id` if backend scoping is absent. |
| R2-P2-1 | Subject-create CLI uses `--body`, not `--description` | Replaced throughout. `animus queue enqueue` does use `--description` (different CLI) — distinction called out explicitly. |
| R2-P2-2 | Used `animus workflow list` where definitions intended | Replaced with `animus workflow definitions list` in Task -2 Step 3+6, Task 11 Step 3, Task 13 Step 4. `workflow list` (runtime runs) kept only where actually checking runs. |

## Round 3 (propagation + scope discipline)

| # | Finding | Resolution |
|---|---|---|
| R3-P1-a | Spec's strategist + watcher directives still showed `--description`, removed `animus task create`, backend-only project scoping, plain "Append IDs" | Spec strategist directive uses `--body`; spec watcher directive rewritten for `(subject_id, transition_ts)` dedup, explicit project post-filter with plugin-call fallback, `animus subject create --kind task` wrapper, atomic tmpfile+rename. |
| R3-P1-b | MCP package names blocked preflight, conflicting with "we don't install MCPs as part of this" | Task -1 Step 9 rewritten to inventory existing config (non-blocking). Task 1 supports both pre-configured form and TODO-stub form. |
| R3-P2 | Migration claimed "no semantic loss" but stub had `default_workflow_ref` + `tools_allowlist` | Task -2 Step 1 lists stub contents and migration decision per key: `default_workflow_ref: standard-workflow` **preserved**; `tools_allowlist: [cargo]` **dropped** as a Rust-template artifact. |
| R3-P3 | Migration rationale cited `animus workflow list` as evidence | Task -2 preamble cites `animus workflow config get --json | jq -r .data.path` as direct evidence; `workflow definitions list` as secondary. |

## Round 4 (ship gate)

| # | Finding | Resolution |
|---|---|---|
| R4-P1 | I claimed TODO MCP stubs only affect discovery; Tasks 6–8 prove that wrong — `content-library` is added to production agents | Task 1 Step 1 rationale split: `krisp` is stubable; `content-library` is production-critical. Tasks 6, 7, 8 carry an explicit "content-library must be real" precondition; if absent, those tasks are skipped. *(Later corrected in Round 5 — the gate is broader than just Tasks 6–8.)* |
| R4-P2 | Stale "package name" / "registered package" language survived | Preflight outcome bullet rewritten as "existing command/args/env OR not configured." Spec open-questions items 4 and 5 rewritten the same way. Plan self-review placeholder-scan rewritten. |
| R4-P3 | Spec Summary still cited `animus workflow list` as evidence | Spec Summary now cites `animus workflow config get --json | jq -r .data.path` and `animus workflow definitions list`. `workflow list` explicitly noted as wrong (runtime runs, not definitions). |

## Round 5 (conditional-rollout coherence)

| # | Finding | Resolution |
|---|---|---|
| R5-P1 | "Skip Tasks 6–8" carveout leaves `blog-from-ticket` (Task 11) referencing `ticket-to-brief`, defined only in skipped Task 6 → workflow references an undefined phase | **Content-library is now a HARD precondition for the entire downstream rollout (Tasks 4–14), not just Tasks 6–8.** If content-library isn't real after preflight Step 9, the plan halts at Task 3 — idea-strategist still ships (the discovery workflow does its own dedup via manifest only), but no part of `blog-from-ticket` is built. Removes the fallback-phase ambiguity. |
| R5-P2 | Preflight text said "blog-from-ticket works when MCPs are not configured" — untrue without Task 6 | Preflight Step 9 outcome statement rewritten to match the new hard gate. Self-review row rewritten. |

## Notes on review process

- Each round was triggered by a fresh reviewer pass against the previous commit.
- Where I disagreed with a finding, the disagreement is documented in the conversation thread rather than this history.
- The plan was committed at each round so the diff between rounds is preserved in git.
