# Agent Prompt Review — `.animus/workflows/custom.yaml`

**Date:** 2026-06-22
**Scope:** The `system_prompt` of every agent in the `agents:` block (12 agents).
Phase `directive:` text is referenced only where it interacts with an agent
prompt. Line numbers cite `.animus/workflows/custom.yaml`.

## Context / anchor

This is a single-business SEO blog pipeline: ~2 scheduled `blog-production`
runs per week plus transcript-driven discovery, all behind a manual Linear
approval gate, operated by one person. It is pre-production (secrets unset,
`discovery`/`approval-watch` schedules disabled, `krisp`/`content-library` MCP
servers stubbed).

At this scale the prompts are mostly in good shape. The review below flags only
issues that would **produce worse posts or trigger wrong behavior** — not
stylistic prompt polish. Generic prompt-engineering additions (in-prompt JSON
schemas, few-shot blocks, blanket error-handling sections) are deliberately
**not** recommended: the per-phase `output_contract`s and the
`.animus/skills/*.md` files already own that, and adding them would dilute the
real findings.

## Verdict per agent

| Agent | Line | Verdict |
|---|---|---|
| content-strategist | 95 | Change — task-creation bias leaks into 2 of its 3 phases |
| content-researcher | 112 | **Change — no `system_prompt` at all** |
| content-writer | 121 | Minor — readability metric conflicts with seo-optimizer |
| seo-optimizer | 152 | Minor — readability metric conflicts with content-writer |
| asset-generator | 179 | Change — `system_prompt` covers social only, but agent also generates images |
| performance-analyst | 193 | OK as written |
| content-refresher | 204 | Minor — "same rules as content-writer" is a drift risk |
| transcript-collector | 219 | OK as written |
| idea-strategist | 228 | OK as written |
| approval-watcher | 256 | OK as written |
| linear-coordinator | 274 | OK as written |
| register-post-runner | 292 | OK as written |

The seven "OK" agents are not detailed below — their prompts are appropriately
scoped for what they do, and the heavy logic correctly lives in their
directives.

---

## Findings (in priority order)

### 1. `content-researcher` has no `system_prompt` (HIGH)

**Where:** lines 112–120. The agent declares five MCP servers and *nothing
else* — no persona, no skill reference, no `business-context.yaml` grounding,
no source-quality rules.

**Why it matters:** This agent produces the `research_package` that the writer
turns into the whole post (phase `research-collection`, line 446). Every other
content agent reads `business-context.yaml` and carries citation rules; the
researcher — the one whose entire job is sourcing — does not. The only guidance
is one line in the directive ("Always cite the source for any statistic", line
459). With no niche/audience grounding, searches drift generic and the writer
inherits weak material. This is the single highest-leverage prompt gap in the
file.

**Suggested fix** — give it a sibling-shaped prompt (mirrors the writer/
refresher, invents no new scope):

```yaml
  content-researcher:
    model: claude-sonnet-4-6
    tool: claude
    mcp_servers:
    - firecrawl
    - exa
    - tavily
    - brave
    - google-maps
    system_prompt: |
      CONTEXT: Read business-context.yaml — niche, audience, market area,
      competitors. Ground every search in that context.

      You gather source material for the content-writer; you do not write prose.

      SOURCING RULES:
      - Prefer primary, recent, authoritative sources (industry/market reports,
        government or census data, named studies). Capture the exact source URL
        and publication date for each.
      - Every statistic must carry an attributable source — no orphan numbers.
      - Include local/market context when the niche is geo-relevant.
      - Flag claims you could not verify instead of passing them through.
```

### 2. `asset-generator` `system_prompt` only covers social, not images (MEDIUM)

**Where:** lines 179–192. The `system_prompt` is entirely `SOCIAL CONTENT
RULES` (Instagram/Facebook/LinkedIn). But this agent runs **three** phases:
`asset-generation` (line 559, image), `social-excerpts` (line 583, social), and
`image-regen` (line 680, image).

**Why it matters:** For the two image phases, the entire system prompt is
irrelevant priming, and there is **no** visual/image-quality guidance at the
agent level — every image instruction is duplicated inline across the
`asset-generation` and `image-regen` directives (style, "no text/watermarks",
16:9, the Nano Banana Pro call). So the image runs get mis-targeted persona
priming, and the shared image rules live in two places that can drift apart.

**Suggested fix:** add an image/visual block to the `system_prompt` so both
asset types are covered, and thin the duplicated style lines out of the two
image directives:

