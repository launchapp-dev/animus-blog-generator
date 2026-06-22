# Required fixes for `animus-subject-linear` to unblock the discovery flow

**Status:** ⚠️ SUPERSEDED on its central premise (2026-06-16) — see [`animus-subject-linear-create-support.md`](./animus-subject-linear-create-support.md). The "requires an upstream protocol change before plugin work" framing below is **incorrect for protocol `v0.5.7`** (which the released plugin v0.1.6+ already builds against): `subject/create` is implementable in the plugin alone by registering an `issue/create` raw method handler and setting `supports_create: true` — no `SubjectBackend` trait verb is needed. Prerequisites 0 and 1 below are also done (v0.1.5–0.1.7 released; pin already bumped to v0.5.7; installed plugin is v0.1.7). The GraphQL mutation, input-mapping table, and test list below remain accurate and useful.
**Discovered:** 2026-06-06 (during discovery-flow preflight re-review)
**Affects:** `animus-subject-linear` v0.1.5 (current). Drives blog-generator [`docs/superpowers/plans/2026-06-05-discovery-flow.md`](../superpowers/plans/2026-06-05-discovery-flow.md) Task 3 (idea-strategist) being able to file blog ideas as Linear issues.
**Target version:** `animus-subject-linear` v0.2.0 (post-protocol bump)
**Related work shipped:** `animus-subject-linear` v0.1.5 fixed `patch.comment` (no longer overwrites issue description; routes through Linear's `commentCreate` mutation). See [`launchapp-dev/animus-subject-linear#3`](https://github.com/launchapp-dev/animus-subject-linear/pull/3).

---

## TL;DR

The discovery flow's idea-strategist needs to file new Linear issues as the human-review surface. `animus-subject-linear` v0.1.5 supports `list` / `get` / `update` (with comment-via-`commentCreate`) but has **no create path**. The block is upstream — `animus-plugin-protocol`'s `SubjectBackend` trait has no `create` verb. Once the protocol gains one, the Linear plugin needs ~200 LOC to wire it through Linear's `issueCreate` GraphQL mutation, plus contract tests and a README update.

A secondary item (`animus subject update --comment` CLI flag) is `animus-cli` scope, not plugin scope, but is documented here because it shows up as a "this plugin is broken" symptom from the workflow author's perspective.

## Prerequisite 0: cut a v0.1.5 release and upgrade the local install (5 min)

The comment-via-`commentCreate` fix is on `main` ([commit](https://github.com/launchapp-dev/animus-subject-linear/commits/main), merged via [`#3`](https://github.com/launchapp-dev/animus-subject-linear/pull/3) on 2026-06-06) but **no v0.1.5 git tag or GitHub release exists yet** — the published tag list ends at `v0.1.4`. The currently-installed plugin is also v0.1.4 (verified via `animus plugin list`), so the discovery flow's `linear-coordinator` agent (Task 5) would still get the `description`-overwriting bug if run today. Before Task 5 of the discovery flow can ship:

1. Cut a `v0.1.5` git tag on `main` in `launchapp-dev/animus-subject-linear`, publish a GitHub release, attach prebuilt binaries (matching v0.1.4's release artifact set).
2. `animus plugin install launchapp-dev/animus-subject-linear --force` to upgrade the local install.
3. `animus plugin info --name animus-subject-linear --json | jq '.data.manifest.version'` should report `0.1.5`.

No code changes — this is release management, but it's a hard gate on the discovery flow being able to post Linear comments correctly. Tracking here because it's the same scope (Linear plugin work needed to unblock discovery).

## Prerequisite 1: bump the protocol dependency (small, low-risk)

The plugin's `Cargo.toml` pins to `animus-protocol` `tag = "v0.1.8"`. The published tag list shows `v0.1.8 → v0.1.14` in the v0.1.x series, and the v0.5.x series is current (latest `v0.5.6`). Notably:

- **`v0.1.13`** introduced an `extra_capabilities` extension point on `backend_main` entrypoints, useful if the plugin ever wants to declare backend-specific capability flags. Not load-bearing for `create`.
- **`v0.5.0`** introduced the typed `KindCapability` system and protocol `PROTOCOL_VERSION = "1.1.0"` plus `init_extensions.project_binding`. The Linear plugin would gain typed kind capabilities (per the v0.5 SubjectBackend protocol crate). The v0.5 protocol crate also reworks the plugin-runtime stdio surface — this is a real migration, not a pure dep bump. Worth doing alongside v0.2.0 since both touch the plugin's wire surface.

**Recommendation:** for the v0.2.0 create work, bump straight to whatever protocol tag introduces `SubjectBackend::create` (likely a fresh `v0.1.15` or `v0.5.7` cut alongside the upstream protocol change). Don't do an interim bump in isolation; let the create work pull in the latest at the same time.

## Context: what `animus-subject-linear` v0.1.5 already does

After [`#3`](https://github.com/launchapp-dev/animus-subject-linear/pull/3) merged today:

| Method | Backed by | Status |
|---|---|---|
| `subject/list` | Linear `issues(filter, first, after)` | ✅ ships |
| `subject/get` | Linear `issue(id)` | ✅ ships |
| `subject/update` (general fields) | Linear `issueUpdate` | ✅ ships |
| `subject/update` (`patch.comment`) | Linear `commentCreate` | ✅ ships in v0.1.5 |
| `subject/schema` | static + runtime workflow states | ✅ ships |
| `health/check` | `viewer { id name }` | ✅ ships |
| `subject/watch` | — | not implemented (polling only, v0.2 roadmap) |
| **`subject/create`** | **— (no protocol method exists)** | **❌ this doc** |

The plugin advertises `subject_kinds: ["issue"]`. CLI calls go through `--kind issue`, ids are namespaced as `linear:<identifier>` (e.g. `linear:ENG-123`).

---

## Gap 1: `subject/create` support (P0 — blocks discovery flow Task 3)

### Why it matters

The discovery flow's idea-strategist (Task 3) needs to do — per `docs/superpowers/specs/2026-06-05-discovery-flow-design.md` line 151 and plan Task 3 Step 2:

```bash
animus subject create --kind issue --title "..." --body "<structured markdown body with idempotency key>"
```

Today the CLI subcommand `animus subject create` exists at the daemon level, but **the Linear plugin doesn't declare `subject/create` in its capability set**. The daemon's subject dispatcher will reject the call as method-not-supported by backend before it ever reaches Linear's API.

No clean workaround without this gap closed:
- A custom skill that calls Linear's GraphQL `issueCreate` directly would bypass the subject backend abstraction entirely, defeating the design's "Linear issues are first-class Animus subjects" goal.
- Pre-creating issues by hand isn't workflow-friendly.
- Falling back to `requirements` or `task` subject kinds would lose the human-review-in-Linear loop, which is the whole point of the flow.

### Upstream protocol prerequisite

**Hard blocker. Not addressable in the plugin alone.** `animus-plugin-protocol`'s `SubjectBackend` trait must gain a `create` verb before any plugin can implement it. Verified across protocol versions:

| Protocol checkout | `SubjectBackend` create verb? |
|---|---|
| `0761ff5` (`v0.1.8`, what `animus-subject-linear` builds against) | ❌ |
| `1dc37a0` (`v0.1.13`, `extra_capabilities` extension point) | ❌ |
| `70a2c1d` (`v0.5.0`, four new plugin-kind protocols) | ❌ |
| `9e4d4b4` (`v0.5.1`) | ❌ |

The `SubjectSchema::supports_create: bool` field exists in every version with a doc-comment saying "reserved for v0.4.x" — a placeholder for the protocol expansion that adds the verb. The expansion was never done.

**What needs to land upstream in `launchapp-dev/animus-protocol`:**

1. A `SubjectCreate` (or `NewSubject`) request type. Suggested shape, mirroring the existing `SubjectPatch` / `Subject` style:

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

2. A `create` method on `SubjectBackend` with a default impl that returns `BackendError::Other(anyhow!("create not supported"))` so existing backends compile unchanged:

   ```rust
   async fn create(&self, _new: NewSubject) -> Result<Subject, BackendError> {
       Err(BackendError::Other(anyhow::anyhow!(
           "this backend does not implement subject/create"
       )))
   }
   ```

3. Wire-verb routing for `subject/create` in `animus-plugin-runtime`'s `handle_subject_request` (paralleling the existing `list/get/update/delete/watch/schema` cases at `0761ff5/animus-plugin-runtime/src/lib.rs:484-572`).

4. `SubjectSchema::supports_create` becomes load-bearing — backends advertise `supports_create: true` when they implement the verb; the host can check this before routing.

This is a small upstream change (~80 LOC) but it has to land first. The Linear plugin work below assumes it has.

### Linear plugin implementation (post-protocol)

**Files:** `src/backend.rs` (~150 new LOC), `tests/contract.rs` (~120 new LOC), `tests/fixtures/` (1–2 new), `README.md` (small update), `Cargo.toml` + `plugin.toml` version bump to `0.2.0`, dependency bump to the protocol release that contains `NewSubject` + `SubjectBackend::create`.

**GraphQL mutation.** Linear's `issueCreate(input: IssueCreateInput!)` returns the created issue. The plugin needs:

```graphql
mutation AnimusCreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id            # Linear UUID (used for subsequent commentCreate)
      identifier    # e.g. ENG-123 (becomes linear:ENG-123 as SubjectId)
      ... (ISSUE_FIELDS — same shape list/get/update already use)
    }
  }
}
```

**Input mapping.** Translate `NewSubject` → `IssueCreateInput`:

| `NewSubject` field | Linear `IssueCreateInput` field | Notes |
|---|---|---|
| `kind` | (validate `== "issue"`) | Reject if anything else — the plugin only owns `issue` kind. |
| `title` | `title` | Required by Linear. |
| `description` | `description` | Optional; pass through as-is (markdown). |
| `status` | `stateId` | Same lookup the existing `update` path uses: `status_map.animus_to_linear_state_id(status)`. If `status` is `None`, omit `stateId` so Linear uses the team's default initial state. |
| `priority` | `priority` | Linear takes a 0-4 int; pass through. |
| `assignee` | `assigneeId` | Same TODO that `update` already has: today `update` passes the raw string through as `assigneeId`, which works only when callers pass a real Linear user UUID. A proper email/name → UUID lookup is a separate fix tracked across both paths. |
| `labels` | `labelIds` | Same problem: `update` today takes label names but Linear wants IDs. Either reuse a name→ID resolver (would need adding) or document that callers must pre-resolve. **Recommendation:** add a `LinearClient::resolve_label_ids(names: &[String]) -> Result<Vec<String>>` helper used by both `create` and `update`. |
| `parent` | `parentId` | Strip the `linear:` prefix, look up the parent's Linear UUID via a `get`, then pass. |
| `custom["project_id"]` | `projectId` | Read from the `custom` map first; fall back to `LINEAR_PROJECT_ID` env var if set. |
| `custom["team_id"]` | `teamId` | Read from `custom` first; fall back to the existing `LINEAR_TEAM_ID` config. Linear requires a team. |

**Default behavior when fields are absent.** Linear's `issueCreate` requires `teamId` + `title`; everything else is optional. So the minimum the plugin must enforce:

- `title` non-empty → `BackendError::InvalidRequest` if empty.
- `teamId` resolvable → `BackendError::InvalidRequest` referencing `LINEAR_TEAM_ID` if missing.
- `kind == "issue"` → `BackendError::InvalidRequest` otherwise.

Everything else can be omitted; Linear assigns defaults.

**Return value.** The mutation response includes the full issue node. Reuse the existing `Self::issue_to_subject(&issue, status_map)` translator. The returned `Subject` has the canonical `linear:<identifier>` SubjectId, matching the `list/get/update` shape.

**Schema declaration.** Update `LinearBackend::schema()` to set `supports_create: true` (currently `false` per `src/backend.rs:574`).

**Error handling.** Same `map_graphql_err` helper the rest of the backend already uses. Linear-specific concerns to surface clearly:
- `success: false` in the response → return `BackendError::InvalidRequest` with the payload (mirrors what `update` does today at `backend.rs:537-541`).
- Permission errors → already mapped to `PermissionDenied` by `map_graphql_err`.
- Missing team/project IDs → `InvalidRequest` before the network call.

### Test coverage

Add to `tests/contract.rs`:

- `create_translates_full_payload` — happy path with title, description, status, priority, assignee, labels, project_id in `custom`. Assert: `issueCreate.input` carries every field, `stateId` resolved from `status_map`, returned `Subject.id` has `linear:` prefix.
- `create_rejects_wrong_kind` — `NewSubject { kind: "task", ... }` → `BackendError::InvalidRequest`.
- `create_rejects_empty_title` → `BackendError::InvalidRequest`.
- `create_requires_team_id` — `LINEAR_TEAM_ID` unset → `BackendError::InvalidRequest` naming the env var.
- `create_omits_stateId_when_status_none` — verify the wire payload doesn't include `stateId` when caller leaves `status: None`.
- `create_propagates_graphql_errors` — Linear returns `success: false` → `BackendError::InvalidRequest` carrying the payload.
- `create_handles_minimum_input` — only `kind` + `title` + team configured → succeeds.
- `create_sets_project_id_from_custom` — `custom: {"project_id": "..."}` → wire payload has `projectId`.

Add one new fixture `tests/fixtures/create_issue_ok.json` mirroring the existing `update_issue_ok.json` shape.

### README update

Add `subject/create` row to the "Supported operations" table that v0.1.5 introduced. Document the `custom` field conventions (`project_id`, `team_id`) the plugin reads.

### Version bump

- `Cargo.toml`: `0.1.5` → `0.2.0` (minor bump: new capability surface).
- `plugin.toml`: `0.1.5` → `0.2.0`.
- Bump `animus-plugin-protocol` / `animus-subject-protocol` / `animus-plugin-runtime` git dependencies to the tag that introduces `NewSubject` + `SubjectBackend::create`.

---

## Gap 2: secondary items (lower priority)

### 2.1 `animus subject update --comment` CLI flag (animus-cli scope, not plugin scope)

Verified just now: `animus subject update --help` exposes `--id / --status / --priority / --labels` but **no `--comment` flag**. The plugin's `patch.comment` path is fully working as of v0.1.5, but the CLI doesn't expose a way to set it. Workflow directives that want to post a comment have to fall back to:

```bash
animus plugin call \
  --name animus-subject-linear \
  --method subject/update \
  --params '{"id":"linear:ENG-123","patch":{"comment":"..."}}'
```

This is a one-line addition to the CLI (`crates/orchestrator-cli/src/services/operations/ops_subject*` in `animus-cli`). **Not in scope for this plugin** — but worth noting because workflow authors hit it as "the Linear plugin can't comment".

### 2.2 Subject-kind naming (`issue` vs `linear`) — already documented, not changing

The plugin declares `subject_kinds: ["issue"]`. The discovery-flow plan and original GitHub issue [`#2`](https://github.com/launchapp-dev/animus-subject-linear/issues/2) both expected `linear`. v0.1.5's README rewrite (PR #3) made the `issue` choice explicit. The discovery-flow plan needs a corresponding `--kind linear` → `--kind issue` correction (see [`docs/superpowers/plans/2026-06-05-discovery-flow.md`](../superpowers/plans/2026-06-05-discovery-flow.md) re-review notes). No plugin change.

### 2.3 Label name → ID resolver (also affects `update`)

Both `update.patch.labels_add/remove` and the new `create.labels` need Linear's label IDs, not names. Today `update` passes names through as if they were IDs, which only "works" when the operator pre-resolves them. A `LinearClient::resolve_label_ids(names: &[String]) -> Result<HashMap<String, String>>` helper that queries the team's `labels` GraphQL field once per session and caches the result would fix both. Lifted to its own helper so `update` and `create` share it.

This isn't a hard blocker for v0.2.0 — workflow authors can pass label IDs directly via `custom` until it's added — but it's the cleanest place to introduce label-name resolution alongside the create work.

### 2.4 Assignee email/name → UUID resolver (also affects `update`)

Same shape as the label resolver. Linear's `issueCreate` / `issueUpdate` both take `assigneeId` (UUID). The plugin currently passes the raw string through, which only succeeds when callers pre-resolve. A `LinearClient::resolve_assignee_id(email_or_name: &str) -> Result<Option<String>>` helper would harden both paths. Same "not a blocker" / "cleanest to introduce here" reasoning as labels.

---

## Acceptance criteria for `animus-subject-linear` v0.2.0

- [ ] Prerequisite 0 done: `v0.1.5` released on GitHub, local install upgraded.
- [ ] Upstream `animus-protocol` release exists that adds `NewSubject`, `SubjectBackend::create`, and wire-verb routing for `subject/create`.
- [ ] `Cargo.toml` + `plugin.toml` bumped to `0.2.0`, protocol git deps point at that upstream tag.
- [ ] `LinearBackend::create` implemented per the input-mapping table above.
- [ ] `LinearBackend::schema()` returns `supports_create: true`.
- [ ] At least the 8 contract tests above pass; existing 21 tests still pass; `cargo clippy --all-targets` clean.
- [ ] README's "Supported operations" table includes `subject/create` with the same level of detail as the other rows.
- [ ] Manual end-to-end check: against a real Linear team, run `animus subject create --kind issue --title "test" --body "body" --json` and observe the issue appearing in Linear with the expected title/body/initial state. (Requires the duplicate-`task` subject-kind error in the local install to be resolved first — see discovery-flow re-review.)

## Open questions for the upstream protocol design

These need answers in the protocol issue, not here, but the Linear plugin implementation depends on them:

1. **Does `create` return a full `Subject` or just a `SubjectId`?** Recommendation: full `Subject` (mirrors `update`'s shape, keeps the wire surface symmetrical). Linear's mutation already returns the issue node so there's no extra round-trip cost.
2. **Is `NewSubject.kind` required, or inferred from the wire method?** The current router (`0761ff5/animus-plugin-runtime/src/lib.rs:590`) splits `<kind>/<verb>` and injects `kind` into `SubjectFilter` for `list`. The cleanest parallel for `create` is the same: extract `kind` from `<kind>/create` wire method, inject if `NewSubject.kind` is empty, error if both are set and disagree.
3. **Does `subject/create` accept idempotency keys at the protocol level**, or is dedup left to each backend? The discovery flow's strategist computes an idempotency key per angle and looks up existing subjects via `list` before creating. That works without protocol support — but a first-class `idempotency_key` field on `NewSubject` would let the backend dedup more efficiently. **Recommendation:** leave to the backend for v0.2; revisit when a second backend wants it.
4. **What's the wire method name — `subject/create` or `<kind>/create`?** Both work with the existing router; v0.1.x already accepts both forms for `list/get/update`. Stay consistent.

## Cross-references

- v0.1.5 ship (comment fix): [`launchapp-dev/animus-subject-linear#3`](https://github.com/launchapp-dev/animus-subject-linear/pull/3) (merged 2026-06-06)
- Original (now closed) plugin issues this work supersedes:
  - [`launchapp-dev/animus-subject-linear#2`](https://github.com/launchapp-dev/animus-subject-linear/issues/2) (subject/comment was the addressable half; subject/create is this doc's primary blocker)
- Discovery flow that needs this:
  - [`docs/superpowers/plans/2026-06-05-discovery-flow.md`](../superpowers/plans/2026-06-05-discovery-flow.md) (Task 3: idea-strategist)
  - [`docs/superpowers/specs/2026-06-05-discovery-flow-design.md`](../superpowers/specs/2026-06-05-discovery-flow-design.md)
- Sibling animus-cli bug doc (CLI-side diagnostic gap):
  - [`animus-cli-handshake-missing-project-binding.md`](./animus-cli-handshake-missing-project-binding.md)
