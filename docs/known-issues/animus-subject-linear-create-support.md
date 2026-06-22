# Adding `issue/create` support to `animus-subject-linear`

**Status:** open — implementable in the plugin **today**, no upstream protocol change required
**Written:** 2026-06-16 (verified against installed `animus` v0.5.14, `/animus-cli` v0.5.15, `animus-subject-protocol` `v0.5.7`, and the plugin source at `/Users/rafal/Animus-Plugins/Linear-Plugin/animus-subject-linear`)
**Affects:** `animus-subject-linear` v0.1.7 (latest release; currently installed). Unblocks blog-generator [`docs/superpowers/plans/2026-06-05-discovery-flow.md`](../superpowers/plans/2026-06-05-discovery-flow.md) Task 3 (idea-strategist files blog ideas as Linear issues).
**Target version:** `animus-subject-linear` v0.1.8 (additive capability — minor/patch, not a breaking change)
**Supersedes the central premise of:** [`animus-subject-linear-required-fixes.md`](./animus-subject-linear-required-fixes.md) — that doc says create is a *"hard blocker, not addressable in the plugin alone, requires an upstream `SubjectBackend::create` trait verb first."* **That is incorrect for protocol v0.5.7.** The GraphQL mutation, input-mapping table, and test list in that doc are still good; the "wait for a protocol change" framing is not.

---

## TL;DR

`animus subject create --kind issue` already works end-to-end on the **daemon/CLI side** — the CLI builds the payload, the daemon's `SubjectRouter` dispatches `issue/create` to whichever backend owns the `issue` kind. The **only** thing missing is on the plugin side: `animus-subject-linear` never registers a handler for `issue/create`, never calls Linear's `issueCreate` GraphQL mutation, and advertises `supports_create: false`.

Crucially, **create is not a `SubjectBackend` trait method and was never meant to be.** The protocol deliberately exposes it as a *raw method handler* you register on the plugin's `Plugin` builder. So the entire change lives in this repo — three source files plus tests — and ships as a normal `v0.1.8`.

Three things are missing, all in `animus-subject-linear`:

1. **A `LinearBackend::create(...)` method** that runs Linear's `issueCreate` mutation (mirror the existing `update()` → `issueUpdate` path).
2. **`issue/create` + `subject/create` handler registration** in `main.rs` (the stock `subject_backend_main` only wires `list/get/update/delete/schema`).
3. **`supports_create: true`** in `schema()` (currently `false` at `src/backend.rs:651`), plus a `project_id` field in `config.rs`.

---

## Why the "upstream protocol change required" claim is wrong

The earlier doc verified (correctly, at the time) that the `SubjectBackend` trait has no `create` verb. The mistaken inference was that a trait verb is a *prerequisite*. It isn't. Here's what protocol `v0.5.7` (the version the released plugin v0.1.6+ already builds against) actually says:

`animus-subject-protocol/src/lib.rs` — `SubjectSchema::supports_create` doc comment (rev `6b98095`, tag `v0.5.7`):

```rust
/// True iff the plugin honors `<kind>/create` verb invocations.
///
/// The protocol-standard `subject/create` verb has not been wired in
/// any first-party plugin or daemon path; the kind-prefixed form is
/// the durable surface in production today. Backends that intend
/// callers to be able to insert new subjects should set this to
/// `true` and register a `<kind>/create` method handler.
pub supports_create: bool,
```

That is the protocol *telling you how to do it*: set `supports_create = true` and **register a `<kind>/create` method handler**. The `SubjectBackend` trait intentionally only carries the five verbs the daemon polls automatically (`list/get/update/delete/schema` + `watch`/`health`); anything else is a raw handler on the generic `Plugin` shell. The runtime gives you `Plugin::register_raw_method` / `register_method` for exactly this — the same primitives the runtime itself uses to wire the trait verbs.

So no change to `launchapp-dev/animus-protocol` is needed. (Prerequisites 0 and 1 from the old doc — "cut a v0.1.5 release" and "bump the protocol pin" — are **already done**: v0.1.5/0.1.6/0.1.7 are released, v0.1.6 bumped the pin to `v0.5.7`, and the installed plugin is now v0.1.7.)

---

## The wire contract you must satisfy (verified end-to-end)

When a workflow or operator runs:

```bash
animus subject create --kind issue --title "Rental yields 2026" \
  --body "<structured markdown body>" --status ready --priority p1 --labels market,investment
```

the CLI builds a **flat** params object (`animus-cli` `crates/orchestrator-cli/src/services/operations/ops_subject.rs:80-95`):

