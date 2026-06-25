# Animus Blog Generator

An automated blog generation pipeline powered by [Animus](https://github.com/launchapp-dev/ao-cli). It uses multiple AI agents working in sequence to research topics, write SEO-optimized posts, generate images, and create social media excerpts — all on autopilot.

You configure it once for your business niche, and it handles the rest: finding topics worth writing about, collecting research, writing with your brand voice, optimizing for search engines and AI citations, and generating platform-specific social content.

<details>
<summary><strong>Preview: what the workflow YAML looks like</strong></summary>

```yaml
# blog-engine.yaml — Automated SEO blog pipeline

mcp_servers:
  exa:
    command: npx
    args: [-y, exa-mcp-server]
    env: { EXA_API_KEY: "${EXA_API_KEY}" }
  firecrawl:
    command: npx
    args: [-y, firecrawl-mcp-server]
    env: { FIRECRAWL_API_KEY: "${FIRECRAWL_API_KEY}" }
  # ... brave, tavily, google-maps, search-console, replicate, perplexity

agents:
  content-strategist:
    model: claude-sonnet-4-6
    mcp_servers: [exa, tavily, brave, firecrawl, search-console]
    system_prompt: |
      SKILLS: Read and follow .animus/skills/content-strategy.md
      CONTEXT: Read business-context.yaml for all client details.

  content-writer:
    model: claude-opus-4-6
    mcp_servers: []
    system_prompt: |
      SKILLS: Read and follow .animus/skills/content-production.md,
      .animus/skills/ai-seo.md, .animus/skills/content-humanizer.md
      CONTEXT: Read business-context.yaml for voice guidelines.

  seo-optimizer:
    model: claude-sonnet-4-6
    mcp_servers: [search-console, firecrawl]
    system_prompt: |
      SKILLS: Read and follow .animus/skills/seo-audit.md,
      .animus/skills/schema-markup.md, .animus/skills/ai-seo.md

  # ... content-researcher, asset-generator, performance-analyst, content-refresher

phases:
  topic-research:
    agent: content-strategist
    directive: |
      Pick ONE blog topic. Analyze Search Console for striking-distance
      keywords, scan industry news, check competitor blogs for gaps,
      and mine Reddit/forums for real questions.

  research-collection:
    agent: content-researcher
    directive: |
      Gather all source material. Scrape data sources via Firecrawl,
      search via Exa/Tavily/Brave, pull location data from Google Maps.

  content-writing:
    agent: content-writer
    directive: |
      Write the full blog post as markdown with YAML frontmatter.
      Follow the voice rules and SEO rules in your system prompt.

  seo-review:
    agent: seo-optimizer
    directive: |
      Audit and fix SEO issues in-place. Keyword density, meta tags,
      internal links, readability, AI cliche removal.

  asset-generation:
    agent: asset-generator
    directive: |
      Generate a featured image via Replicate (Nano Banana Pro).

  social-excerpts:
    agent: asset-generator
    directive: |
      Create platform-specific social content for Instagram,
      Facebook, and LinkedIn.

workflows:
  - id: blog-production
    phases: [topic-research, research-collection, content-writing,
             commit-draft, seo-review, asset-generation, social-excerpts,
             push-branch]

  - id: refresh-cycle
    phases: [performance-analysis, content-refresh-write,
             refresh-seo-review, push-branch]

schedules:
  - { id: blog-tue, cron: "0 8 * * 2", workflow_ref: blog-production }
  - { id: blog-thu, cron: "0 8 * * 4", workflow_ref: blog-production }
  - { id: refresh,  cron: "0 8 * * 3", workflow_ref: refresh-cycle }
  - { id: news,     cron: "0 6 * * *", workflow_ref: news-monitor }
```

See the full workflow definition in [`.animus/workflows/custom.yaml`](.animus/workflows/custom.yaml).

</details>

## How It Works

The pipeline runs as a series of **workflows**, each made up of **phases** executed by specialized **agents**. Each agent has a specific role, its own set of tools (MCP servers), and access to your business context.

### Blog Production Workflow

```
topic-research ─→ research-collection ─→ content-writing ─→ commit-draft
                                                                │
    push-branch ←── social-excerpts ←── asset-generation ←── seo-review
```

| Phase | Agent | What it does |
|-------|-------|-------------|
| **topic-research** | content-strategist | Picks the highest-priority topic by analyzing Search Console data, scanning industry news, checking competitor blogs for gaps, and mining forums for real questions |
| **research-collection** | content-researcher | Gathers source material — scrapes reports, market data, government records via Firecrawl; searches via Exa, Tavily, Brave; pulls location data from Google Maps |
| **content-writing** | content-writer | Writes the full blog post (1,500-2,500+ words) as markdown with YAML frontmatter, following your brand voice and SEO rules |
| **commit-draft** | (command) | Git commits the draft |
| **seo-review** | seo-optimizer | Audits and fixes SEO issues in-place — keyword density, meta tags, internal links, readability, AI cliche removal |
| **asset-generation** | asset-generator | Generates a featured image via Replicate (Nano Banana Pro) and updates the post frontmatter |
| **social-excerpts** | asset-generator | Creates platform-specific social media content (Instagram, Facebook, LinkedIn) |
| **push-branch** | (command) | Pushes the branch to origin |

### Other Workflows

| Workflow | Purpose | Schedule |
|----------|---------|----------|
| **refresh-cycle** | Analyzes Search Console performance, identifies the most impactful post to refresh, updates statistics and data, re-optimizes SEO | Weekly |
| **image-refresh** | Regenerates featured images for existing posts | On demand |
| **news-monitor** | Scans for breaking industry news and auto-enqueues urgent blog topics | Daily |

### Agent Architecture

Each agent is a Claude instance with a focused role:

| Agent | Model | Role | Tools |
|-------|-------|------|-------|
| content-strategist | Sonnet 4.6 | Topic selection and content planning | Exa, Tavily, Brave, Firecrawl, Search Console |
| content-researcher | Sonnet 4.6 | Data collection and source gathering | Firecrawl, Exa, Tavily, Brave, Google Maps |
| content-writer | Opus 4.6 | Long-form content writing | None (pure writing) |
| seo-optimizer | Sonnet 4.6 | SEO auditing and fixing | Search Console, Firecrawl |
| asset-generator | Sonnet 4.6 | Image generation and social content | Replicate |
| performance-analyst | Sonnet 4.6 | Content performance analysis | Search Console, Exa, Perplexity |
| content-refresher | Opus 4.6 | Updating existing content | Firecrawl |

All agents read `business-context.yaml` for your business details, brand voice, and content strategy. The content-writing agents also follow skill files in `.animus/skills/` that encode best practices for content production, SEO, humanization, and social media.

## Discovery Flow (transcript-driven)

In addition to the cron-driven `blog-production` pipeline, this generator supports a transcript-driven discovery loop with a human-review gate in Linear (integrated as an Animus subject backend).

**Daily 7am — `idea-discovery`.** Polls Krisp for new transcripts. The strategist proposes 3–5 angles per transcript, each pre-validated with Search Console + competitor scan + spot-scraped citable sources. Surviving angles become Linear issues (Animus subjects) at status `ready`.

**Every 15 min — `approval-watch`.** Polls Linear-backed subjects for `status == in-progress` (the human-approval signal) and dispatches each newly-approved subject to `blog-from-ticket` via the queue (carrying `linear_subject_id`). Cancelled/Done/Blocked are filtered out. The gate is a deterministic script (`scripts/approval-watch.sh`), not an LLM — dedup is exact and a no-op poll costs no tokens.

**Per approved ticket — `blog-from-ticket`.** A variant of blog-production using the Linear ticket as the topic brief. `ticket-acknowledge` and `ticket-to-brief` both re-check the subject's status; if the human cancelled after approval, the run aborts cleanly. `register-post` runs before `push-branch` so the manifest commit ships with the push. The last phase posts a completion comment; status transition is opt-in via `LINEAR_FINALIZE_TRANSITION=done`.

**Authoritative-lifecycle invariant.** Linear is the single source of truth for lifecycle. The local SQLite `blogtask` wrapper is a subordinate, reference-only dispatch log — no phase reads its status; only `linear-finalize` writes back.

### One-time setup

```bash
animus plugin install launchapp-dev/animus-subject-linear
animus plugin list
animus plugin ping --name animus-subject-linear
```

### Daemon environment (`.env` is NOT auto-loaded)

The Animus daemon does **not** auto-load `.env`. Source it into the daemon's parent shell before starting:

```bash
set -a; source .env; set +a
animus daemon start --autonomous
```

`ANIMUS_SQLITE_KINDS=blogtask` must be in that environment too — it routes the local SQLite backend onto a dedicated kind so it doesn't collide with markdown's `task`.

### Required `.env` values (placeholders are in `.env.example`)

- `KRISP_API_KEY`
- `LINEAR_API_TOKEN`, `LINEAR_TEAM_ID`, `LINEAR_DISCOVERY_PROJECT_ID`
- `CONTENT_LIBRARY_URL`, `CONTENT_LIBRARY_TOKEN`
- `ANIMUS_SQLITE_KINDS=blogtask`

Optional: `LINEAR_STATUS_MAP`, `LINEAR_FINALIZE_TRANSITION=done`.

The `discovery` and `approval-watch` schedules ship **disabled** — flip them to `enabled: true` in `.animus/workflows/custom.yaml` once the secrets above are set and the daemon has been restarted.

### State

Gitignored runtime state (`.animus/state/`):
- `discovery-cursor.json` — last *processed* Krisp transcript
- `approval-seen.json` — already-enqueued Linear subject IDs
- `transcripts/<id>.json` — staged transcripts

Tracked in repo (`content/manifest.json`): the canonical list of every post this generator produces — written by `register-post`, consumed for dedup + real internal-link slugs.

## Prerequisites

- **[Animus CLI](https://github.com/launchapp-dev/ao-cli)** — Install the Animus command-line tool
- **Node.js 18+** — Required for MCP servers (installed via npx)
- **Git** — For version control of generated content
- **API keys** — At least one search API (Exa, Tavily, or Brave). See [API Keys](#api-keys) below.

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/your-org/animus-blog-generator.git
cd animus-blog-generator
```

### 2. Set up API keys

```bash
cp .env.example .env
# Edit .env and add your API keys
```

### 3. Run the setup wizard

The setup wizard walks you through configuring the pipeline for your business. It asks about your niche, audience, brand voice, competitors, and content pillars, then generates `business-context.yaml`.

```bash
ao workflow run setup
```

Or if you prefer, create `business-context.yaml` manually — see [Business Context](#business-context) below.

### 4. Run your first blog post

```bash
ao workflow run blog-production
```

This kicks off the full pipeline. The first run typically takes 15-30 minutes as agents research, write, optimize, and generate assets. Output lands in `content/` and `assets/`.

### 5. Set up scheduled runs (optional)

The pipeline includes default schedules in `.animus/workflows/custom.yaml`:

- **Tuesday 8am** — Blog production
- **Wednesday 8am** — Refresh cycle
- **Thursday 8am** — Blog production
- **Daily 6am** — News monitoring

Start the Animus daemon to enable scheduled runs:

```bash
ao daemon start
```

Edit the `schedules` section in `custom.yaml` to adjust timing and pillar preferences.

## Configuration

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


The pipeline degrades gracefully — if you don't have Search Console configured, the topic-research phase relies more on web search. If you don't have Replicate, skip the image generation phase.

### Business Context

`business-context.yaml` is the central configuration file. All agents read it. It defines:

```yaml
business:
  name: "Your Business"          # Business or brand name
  niche: "your industry"         # e.g., real estate, SaaS, fitness
  location: "City, State"        # Where you're based
  scope: "local"                 # local | regional | national | global
  services: [...]                # Core offerings
  differentiator: "..."          # What makes you unique
  blog_url: "https://..."        # Where blog posts are published

audience:
  ideal_reader: "..."            # One-sentence reader description
  common_questions: [...]        # Questions they ask before buying
  objections: [...]              # What holds them back

competitors:
- name: "Competitor A"
  notes: "..."

voice:
  perspective: "first-person"    # first-person | first-person-plural | third-person
  author_name: "Your Name"
  author_bio: "..."
  tone: ["practical", "data-driven"]
  banned_words: ["delve", ...]   # AI cliches are banned by default

content:
  pillars: [...]                 # 3-7 topic categories
  target_word_count: 2000
  publish_frequency: "2x per week"
  social_platforms: ["Instagram", "Facebook", "LinkedIn"]
```

Run the setup wizard (`ao workflow run setup`) to generate this interactively, or create it manually.

### Publishing to Your CMS

The pipeline generates content as local markdown files and pushes to git. To publish directly to your CMS:

1. Create an MCP server that exposes publishing tools (see [Animus MCP docs](https://github.com/launchapp-dev/ao-cli))
2. Add it to the `mcp_servers` section in `.animus/workflows/custom.yaml`
3. Uncomment the `publish` phase in the workflow definitions
4. Add the MCP server to the `asset-generator` agent's `mcp_servers` list

## Project Structure

```
animus-blog-generator/
├── .animus/
│   ├── skills/                        # Agent skill files (markdown — source of truth)
│   │   ├── setup-wizard.md            # Interactive business setup
│   │   ├── content-strategy.md        # Topic planning best practices
│   │   ├── content-production.md      # Writing pipeline guide
│   │   ├── content-humanizer.md       # De-AI-ify content
│   │   ├── ai-seo.md                 # AI search optimization
│   │   ├── seo-audit.md              # SEO audit checklist
│   │   ├── schema-markup.md          # Structured data guide
│   │   └── social-content.md         # Social media content guide
│   └── workflows/
│       ├── custom.yaml                # Main pipeline definition
│       └── standard-workflow.yaml     # Animus default workflow
├── content/                           # Generated blog posts (.md)
├── assets/                            # Generated images (.webp)
├── business-context.yaml              # Your business config (generated by setup wizard)
├── .env.example                       # API key template
├── .env                               # Your API keys (gitignored)
├── .mcp.json                          # MCP server config for Claude Code
├── CLAUDE.md                          # Project instructions for Claude
└── README.md
```

## Skills

Skills are markdown files that encode domain expertise. Agents reference them in their system prompts. They come from the [Animus marketing skills library](https://github.com/launchapp-dev/ao-cli) and can be customized.

| Skill | What it teaches the agent |
|-------|--------------------------|
| **content-strategy** | Topic discovery, pillar planning, keyword gap analysis, competitor content mapping |
| **content-production** | End-to-end writing: research briefs, drafting, SEO optimization, quality gates |
| **content-humanizer** | Detecting and removing AI writing patterns, injecting brand voice, fixing rhythm |
| **ai-seo** | Optimizing for AI search citations (ChatGPT, Perplexity, Google AI Overviews) |
| **seo-audit** | Technical and on-page SEO auditing with actionable fix recommendations |
| **schema-markup** | JSON-LD structured data for rich results and AI readability |
| **social-content** | Platform-specific social media content creation and strategy |
| **setup-wizard** | Interactive business context questionnaire and config generation |

## Customization

### Adjust the pipeline

Edit `.animus/workflows/custom.yaml` to:

- **Change agent models** — Swap `claude-opus-4-6` for `claude-sonnet-4-6` to reduce cost, or vice versa for higher quality
- **Add/remove MCP servers** — Enable only the search APIs you have keys for
- **Modify phase directives** — Change what each agent does in its phase
- **Adjust schedules** — Change publishing frequency and timing
- **Add new phases** — Insert custom steps (e.g., email newsletter generation, translation)

After editing, always run:

```bash
ao workflow config compile
```

### Customize agent behavior

Edit the skill files in `.animus/skills/` to change how agents approach their work. These are markdown files with best practices — agents read and follow them.

### Override voice and content rules

Edit `business-context.yaml` to change your brand voice, content pillars, or publishing preferences at any time. Changes take effect on the next workflow run.

## License

MIT
