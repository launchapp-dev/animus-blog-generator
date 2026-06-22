# Animus stack — two protocol gaps blocking the v0.5 plugin path

**Date:** 2026-06-07
**Affects:** `animus-cli` v0.5.4; `animus-protocol` (all released versions, v0.1.x and v0.5.x); every v1.1.0 plugin that requires `init_extensions.project_binding` (currently `animus-queue-default`, `animus-workflow-runner-default`); every `subject_backend` plugin that conceptually supports creation (Linear, hypothetical Jira / GitHub Issues / Notion plugins, etc.).
**Severity:** Medium — runtime workflow execution and queue dispatch work today via daemon-side workarounds; diagnostic plugin tooling and new-subject creation are blocked.
**Filable against:** `launchapp-dev/animus-cli` (Bug A) and `launchapp-dev/animus-protocol` (Bug B) — see §3.

---

## Summary

Two unrelated protocol gaps share the same symptom surface, which has driven misfiled bug reports against the wrong repos:

**Bug A — daemon ↔ plugin protocol version mismatch.** `animus-cli` v0.5.4 keeps an in-tree copy of `animus-plugin-protocol` pinned at `PROTOCOL_VERSION = "1.0.0"` while the published `animus-plugin-protocol` is at v1.1.0 and every default plugin built against v1.1.0 (queue, workflow-runner) requires an `init_extensions.project_binding` init-extension the v1.0 wire shape can't carry. The daemon learned to hand-roll the v1.1 frame in three inline copies for runtime calls, but the generic `PluginHost::handshake()` and the three plugin-management CLI commands (`plugin ping/info/call`) still emit the v1.0 shape. Result: those CLI commands report `plugin initialize failed exit_code 1` for every v1.1 plugin even though the plugin is working fine. Because the plugin process exits cleanly and only the daemon's CLI rendering swallows the plugin's actual error, the failure looks like a plugin bug — drawing bug reports against plugin repos rather than the daemon.

**Bug B — `SubjectBackend` trait has no `create` verb.** The `animus-subject-protocol` trait exposes `list / get / update / delete / watch / schema / health`. There is no `create`. The `SubjectSchema::supports_create` field has been a placeholder for years (doc-comment: "reserved for v0.4.x"). No subject backend can create new records through the normalized Animus subject API. Workflows or operators that need to insert new subjects from agent directives (file a ticket, open an issue, append a record) currently can't go through `animus subject create` against any backend that owns its data upstream.

**Net runtime impact:** lower than the surface symptoms suggest. Workflow execution and queue ops work normally via the workarounds. The visible breakage is concentrated in (a) diagnostic and inspection tooling for v1.1 plugins and (b) any workflow path that needs to create new subjects.

---

## Status at a glance

| Observed symptom | Root cause | Status |
|---|---|---|
| `animus plugin ping --name <v1.1 plugin>` → "plugin initialize failed exit_code 1" | Bug A | Open |
| `animus plugin info --name <v1.1 plugin>` → same | Bug A | Open |
| `animus plugin call --name <v1.1 plugin>` → same | Bug A | Open |
| `animus-cli` shows `exit_code: 1` though plugin actually exits 0 cleanly | Bug A (diagnostic noise side-effect) | Open |
| `animus plugin ping --json` doesn't show the plugin's structured error message | Bug A (formatter side-effect) | Open |
| `animus subject create --kind <K>` → "method not supported by backend" against any non-local-storage backend | Bug B | Open |
| `animus daemon start` works | n/a — preflight is manifest-only, skips handshake | ✅ Working as designed |
| Workflow execution through `animus-workflow-runner-default` | n/a — runtime path uses workaround | ✅ Working |
| Queue dispatch through `animus-queue-default` | n/a — runtime path uses workaround | ✅ Working |

---

## Bug A — daemon's generic handshake sends a v1.0 frame against v1.1 plugins

### Reproduction

