# Animus protocol + plugin state — comprehensive summary

**Date:** 2026-06-07
**Scope:** Daemon (`animus-cli` v0.5.4), the `animus-protocol` crate workspace, and the four plugins this project depends on (`animus-subject-linear`, `animus-queue-default`, `animus-workflow-runner-default`, `animus-subject-default`/`animus-subject-sqlite`).
**Why this exists:** the discovery-flow implementation halted on a tangle of plugin "init failures" that turned out to be daemon bugs, plugin behaviour bugs, and protocol gaps in roughly equal measure. Disentangling them required reading source across three repos. This doc captures the result so the next person doesn't re-derive it.

---

## TL;DR

The animus plugin stack has **one real protocol gap** that blocks new functionality, **one real daemon bug** that produces misleading errors, and **one real plugin bug** that was fixed today. The remaining "issues" people have filed against various plugin repos were misdiagnoses caused by those three. Concretely:

| Layer | Real bug? | Status | Fix lives in |
|---|---|---|---|
| `animus-protocol` — `SubjectBackend` trait has no `create` verb | **Yes** | Open, blocks `subject/create` for every backend forever | Upstream `launchapp-dev/animus-protocol` |
| `animus-protocol` (in-tree daemon copy) — `InitializeParams` has no `init_extensions` field; daemon pinned at protocol v1.0.0 while published plugins ship v1.1.0 | **Yes** | Open, manifests as daemon-side diagnostic CLI failures | Upstream `launchapp-dev/animus-cli` |
| `animus-cli` — `PluginHost::handshake()` sends a v1.0-shape frame; `ops_plugin.rs` (`ping`/`info`/`call`) uses it | **Yes** | Open, downstream of the above | `launchapp-dev/animus-cli` |
| `animus-cli` — error formatter shows only topmost anyhow context, hiding the plugin's actual structured error | **Yes** | Open, quality-of-life | `launchapp-dev/animus-cli` |
| `animus-subject-linear` v0.1.4 — `patch.comment` overwrote `description` | **Yes** | **Fixed in v0.1.5** (PR #3, merged 2026-06-06); release not yet cut | `launchapp-dev/animus-subject-linear` (release management) |
| `animus-subject-linear` — `update.assignee` / `update.labels_*` passed raw to Linear (UUIDs expected) | **Yes**, latent | Open, fix queued for v0.1.6 | `launchapp-dev/animus-subject-linear` |
| `animus-subject-linear` — no `subject/create` capability | Gated on protocol | Open, fix queued for v0.2.0 once protocol lands | `launchapp-dev/animus-subject-linear` + `launchapp-dev/animus-protocol` |
| `animus-queue-default` v0.2.0 — "init fails with exit_code 1, no stderr" | **No** | Closed — was the daemon handshake bug | n/a |
| `animus-workflow-runner-default` v0.3.0 — same as above | **No** | Closed — same root cause | n/a |
| Local install — `animus-subject-default` + `animus-subject-sqlite` both claim `task` kind | **Yes** (installed-state, not a plugin bug) | Open, blocks every `animus subject` CLI call | `animus plugin uninstall <one>` |

**Net runtime impact on this project today:** much lower than the bug reports suggest. Workflow execution and queue dispatch route through the daemon's correctly-implemented v1.1 hand-roll path (`plugin_clients.rs::spawn_with_project_binding`), not the broken generic handshake. Only diagnostic CLI commands (`plugin ping/info/call`) and the broken `animus subject` CLI (duplicate-kind error) are visibly broken from the user's perspective.

---

## 1. Protocol architecture

The animus plugin stack has three layers:

1. **`launchapp-dev/animus-protocol`** — a workspace of small crates that define wire types and a stable runtime helper. Most important:
   - `animus-plugin-protocol` — top-level wire types (`InitializeParams`, `InitializeResult`, `PluginCapabilities`, `PluginManifest`, `PROTOCOL_VERSION`). Defines what's on the wire between daemon and plugin.
   - `animus-subject-protocol` — the `SubjectBackend` trait. Defines what verbs a subject-backend plugin must implement.
   - `animus-queue-protocol`, `animus-workflow-runner-protocol` (added in v0.5.0) — per-kind traits + verbs for the new plugin kinds.
   - `animus-plugin-runtime` — shared stdio-loop helper (`subject_backend_main`, `run_provider`, etc.) plugins call from their `main`. Handles initialize handshake, JSON-RPC dispatch, manifest emission, the well-known verbs.

2. **`launchapp-dev/animus-cli`** (the daemon, distributed as `animus`) — depends on `animus-protocol` but in v0.5.4 keeps its **own in-tree copy** of `animus-plugin-protocol` at `crates/animus-plugin-protocol/`, pinned at `PROTOCOL_VERSION = "1.0.0"`. This is the dependency mismatch that causes the daemon vs. v1.1 plugin handshake failures (see §3.1).

3. **Individual plugin binaries** — built from their own crates (`launchapp-dev/animus-subject-linear`, `launchapp-dev/animus-queue-default`, etc.), each depending on the *published* `animus-protocol` at some pinned tag. The Linear plugin is pinned at `v0.1.8`; the queue + workflow-runner plugins build against `v0.5.x` (the version that introduced their per-kind protocol crates).

The wire is JSON-RPC over the plugin process's stdin/stdout, NDJSON-framed. The daemon spawns one plugin process per call (with caching deferred to v0.5.1+), runs `initialize` → `initialized` → method calls → `shutdown` → `exit`.

### 1.1 The verbs a `subject_backend` plugin can implement (all protocol versions)

Verified across `animus-subject-protocol` tags `v0.1.8`, `v0.1.13`, `v0.5.0`, `v0.5.1`, `v0.5.6`:

```rust
#[async_trait]
pub trait SubjectBackend: Send + Sync + 'static {
    async fn list(&self, filter: SubjectFilter) -> Result<SubjectList, BackendError>;
    async fn get(&self, id: &SubjectId) -> Result<Subject, BackendError>;
    async fn update(&self, id: &SubjectId, patch: SubjectPatch) -> Result<Subject, BackendError>;
    async fn delete(&self, _id: &SubjectId) -> Result<DeleteSubjectResponse, BackendError> {
        Err(BackendError::Other(anyhow::anyhow!("delete not implemented")))
    }
    async fn watch(&self) -> Option<EventStream>;
    fn schema(&self) -> SubjectSchema;
    async fn health(&self) -> Result<HealthCheckResult, BackendError>;
}
```

That's the entire surface. **There is no `create` verb.** The `SubjectSchema::supports_create: bool` field exists with a doc-comment saying "reserved for v0.4.x" — placeholder for a never-shipped protocol expansion. Comments ride on `SubjectPatch.comment` passed to `update`.

The plugin-runtime's wire-verb router (`animus-plugin-runtime/src/lib.rs` at v0.1.8, lines 480–578) hardcodes the matchable verb set: `list`, `get`, `update`, `delete`, `watch`, `schema`, plus the literal protocol-level methods (`initialize`, `initialized`, `$/ping`, `health/check`, `shutdown`). Anything else returns `method_not_found`. A plugin cannot unilaterally add a verb.

### 1.2 The `init_extensions` field (added in plugin-protocol v1.1.0)

Published `animus-plugin-protocol` v0.1.14 (`PROTOCOL_VERSION = "1.1.0"`) adds an optional map to `InitializeParams`:

```rust
pub struct InitializeParams {
    pub protocol_version: String,
    pub host_info: HostInfo,
    pub capabilities: HostCapabilities,
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub init_extensions: std::collections::HashMap<String, Value>,
}
```

The v0.5.0 plugin kinds (`workflow_runner`, `queue`, `durable_store`, `memory_store`) introduced `init_extensions.project_binding.project_root` as a **required** init-extension for their initialize handlers. v1.0 plugins ignore unknown keys (the field is `#[serde(default)]`); v1.1+ plugins that require it reject initialize with a structured error.

---

## 2. Protocol gaps (root causes)

### 2.1 No `SubjectBackend::create` verb

**The big one.** The `SubjectBackend` trait has no `create` method in any released protocol version. The `SubjectSchema::supports_create` field has been a placeholder for years. This blocks any `subject_backend` plugin from supporting issue/ticket/record creation through the normalized Animus subject API.

**Impact on this project:** the discovery flow's idea-strategist (Task 3) needs to file blog ideas as Linear issues via `animus subject create --kind issue --title "..." --body "..."`. Today this fails because:
- `animus subject create` exists at the CLI level and tries to dispatch to the backend
- The Linear plugin (and every other `subject_backend` plugin) doesn't declare `subject/create` in its capability set
- The daemon's subject dispatcher errors with method-not-supported by backend before reaching Linear's API

**What needs to land:**
- Add a `NewSubject` (or `SubjectCreate`) request type to `animus-subject-protocol`. Shape mirrors `SubjectPatch` / `Subject`.
- Add `async fn create(&self, new: NewSubject) -> Result<Subject, BackendError>` to the trait, with a default impl returning `BackendError::Other("create not supported")` so existing backends compile unchanged.
- Add wire-verb routing for `subject/create` in `animus-plugin-runtime`'s `handle_subject_request` (paralleling the existing list/get/update/delete cases).
- `SubjectSchema::supports_create` becomes load-bearing — backends advertise `true` when they implement; the daemon checks this before routing.

This is a small upstream change (~80 LOC) but must land first before any plugin can implement create. Tracked: `docs/known-issues/animus-subject-linear-required-fixes.md` "Prerequisite 1".

### 2.2 In-tree daemon protocol is one minor version behind every published plugin

`animus-cli` v0.5.4's `crates/animus-plugin-protocol/src/lib.rs` declares:
- `PROTOCOL_VERSION = "1.0.0"`
- `InitializeParams` with **three** fields (`protocol_version`, `host_info`, `capabilities`) — no `init_extensions`

Meanwhile the published `animus-plugin-protocol` v0.1.14 (which queue + workflow-runner build against) is at:
- `PROTOCOL_VERSION = "1.1.0"`
- `InitializeParams` with **four** fields, including `init_extensions`

The CHANGELOG entry `CHANGELOG-v0.5.0.md:37` claims "Extended `animus-plugin-protocol` with `init_extensions.project_binding` + `memory_mcp_stdio_command`". That's true for the *published* crate, not for the in-tree daemon copy. The two have drifted.

**Why it doesn't fully break the daemon:** v0.5 plugin-management code learned to hand-roll the v1.1 frame inline as a workaround. There are **three independent inline copies** of the same JSON literal at:
- `crates/orchestrator-cli/src/services/plugin_clients.rs:100-117` (used by `call_workflow_execute`, `call_workflow_run_phase`, `call_queue_*`)
- `crates/orchestrator-cli/src/services/runtime/runtime_daemon/notifier_dispatcher.rs:212-228` (used by notifier plugins)
- `crates/animus-runtime-shared/src/recording/dbos_client.rs:257-258` (used by durable-store)

Each one builds a literal JSON map matching the v1.1 InitializeParams shape because the typed in-tree struct doesn't have the field.

**What needs to land:**
- Bump the in-tree `animus-plugin-protocol` to v1.1.0 (or copy the `init_extensions` field across).
- Delete the three inline workarounds — they become a one-line struct field assignment each.

### 2.3 Generic `PluginHost::handshake()` uses the v1.0 shape

`crates/orchestrator-plugin-host/src/host.rs:702-709`:

```rust
pub async fn handshake(&self) -> Result<InitializeResult> {
    const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

    let params = InitializeParams {
        protocol_version: PROTOCOL_VERSION.to_string(),
        host_info: HostInfo { name: "animus".to_string(), version: env!("CARGO_PKG_VERSION").to_string() },
        capabilities: HostCapabilities { streaming: true, progress: true, cancellation: true },
    };
    // ...
}
```

No `init_extensions`. This is the *generic* handshake — used by anything that doesn't go through the hand-rolled workarounds. The three call sites are:

- `crates/orchestrator-cli/src/services/operations/ops_plugin.rs:585-586` → `run_plugin_info` → `animus plugin info`
- `crates/orchestrator-cli/src/services/operations/ops_plugin.rs:605-606` → `run_plugin_ping` → `animus plugin ping`
- `crates/orchestrator-cli/src/services/operations/ops_plugin.rs:621-622` → `run_plugin_call` → `animus plugin call`

When any of these is invoked against a v1.1 plugin that requires `project_binding` (queue, workflow_runner), the plugin returns a structured RPC error like `(-32207) init_extensions.project_binding is required to bind a project root` or `(-32603) missing project_binding init extension`. The daemon collapses this to:

```json
{"schema":"animus.cli.v1","ok":false,"error":{"code":"internal","message":"plugin initialize failed","exit_code":1}}
```

**The plugin process actually exits 0.** The `exit_code: 1` is `crates/orchestrator-cli/src/shared.rs::classify_exit_code` mapping the `internal` error class. The plugin's actual error message *is* propagated through the anyhow chain at `host.rs:717` (`anyhow!("plugin initialize failed ({}): {}", error.code, error.message)`) but `ops_plugin.rs:606` wraps it with `.context("plugin initialize failed")` and the CLI's JSON envelope renders only that topmost context. So the underlying `(-32207)` message is in the chain — just not visible to the user.

**What needs to land:**
- Lift the `spawn_with_project_binding` body into a reusable helper on `PluginHost` (e.g. `handshake_with_project_binding(&self, project_root: &Path)` or a builder option on `PluginSpawnOptions`).
- Wire it through the three `ops_plugin.rs` call sites.
- Render the full `anyhow::Error::chain()` in the CLI JSON envelope (or surface the plugin's `error.code`/`error.message` as a structured `cause` field).

Tracked: `docs/known-issues/animus-cli-handshake-missing-project-binding.md`.

### 2.4 Preflight is manifest-only (good design, included for completeness)

`crates/orchestrator-core/src/plugin_preflight/` checks plugin **presence** via manifest reads only. It doesn't run a handshake. Which is why `animus daemon start` works on this machine even though `animus plugin ping` for the same plugins doesn't — the daemon never triggers the broken generic handshake at startup. This is correct design, but it also means the bug stays invisible until someone runs the diagnostic commands.

---

## 3. Daemon-side workarounds and their limits

§2.2 already enumerated the three inline copies of the v1.1 init frame. To make the scope explicit:

| Code path | Triggered by | Works? |
|---|---|---|
| `plugin_clients.rs::spawn_with_project_binding` | Workflow execution (`call_workflow_execute`, `call_workflow_run_phase`), queue ops (`call_queue_*`) | ✅ Yes |
| `notifier_dispatcher.rs:209-228` inline | Notifier plugins | ✅ Yes |
| `dbos_client.rs:257-258` inline | Durable-store plugin (DBOS) | ✅ Yes |
| `PluginHost::handshake()` (generic) | `animus plugin ping/info/call` | ❌ No, against v1.1 plugins |
| Preflight manifest read | `animus daemon start` | ✅ Yes (skips handshake entirely) |

So on this machine right now:
- Workflows execute through `animus-workflow-runner-default` v0.3.0 normally. The CHANGELOG-v0.5.0 deletion of the legacy in-tree workflow runner means there's no fallback to fall back to — but there doesn't need to be, because the plugin path works.
- Queue ops dispatch through `animus-queue-default` v0.2.0 normally.
- `animus plugin ping --name animus-queue-default` returns "plugin initialize failed exit_code 1" — diagnostic bug only.
- `animus plugin info --name animus-workflow-runner-default` would do the same.
- `animus daemon start` works.

The original framing in `docs/known-issues/animus-queue-default-init-fails.md` and `animus-workflow-runner-default-init-fails.md` — that we were "locked into the legacy runner" — was wrong. Those docs are now marked superseded; the plugin-repo GitHub issues based on them are pending closure.

---

## 4. Per-plugin status

### 4.1 `animus-subject-linear` — what we shipped today and what's left

**v0.1.4 (released, currently installed):**
- ✅ `subject/list`, `subject/get`, `subject/update` (mostly), `subject/schema`, `health/check`
- ❌ Real bug: `patch.comment` mapped to `IssueUpdateInput.description`, silently overwriting the Linear issue body on every comment. Filed as `launchapp-dev/animus-subject-linear#2`.

**v0.1.5 (merged to `main` 2026-06-06, NO tag/release yet, NOT installed locally):**
- ✅ Fixed `patch.comment` — now posts via Linear's `commentCreate` mutation; description untouched. PR `launchapp-dev/animus-subject-linear#3`.
- ✅ README rewrite explicitly documenting the `--kind issue` semantics and the subject-kind contract.
- 33 contract + unit tests, clippy clean.
- **Prerequisite for the discovery flow's `linear-coordinator` agent (Task 5).** Until the release ships and the local install is upgraded, that task posts will continue to destroy issue descriptions.

**v0.1.6 (planned, not started):**
- Latent bug in `update`: `patch.assignee` passed as raw string (Linear expects UUID).
- Latent bug in `update`: `patch.labels_add/remove` passed as label names (Linear expects label UUIDs).
- Add `LinearClient::resolve_assignee_id` + `LinearClient::resolve_label_ids` helpers with `OnceCell` cache, wire into `build_update_input`.
- Tracked: `docs/known-issues/animus-subject-linear-required-fixes.md` "Gap 2.3 / 2.4".

**v0.2.0 (planned, gated on protocol):**
- `subject/create` via Linear's `issueCreate` mutation.
- Schema declares `supports_create: true`.
- Hard prerequisite: §2.1 must land first.

**Documentation: kind naming.** The plugin declares `subject_kinds: ["issue"]`, not `["linear"]`. The discovery flow plan was originally written using `--kind linear` throughout; corrected to `--kind issue` in this session's plan/spec re-review.

### 4.2 `animus-queue-default` v0.2.0 — not a plugin bug

Filed at `launchapp-dev/animus-queue-default#2` as "plugin initialize fails with exit_code 1 and no stderr".

**Reality:** the plugin works correctly. The daemon sends a v1.0-shape `initialize` frame missing `init_extensions.project_binding`, which the plugin requires per its `extract_project_root` handler at `src/plugin.rs:315`. The plugin returns a structured RPC error: `(-32207) init_extensions.project_binding is required to bind a project root`. The plugin process exits 0 cleanly (verified). The `exit_code: 1` in `animus plugin ping --json` output is a daemon-fabricated value (§2.3).

Verified by sending exactly the daemon's `initialize` shape directly to the plugin binary:
- Daemon-shape frame (no `init_extensions`) → plugin returns the structured error ✓
- Daemon-shape frame **with** `init_extensions.project_binding.project_root` → plugin returns a full `InitializeResult` including its typed `kind_capabilities` ✓

**Runtime is unaffected** because the daemon's actual queue-call path (`plugin_clients.rs::call_queue_*` → `spawn_with_project_binding`) hand-rolls the v1.1 frame correctly.

**Disposition:** issue closing comment drafted, pending user choice on phrasing.

### 4.3 `animus-workflow-runner-default` v0.3.0 — not a plugin bug

Filed at `launchapp-dev/animus-workflow-runner-default#2`. Same symptom, same root cause as 4.2. Plugin works correctly; daemon's generic handshake is broken.

Plugin returns `(-32603) missing project_binding init extension` from its `plugin_initialize_result` handler at `src/plugin.rs:159`. With the v1.1 frame, it returns a full `InitializeResult` with `WorkflowRunnerCapabilities` including `phase_decision_parsing`, `rework_context_support`, `post_success_actions`, `crash_recovery`, `manual_pause_support` — all the v0.5 features the original concern worried were "silently inactive".

Runtime workflow execution routes through `plugin_clients::call_workflow_execute` / `call_workflow_run_phase`, which work.

**Disposition:** same as 4.2 — pending close.

### 4.4 Installed-state issue (NOT a plugin bug): duplicate `task` subject-kind

On this machine, both `animus-subject-default` and `animus-subject-sqlite` declare `subject_kinds: ["task"]`. The daemon's subject router has no tiebreaker; it errors out at the routing layer:

```
$ animus subject list --kind issue --limit 1
error: duplicate subject kind 'task' claimed by 'animus-subject-default' and 'animus-subject-sqlite'
```

This blocks **every** `animus subject` CLI call regardless of `--kind` — even kinds neither plugin claims (`issue`, `requirement`, etc.) — because the router fails fast at startup of the dispatch path.

The original preflight note recorded the same error with a different pair (`animus-subject-default` + `animus-subject-markdown`). The pair has shifted on this install, suggesting the duplicate is a recurring artifact of `animus plugin install-defaults --include-subjects`: it installs multiple subject backends and several of them advertise `task` as their default kind.

**Fix:** `animus plugin uninstall <one>`. Neither is in active use yet on this project, so the choice is informed mainly by what task-backend features the project will eventually need (sqlite supports watch + cursors; default is in-tree-file-backed, simpler).

**Tracked:** new preflight Step 3.5 added to the discovery-flow plan in today's revision.

---

## 5. What needs to land where, in what order

### 5.1 Daemon side (`launchapp-dev/animus-cli`)

Priority order:

1. **Bump in-tree `animus-plugin-protocol` to v1.1.0** (or add `init_extensions` as `#[serde(default)] HashMap<String, Value>` to the in-tree v1.0). Bump `PROTOCOL_VERSION` to `"1.1.0"`. Low risk; v1.0 plugins ignore unknown init keys because the field is `#[serde(default)]`.
2. **Add `handshake_with_project_binding` to `PluginHost`** (or a `PluginSpawnOptions::with_project_binding` builder option that pairs with the existing `with_working_dir`). Delete the three inline workarounds in `plugin_clients.rs`, `notifier_dispatcher.rs`, `dbos_client.rs`.
3. **Wire it through `ops_plugin.rs`** for `run_plugin_info`, `run_plugin_ping`, `run_plugin_call`. The `project_root` is already available in each `*Request` struct.
4. **Render the full anyhow chain** in `animus plugin ping --json` (or expose `error.code` / `error.message` as a structured `cause` field). Optional but high-leverage.

Tracked: `docs/known-issues/animus-cli-handshake-missing-project-binding.md`. Draft ready to file as a single upstream issue.

### 5.2 Protocol side (`launchapp-dev/animus-protocol`)

1. **Add `SubjectBackend::create`** with default impl returning `BackendError::Other("create not supported")`. New `NewSubject` request type mirroring `SubjectPatch` shape. Wire-verb routing for `subject/create` in `animus-plugin-runtime::handle_subject_request`.
2. Make `SubjectSchema::supports_create` load-bearing (daemon checks before routing).

Optional follow-ups not blocking the discovery flow:
- A `NewSubject.idempotency_key` field — discovery flow handles this in user-space today but a protocol field would let backends de-dup more efficiently. Defer to the second backend that needs it.

Tracked: `docs/known-issues/animus-subject-linear-required-fixes.md` "Gap 1 — Upstream protocol prerequisite". User is working on this elsewhere.

### 5.3 Linear plugin (`launchapp-dev/animus-subject-linear`)

1. **Cut v0.1.5 git tag + GitHub release** with binaries. The fix is on `main`; the tag isn't. ~10 min release management work.
2. **v0.1.6** (independent of protocol work): label / assignee name → UUID resolvers, wire into `build_update_input`. Fixes latent bugs in `update`.
3. **v0.2.0** (gated on 5.2): `LinearBackend::create` via Linear's `issueCreate` GraphQL mutation. ~200 LOC + contract tests + README row.

Tracked: `docs/known-issues/animus-subject-linear-required-fixes.md`.

### 5.4 Installed-state (this machine)

1. **Uninstall one of `animus-subject-default` / `animus-subject-sqlite`** to clear the duplicate-`task` claim. Pick based on which task-backend feature set the project needs.
2. **Install `animus-subject-linear` v0.1.5 (`--force`)** once the release ships.

---

## 6. Cross-references

- `docs/known-issues/animus-cli-handshake-missing-project-binding.md` — daemon-side bug detail + draft upstream issue.
- `docs/known-issues/animus-subject-linear-required-fixes.md` — Linear plugin gap detail (comment fix shipped, create gap, helpers, version path to v0.2.0).
- `docs/known-issues/animus-queue-default-init-fails.md` — original (now superseded) report. Header notes the runtime is unaffected.
- `docs/known-issues/animus-workflow-runner-default-init-fails.md` — same.
- `launchapp-dev/animus-subject-linear#2` — open, fixed by #3.
- `launchapp-dev/animus-subject-linear#3` — merged 2026-06-06 (v0.1.5 comment fix).
- `launchapp-dev/animus-queue-default#2` — open, pending close (closing comment drafted, pending user phrasing choice).
- `launchapp-dev/animus-workflow-runner-default#2` — open, pending close (same).
- Discovery-flow consumers of this state:
  - `docs/superpowers/specs/2026-06-05-discovery-flow-design.md` — revised today.
  - `docs/superpowers/plans/2026-06-05-discovery-flow.md` — revised today.
  - `~/.animus-blog-generator-preflight.md` — revised today; original 2026-06-05 snapshot preserved below the header for the investigation trail.

## 7. Honest uncertainty

Things I claimed in this session that I had to walk back:
- "Both queue + workflow-runner plugins exit silently with code 1." — wrong. Both exit 0 cleanly; the `1` is a daemon-fabricated value.
- "The daemon's `animus-plugin-protocol` is at v1.0 with no `init_extensions`" — initially verified against a stale cargo checkout (v0.4.20), corrected when the user challenged me to re-check against the actual v0.5.4 source. Conclusion held but the verification path was sloppy first time around.
- "Workflow execution falls back to a legacy oai-agent runner" — wrong. CHANGELOG-v0.5.0:81 deleted the in-tree workflow runner; there is no fallback. The plugin path is what's running, via `spawn_with_project_binding` (which works).

Things I have NOT verified empirically that I'm asserting from code reading:
- That this project's actual cron-driven `blog-production` workflows are routing through `call_workflow_execute` → plugin path, vs. through `build_runner_command_from_dispatch` → direct-execute CLI subprocess mode. Both invoke the same `animus-workflow-runner-default` binary, but only the former exercises the JSON-RPC handshake. To confirm, watch daemon events / logs during a workflow run and look for the plugin handshake messages.

Things I haven't done that may be worth doing:
- Reading the v0.5.4 `crates/orchestrator-daemon-runtime` dispatch code to confirm which workflow runner path is actually invoked at runtime (resolves the above uncertainty).
- Checking whether `animus-subject-requirements` v0.1.7 has the same `subject/create` gap or has somehow worked around it.
