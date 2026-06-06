# Bug: `animus-queue-default` v0.2.0 fails plugin initialization

**Status:** open
**Discovered:** 2026-06-05
**Plugin:** `animus-queue-default` v0.2.0 (kind: `queue`)
**Installed at:** `~/.animus/plugins/animus-queue-default` (1.6 MB binary)
**Filed externally:** https://github.com/launchapp-dev/animus-queue-default/issues/2

## Summary

The reference queue plugin shipped as the default in Animus v0.5.4 advertises a complete manifest (capabilities: `queue/enqueue, queue/list, queue/lease, queue/stats, queue/hold, queue/release, queue/release_pending, queue/drop, queue/reorder, queue/mark_assigned, queue/completion, health/check`) but **fails the post-handshake initialize step**, leaving the daemon unable to route queue operations through it. The daemon falls back to a bundled implementation, but the v0.5 external-plugin replacement isn't running.

## Environment

- Animus: `animus 0.5.4`
- Plugin: `animus-queue-default` v0.2.0 (`launchapp-dev/animus-queue-default`, installed via `path` source)
- Platform: macOS Darwin 24.6.0 (arm64)

## Reproduction

```bash
animus plugin ping --name animus-queue-default --json
```

Output:

```json
{
  "schema": "animus.cli.v1",
  "ok": false,
  "error": {
    "code": "internal",
    "message": "plugin initialize failed",
    "exit_code": 1
  }
}
```

The manifest loads fine in isolation:

```bash
~/.animus/plugins/animus-queue-default --manifest
```

returns the full JSON manifest without error. The failure is downstream of manifest reporting — somewhere in the JSON-RPC initialize handshake the plugin process exits with code 1.

Running the binary directly with no stdin (`< /dev/null`) shows it exits silently and immediately — no stderr diagnostic surfaced. The binary's own `--help` confirms it expects JSON-RPC over stdin/stdout for the run mode, but offers no debug or verbose flag to surface the initialize failure cause.

## Expected behavior

`animus plugin ping --name animus-queue-default` should return `ok: true` after a successful handshake, and the daemon should route queue dispatches through this plugin.

## Actual behavior

Init fails with exit_code 1 and no diagnostic output. Daemon presumably falls back to its bundled queue implementation (this is inferred — daemon stays up; `animus queue` CLI calls still work against some queue backend, just not this plugin).

## Impact on this project

Our blog discovery flow (`docs/superpowers/plans/2026-06-05-discovery-flow.md`) depends on `animus queue enqueue --task-id ... --workflow-ref blog-from-ticket --input-json '...'` for the approval → blog-from-ticket handoff. While the bundled queue fallback may handle this transparently, we can't validate the v0.5 plugin-routed queue dispatch path until this plugin initializes.

If the daemon's bundled fallback diverges from the plugin's documented behavior (e.g. on lease semantics, retry shape), we'll discover that mismatch only when we actually run the queue at scale — and the failure mode would be subtle.

## What we know

- Binary is executable (`-rwxr-xr-x`) and 1.6 MB.
- `--manifest` works (so the binary is at least partially functional).
- `--help` works and describes the JSON-RPC mode.
- No stderr output on either silent exit or attempted init — failure cause is opaque from the outside.

## Suggested resolution

1. Add an `--verbose` or `--init-debug` flag that prints initialize errors to stderr so the failure cause is surfaceable from `animus plugin ping`.
2. Investigate whether the initialize step expects state (config file, env var, working directory) that's missing in a fresh install. The binary should fail more gracefully with a descriptive error message identifying what's missing, rather than exiting 1 silently.
3. Document the relationship between this plugin and the daemon's bundled queue fallback — if the bundled implementation is now the default, the v0.5 plugin should either be uninstalled by default or boot cleanly.

## Workaround

For now, the daemon's bundled queue implementation handles our queue dispatch; no immediate workaround needed at the workflow level. Document failure in case the daemon's behavior changes in a future version that requires the plugin path to work.

## Tracking

Filed upstream: https://github.com/launchapp-dev/animus-queue-default/issues/2 (cross-references the `animus-workflow-runner-default` issue since both share the same init-failure signature).
