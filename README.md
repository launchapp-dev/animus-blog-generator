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
      SKILLS: Read and follow .ao/skills/content-strategy.md
      CONTEXT: Read business-context.yaml for all client details.

  content-writer:
    model: claude-opus-4-6
    mcp_servers: []
    system_prompt: |
      SKILLS: Read and follow .ao/skills/content-production.md,
      .ao/skills/ai-seo.md, .ao/skills/content-humanizer.md
      CONTEXT: Read business-context.yaml for voice guidelines.

  seo-optimizer:
    model: claude-sonnet-4-6
    mcp_servers: [search-console, firecrawl]
    system_prompt: |
      SKILLS: Read and follow .ao/skills/seo-audit.md,
      .ao/skills/schema-markup.md, .ao/skills/ai-seo.md

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

See the full workflow definition in [`.ao/workflows/custom.yaml`](.ao/workflows/custom.yaml).

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

All agents read `business-context.yaml` for your business details, brand voice, and content strategy. The content-writing agents also follow skill files in `.ao/skills/` that encode best practices for content production, SEO, humanization, and social media.

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

The pipeline includes default schedules in `.ao/workflows/custom.yaml`:

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

### API Keys

| Key | Service | Required | Used for |
|-----|---------|----------|----------|
| `EXA_API_KEY` | [Exa](https://exa.ai) | At least one search API | Web search |
| `TAVILY_API_KEY` | [Tavily](https://tavily.com) | At least one search API | Research search |
| `BRAVE_API_KEY` | [Brave Search](https://brave.com/search/api/) | At least one search API | Web search |
| `FIRECRAWL_API_KEY` | [Firecrawl](https://firecrawl.dev) | Recommended | Web scraping for research data |
| `GOOGLE_MAPS_API_KEY` | Google Maps | Optional | Location data for local businesses |
| `GSC_CLIENT_EMAIL` | Google Search Console | Optional | Keyword and performance data |
| `GSC_PRIVATE_KEY` | Google Search Console | Optional | Keyword and performance data |
| `REPLICATE_API_TOKEN` | [Replicate](https://replicate.com) | Optional | Featured image generation |
| `PERPLEXITY_API_KEY` | [Perplexity](https://perplexity.ai) | Optional | AI citation tracking |

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
2. Add it to the `mcp_servers` section in `.ao/workflows/custom.yaml`
3. Uncomment the `publish` phase in the workflow definitions
4. Add the MCP server to the `asset-generator` agent's `mcp_servers` list

## Project Structure

```
animus-blog-generator/
├── .ao/
│   ├── config.json                    # Animus project config
│   ├── config/skill_definitions/      # Skill metadata (YAML)
│   ├── skills/                        # Agent skill files (markdown)
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

Edit `.ao/workflows/custom.yaml` to:

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

Edit the skill files in `.ao/skills/` to change how agents approach their work. These are markdown files with best practices — agents read and follow them.

### Override voice and content rules

Edit `business-context.yaml` to change your brand voice, content pillars, or publishing preferences at any time. Changes take effect on the next workflow run.

## License

MIT