```jsonc
// JSON-RPC method:  "issue/create"   (kind-prefixed; the daemon's SubjectRouter form)
// params:
{
  "title":    "Rental yields 2026",   // always present; CLI rejects empty
  "body":     "<structured markdown body>",  // optional  (NOTE: field is `body`, not `description`)
  "status":   "ready",                 // optional; normalized lowercase status string
  "priority": "p1",                    // optional; priority *bucket* string (p0..p3), NOT a Linear int
  "labels":   ["market", "investment"] // optional; label *names*, NOT Linear IDs
}
```

Key facts your handler must honor (all verified in source, not assumed):

- **Method name is `issue/create`** (kind-prefixed). There is **no** `METHOD_SUBJECT_CREATE` constant in the protocol — only `LIST/GET/UPDATE/DELETE/WATCH/SCHEMA` exist (`animus-subject-protocol/src/lib.rs:54-73`). Register `issue/create` (what the daemon sends) and `subject/create` (canonical alias) to be safe.
- **Params are flat**, not wrapped. Compare to `subject/update`, which sends `{id, patch}`. Create sends the fields at the top level. Your deserialize struct is flat.
- **`body`**, not `description`, is the JSON key the CLI emits → map it to Linear's `description`.
- **`status` is the normalized lowercase string** (`ready` / `in-progress` / `blocked` / `done` / `cancelled`). Parse it, then resolve to a Linear `stateId` via the existing `StatusMap`.
- **`priority` is a bucket string** (`p0`..`p3`), not Linear's `0..4` int — you must map it (see Decisions).
- **`labels` are names**, but Linear `issueCreate` wants `labelIds` (UUIDs) — you must resolve or skip (see Decisions).
- The handler must **return a serialized `Subject`** (same shape `get`/`update` return), so reuse `Self::issue_to_subject`.

The daemon control method that emits this is `subject_create` in `/animus-cli` `crates/orchestrator-daemon-runtime/src/control/dispatch.rs:360` — it routes `route_subject_call(kind, "create", params)` and nudges the scheduler. Confirmed present in the installed v0.5.14 CLI (`animus subject create --help` lists `--kind/--title/--body/--status/--priority/--labels`).

---

## What the plugin does today (and the one missing piece)

| Verb | Backed by | State |
|---|---|---|
| `issue/list` | `issues(filter, first, after)` | ✅ |
| `issue/get` | `issue(id)` | ✅ |
| `issue/update` (fields) | `issueUpdate` | ✅ (`backend.rs:155-168`, `534-593`) |
| `issue/update` (`patch.comment`) | `commentCreate` (`AnimusCreateComment`) | ✅ since v0.1.5 (`backend.rs:179-188`, `595-623`) |
| `issue/schema` | static + runtime workflow states | ✅ (`backend.rs:640-694`) |
| `health/check` | `viewer { id name }` | ✅ |
| `issue/watch` | — | not implemented (polling only) |
| **`issue/create`** | **— (no handler, no mutation, `supports_create:false`)** | **❌ this doc** |

The backend already has every building block create needs: a GraphQL `execute` client, a `StatusMap` (`animus_to_linear_state_id`), the `ISSUE_FIELDS` projection, and the `issue_to_subject` translator. Create is ~150 LOC of *recombination*, not new infrastructure.

---

## Step-by-step implementation

### Step 0 — sync the local clone to v0.1.7 (protocol v0.5.7)

The local checkout at `/Users/rafal/Animus-Plugins/Linear-Plugin/animus-subject-linear` is on `main`@`4df9aaa` (the v0.1.5 state, `Cargo.toml` still pins `animus-protocol` `v0.1.8`). The released v0.1.6/0.1.7 already bumped to `v0.5.7`. Start from there:

```bash
cd /Users/rafal/Animus-Plugins/Linear-Plugin/animus-subject-linear
git fetch --tags && git checkout v0.1.7 -b feat/issue-create
# Cargo.toml should now pin animus-{plugin,subject}-protocol + animus-plugin-runtime to tag "v0.5.7"
```

If for any reason v0.1.7 is still on `v0.1.8`, bump all three `animus-protocol` git deps in `Cargo.toml` to `tag = "v0.5.7"` — that release added the `supports_create` field and restored the `subject_backend_main*` helper family. No other dep change is needed.

### Step 1 — `config.rs`: add `project_id`

`LinearConfig` has `team_id` but **no `project_id`** (`src/config.rs:43-59`). Linear's `issueCreate` requires `teamId`; the discovery flow also wants to scope new issues to a project. Add:

