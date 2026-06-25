# Implementation Plan: Provider-Neutral Transcript Source (Krisp / Granola)

**Date:** 2026-06-25
**Status:** Provider-neutral plumbing implemented + released (v0.2.0). Granola access spike **complete** (2026-06-25) — see `docs/integrations/transcript-providers/`. Granola has a usable MCP (official remote OAuth + community local-cache); concrete wiring snippets documented per provider.
**Verified against:** current `.animus/workflows/custom.yaml`, `workflow-idea-discovery.yaml`, `.env.example`, `README.md`, `MCP-TOOLS.md`.

## Goal

Let the discovery pipeline source transcripts from **either Krisp or Granola** —
one active provider at a time — without provider-specific branching in the
workflow. The mechanism is a single provider-neutral MCP alias
(`transcript-source`) plus a small normalization contract the collector agent
already produces.

## Design

Exactly one provider is active at a time, selected by what is wired under
`mcp_servers.transcript-source`. There is **no multiplexer** and **no separate
adapter process**: the `transcript-collector` agent already calls provider MCP
tools and writes a normalized staged transcript file — it *is* the
normalization layer. A provider-neutral prompt plus the wired MCP's tool list is
enough for the agent to adapt to a different provider's tool names.

`TRANSCRIPT_PROVIDER` (env) is the **canonical** declaration of which provider
is active. It must match the wired MCP. The cursor records the same provider so
a provider switch is detected and fails closed instead of silently applying a
stale cross-provider timestamp cutoff.

### Normalized staged transcript contract

```json
{
  "id": "<provider>:<raw_provider_id>",
  "raw_provider_id": "<raw_provider_id>",
  "created_at": "<ISO8601>",
  "participants": [],
  "duration_secs": 0,
  "title": "...",
  "text": "...",
  "segments": []
}
```

- **`id` is namespaced** as `<provider>:<raw_provider_id>` (e.g.
  `granola:abc123`). This makes ids globally unique across providers, so
  idempotency keys (`discovery:<id>:<hash>`) and staged filenames
  (`<id>.json` → sanitized) never collide after a provider switch.
- `raw_provider_id` keeps the unprefixed provider id for provenance/debugging.
- `id`, `created_at`, `text`, and `segments` stay load-bearing — downstream
  idempotency keys, the cursor, the Source section, and timestamp handling all
  depend on them. `segments` remains optional (`timestamp_available=false` when
  absent — already handled).

### Cursor contract

```json
{
  "provider": "<krisp|granola>",
  "last_processed_id": "<namespaced id>",
  "last_processed_at": "<transcript created_at>",
  "updated_at": "<ISO8601>"
}
```

- Written by `idea-strategist` (the cursor owner) — its write step now includes
  `provider`.
- Read by `transcript-fetch`. **Before listing**, if `cursor.provider` exists
  and differs from `TRANSCRIPT_PROVIDER`, the phase fails/skips with reason
  `provider_changed_reset_cursor_required` (operator deletes the gitignored
  cursor to migrate — single-user, no migration tooling needed).

## Steps

### 0. Spike Granola access — ✅ DONE (2026-06-25)

Granola **does** expose a usable callable transcript list + fetch interface:
- **Official remote MCP** `https://mcp.granola.ai/mcp` (Streamable HTTP, browser
  OAuth, no service-account key; `list_meetings` + `get_meeting_transcript`,
  transcript fetch is **paid-plan only**).
- **Community local-cache MCPs** (stdio, macOS) that reuse the desktop app's
  creds — fully non-interactive, unofficial, coupled to Granola's cache format.

Full findings, tool tables, auth/daemon trade-offs, and concrete wiring snippets
for **both Krisp and Granola** are documented in
`docs/integrations/transcript-providers/` (`README.md`, `krisp.md`,
`granola.md`). Krisp is likewise an official remote OAuth MCP
(`https://mcp.krisp.ai/mcp`). Wiring either provider is config-only against the
existing `transcript-source` alias.

### 1. Rename the MCP boundary to `transcript-source` (`custom.yaml`)

- `mcp_servers.krisp` → `mcp_servers.transcript-source`; keep the
  `command: "true"` stub (BYO, same pattern as `content-library`) until a real
  provider is wired. Comment explains it's the single active transcript
  provider (Krisp or Granola).
- `transcript-collector.mcp_servers`: `- krisp` → `- transcript-source`.
- Do **not** define both Krisp and Granola servers in the active config.

### 2. Make prompts provider-neutral

- `transcript-collector.system_prompt`: "List new transcripts from the
  configured transcript provider…" (drop "Krisp").
- `workflow-idea-discovery.yaml`: neutral comment header, neutral
  `transcript-fetch` directive ("List transcripts from the configured
  provider"), neutral workflow `description`, neutral schedule comment.

### 3. Apply the namespaced-id contract (`workflow-idea-discovery.yaml`)

- `transcript-fetch` directive: stage `id` as `<TRANSCRIPT_PROVIDER>:<raw id>`,
  add `raw_provider_id`, write to a filename derived from a sanitized `id`
  (replace `:` so it is filesystem-safe, e.g. `<provider>__<rawid>.json`).
- `idea-strategist` directive: idempotency key uses the namespaced `id`; cursor
  write adds `provider` (from `TRANSCRIPT_PROVIDER`).

### 4. Provider-change guard (`transcript-fetch`)

- At the top of the `transcript-fetch` directive, read the cursor; if
  `cursor.provider` is present and `!= TRANSCRIPT_PROVIDER`, emit skip with
  reason `provider_changed_reset_cursor_required` and do nothing else.

### 5. Env + docs

- `.env.example`: replace the Krisp-only block with a canonical provider switch:
  ```bash
  TRANSCRIPT_PROVIDER=krisp   # krisp | granola — MUST match the wired transcript-source MCP
  KRISP_API_KEY=
  GRANOLA_API_KEY=
  ```
- `README.md`: required-values list — transcript key is conditional on
  `TRANSCRIPT_PROVIDER`; replace "Krisp" mentions in the discovery section and
  state docs with "the configured transcript provider".
- `MCP-TOOLS.md`: rename the `Krisp` table row and the
  `Transcript Collector → krisp` diagram edge to `Transcript Source`. Server
  count stays 11 (rename, not add).

### 6. Validate

```bash
animus workflow config validate
animus workflow config compile
rg -n "Krisp|krisp" .animus README.md MCP-TOOLS.md .env.example   # expect clean
```

Then, once a real provider MCP is wired and `TRANSCRIPT_PROVIDER` is set, run
`transcript-fetch` manually with schedules still disabled, inspect the staged
JSON (namespaced `id`, provider-correct), and only then flip the `discovery`
schedule to `enabled: true`.

## Scope discipline (explicitly NOT doing)

Single user, <20 transcripts/day, manual Linear approval gate, never-run-live
flow → **no** multiplexer, transcript-schema versioning, provider
retry/backoff/rate-limiting, cursor migration tooling, or new unit tests for a
config rename. Verification is `config validate`/`compile` + the leakage grep +
one manual fetch. The provider-change guard lives in the `transcript-fetch`
agent directive (not a separate command phase) — a wrong cutoff just re-fetches
from a wrong timestamp, which is recoverable, so a deterministic command phase
is unwarranted here.
