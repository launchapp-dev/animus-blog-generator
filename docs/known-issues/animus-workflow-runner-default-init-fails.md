# Bug: `animus-workflow-runner-default` v0.3.0 fails plugin initialization

**Status:** open
**Discovered:** 2026-06-05
**Plugin:** `animus-workflow-runner-default` v0.3.0 (kind: `workflow_runner`)
**Installed at:** `~/.animus/plugins/animus-workflow-runner-default` (23 MB binary)
**Filed externally:** not yet (this is the local placeholder until reported upstream)

## Summary

The reference workflow runner shipped as the default in Animus v0.5.4 advertises a complete manifest (`workflow/execute`, `workflow/run_phase`, `health/check`, protocol_version `1.1.0`) but **fails the post-handshake initialize step**, leaving the daemon unable to route phase execution through it. The daemon falls back to a bundled implementation (`oai-agent` legacy binary path, per the project-level CLAUDE.md context), but the v0.5 external-plugin replacement isn't running.

This plugin is the explicit replacement for the v0.4 in-tree `workflow-runner-v2`. If the v0.5 plugin path is intended to be the future default, this is a critical break.

## Environment

- Animus: `animus 0.5.4`
- Plugin: `animus-workflow-runner-default` v0.3.0 (`launchapp-dev/animus-workflow-runner-default`, installed via `path` source)
- Platform: macOS Darwin 24.6.0 (arm64)

## Reproduction

```bash
animus plugin ping --name animus-workflow-runner-default --json
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
~/.animus/plugins/animus-workflow-runner-default --manifest
```

returns:

```json
{
  "name": "animus-workflow-runner-default",
  "version": "0.3.0",
  "plugin_kind": "workflow_runner",
  "description": "Reference workflow_runner plugin for Animus v0.5 (stdio JSON-RPC + direct-execute CLI; replaces in-tree workflow-runner-v2)",
  "protocol_version": "1.1.0",
  "capabilities": ["workflow/execute", "workflow/run_phase"]
}
```

The failure is downstream of manifest reporting — the JSON-RPC initialize handshake exits with code 1. Running the binary directly with no stdin shows it exits silently and immediately, no stderr diagnostic.

Notably this is a 23 MB binary (vs 1.6 MB for queue-default) — likely embeds substantial workflow-orchestration logic, so initialize failures could have many root causes.

## Expected behavior

`animus plugin ping --name animus-workflow-runner-default` should return `ok: true` after a successful handshake. The daemon should route phase execution through this plugin, not the bundled fallback.

## Actual behavior

Init fails with exit_code 1 and no diagnostic output. The daemon presumably falls back to the bundled `oai-agent` workflow runner that ships with v0.5.4 as a "legacy" binary (per the project-level CLAUDE.md note). Our workflows still execute, but via the legacy path, not the v0.5 plugin path.

## Impact on this project

Our entire blog discovery flow runs workflows. If the v0.5 plugin path is the future and the legacy fallback is deprecated, our workflows will break when the fallback is removed. Until this plugin initializes, we're locked into the legacy runner — fine for now, but a future Animus version that drops the fallback would silently break our pipeline.

Additionally, any features documented as "v0.5 workflow_runner plugin" capabilities (e.g. potentially: phase-level retry policy, structured phase output streaming, on_failure hooks the plan checked for in Task -1) may not actually be active even though we've configured them in YAML.

## What we know

- Binary is executable, 23 MB.
- `--manifest` works.
- `--help` (would work — not verified) describes JSON-RPC mode.
- No stderr output on either silent exit or attempted init.
- Daemon stays up, suggesting the bundled fallback is taking over.

## Suggested resolution

Same as the parallel queue-default bug:
1. Add diagnostic output (`--verbose` / `--init-debug` flag) so initialize failures surface a cause.
2. Investigate whether the init step requires state / config / env / cwd that's missing on a fresh install.
3. Make the failure mode loud — silent exit 1 from a binary that the daemon depends on by name is a footgun.

## Relationship to `animus-queue-default-init-fails.md`

These two failures look identical from the outside: both are reference plugins that ship installed in v0.5.4, both pass `--manifest`, both fail `plugin ping` with `plugin initialize failed exit_code 1` and no stderr. This pattern suggests a **common root cause** — perhaps a shared initialize-handshake library in the plugin SDK, perhaps a shared config requirement neither plugin documents, perhaps a regression in the v0.5.4 daemon's handshake protocol that's incompatible with both plugins.

Worth investigating together rather than as two independent bugs. If filed upstream, cross-reference both issues.

## Workaround

The bundled legacy `oai-agent` workflow runner handles our workflows. No workflow-level workaround needed today. Document the failure so we notice if the daemon's fallback behavior changes.

## Tracking

When this is filed upstream at `launchapp-dev/animus-workflow-runner-default`, update this file with the issue URL.
