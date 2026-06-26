# Animus Blog Generator

An automated blog generation pipeline powered by [Animus](https://github.com/launchapp-dev/animus-cli). It uses multiple AI agents working in sequence to research topics, write SEO-optimized posts, generate images, and create social media excerpts — all on autopilot.

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

# Workflows + schedules live in per-workflow files (workflow-*.yaml), e.g.:
workflows:
  - id: blog-production
    phases: [topic-research, research-collection, content-writing,
             commit-draft, seo-review, asset-generation, social-excerpts,
             register-post, push-branch, publish-post]

schedules:
  - { id: blog-primary, cron: "0 8 * * 2", workflow_ref: blog-production,
      enabled: false }   # all schedules ship disabled
```

This preview is abridged. The real config is **split**: `custom.yaml` holds shared base config, `mcp_servers`, `subjects`, agents, and shared phases; each workflow (and its schedule) lives in its own [`.animus/workflows/workflow-*.yaml`](.animus/workflows/).

</details>

## How It Works

The pipeline runs as a series of **workflows**, each made up of **phases** executed by specialized **agents**. Each agent has a specific role, its own set of tools (MCP servers), and access to your business context.

### Blog Production Workflow

```
topic-research ─→ research-collection ─→ content-writing ─→ commit-draft
                                                                │
       seo-review ─→ asset-generation ─→ social-excerpts ─→ register-post
                                                                │
                                       publish-post ←──────── push-branch
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
| **register-post** | register-post-runner (agent) | Runs `scripts/register-post.sh` to append the post to `content/manifest.json` (dedup index + internal-link slugs) |
| **push-branch** | (command) | Pushes the branch to origin |
| **publish-post** | (command) | *Optional.* Upserts the finished post into a database (Supabase/PostgREST by default). Skips unless configured; git stays the source of truth. See [publish targets](docs/integrations/publish-targets/README.md) |

### Other Workflows

| Workflow | Purpose | Schedule |
|----------|---------|----------|
| **refresh-cycle** | Analyzes Search Console performance, identifies the most impactful post to refresh, updates statistics and data, re-optimizes SEO | Weekly |
| **image-refresh** | Regenerates featured images for existing posts | On demand |
| **news-monitor** | Scans for breaking industry news and auto-enqueues urgent blog topics | Daily |

### Agent Architecture

Each agent is a Claude instance with a focused role. These are the **core content-pipeline** agents; the discovery flow adds more (transcript-collector, idea-strategist, approval-watcher, linear-coordinator, register-post-runner) — the full agent→MCP map is in [MCP-TOOLS.md](MCP-TOOLS.md).

| Agent | Model | Role | Tools |
|-------|-------|------|-------|
| content-strategist | Sonnet 4.6 | Topic selection and content planning | Animus, Exa, Tavily, Brave, Firecrawl, Search Console, Content Library |
| content-researcher | Sonnet 4.6 | Data collection and source gathering | Firecrawl, Exa, Tavily, Brave, Google Maps, Content Library |
| content-writer | Opus 4.6 | Long-form content writing | Content Library |
| seo-optimizer | Sonnet 4.6 | SEO auditing and fixing | Search Console, Firecrawl, Content Library |
| asset-generator | Sonnet 4.6 | Image generation and social content | Replicate |
| performance-analyst | Sonnet 4.6 | Content performance analysis | Animus, Search Console, Exa, Perplexity |
| content-refresher | Opus 4.6 | Updating existing content | Firecrawl, Content Library |

All **content** agents read `business-context.yaml` for your business details, brand voice, and content strategy (the data-plumbing agents — transcript-collector, approval-watcher, linear-coordinator, register-post-runner — do not). The content-writing agents also follow skill files in `.animus/skills/` that encode best practices for content production, SEO, humanization, and social media.

## Discovery Flow (transcript-driven)

In addition to the cron-driven `blog-production` pipeline, this generator supports a transcript-driven discovery loop with a human-review gate in Linear (integrated as an Animus subject backend).

**Daily 7am — `idea-discovery`.** Polls the configured transcript provider (Krisp or Granola) for new transcripts. The strategist proposes 3–5 angles per transcript, each pre-validated with Search Console + competitor scan + spot-scraped citable sources. Surviving angles become Linear issues (Animus subjects) at status `ready`.

**Every 15 min — `approval-watch`.** Polls Linear-backed subjects for `status == in-progress` (the human-approval signal) and dispatches each newly-approved subject to `blog-from-ticket` via the queue (carrying `linear_subject_id`). Cancelled/Done/Blocked are filtered out. The gate is a deterministic script (`scripts/approval-watch.sh`), not an LLM — dedup is exact and a no-op poll costs no tokens.

**Per approved ticket — `blog-from-ticket`.** A variant of blog-production using the Linear ticket as the topic brief. `ticket-acknowledge` and `ticket-to-brief` both re-check the subject's status; if the human cancelled after approval, the run aborts cleanly. `register-post` runs before `push-branch` so the manifest commit ships with the push. The last phase posts a completion comment; status transition is opt-in via `LINEAR_FINALIZE_TRANSITION=done`.

**Authoritative-lifecycle invariant.** Linear is the single source of truth for lifecycle. The local SQLite `blogtask` wrapper — created by `scripts/approval-watch.sh` purely as a dispatch log — is subordinate and reference-only: no phase reads its status, and lifecycle is written back only to Linear (by `linear-finalize`).

### Transcript provider (Krisp or Granola)

Transcripts flow through one provider-neutral MCP alias, `transcript-source`, in `.animus/workflows/custom.yaml`. Exactly one provider is active at a time, declared by `TRANSCRIPT_PROVIDER` and matched by what you wire under that alias. Switching providers is config-only — the collector agent normalizes either provider's tools into the staged transcript contract, and transcript ids are namespaced (`<provider>:<raw_id>`) so they never collide across a switch.

Both **Krisp** and **Granola** ship official remote MCP servers (Streamable HTTP, OAuth — no static API key); Granola also has community local-cache servers for fully non-interactive macOS use. Per-provider endpoints, tool tables, auth/daemon trade-offs, and copy-paste wiring snippets are in **[`docs/integrations/transcript-providers/`](docs/integrations/transcript-providers/README.md)**. Until you wire one, `transcript-source` is a no-op stub and the discovery schedule stays disabled.

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

- `TRANSCRIPT_PROVIDER` (`krisp` or `granola`) — the official MCPs authenticate via OAuth (`animus mcp auth transcript-source`); `KRISP_API_KEY` / `GRANOLA_API_KEY` are only for non-MCP or community paths (see the [transcript-provider docs](docs/integrations/transcript-providers/README.md))
- `LINEAR_API_TOKEN`, `LINEAR_TEAM_ID`, `LINEAR_DISCOVERY_PROJECT_ID`
- `CONTENT_LIBRARY_URL`, `CONTENT_LIBRARY_TOKEN`
- `ANIMUS_SQLITE_KINDS=blogtask`

Optional: `LINEAR_STATUS_MAP`, `LINEAR_FINALIZE_TRANSITION=done`. To publish finished posts to a database, also set `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` (+ optional `PUBLISH_TABLE`) — see [publish targets](docs/integrations/publish-targets/README.md); unset = publishing skipped.

The `discovery` and `approval-watch` schedules ship **disabled** — flip them to `enabled: true` in their files (`.animus/workflows/workflow-idea-discovery.yaml` and `workflow-approval-watch.yaml`) once the secrets above are set and the daemon has been restarted.

### State

Gitignored runtime state (`.animus/state/`):
- `discovery-cursor.json` — last *processed* transcript (+ active `provider`)
- `approval-seen.json` — already-enqueued Linear subject IDs
- `transcripts/<id>.json` — staged transcripts

Tracked in repo (`content/manifest.json`): the canonical list of every post this generator produces — written by `register-post`, consumed for dedup + real internal-link slugs.

## Prerequisites

- **[Animus CLI](https://github.com/launchapp-dev/animus-cli)** — Install the Animus command-line tool
- **Node.js 18+** — Required for MCP servers (installed via npx)
- **Git** — For version control of generated content
- **API keys** — At least one search API (Exa, Tavily, or Brave). See [API Keys](#api-keys) below.

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/launchapp-dev/animus-blog-generator.git
cd animus-blog-generator
```

### 2. Install Animus plugins (one-time)

The daemon needs provider, queue, and workflow-runner plugins. The discovery flow additionally needs the Linear subject backend.

```bash
animus plugin install-defaults                              # providers + queue + runner
animus plugin install launchapp-dev/animus-subject-linear   # only for the discovery flow
animus daemon preflight                                     # verifies required roles are satisfied
```

### 3. Configure secrets

```bash
cp .env.example .env
# Edit .env — at minimum one search key (EXA / TAVILY / BRAVE).
# See "Required .env values" above for the full set.
```

### 4. Create your business context

The pipeline reads `business-context.yaml` (niche, audience, brand voice, pillars) on every run. Create it manually — see [Business Context](#business-context) below — or ask Claude Code to run the **setup-wizard** skill, which generates it interactively. (There is no `workflow run setup`; the wizard is a skill, not a workflow.)

### 5. Start the daemon

The daemon does **not** auto-load `.env`, so source it into the daemon's shell first; `ANIMUS_SQLITE_KINDS=blogtask` must be present too (see [Daemon environment](#daemon-environment-env-is-not-auto-loaded)).

```bash
set -a; source .env; set +a
animus daemon start --autonomous
```

### 6. Run your first blog post

```bash
animus workflow run blog-production
```

The first run typically takes 15–30 minutes as agents research, write, optimize, and generate assets. Output lands in `content/` and `assets/` and is committed/pushed to a branch.

### 7. Enable scheduled runs (optional)

**All schedules ship disabled.** To automate runs, flip `enabled: true` on the schedule in the relevant `.animus/workflows/*.yaml`, then persist the config (the running daemon also hot-reloads YAML edits):

```bash
animus workflow config compile
```

Default (currently disabled) schedules:

- **`blog-primary`** — Tue 8am · **`blog-secondary`** — Thu 8am → `blog-production`
- **`refresh`** — Wed 8am → `refresh-cycle`
- **`news`** — daily 6am → `news-monitor`
- **`discovery`** — daily 7am · **`approval-watch`** — every 15 min → discovery flow (also needs Linear + transcript secrets)

## Configuration

# MCP Tools

The blog generator ships with **9 core content-pipeline MCP servers** that give agents access to search, scraping, analytics, image generation, and self-orchestration. The discovery flow adds two more bring-your-own servers — `transcript-source` and `content-library` — covered under [Discovery Flow](#discovery-flow-transcript-driven).

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
| **animus** | `animus mcp serve` | Animus self-management — task creation, queue management, lets agents schedule follow-up work |

## Which Agents Use What

Core content pipeline (the discovery-flow agents — transcript-collector, idea-strategist, approval-watcher — are covered under [Discovery Flow](#discovery-flow-transcript-driven); the full map is in [MCP-TOOLS.md](MCP-TOOLS.md)):

```
Strategist          → animus, exa, tavily, brave, firecrawl, search-console, content-library
Researcher          → firecrawl, exa, tavily, brave, google-maps, content-library
Writer              → content-library
SEO Optimizer       → search-console, firecrawl, content-library
Asset Generator     → replicate
Performance Analyst → animus, search-console, exa, perplexity
Content Refresher   → firecrawl, content-library
```

## Publishing to a database

The pipeline writes posts as markdown to git (the source of truth). To also upsert each finished post into a database, the optional **`publish-post`** phase ships built in (Supabase/PostgREST by default, swappable). Set `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` to enable it — see [publish targets](docs/integrations/publish-targets/README.md). It skips cleanly when unconfigured.


Agents degrade gracefully on missing *optional* tools — without Search Console, `topic-research` leans more on web search. Note that `asset-generation` (Replicate) is a **required** phase in `blog-production`: if you don't have a Replicate token, remove that phase from the workflow rather than expecting it to be skipped automatically.

### Business Context

`business-context.yaml` is the central configuration file. Every content agent reads it. It defines:

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

Create it manually, or ask Claude Code to run the **setup-wizard** skill, which generates it interactively. (`setup-wizard` is a skill, not a `workflow run setup` target.)

### Publishing to a database or CMS

The pipeline writes posts as markdown to git (the source of truth) and, optionally, upserts each finished post into a database via the built-in **`publish-post`** phase (Supabase/PostgREST by default). To enable or retarget it, see [publish targets](docs/integrations/publish-targets/README.md). To push to a CMS instead, point `scripts/publish-post.sh`'s two seams (`build_payload()` + `publish()`) at your CMS's API.

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
│   └── workflows/                     # Config is split across these files
│       ├── custom.yaml                # Shared base config, mcp_servers, subjects, agents, shared phases
│       ├── workflow-blog-production.yaml
│       ├── workflow-blog-from-ticket.yaml
│       ├── workflow-idea-discovery.yaml
│       ├── workflow-news-monitor.yaml
│       ├── workflow-refresh-cycle.yaml
│       ├── workflow-image-refresh.yaml
│       └── workflow-approval-watch.yaml
├── scripts/                           # approval-watch.sh, register-post.sh, publish-post.sh (+ bats tests)
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

Skills are markdown files that encode domain expertise. Agents reference them in their system prompts. They come from the [Animus marketing skills library](https://github.com/launchapp-dev/animus-cli) and can be customized.

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
animus workflow config compile
```

### Customize agent behavior

Edit the skill files in `.animus/skills/` to change how agents approach their work. These are markdown files with best practices — agents read and follow them.

### Override voice and content rules

Edit `business-context.yaml` to change your brand voice, content pillars, or publishing preferences at any time. Changes take effect on the next workflow run.

## License

MIT