Any operator with a v1.1 plugin installed can reproduce in seconds:

```bash
$ animus plugin ping --name animus-queue-default --json
{"schema":"animus.cli.v1","ok":false,"error":{"code":"internal","message":"plugin initialize failed","exit_code":1}}

$ animus plugin ping --name animus-workflow-runner-default --json
# same shape
```

The plugins themselves are responding correctly. Sending exactly the daemon's `initialize` frame directly to either plugin binary reproduces a clear structured error:

```bash
$ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol_version":"1.1.0","host_info":{"name":"animus","version":"0.5.4"},"capabilities":{"streaming":true,"progress":true,"cancellation":true}}}' \
    | ~/.animus/plugins/animus-queue-default
{"jsonrpc":"2.0","id":1,"error":{"code":-32207,"message":"init_extensions.project_binding is required to bind a project root"}}

$ printf '%s\n' '{...same frame...}' \
    | ~/.animus/plugins/animus-workflow-runner-default
{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"missing project_binding init extension"}}
```

Add `init_extensions.project_binding.project_root` to the request body and both plugins return a full `InitializeResult` with kind-typed capabilities. They behave correctly.

### Root cause

**A.1 — In-tree protocol is pinned at v1.0; published plugins build against v1.1.**

`animus-cli` v0.5.4 source (tag `v0.5.4`, commit `77dadec`):

- `crates/animus-plugin-protocol/src/lib.rs:42` — `pub const PROTOCOL_VERSION: &str = "1.0.0";`
- `crates/animus-plugin-protocol/src/lib.rs:486-493` — `InitializeParams` has three fields (`protocol_version`, `host_info`, `capabilities`), no `init_extensions`.

Published `animus-plugin-protocol` v0.1.14:

- `PROTOCOL_VERSION = "1.1.0"`
- `InitializeParams` adds `pub init_extensions: HashMap<String, Value>` (`#[serde(default)]`).

The v0.5.0 plugin kinds (`workflow_runner`, `queue`, `durable_store`, `memory_store`) introduced `project_binding` as a required init-extension. v1.0 plugins ignore unknown init keys; v1.1 plugins that require it reject initialize when it's absent.

The CHANGELOG-v0.5.0.md:37 entry — "Extended `animus-plugin-protocol` with `init_extensions.project_binding` + `memory_mcp_stdio_command`" — is true for the *published* crate, not the in-tree daemon copy. The two have drifted.

**A.2 — `PluginHost::handshake()` builds the v1.0 shape.**

`crates/orchestrator-plugin-host/src/host.rs:702-709`:

```rust
pub async fn handshake(&self) -> Result<InitializeResult> {
    const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
    let params = InitializeParams {
        protocol_version: PROTOCOL_VERSION.to_string(),
        host_info: HostInfo { name: "animus".to_string(), version: env!("CARGO_PKG_VERSION").to_string() },
        capabilities: HostCapabilities { streaming: true, progress: true, cancellation: true },
    };
    // ...no init_extensions ever set
}
```

The typed in-tree `InitializeParams` literally doesn't have an `init_extensions` field, so this can't populate it even if it wanted to.

**A.3 — Three inline workarounds exist already; the diagnostic path was missed.**

The runtime code paths bypass `handshake()` and hand-roll the v1.1 frame as a JSON literal:

- `crates/orchestrator-cli/src/services/plugin_clients.rs:74-128` — `spawn_with_project_binding`. Used by `call_workflow_execute`, `call_workflow_run_phase`, all `call_queue_*` helpers. The comment at lines 42-46 explicitly acknowledges the in-tree protocol pin: *"The in-tree `animus-plugin-protocol` crate is still on protocol v1.0 and does NOT export this constant; the v0.5 protocol crate (transitively via `animus-workflow-runner-protocol`) defines it as the wire literal."*
- `crates/orchestrator-cli/src/services/runtime/runtime_daemon/notifier_dispatcher.rs:212-228` — same JSON literal for notifier plugins.
- `crates/animus-runtime-shared/src/recording/dbos_client.rs:257-258` — same for durable-store.

