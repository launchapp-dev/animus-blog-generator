# MCP Tools

The blog generator ships with **11 MCP servers** that give agents access to search, scraping, analytics, image generation, transcript ingest, content library, and self-orchestration.

## Search & Discovery

| Server | Package | What It Does |
|--------|---------|--------------|
| **Exa** | `exa-mcp-server` | Neural/semantic search — finds topically relevant content, competitor articles, and research papers |
| **Tavily** | `tavily-mcp` | AI-optimized search — returns structured, LLM-friendly results for research queries |
| **Brave Search** | `@anthropic/brave-search-mcp` | Web search — broad coverage for news, forums, Reddit threads, and general queries |

## Data Extraction

| Server | Package | What It Does |
|--------|---------|--------------|
| **Firecrawl** | `firecrawl-mcp-server` | Web scraping — extracts clean content from industry reports, competitor blogs, government data |
| **Google Maps** | `google-maps-mcp-server` | Location data — business details, local context, neighborhood info for geo-relevant content |

## Analytics & Performance

| Server | Package | What It Does |
|--------|---------|--------------|
| **Search Console** | `search-console-mcp` | Google Search Console — ranking data, click-through rates, striking-distance keywords, performance trends |
| **Perplexity** | `@perplexity/modelcontextprotocol` | AI citation tracking — checks whether your content is being cited by LLM-powered search engines |

## Asset Generation

| Server | Package | What It Does |
|--------|---------|--------------|
| **Replicate** | `replicate-mcp` | Image generation — creates featured images via Google's Nano Banana Pro model (16:9, no text/watermarks) |

## Orchestration

| Server | Package | What It Does |
|--------|---------|--------------|
| **animus** | `animus mcp serve` | Animus self-management — task/subject creation, queue management, lets agents schedule follow-up work |

## Discovery Loop

| Server | Package | What It Does |
|--------|---------|--------------|
| **Transcript Source** | (in workflow YAML, BYO) | Transcript ingest — the single active provider (Krisp or Granola) for the idea-discovery pipeline. Selected by `TRANSCRIPT_PROVIDER`. |
| **Content Library** | (in workflow YAML, BYO) | Org "knowledge brain" — deep drafting context (prior research, established facts, brand positions, angles already used) so agents write unique, high-quality content; also dedup + internal-link slugs. Bring your own content MCP. |

> Both ship as no-op stubs (`command: "true"`, macOS). The transcript-source gates the discovery half — wire your provider's MCP (Krisp or Granola) and set `TRANSCRIPT_PROVIDER` to match. **content-library is a bring-your-own extension point** — wire your own content MCP to give agents a knowledge brain. Until then it is a no-op stub and every agent that uses it falls back to `content/manifest.json` + research (the prompts say "do not block"), so the pipeline runs without it.

## Subject Backends

Linear is integrated as an **Animus subject backend** (not an MCP server). The `animus-subject-linear` plugin auto-maps Linear's `WorkflowState.type` to Animus's normalized statuses (`ready / in-progress / blocked / done / cancelled`). The local SQLite backend serves a dedicated `blogtask` kind for queue-wrapper dispatch logs (`ANIMUS_SQLITE_KINDS=blogtask`).

| Backend | Kind | What It Does |
|---|---|---|
| **Linear** | `issue` | Linear issues as Animus subjects — the human-review system-of-record |
| **SQLite** | `blogtask` | Local `blog-from-ticket` dispatch log (reference-only) |
| **Markdown** | `task` | Git-visible content tasks |

One-time install: `animus plugin install launchapp-dev/animus-subject-linear`

## Which Agents Use What

```
Strategist           → animus, exa, tavily, brave, firecrawl, search-console, content-library
Researcher           → firecrawl, exa, tavily, brave, google-maps, content-library
Writer               → content-library
SEO Optimizer        → search-console, firecrawl, content-library
Asset Generator      → replicate
Performance Analyst  → animus, search-console, exa, perplexity
Content Refresher    → firecrawl, content-library
Transcript Collector → transcript-source
Idea Strategist      → animus, content-library, search-console, exa, tavily, brave, firecrawl
Approval Watcher     → animus
Linear Coordinator   → animus
Register Post Runner → (local script only)
```

## Bring Your Own CMS

There's a commented-out slot in `custom.yaml` for a publishing MCP server. Plug in your blog's API to go from "push branch" to "live on site" automatically.
