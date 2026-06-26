# Publish Targets (database / CMS)

After a post is written, optimized, asset-generated, registered in
`content/manifest.json`, and pushed to git, the **`publish-post`** command phase
upserts the finished post into a database. **Git remains the source of truth**;
the database is a downstream publish target.

This is **opt-in and swappable**, in the same spirit as the content-library
brain and the transcript-source provider.

## Default implementation: Supabase / PostgREST

`scripts/publish-post.sh` upserts into a Supabase table over the PostgREST REST
API. It is a deterministic command (no LLM): it discovers the slug from
`content/manifest.json` — the entry whose `branch` matches the current run's git
branch (the post `register-post` just recorded), falling back to the last entry
— then reads the post's frontmatter + body, builds a JSON payload, and POSTs
with `Prefer: resolution=merge-duplicates` so re-runs upsert instead of
duplicate. Pass an explicit slug argument to override discovery.

> **Known limitation (slug inference).** Discovery is heuristic, not an explicit
> handoff. If a single branch accumulates multiple registered posts — e.g. a
> publish fails, a second post is registered on the same branch, then the
> original publish is retried — the branch lookup returns the *latest* matching
> entry, which may not be the post the original run intended. Per-run
> worktrees/branches make this unlikely in practice; for guaranteed correctness,
> invoke the script with the slug as an explicit argument.

### Enable

```bash
# .env  (sourced into the daemon's environment — the daemon does NOT auto-load .env)
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service-role key>   # server-side only, never client-exposed
PUBLISH_TABLE=posts                            # optional, default "posts"
```

Leave **both** unset and the phase **skips cleanly**
(`{"status":"skip","reason":"publish_not_configured"}`, exit 0) — the pipeline
still completes; nothing is published. Setting **exactly one** of the two is
treated as a hard config error (exit 2) so a typo can't silently no-op the
publish (which, in `blog-from-ticket`, would otherwise let the ticket be
finalized with nothing in the DB).

### Required table shape

The request upserts with `Prefer: resolution=merge-duplicates` **and**
`?on_conflict=slug`, so `slug` may be either the **primary key** or just a
column with a **UNIQUE constraint** — both work. (Without `on_conflict`,
PostgREST resolves conflicts on the primary key only.) Override the conflict
target with `PUBLISH_CONFLICT_COL` if your key column differs.

Default columns the script writes:

| Column | Source |
|---|---|
| `slug` (unique) | manifest entry / filename |
| `title` | frontmatter `title` |
| `body_markdown` | post body (after frontmatter) |
| `meta_description` | frontmatter `meta_description` → `excerpt` |
| `pillar` | frontmatter `content_pillar` |
| `target_keyword` | frontmatter `target_keyword` |
| `tags` | frontmatter `keywords[]` |
| `word_count` | frontmatter `word_count` |
| `featured_image_path` | frontmatter `featuredImage` |
| `source_ref` | `LINEAR_SUBJECT_ID` / `SOURCE_TRANSCRIPT_ID` env, else manifest entry |
| `status` | constant `"published"` |
| `published_at` | frontmatter `date` |

Example DDL:

```sql
create table posts (
  slug                text primary key,
  title               text not null,
  body_markdown       text,
  meta_description    text,
  pillar              text,
  target_keyword      text,
  tags                jsonb,
  word_count          int,
  featured_image_path text,
  source_ref          text,
  status              text,
  published_at        date
);
```

## Scope of the default implementation

The default targets **Supabase / PostgREST against the public schema only**. It
does **not** support raw Postgres (`DATABASE_URL` / `psql`), PostgREST schema
selection (`Content-Profile` / non-public schemas), or URL-encoding of
`PUBLISH_TABLE` / `PUBLISH_CONFLICT_COL` (treat those as plain SQL identifiers).
Any of those is a script edit — see the seams below.

## Swapping the target

The script has exactly **two seams**:

1. `build_payload()` — the field → column mapping (a single `jq -n` object).
2. `publish()` — the HTTP call (URL, headers, upsert semantics).

To target a different backend (a headless CMS, a custom REST endpoint, raw
Postgres via `psql`, etc.), edit those two functions — the phase wiring, slug
discovery, frontmatter parsing, and opt-in gate stay as-is. For a fundamentally
different system you can also replace the whole script; the `publish-post` phase
just runs `bash scripts/publish-post.sh`.

## Where it runs

`publish-post` is the final phase of `blog-production`, and runs after
`push-branch` and before `linear-finalize` in `blog-from-ticket` (so the post is
in the DB before the Linear ticket is marked complete). Exit codes: `0` ok/skip,
`1` read or HTTP failure (fails the phase loudly), `2` bad input.

Tests: `scripts/test/publish-post.bats` (13 cases, curl stubbed).