Three inline copies of the same workaround is a clear smell. The diagnostic CLI commands use the bare `handshake()` and aren't routed through any of these:

- `crates/orchestrator-cli/src/services/operations/ops_plugin.rs:585-586` — `run_plugin_info` → `animus plugin info`
- `crates/orchestrator-cli/src/services/operations/ops_plugin.rs:605-606` — `run_plugin_ping` → `animus plugin ping`
- `crates/orchestrator-cli/src/services/operations/ops_plugin.rs:621-622` — `run_plugin_call` → `animus plugin call`

**A.4 — Diagnostic noise (not the root cause, but worth fixing alongside).**

- `exit_code: 1` in the CLI JSON output is `crates/orchestrator-cli/src/shared.rs::classify_exit_code` mapping the `internal` error class. **The plugin process actually exits 0.** Verified: `~/.animus/plugins/animus-queue-default < /dev/null; echo $?` → `0`. The "exit_code 1" reading drove the assumption that plugins were crashing in initialization when they were just rejecting a malformed frame cleanly.
- The plugin's actual error message *is* propagated through the anyhow chain at `host.rs:717` (`anyhow!("plugin initialize failed ({}): {}", error.code, error.message)`) but `ops_plugin.rs:606` wraps it with `.context("plugin initialize failed")` and the CLI's JSON envelope renders only the topmost context. The `(-32207) init_extensions.project_binding is required…` part of the chain is dropped from the user-facing message — so the diagnostic surface gives the operator no signal pointing at the real cause.

### General impact

- **Runtime workflow + queue ops:** unaffected. The workarounds work.
- **`animus daemon start`:** unaffected. Preflight is manifest-only (`crates/orchestrator-core/src/plugin_preflight/`), doesn't trigger handshakes.
- **`animus plugin ping/info/call` against any v1.1 plugin:** broken. This is the operator-facing surface for sanity-checking a plugin install. When it reports `plugin initialize failed`, the natural conclusion is "the plugin is broken" — not "the daemon's handshake is missing a field". The misdiagnosis drives bug reports against plugin repos (`animus-queue-default`, `animus-workflow-runner-default` have both received bug reports of this exact shape).
- **Plugin authors writing v1.1 plugins:** every new plugin that requires `project_binding` will hit this. The published protocol's `init_extensions.project_binding` is reasonable to require; the daemon's diagnostic CLI just can't speak it. New plugin authors will spend time diagnosing this before discovering the workaround paths exist for runtime calls.
- **Operators trying to debug "is my plugin healthy?":** the standard tool reports a misleading failure with no useful detail, so operators have to drive the plugin's stdio by hand (as in the reproduction above) to learn what's actually wrong.

### Fix

1. Bump in-tree `animus-plugin-protocol` to v1.1.0 (or add `init_extensions: HashMap<String, Value>` as `#[serde(default)]` to the in-tree struct). Bump `PROTOCOL_VERSION` to `"1.1.0"`. v1.0 plugins ignore unknown init keys; no breakage.
2. Lift `spawn_with_project_binding` into a `PluginHost::handshake_with_project_binding(&self, project_root: &Path)` method (or a `PluginSpawnOptions::with_project_binding` builder option that pairs with the existing `with_working_dir`).
3. Delete the three inline hand-rolls in `plugin_clients.rs`, `notifier_dispatcher.rs`, `dbos_client.rs` — they collapse to a one-line method call.
4. Wire the new helper through `ops_plugin.rs` (lines 585-586, 605-606, 621-622). The `project_root` is already available in each `PluginInfoRequest` / `PluginPingRequest` / `PluginCallRequest`.
5. Render the full `anyhow::Error::chain()` in the CLI JSON envelope, or surface the plugin's `error.code` / `error.message` as a structured `cause` field. Optional but high-leverage — would have made this bug a 30-second diagnosis.