```rust
/// Environment variable holding the Linear project UUID to file new issues into.
pub const ENV_PROJECT_ID: &str = "LINEAR_PROJECT_ID"; // discovery flow uses LINEAR_DISCOVERY_PROJECT_ID -> map in workflow YAML

pub struct LinearConfig {
    // ...existing fields...
    /// Optional project to attach created issues to. Read by `create`.
    pub project_id: Option<String>,
}
```

Populate it in `from_env()` (mirror the `team_id` line at `config.rs:71`) and thread it through `new()` / `without_token()` for the tests. Expose `LinearClient::project_id()` the same way `team_id()` is exposed.

### Step 2 — `backend.rs`: the `issueCreate` GraphQL mutation

Mirror `update_mutation()` (`backend.rs:155-168`). Add alongside it:

```rust
fn create_mutation() -> String {
    format!(
        r#"
        mutation AnimusCreateIssue($input: IssueCreateInput!) {{
          issueCreate(input: $input) {{
            success
            issue {{
              {ISSUE_FIELDS}
            }}
          }}
        }}
        "#
    )
}
```

Reusing `ISSUE_FIELDS` means the created issue comes back in the exact shape `issue_to_subject` already parses.

### Step 3 — `backend.rs`: a `CreateRequest` + `LinearBackend::create`

`create` is an **inherent** method (not a trait impl). Define the flat request struct to match the wire payload, then build the `IssueCreateInput`:

```rust
#[derive(Debug, Deserialize)]
pub struct CreateRequest {
    pub title: String,
    #[serde(default)] pub body: Option<String>,       // -> Linear `description`
    #[serde(default)] pub status: Option<String>,     // normalized: ready/in-progress/...
    #[serde(default)] pub priority: Option<String>,   // bucket: p0..p3
    #[serde(default)] pub labels: Vec<String>,         // names
    // richer callers (animus plugin call) may also pass:
    #[serde(default)] pub project_id: Option<String>,
    #[serde(default)] pub team_id: Option<String>,
}

impl LinearBackend {
    pub async fn create(&self, req: CreateRequest) -> Result<Subject, BackendError> {
        if !self.client.has_token() { return Err(missing_token_error()); }

        let title = req.title.trim();
        if title.is_empty() {
            return Err(BackendError::InvalidRequest("title must not be empty".into()));
        }
        let team_id = req.team_id.or_else(|| self.client.team_id().map(str::to_string))
            .ok_or_else(|| BackendError::InvalidRequest(
                "LINEAR_TEAM_ID must be set to create issues".into()))?;

        let status_map = self.status_map().await?;
        let mut input = serde_json::Map::new();
        input.insert("teamId".into(), json!(team_id));
        input.insert("title".into(), json!(title));
        if let Some(body) = req.body.filter(|b| !b.is_empty()) {
            input.insert("description".into(), json!(body));
        }
        if let Some(project) = req.project_id.or_else(|| self.client.project_id().map(str::to_string)) {
            input.insert("projectId".into(), json!(project));
        }
        if let Some(status_str) = req.status.as_deref() {
            let status = parse_subject_status(status_str)        // reuse config.rs helper (make it pub(crate))
                .ok_or_else(|| BackendError::InvalidRequest(format!("unknown status {status_str:?}")))?;
            let state_id = status_map.animus_to_linear_state_id(status).ok_or_else(|| {
                BackendError::InvalidRequest(format!(
                    "no Linear workflow state maps to {status:?}; set LINEAR_STATUS_MAP"))
            })?;
            input.insert("stateId".into(), json!(state_id));
        }
        if let Some(p) = req.priority.as_deref().and_then(priority_bucket_to_linear) {
            input.insert("priority".into(), json!(p));
        }
        // labels: see Decision 3 — resolve names -> labelIds, or omit.

        let response = self.client.execute(&Self::create_mutation(), json!({ "input": input }))
            .await.map_err(|e| BackendError::Unavailable(e.to_string()))?;
        let data = response.into_data().map_err(map_graphql_err)?;
        let payload = data.get("issueCreate")
            .ok_or_else(|| BackendError::Other(anyhow::anyhow!("missing `issueCreate` in response")))?;
        let success = payload.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
        if !success {
            return Err(BackendError::InvalidRequest(format!("linear rejected create: {payload}")));
        }
        let issue = payload.get("issue").filter(|v| !v.is_null()).cloned()
            .ok_or_else(|| BackendError::Other(anyhow::anyhow!("issueCreate returned no issue node")))?;
        Self::issue_to_subject(&issue, status_map)
    }
}
```

