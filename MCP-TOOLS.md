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
| **Krisp** | (in workflow YAML) | Audio transcript ingest — source for the idea-discovery pipeline |
| **Content Library** | (in workflow YAML) | Org-wide content + artifact database — dedup + internal-link selection |

> Both ship as TODO stubs (`command: "true"`) until configured. Krisp may stay stubbed (discovery no-ops); content-library is a hard precondition for the blog-from-ticket generation half.

## Subject Backends

Linear is integrated as an **Animus subject backend** (not an MCP server). The `animus-subject-linear` plugin auto-maps Linear's `WorkflowState.type` to Animus's normalized statuses (`ready / in_progress / blocked / done / cancelled`). The local SQLite backend serves a dedicated `blogtask` kind for queue-wrapper dispatch logs (`ANIMUS_SQLITE_KINDS=blogtask`).

| Backend | Kind | What It Does |
|---|---|---|
| **Linear** | `issue` | Linear issues as Animus subjects — the human-review system-of-record |
| **SQLite** | `blogtask` | Local `blog-from-ticket` dispatch log (reference-only) |
| **Markdown** | `task` | Git-visible content tasks |

One-time install: `animus plugin install launchapp-dev/animus-subject-linear`

## Which Agents Use What

```
Strategist           → animus, exa, tavily, brave, firecrawl, search-console, content-library
Researcher           → firecrawl, exa, tavily, brave, google-maps
Writer               → content-library
SEO Optimizer        → search-console, firecrawl, content-library
Asset Generator      → replicate
Performance Analyst  → animus, search-console, exa, perplexity
Content Refresher    → firecrawl
Transcript Collector → krisp
Idea Strategist      → animus, content-library, search-console, exa, tavily, brave, firecrawl
Approval Watcher     → animus
Linear Coordinator   → animus
Register Post Runner → (local script only)
```

## Bring Your Own CMS

There's a commented-out slot in `custom.yaml` for a publishing MCP server. Plug in your blog's API to go from "push branch" to "live on site" automatically.