Total scope: ~150 LOC change in one repo. No plugin-side changes required.

---

## Bug B — `SubjectBackend` trait has no `create` verb

### Reproduction

Any backend that owns its data upstream (a third-party system like Linear, Jira, GitHub Issues, Notion, etc.) cannot expose a creation path through `animus subject create`:

```bash
$ animus subject create --kind <K> --title "..." --body "..."
# Fails when <K> is owned by a backend whose plugin doesn't declare subject/create.
# The backend can't declare it: the trait doesn't have the method.
```

Verified across every released `animus-subject-protocol` version (`v0.1.8`, `v0.1.13`, `v0.5.0`, `v0.5.1`, `v0.5.6`). The trait at v0.1.8 (`crates/animus-subject-protocol/src/lib.rs:719-754`):

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

No `create`. The `SubjectSchema::supports_create: bool` field exists with the doc-comment *"Whether the backend can create new subjects (reserved for v0.4.x)"* — a placeholder for a never-shipped protocol expansion.

The plugin runtime's wire-verb router (`animus-plugin-runtime/src/lib.rs:480-578` at v0.1.8) hardcodes the matchable verb set: `list`, `get`, `update`, `delete`, `watch`, `schema`. Anything else returns `method_not_found`. A plugin cannot unilaterally add a verb — it has to live in the trait.

### General impact

- **Every `subject_backend` plugin author who wants to expose creation:** blocked at the protocol level. Their backend likely already supports creation natively (it's a CRUD-shaped API in most cases — Linear's `issueCreate`, Jira's `POST /issue`, GitHub's `POST /issues`, etc.); the plugin just has no wire surface to expose it through.
- **Workflow authors using `subject_backend` plugins as a dispatch surface:** any workflow that needs to insert a new subject — a discovery loop that proposes ideas as tickets, an automated triage agent that files bugs, a CRM-touching workflow that opens cases — can't go through the standard subject CLI. Workarounds (calling the backend's native API directly via a custom skill or MCP tool) defeat the abstraction.
- **The `supports_create: bool` schema field is misleading.** Backends advertise it in their schema response today, but there's nothing for it to gate — there's no `create` verb for the daemon to refuse routing to.
- **Reference plugin behavior diverges.** `animus-subject-sqlite` is local-storage-backed and could implement creation directly (no API call to make), but it can't expose it through the protocol either. Workflows that need create end up needing a custom side-channel regardless of whether the data lives in a remote API or a local file.

### Fix

1. **In `animus-subject-protocol`:** add a `NewSubject` request type mirroring the existing `SubjectPatch` / `Subject` shapes:

   ```rust
   #[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
   pub struct NewSubject {
       pub kind: String,
       pub title: String,
       #[serde(default, skip_serializing_if = "Option::is_none")]
       pub description: Option<String>,
       #[serde(default, skip_serializing_if = "Option::is_none")]
       pub status: Option<SubjectStatus>,
       #[serde(default, skip_serializing_if = "Option::is_none")]
       pub priority: Option<u8>,
       #[serde(default, skip_serializing_if = "Option::is_none")]
       pub assignee: Option<String>,
       #[serde(default, skip_serializing_if = "Vec::is_empty")]
       pub labels: Vec<String>,
       #[serde(default, skip_serializing_if = "Option::is_none")]
       pub parent: Option<SubjectId>,
       #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
       pub custom: BTreeMap<String, Value>,
   }
   ```

2. **Add `create` to the trait** with a default impl so existing backends compile unchanged:

   ```rust
   async fn create(&self, _new: NewSubject) -> Result<Subject, BackendError> {
       Err(BackendError::Other(anyhow::anyhow!(
           "this backend does not implement subject/create"
       )))
   }
   ```