This reuses `status_map()`, `animus_to_linear_state_id`, `map_graphql_err`, and `issue_to_subject` verbatim — the same helpers `update()` uses.

### Step 4 — `backend.rs`: flip the schema flag

`src/backend.rs:651`:

```rust
-            supports_create: false,
+            supports_create: true,
```

### Step 5 — `main.rs`: register the create handler

This is the part the old doc missed. The stock entrypoint **cannot** carry create:

```rust
// animus-plugin-runtime v0.5.7, subject.rs:147
pub async fn subject_backend_main<B: SubjectBackend>(info, backend) -> Result<()> {
    let kinds = backend.schema().kinds.clone();          // ["issue"]
    subject_plugin_with_kind_aliases(info, backend, kinds).run().await
}
```

`subject_plugin_with_kind_aliases` only registers `list/get/update/delete/schema` (in both `subject/*` and `issue/*` forms). So replace the `subject_backend_main(info, backend)` call at `src/main.rs:23` with a manual build that adds the create handlers:

```rust
use std::sync::Arc;
use animus_plugin_runtime::{subject_plugin_with_kind_aliases};
use animus_subject_linear::backend::{LinearBackend, CreateRequest};

let backend = Arc::new(LinearBackend::new(config)?);

// Base plugin: the 5 polled verbs in subject/* and issue/* forms.
let mut plugin = subject_plugin_with_kind_aliases(info, (*backend).clone(), ["issue"]);

// Register the create handler for BOTH the kind-prefixed form the daemon
// emits and the canonical alias. `register_method` deserializes CreateRequest
// for us (same primitive the runtime uses for get/update at subject.rs:314-326).
for method in ["issue/create", "subject/create"] {
    let b = backend.clone();
    plugin = plugin.register_method::<CreateRequest, _, _, _>(method, move |req, _ctx| {
        let b = b.clone();
        async move { b.create(req).await.map_err(animus_plugin_protocol::RpcError::from) }
    });
}

// Make sure the new verbs are advertised in the manifest / initialize response.
let mut methods = plugin.advertised_methods().to_vec();
for m in ["issue/create", "subject/create"] {
    if !methods.iter().any(|x| x == m) { methods.push(m.to_string()); }
}
plugin = plugin.methods(methods);

plugin.run().await
```

