# Transcript Providers (Krisp / Granola)

The discovery pipeline sources meeting transcripts through a single
provider-neutral MCP alias, `transcript-source`, wired in
`.animus/workflows/custom.yaml`. Exactly **one** provider is active at a time,
declared canonically by `TRANSCRIPT_PROVIDER` (`krisp | granola`) and matched by
whatever you wire under `mcp_servers.transcript-source`.

This folder documents the spike (2026-06-25) into each provider's real MCP
interface and the particularities that matter for wiring it into an **always-on,
headless macOS Animus daemon**.

- [`krisp.md`](krisp.md) — Krisp's official remote MCP.
- [`granola.md`](granola.md) — Granola's official remote MCP **and** the
  community local-cache option.

## Spike verdict

**Both providers expose a usable MCP interface.** Both *official* servers are
**remote Streamable-HTTP** endpoints behind **interactive OAuth** — there is no
static API key / service account for either official MCP. Granola additionally
has **community** MCP servers that read the desktop app's **local cache**, which
is the only fully non-interactive option.

| | Krisp (official) | Granola (official) | Granola (community) |
|---|---|---|---|
| Endpoint | `https://mcp.krisp.ai/mcp` | `https://mcp.granola.ai/mcp` | local stdio process |
| Transport | Streamable HTTP (no SSE) | Streamable HTTP | stdio |
| Auth | OAuth 2.0 + PKCE, Bearer token | Browser OAuth 2.0 + Dynamic Client Registration | reads `~/Library/Application Support/Granola/supabase.json` (or `cache-v3.json`) |
| Static token / service acct | ❌ (interactive OAuth) | ❌ ("no API key or service account") | ✅ (reuses desktop app creds) |
| Transcript fetch | read meeting content by id | `get_meeting_transcript` (**paid plan only**) | `get_granola_transcript` |
| List/search | search meetings by date/topic/attendees | `list_meetings`, `get_meetings`, `query_granola_meetings` | `list_granola_documents`, `search_granola_transcripts` |
| Official | ✅ | ✅ | ❌ (third-party) |
| macOS-only | no (remote) | no (remote) | yes (local app data) |
| Rate limit | varies by plan | ~100 req/min, varies by plan | n/a (local) |

(Discovery fetches ≤20 transcripts/day, so rate limits are a non-issue.)

## How auth interacts with a headless daemon

The Animus daemon runs non-interactively, but it **can** drive an OAuth remote
MCP. `mcp_servers` entries support `transport: http` + `url` + an `oauth:` block
(HTTP transport only; flows `client_credentials` / `refresh_token` /
`manual_bearer` / authorization-code). Tokens are seeded once with
`animus mcp auth transcript-source`, cached at
`~/.animus/<repo-scope>/mcp-oauth-cache/transcript-source.json`, and refreshed
automatically thereafter. OAuth servers are rewritten to an
`animus-mcp-proxy` stdio entry so tokens never reach CLI argv. Check status with
`animus mcp auth-status`.

The catch: **authorization-code OAuth needs a one-time interactive browser
login, and a fresh interactive login again whenever the refresh chain expires.**
For a server you babysit, that's fine. For a truly unattended box, it's a
recurring manual touch.

## Recommendation

- **Krisp →** official remote MCP via Animus `transport: http` + `oauth`
  (authorization-code, `animus mcp auth transcript-source`). Official,
  supported, one-time interactive seed. See [`krisp.md`](krisp.md).
- **Granola →** pick by priority:
  - *Most supported / stable:* official remote MCP (same HTTP+OAuth pattern as
    Krisp). Requires a **paid Granola plan** for `get_meeting_transcript`, and
    periodic interactive re-auth.
  - *Most daemon-friendly:* a **community local-cache** stdio MCP — fully
    non-interactive (reuses the running desktop app's creds), macOS-only, but
    unofficial and coupled to Granola's local cache format (which has changed
    before). See [`granola.md`](granola.md).

## Wiring (either provider)

1. Set `TRANSCRIPT_PROVIDER` in `.env` to match the provider you wire.
2. Replace the `transcript-source` stub in `.animus/workflows/custom.yaml` with
   the provider block from `krisp.md` / `granola.md`.
3. `animus workflow config validate && animus workflow config compile`.
4. For OAuth providers: `animus mcp auth transcript-source`, then
   `animus mcp auth-status`.
5. Run `transcript-fetch` manually (schedule still disabled), confirm staged
   JSON has the namespaced `id` (`<provider>:<raw>`), then flip the `discovery`
   schedule to `enabled: true`.

The collector agent is the normalization layer — it maps whichever provider's
list/fetch tools into the staged transcript contract (see the discovery plan,
`docs/superpowers/plans/2026-06-25-granola-transcript-source.md`). No adapter
process is needed.