3. **Add wire-verb routing** for `subject/create` in `animus-plugin-runtime::handle_subject_request`, paralleling the existing `list/get/update/delete/schema` arms. Use the same `<kind>/<verb>` injection pattern the router already uses for `list`.

4. **Make `SubjectSchema::supports_create` load-bearing** — backends that implement `create` advertise `true`; the daemon checks this before routing and gives a clean "this backend does not implement create" error otherwise.

Per-backend follow-on work is then trivial — translate `NewSubject` to whatever the backend's native creation API expects (e.g., Linear's `issueCreate(input: IssueCreateInput!)`, Jira's POST body, etc.).

### Open questions for the design

These don't block the protocol expansion but are worth deciding once:

1. **Does `create` return a full `Subject` or just a `SubjectId`?** Recommendation: full `Subject` (mirrors `update`'s shape, keeps the wire surface symmetrical, costs no extra round trip for backends whose creation APIs already return the created record).
2. **Is `NewSubject.kind` required, or inferred from the wire method?** The current router splits `<kind>/<verb>` and injects `kind` into `SubjectFilter` for `list`. Cleanest parallel for `create` is the same — extract kind from `<kind>/create`, inject if `NewSubject.kind` is empty, error if both are set and disagree.
3. **First-class `idempotency_key` field on `NewSubject`?** Many real workflows want create-or-confirm-existing semantics. Backends could de-dup more efficiently with a protocol field than with `list`-then-conditionally-`create` in user-space. Defer until a second backend wants it; the user-space dance works in v1.

---

## Filing split

The two bugs do not need to be filed as one. They have different scopes, different repos, and different fix shapes. Cross-link them in the bodies.

**Bug A → `launchapp-dev/animus-cli`.** One issue covering A.1–A.4. Suggested title:

> v0.5.4: `animus plugin ping/info/call` use the v1.0 handshake (no `init_extensions`), so they fail against every v1.1.0 plugin that requires `project_binding`. Runtime is unaffected because `plugin_clients::spawn_with_project_binding` hand-rolls the v1.1.0 frame inline — but the workaround was never threaded through the plugin-management CLI commands.

**Bug B → `launchapp-dev/animus-protocol`.** One issue, scoped narrowly to the `SubjectBackend::create` trait expansion. Suggested title:

> Add `SubjectBackend::create` verb (and `NewSubject` type) to unblock creation through the normalized subject API

---

## What's NOT a protocol bug, included for completeness

These show up in the same investigation surface but are different in shape — they're either fixed already or are environmental:

| Symptom | Nature | Where to fix |
|---|---|---|
| `subject/update` with `patch.comment` set silently overwrites the upstream record's description on some backends | Plugin bug (per-backend). On `animus-subject-linear` v0.1.4 the `patch.comment` field was mapped to Linear's `IssueUpdateInput.description`, destroying the issue body. | Fixed per-backend. `animus-subject-linear` v0.1.5 routes `patch.comment` through Linear's `commentCreate` mutation. |
| `subject/update` for backends that accept UUIDs (Linear assignees, label IDs) doesn't resolve user-supplied names/emails | Plugin bug (per-backend). Backends need a name→UUID resolver layer. | Per-backend, e.g. `animus-subject-linear` v0.1.6. |
| `animus subject list/get/update/...` fails with "duplicate subject kind '<K>' claimed by '<plugin-A>' and '<plugin-B>'" | Installed-state collision. Multiple subject_backend plugins advertise the same kind (e.g., several reference plugins claim `task` as their default kind). Routing has no tiebreaker. | Operator: `animus plugin uninstall <one>`. Daemon could also help by warning at `install-defaults --include-subjects` time. |
| `animus subject update --help` has no `--comment` flag | CLI UX gap. Even after the per-backend comment fix (above), the CLI exposes no flag to set `patch.comment` — operators have to use `animus plugin call --method subject/update --params '{...,"patch":{"comment":"..."}}'`. | `animus-cli` scope. |
