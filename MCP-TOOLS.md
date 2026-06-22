# MCP Tools

The blog generator ships with **9 MCP servers** that give agents access to search, scraping, analytics, image generation, and self-orchestration.

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
| **ao** | `ao mcp serve` | Animus self-management — task creation, queue management, lets agents schedule follow-up work |

## Which Agents Use What

```
Strategist        → ao, exa, tavily, brave, firecrawl, search-console
Researcher        → firecrawl, exa, tavily, brave, google-maps
Writer            → (none — pure writing)
SEO Optimizer     → search-console, firecrawl
Asset Generator   → replicate
Performance Analyst → ao, search-console, exa, perplexity
Content Refresher → firecrawl
```

## Bring Your Own CMS

There's a commented-out slot in `custom.yaml` for a publishing MCP server. Plug in your blog's API to go from "push branch" to "live on site" automatically.