Notes:
- `LinearBackend` is `#[derive(Clone)]` over an `Arc` (`backend.rs:59-67`), so cloning for each handler is cheap.
- `BackendError: Into<RpcError>` (the runtime's `backend_error_to_rpc` is just `err.into()`), so `RpcError::from` works.
- If you prefer, `subject_backend_main_with_capabilities(info, backend, vec!["issue/create".into(), "subject/create".into()])` advertises the methods but **does not register handlers** — you still need the `register_method` calls, so the manual build above is the cleaner path.

### Step 6 — input mapping reference

| Wire field (flat params) | Linear `IssueCreateInput` | Handling |
|---|---|---|
| `title` (required) | `title` (required) | trim; reject empty → `InvalidRequest` |
| `body` | `description` | pass through markdown; field rename `body`→`description` |
| `status` (`"ready"`...) | `stateId` | `parse_subject_status` → `status_map.animus_to_linear_state_id`; omit when absent so Linear uses the team default |
| `priority` (`"p1"`...) | `priority` (int 0-4) | **map** (Decision 2); omit when absent |
| `labels` (names) | `labelIds` (UUIDs) | **resolve or omit** (Decision 3) |
| `project_id` (custom/plugin-call, or `LINEAR_PROJECT_ID`) | `projectId` | optional |
| `team_id` (or `LINEAR_TEAM_ID`) | `teamId` (required) | required → `InvalidRequest` if missing |

Enforce only Linear's hard requirements: non-empty `title`, resolvable `teamId`. Everything else is optional.

### Step 7 — tests (`tests/contract.rs`, mockito)

Mirror the existing update tests and the old doc's list:

- `create_translates_full_payload` — title+body+status+priority+project_id → assert `issueCreate.input` carries each, `stateId` resolved, returned `Subject.id` has `linear:` prefix.
- `create_rejects_empty_title` → `InvalidRequest`.
- `create_requires_team_id` — `LINEAR_TEAM_ID` unset → `InvalidRequest` naming the env var.
- `create_omits_stateId_when_status_none` — wire payload has no `stateId`.
- `create_maps_status_ready_to_backlog_stateId` — uses the discovered `StatusMap`.
- `create_propagates_graphql_errors` — `success:false` → `InvalidRequest` carrying the payload.
- `create_sets_projectId_from_config` — `LINEAR_PROJECT_ID` set → wire payload has `projectId`.
- `schema_advertises_supports_create_true` — guards against regressions.

Add a `tests/fixtures/create_issue_ok.json` mirroring `update_issue_ok.json`.

### Step 8 — version, release, install

```bash
# Cargo.toml (and plugin.toml if present): 0.1.7 -> 0.1.8
git commit -am "feat(create): implement issue/create via Linear issueCreate"
# open PR, tag v0.1.8, publish a GitHub release with the platform binaries (match v0.1.7's asset set)
animus plugin update --name animus-subject-linear --tag v0.1.8 --yes --restart-daemon
```

---

## Decisions you need to make

1. **Status on create.** The discovery flow creates issues at `status = ready` (Linear `backlog`-type state). If the caller omits `--status`, the cleanest behavior is to omit `stateId` and let Linear assign the team default (usually a backlog state → maps back to `ready`). Confirm that's acceptable vs. forcing `ready`.
2. **Priority bucket → Linear int.** The CLI sends `p0..p3`; Linear `priority` is `0=None, 1=Urgent, 2=High, 3=Medium/Normal, 4=Low`. There's no canonical mapping — pick one (e.g. `p0→1, p1→2, p2→3, p3→4`) and document it. Note: the existing `update()` path doesn't map priority at all, so this is genuinely new ground.
3. **Label names → IDs.** Linear `issueCreate` wants `labelIds` (UUIDs), not names. Options: (a) ship without label support on create and document it; (b) add a `LinearClient::resolve_label_ids(&[String]) -> HashMap<name,id>` helper (one `team.labels` query, cached) and share it with `update()` — which today passes names through as if they were IDs (latent bug). Recommended: (a) for v0.1.8, (b) as a fast-follow that fixes both paths.
4. **Idempotency.** Linear has no native dedup. The discovery-flow strategist already computes an idempotency key and `list`s for an existing subject before creating, so the plugin's `create` can stay a thin create. Don't add an `idempotency_key` field unless a second backend needs it.

---

## Verified against source (so you can trust the above)

| Claim | Evidence |
|---|---|
| `SubjectBackend` trait has no `create` (by design) | `animus-protocol@v0.5.7` `animus-subject-protocol/src/lib.rs:742-779` — list/get/update/delete/watch/schema/health only |
| Create is a raw handler, gated by `supports_create` | same file `:450-457` doc comment |
| Runtime exposes the handler primitives | `animus-plugin-runtime/src/subject.rs:63` (`subject_plugin`), `:147` (`subject_backend_main`), `:287/:314` (`register_raw_method`/`register_method`) |
| `subject_backend_main` wires only 5 verbs | `subject.rs:147-155` → `subject_plugin_with_kind_aliases` (`:94-136`) |
| Daemon emits `issue/create` with flat params | `/animus-cli` `ops_subject.rs:80-95`, `dispatch(kind,"create")`; router `subject_router.rs:285-298` |
| No `METHOD_SUBJECT_CREATE` constant exists | `animus-subject-protocol/src/lib.rs:54-73` |
| Plugin currently `supports_create:false`, uses `subject_backend_main` | `backend.rs:651`, `main.rs:23` |
| Installed plugin v0.1.7 has no `issueCreate`/`subject/create` | binary string scan: only `issueUpdate` + `commentCreate`; methods `subject/{list,get,update,delete,schema}` |

**Not verified / assumptions:** Linear's exact `IssueCreateInput` field names (`teamId`/`title`/`description`/`projectId`/`priority`/`stateId`/`labelIds`) are from Linear's public GraphQL schema — confirm against your account's schema. The v0.1.7 `main.rs` is inferred to use `subject_backend_main` from the v0.1.6 changelog ("restored `subject_backend_main` helper"); confirm after `git checkout v0.1.7`.

---

## Cross-references

- Old (now partially superseded) doc: [`animus-subject-linear-required-fixes.md`](./animus-subject-linear-required-fixes.md)
- Discovery flow that needs this: [`docs/superpowers/plans/2026-06-05-discovery-flow.md`](../superpowers/plans/2026-06-05-discovery-flow.md) (Task 3), [`…/specs/2026-06-05-discovery-flow-design.md`](../superpowers/specs/2026-06-05-discovery-flow-design.md)
- Plugin source: `/Users/rafal/Animus-Plugins/Linear-Plugin/animus-subject-linear` (`src/backend.rs`, `src/config.rs`, `src/main.rs`)
- Repo: `animus-ecosystem/animus-subject-linear` (formerly `launchapp-dev/animus-subject-linear`; old path still redirects)
