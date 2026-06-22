# Draft: `animus-cli` v0.5.4 — `plugin ping/info/call` use the v1.0 handshake, fail against every v1.1.0 plugin

**Status:** draft (ready to file at `launchapp-dev/animus-cli` once reviewed)
**Discovered:** 2026-06-06
**Affects:** `animus-cli` v0.5.4 (likely all v0.5.x). Symptom visible against `animus-queue-default` v0.2.0 and `animus-workflow-runner-default` v0.3.0; will affect every v1.1.0 plugin whose kind requires `project_binding`.
**Verified against:** `launchapp-dev/animus-cli` at tag `v0.5.4` (commit `77dadec`), local clone at `~/animus-cli`. File:line refs below all point at v0.5.4 source.
**Supersedes (probably):** [`launchapp-dev/animus-queue-default#2`](https://github.com/launchapp-dev/animus-queue-default/issues/2), [`launchapp-dev/animus-workflow-runner-default#2`](https://github.com/launchapp-dev/animus-workflow-runner-default/issues/2). Both were filed against the plugin repos but the fault is on the host side; neither plugin needs changes.

---

## Suggested title

> v0.5.4: `animus plugin ping/info/call` use the v1.0 handshake (no `init_extensions`), so they fail against every v1.1.0 plugin that requires `project_binding`. Runtime is unaffected because `plugin_clients::spawn_with_project_binding` hand-rolls the v1.1.0 frame inline — but the workaround was never threaded through the plugin-management CLI commands.

## Suggested body

### Summary

`animus plugin ping --name animus-queue-default` (and same for `animus-workflow-runner-default`, plus any other v1.1.0 plugin whose `initialize` handler requires `init_extensions.project_binding`) reports `plugin initialize failed`, `exit_code: 1`. **Workflow execution and queue dispatch still work** — those paths go through `crates/orchestrator-cli/src/services/plugin_clients.rs`, which hand-rolls a v1.1.0-shape `initialize` frame inline (with `init_extensions.project_binding` set from the project root). The diagnostic-style commands (`plugin ping/info/call`) don't use that helper; they go through `PluginHost::handshake()` which still emits a v1.0.0 frame with no `init_extensions`.

The fix is to lift `spawn_with_project_binding` into a reusable helper on `PluginHost` (or its spawn-options builder) and have `ops_plugin.rs` use it. The handshake bug is real but isolated to diagnostic tooling — most users will only notice when they run `animus plugin ping` and assume the runtime is broken too (it isn't).

### Environment

- `animus 0.5.4` (macOS Darwin 24.6.0, arm64)
- `animus-queue-default` v0.2.0, `animus-workflow-runner-default` v0.3.0 — both installed by `animus plugin install-defaults`, both pass `--manifest` cleanly.

### Reproduction

```bash
$ animus plugin ping --name animus-queue-default --json
{"schema":"animus.cli.v1","ok":false,"error":{"code":"internal","message":"plugin initialize failed","exit_code":1}}

$ animus plugin ping --name animus-workflow-runner-default --json
{"schema":"animus.cli.v1","ok":false,"error":{"code":"internal","message":"plugin initialize failed","exit_code":1}}
```

The plugin's actual error response (visible if you drive its stdio directly):

```bash
$ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol_version":"1.1.0","host_info":{"name":"animus","version":"0.5.4"},"capabilities":{"streaming":true,"progress":true,"cancellation":true}}}' \
    | ~/.animus/plugins/animus-queue-default
{"jsonrpc":"2.0","id":1,"error":{"code":-32207,"message":"init_extensions.project_binding is required to bind a project root"}}

$ printf '%s\n' '{...same frame...}' \
    | ~/.animus/plugins/animus-workflow-runner-default
{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"missing project_binding init extension"}}
```

Add `init_extensions.project_binding.project_root` and both plugins respond with a full `InitializeResult` including their typed `kind_capabilities`. They behave correctly.

### Root cause

**There are two `initialize` paths in the daemon, and only one was updated for protocol v1.1.0.**

1. **Runtime path (works):** `crates/orchestrator-cli/src/services/plugin_clients.rs::spawn_with_project_binding` hand-rolls a v1.1.0-shape JSON frame inline (lines 100-117), including `init_extensions.project_binding.project_root` and `repo_scope`, plus the optional `memory_mcp_stdio_command` extension. Used by `call_workflow_execute`, `call_workflow_run_phase`, and all the `call_queue_*` helpers. Daemon dispatch routes through these — workflow execution, queue lease, queue enqueue all work.

2. **Diagnostic / generic path (broken for v1.1.0 plugins):** `crates/orchestrator-plugin-host/src/host.rs::handshake` (lines 702-709) builds the typed `InitializeParams` struct, which is **the in-tree v1.0.0 shape with no `init_extensions` field at all**:

   ```rust
   // crates/animus-plugin-protocol/src/lib.rs:42, 486-493
   pub const PROTOCOL_VERSION: &str = "1.0.0";

   pub struct InitializeParams {
       pub protocol_version: String,
       pub host_info: HostInfo,
       pub capabilities: HostCapabilities,
   }
   ```

   The intent is explicit; the comment at `plugin_clients.rs:42-46` calls this out:

   > // The in-tree `animus-plugin-protocol` crate is still on protocol v1.0 and does NOT
   > // export this constant; the v0.5 protocol crate (transitively via
   > // `animus-workflow-runner-protocol`) defines it as the wire literal.

   `crates/orchestrator-cli/src/services/operations/ops_plugin.rs` calls the generic `handshake()` in three places:

   ```
   ops_plugin.rs:585-586  run_plugin_info  → `animus plugin info`
   ops_plugin.rs:605-606  run_plugin_ping  → `animus plugin ping`
   ops_plugin.rs:621-622  run_plugin_call  → `animus plugin call`
   ```

   None of them detour through `spawn_with_project_binding`. Result: every plugin that requires `init_extensions.project_binding` reports the (correct, structured) error, the daemon collapses it to `plugin initialize failed`, and the user assumes the plugin is broken when in fact the diagnostic command is what's broken.

**There's also a third inline copy of the project_binding handshake** at `crates/orchestrator-cli/src/services/runtime/runtime_daemon/notifier_dispatcher.rs:209-228` for notifier plugins. Three copies of the same workaround is a clear smell — the project_binding handshake needs to live on `PluginHost`.

### Diagnostic noise (secondary)

The `exit_code: 1` field in the `animus plugin ping --json` output is **not** the plugin process's exit code. Verified:

```bash
$ ~/.animus/plugins/animus-queue-default < /dev/null; echo $?
0
$ ~/.animus/plugins/animus-workflow-runner-default < /dev/null; echo $?
0
```

`exit_code: 1` is `crates/orchestrator-cli/src/shared.rs::classify_exit_code` mapping the `internal` error class to process exit code 1. It's the CLI's intended exit code, not anything the plugin produced. Worth renaming or adding a clarifying doc-comment.

Meanwhile the plugin's actual error message *is* propagated through the anyhow chain — `host.rs:717` formats it as `anyhow!("plugin initialize failed ({}): {}", error.code, error.message)` — but `ops_plugin.rs:606` wraps it with `.context("plugin initialize failed")` and the CLI's JSON envelope renders only that topmost context. Rendering the full chain (or surfacing `error.code`/`error.message` as a structured `cause` field) would have made this trivially diagnosable.

### What's NOT broken (worth saying explicitly)

If you're hitting `plugin ping failed` for queue/workflow_runner and worrying that workflows are falling back to a legacy runner — they aren't. The daemon's actual dispatch path for `workflow/execute`, `workflow/run_phase`, and the queue methods routes through `plugin_clients.rs` which hand-rolls the correct v1.1.0 frame. Preflight (`crates/orchestrator-core/src/plugin_preflight/`) is manifest-only — it doesn't run a handshake — so `animus daemon start` doesn't trip this bug either.

The bug is real, but its scope is the plugin-management CLI commands, not the runtime.

### Proposed fix

**One real change, plus two cleanups.** No plugin-side changes are required.

1. **Lift `spawn_with_project_binding` onto `PluginHost`.** Move the body of `crates/orchestrator-cli/src/services/plugin_clients.rs::spawn_with_project_binding` (lines 74-128) into a `PluginHost::handshake_with_project_binding(&self, project_root: &Path)` method on the host crate, or expose it as a builder option (`PluginSpawnOptions::with_project_binding(...)` already pairs nicely with `with_working_dir`). Have `ops_plugin.rs` call it from the three sites that currently call the bare `handshake()` (lines 585-586, 605-606, 621-622). Have `notifier_dispatcher.rs:212-228` and `plugin_clients.rs:100-117` use it too — three inline copies of the same JSON literal is a maintenance trap.

   The project root is already available at every call site:
   - `ops_plugin.rs` receives `req.project_root` in `PluginInfoRequest` / `PluginPingRequest` / `PluginCallRequest`.
   - `plugin_clients.rs` is already called with `project_root: &Path`.
   - `notifier_dispatcher.rs` already constructs the project_binding map from a local `project_root`.

2. **Bump in-tree `animus-plugin-protocol` to v1.1.0** (or add `init_extensions: HashMap<String, Value>` as `#[serde(default)]` to the in-tree v1.0.0 struct). The in-tree pin is what forces the three inline JSON hand-rolls today — the typed `InitializeParams` literally can't express the field. The published v1.1.0 protocol has it (`std::collections::HashMap<String, Value>` with `#[serde(default, skip_serializing_if = "...")]`); copying that field across is one line. Also bump `PROTOCOL_VERSION` to `"1.1.0"` so plugins can do version-pegged behavior correctly.

3. **Render the full anyhow chain in CLI JSON output.** Whichever sink emits the `{ "code", "message", "exit_code" }` envelope for `animus plugin ping --json` should walk `anyhow::Error::chain()` and include the deepest message as a `cause` field (or render the whole chain in `message`). Optional but high-leverage — this bug would have been a 30-second diagnosis if the plugin's `(-32207) init_extensions.project_binding is required` had been in the output.

### Why this is one bug, not two

The two plugin-repo issues report identical symptoms against different binaries and explicitly suspect a shared root cause. They were correct: both fail because the daemon's diagnostic-handshake path is missing a field that protocol v1.1.0 made required for the new plugin kinds those plugins implement. Fix `PluginHost::handshake_with_project_binding` (or equivalent) + thread it through `ops_plugin.rs` → both plugins start passing `plugin ping`. No plugin-side changes needed in either repo; both upstream issues can be closed by pointing here.

### Cross-references

- [`launchapp-dev/animus-queue-default#2`](https://github.com/launchapp-dev/animus-queue-default/issues/2)
- [`launchapp-dev/animus-workflow-runner-default#2`](https://github.com/launchapp-dev/animus-workflow-runner-default/issues/2)
- Internal: `docs/known-issues/animus-queue-default-init-fails.md`, `docs/known-issues/animus-workflow-runner-default-init-fails.md` — both should be updated to note that the runtime path isn't affected.

### Workaround until fixed

No daemon-side workaround needed — workflows and queue dispatch keep working through the inline-hand-rolled v1.1.0 path. The diagnostic commands stay broken until the fix lands. If you really need to ping/info/call a v1.1.0 plugin from the CLI today, you can drive it directly with `printf … | ~/.animus/plugins/<name>` using a hand-rolled JSON-RPC frame that includes `init_extensions.project_binding.project_root`.
