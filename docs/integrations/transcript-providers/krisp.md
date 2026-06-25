# Krisp

Spike date: 2026-06-25. Sources at the bottom.

## Interface

- **Official MCP**, remote: `https://mcp.krisp.ai/mcp`.
- **Transport:** Streamable HTTP only. **SSE is not supported.** Use only this
  endpoint.
- **Auth:** OAuth 2.0 + PKCE. Custom clients send JSON-RPC over HTTP POST with
  `Authorization: Bearer <access_token>` and `Content-Type: application/json`.
  There is **no static API key** for the MCP — `KRISP_API_KEY` in `.env.example`
  is a placeholder for non-MCP paths (e.g. the Webhook/Speech-to-Text APIs); the
  MCP itself authenticates via OAuth.

## Tools (by capability)

Krisp's help center 403s automated fetches, so confirm exact tool names via
`animus mcp` tool listing once connected, or the "Krisp MCP — Supported tools"
help page. Documented capabilities:

- **List / search meetings** by topic, content, attendees, or date range
  → maps to the collector's "list new transcripts since cutoff".
- **Read meeting content by document id** — full transcript, summary, key
  points, action items → maps to "fetch full text + metadata".
- Plus: list action items, upcoming calendar meetings, Activity Center
  notifications (unused by discovery).

## Particularities for this project

- **Remote + OAuth** → wire via Animus HTTP transport with an `oauth:` block,
  not the stdio stub. One-time interactive seed with
  `animus mcp auth transcript-source`; tokens cached + auto-refreshed.
- For an MCP client that can't speak remote HTTP directly, Krisp documents an
  `mcp-remote` bridge — not needed for Animus, which supports `transport: http`
  natively.
- Transcript segment timestamps: include `segments[]` only if the tool returns
  per-utterance timing; otherwise the collector sets `timestamp_available=false`
  (already handled downstream).

## Wiring snippet (`.animus/workflows/custom.yaml`)

```yaml
mcp_servers:
  transcript-source:
    transport: http
    url: https://mcp.krisp.ai/mcp
    oauth:
      flow: authorization_code   # seed via: animus mcp auth transcript-source
    # tools: [ ... ]             # optionally restrict to list/read transcript tools
```

```bash
# .env
TRANSCRIPT_PROVIDER=krisp
# KRISP_API_KEY only needed for non-MCP Krisp APIs; MCP uses OAuth.
```

Then: `animus mcp auth transcript-source` → `animus mcp auth-status` → manual
`transcript-fetch` → enable the `discovery` schedule.

## Sources

- Krisp MCP (endpoint, transport, OAuth, Bearer): https://help.krisp.ai/hc/en-us/articles/25396920405148-Krisp-MCP
- Krisp MCP — Supported tools: https://help.krisp.ai/hc/en-us/articles/25416265429660-Krisp-MCP-Supported-tools
- Krisp MCP — Integrating your own MCP client: https://help.krisp.ai/hc/en-us/articles/25416400191004-Krisp-MCP-Integrating-your-own-MCP-client
- Krisp Webhook API: https://help.krisp.ai/hc/en-us/articles/24514911804316-Webhook-API