```yaml
    system_prompt: |
      SKILLS: Read and follow .animus/skills/social-content.md
      CONTEXT: Read business-context.yaml for brand voice, social guidelines,
      and visual aesthetic.

      You produce two asset types depending on the phase: a featured IMAGE, or
      SOCIAL excerpts.

      IMAGE RULES (asset-generation, image-regen):
      - Style: professional photography relevant to the business niche, natural
        lighting. No text overlays, watermarks, or AI artifacts. 16:9.
      - Model: google/nano-banana-pro. Save to assets/<slug>.webp.

      SOCIAL CONTENT RULES (social-excerpts):
      - Instagram: short, emoji-friendly, 5-10 hashtags, hook-first
      - Facebook: conversational, end with a question to drive comments
      - LinkedIn: professional, data-forward, insight-led
      - Adapt per platform — never copy-paste across channels
```

(Splitting into two agents — `image-generator` + `social-writer` — is the
cleaner long-term shape, but that's a structural change beyond a prompt edit and
not worth it at this volume.)

### 3. `content-strategist` task-creation bias leaks into the wrong phases (MEDIUM)

**Where:** line 111 — `Use Animus tools (animus_task_create,
animus_queue_enqueue) for urgent news topics.` This agent runs three phases:
`topic-research` (411), `news-scan` (715), and `ticket-to-brief` (830).

**Why it matters:** Creating tasks/enqueuing is correct only for `news-scan`.
In `ticket-to-brief` (line 830) the agent's job is to *convert an existing
approved Linear subject into a brief* — `mutates_state: false` (line 865) — yet
the system prompt actively tells it to create subjects for "urgent" topics.
That's a standing instruction pulling against the directive's intent. Low
probability of firing, but it's a real wrong-behavior nudge in a no-write phase.

**Suggested fix:** scope the line to where it belongs:

```
Only in the news-scan / discovery phases: create tasks via animus_task_create
and enqueue via animus_queue_enqueue for genuinely time-sensitive topics.
When converting an existing ticket to a brief, do NOT create new subjects.
```

### 4. Readability metric conflicts between writer and seo-optimizer (LOW–MEDIUM)

**Where:** content-writer says `Target readability >= 70` (line 137, Flesch
Reading Ease); seo-optimizer says `Readability grade 8-10` (line 172 and the
seo-review checklist, line 531, grade level).

**Why it matters:** These pull in opposite directions. Flesch ≥ 70 is "fairly
easy" (~grade 6–7); grade 8–10 is "fairly difficult." The seo-review phase
edits the writer's output, so it can "fix" prose to be *harder* than the writer
was told to make it — the two phases fight at the margin and the result is
inconsistent run-to-run.

**Suggested fix:** pick one scale and state it identically in both agents.
Either set the writer to "Readability grade 8–10" to match seo-optimizer, or
state both numbers in both prompts ("Flesch Reading Ease ~60–70, US grade
8–10"). Aligning on the grade-level framing already used by the SEO checklist is
the smaller change.

### 5. `content-refresher` "same rules as the content-writer" is a drift risk (LOW)

**Where:** line 214 — `Same voice and content rules as the content-writer.`

**Why it matters:** Prose cross-reference, not a shared source — if the writer's
rules change, the refresher silently diverges. It's partly mitigated because
both agents load the same three skills (content-production, ai-seo,
content-humanizer), which are the real shared spec.

**Suggested fix (optional):** drop the cross-reference and lean on the shared
skills explicitly — e.g. "Voice and content rules are defined in the skills
above; apply them identically to the content-writer." Borderline; only worth it
if you touch this agent for another reason.

---

## Adjacent (outside prompt scope, but worth a look)

- **Model IDs.** `content-writer` and `content-refresher` are pinned to
  `claude-opus-4-6` (lines 122, 205). The current Opus generation is 4.8; if
  `claude-opus-4-6` is not a valid provider ID, both writing phases fail at
  dispatch regardless of prompt quality. Verify against the installed
  `animus-provider-claude` plugin before going live. Not a prompt issue — noted
  because it would block the same phases this review covers.

## What was deliberately left out

Per right-sized-feedback, these tempting-but-wrong-scale additions were dropped:
in-prompt output JSON schemas (covered by `output_contract`), few-shot examples
(unjustified at this volume), blanket error/skip-handling sections (directives
already specify skip/fail reasons where they matter), and persona/tone polish
for the haiku utility agents (terse is correct for them).
