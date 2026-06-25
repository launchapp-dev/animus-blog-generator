# Granola

Spike date: 2026-06-25. Sources at the bottom. **Granola does expose a usable
MCP interface — an official one, plus several community ones.**

## Option A — Official Granola MCP (remote, OAuth)

- **Endpoint:** `https://mcp.granola.ai/mcp`. **Transport:** Streamable HTTP.
- **Auth:** browser OAuth 2.0 with **Dynamic Client Registration** (no client
  credentials needed). Each user authenticates individually in a browser.
  **"There is no API key or service account access method for MCP"** — so a
  headless daemon must seed/refresh via interactive `animus mcp auth`.
- **Tools:**
  | Tool | Purpose |
  |---|---|
  | `list_meetings` | Browse meetings (id, title, date, attendees) → collector "list" |
  | `get_meeting_transcript` | Raw transcript by id → collector "fetch" — **paid plans only** |
  | `get_meetings` | Search meeting content/notes |
  | `query_granola_meetings` | Conversational query over meetings |
  | `list_meeting_folders` | Folder info — **paid plans only** |
  | `get_account_info` | Verify connected account |
- **Plan gating:** free plan = your own notes, last 30 days;
  `get_meeting_transcript` and folders require a **paid plan**. This is the key
  gotcha — discovery needs raw transcripts, so a paid plan is effectively
  required for the official MCP.
- **Rate limit:** ~100 req/min, varies by plan (irrelevant at ≤20/day).

### Wiring (official)

```yaml
mcp_servers:
  transcript-source:
    transport: http
    url: https://mcp.granola.ai/mcp
    oauth:
      flow: authorization_code   # seed via: animus mcp auth transcript-source
```

```bash
# .env
TRANSCRIPT_PROVIDER=granola
```

`animus mcp auth transcript-source` → `auth-status` → manual fetch → enable.

## Option B — Community local-cache MCP (stdio, macOS, non-interactive)

Several third-party servers (e.g. `btn0s/granola-mcp`, `pedramamini/GranolaMCP`,
`proofsh/granola-mcp-server`) read the **desktop app's local data** instead of
calling Granola's API with OAuth:

- **Auth:** reuses the running desktop app's credentials —
  `~/Library/Application Support/Granola/supabase.json` (API-backed variants) or
  the local `cache-v3.json` (pure-local variants). **No per-run OAuth.**
- **Transport:** stdio (`command: node`, `args: [".../dist/index.js"]`).
- **Tools (btn0s example):** `list_granola_documents`,
  `search_granola_transcripts`, `get_granola_transcript`,
  `search_granola_notes`, `get_granola_document`, `search_granola_events`,
  `search_granola_panels`.
- **Trade-offs:** unofficial; coupled to Granola's local cache format, which has
  changed before (there are public "reverse-engineering Granola's export"
  write-ups). It can break on a Granola desktop update. But it is the only
  **fully non-interactive** path, which suits an always-on daemon.

### Wiring (community local-cache)

```yaml
mcp_servers:
  transcript-source:
    command: node
    args: ["/abs/path/to/granola-mcp/dist/index.js"]
    # reads ~/Library/Application Support/Granola/* — Granola desktop must be
    # installed and signed in on this Mac.
```

```bash
# .env
TRANSCRIPT_PROVIDER=granola
```

No `animus mcp auth` step — it authenticates off local app data.

## Choosing

- Want **official + supported** and have a **paid Granola plan** → Option A.
- Want **unattended on a macOS box** and accept third-party fragility → Option B.

Either way the collector agent normalizes the provider's list/fetch tools into
the staged contract; ids are namespaced `granola:<raw_id>`.

## Sources

- Official Granola MCP docs (endpoint, OAuth, tools, plan gating, rate limits): https://docs.granola.ai/help-center/sharing/integrations/mcp
- Official server listing: https://www.pulsemcp.com/servers/granola
- Community (btn0s, local cache + supabase.json): https://github.com/btn0s/granola-mcp · https://glama.ai/mcp/servers/btn0s/granola-mcp
- Community (pedramamini): https://mcpservers.org/servers/pedramamini/GranolaMCP
- Community (proofsh, local): https://github.com/proofsh/granola-mcp-server
- Granola MCP vs API for agents: https://www.scalekit.com/blog/granola-mcp-vs-api
- Reverse-engineering Granola's local export (cache fragility): https://medium.com/@danielmoon_65473/reverse-engineering-granolas-data-export-with-claude-code-and-a-script-to-do-it-d3d292452a43
