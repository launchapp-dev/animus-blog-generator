#!/usr/bin/env bash
# publish-post.sh — deterministic upsert of a finished post into a
# Supabase / PostgREST table. Runs as a command phase AFTER push-branch, so git
# remains the source of truth and the database is a downstream publish target.
#
# Usage: ./scripts/publish-post.sh <slug>
#
# Env:
#   SUPABASE_URL                 e.g. https://<proj>.supabase.co   (required to publish)
#   SUPABASE_SERVICE_ROLE_KEY    PostgREST service key             (required to publish)
#   PUBLISH_TABLE                target table (default "posts")
#   LINEAR_SUBJECT_ID            optional provenance → source_ref
#   SOURCE_TRANSCRIPT_ID         optional provenance → source_ref (fallback)
#
# If SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are unset, the phase SKIPS
# (exit 0) — publishing ships off-by-default and is opt-in, like content-library.
#
# Idempotent: upserts keyed on `slug` via `Prefer: resolution=merge-duplicates`,
# which requires a UNIQUE constraint on the table's `slug` column.
#
# Exit codes: 0 ok / skip; 1 hard error (read or HTTP failure); 2 bad input.
#
# SWAPPABLE: this targets Supabase/PostgREST with the default schema below. To
# adopt a different backend or table shape, edit build_payload() (the field→
# column mapping) and the curl call in publish() — they are the only two seams.

set -euo pipefail

MANIFEST="content/manifest.json"

# Slug resolution (pure command phase — no arg threading needed):
#   1. explicit arg (manual / tests)
#   2. the manifest entry whose `branch` is this run's git branch — register-post
#      records `branch` per entry and runs normally get their own branch.
#   3. fallback: the last manifest entry.
# KNOWN LIMITATION: this is inference, not an explicit handoff. If a branch ends
# up with multiple registered posts (e.g. a failed publish, a second post
# registered on the same branch, then a retry of the old publish), the branch
# lookup returns the latest match — which may not be the post the original run
# meant to publish. Per-run worktrees/branches make this unlikely; for absolute
# certainty, pass the slug explicitly as the argument.
SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$branch" ] && [ "$branch" != "HEAD" ] && [ -f "$MANIFEST" ]; then
    SLUG="$(jq -r --arg b "$branch" 'last(.posts[] | select(.branch==$b)).slug // empty' "$MANIFEST" 2>/dev/null || true)"
  fi
fi
if [ -z "$SLUG" ] && [ -f "$MANIFEST" ]; then
  SLUG="$(jq -r '.posts[-1].slug // empty' "$MANIFEST" 2>/dev/null || true)"
fi
[ -n "$SLUG" ] || { echo "publish-post: slug required (pass as arg or register it in $MANIFEST first)" >&2; exit 2; }

PUBLISH_TABLE="${PUBLISH_TABLE:-posts}"
POST_FILE="content/${SLUG}.md"

# --- opt-in gate ---
# Both unset → publishing is intentionally disabled → skip cleanly.
# Exactly one set → almost certainly a typo / broken daemon env → fail loud, so a
# misconfigured target can't silently no-op (and, in blog-from-ticket, let the
# ticket be finalized with nothing in the DB).
if [ -z "${SUPABASE_URL:-}" ] && [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  echo '{"status":"skip","reason":"publish_not_configured"}'
  exit 0
fi
if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  echo "publish-post: partial config — set BOTH SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY, or neither" >&2
  exit 2
fi

[ -f "$POST_FILE" ] || { echo "publish-post: post not found: $POST_FILE" >&2; exit 1; }

# --- parse frontmatter (between the first two '---') and body (after them) ---
FM="$(awk '/^---$/{c++; next} c==1{print}' "$POST_FILE")"
[ -n "$FM" ] || { echo "publish-post: no frontmatter in $POST_FILE" >&2; exit 1; }
BODY="$(awk '/^---$/{c++; next} c>=2{print}' "$POST_FILE")"

title="$(echo "$FM" | yq -r '.title // ""')"
[ -n "$title" ] || { echo "publish-post: frontmatter missing title" >&2; exit 1; }
meta_description="$(echo "$FM" | yq -r '.meta_description // .excerpt // ""')"
pillar="$(echo "$FM" | yq -r '.content_pillar // ""')"
target_keyword="$(echo "$FM" | yq -r '.target_keyword // ""')"
word_count="$(echo "$FM" | yq -r '.word_count // 0')"
published_at="$(echo "$FM" | yq -r '.date // ""')"
featured_image="$(echo "$FM" | yq -r '.featuredImage // .featured_image // ""')"
tags_json="$(echo "$FM" | yq -o=json -I=0 '.keywords // []')"
source_ref="${LINEAR_SUBJECT_ID:-${SOURCE_TRANSCRIPT_ID:-}}"
# fall back to provenance recorded in the manifest entry for this slug
if [ -z "$source_ref" ] && [ -f "$MANIFEST" ]; then
  source_ref="$(jq -r --arg s "$SLUG" \
    '.posts[] | select(.slug==$s) | (.linear_subject_id // "") as $l | (.source_transcript_id // "") as $t | (if $l != "" then $l elif $t != "" then $t else "" end)' \
    "$MANIFEST" 2>/dev/null | head -1 || true)"
fi

# --- field → column mapping (EDIT HERE to match your table) ---
build_payload() {
  jq -n \
    --arg slug "$SLUG" \
    --arg title "$title" \
    --arg body_markdown "$BODY" \
    --arg meta_description "$meta_description" \
    --arg pillar "$pillar" \
    --arg target_keyword "$target_keyword" \
    --argjson word_count "${word_count:-0}" \
    --arg featured_image_path "$featured_image" \
    --arg published_at "$published_at" \
    --arg source_ref "$source_ref" \
    --argjson tags "$tags_json" \
    '{
      slug: $slug,
      title: $title,
      body_markdown: $body_markdown,
      meta_description: $meta_description,
      pillar: $pillar,
      target_keyword: $target_keyword,
      tags: $tags,
      word_count: $word_count,
      featured_image_path: $featured_image_path,
      source_ref: $source_ref,
      status: "published",
      published_at: $published_at
    }'
}

# --- POST (upsert) to PostgREST ---
publish() {
  local payload="$1" code
  # on_conflict makes merge-duplicates upsert resolve on `slug`. Without it,
  # PostgREST resolves on the PRIMARY KEY, so a `slug text unique` (non-PK)
  # column would duplicate or fail on rerun. Overridable for other schemas.
  code="$(printf '%s' "$payload" | curl -sS -X POST \
    "${SUPABASE_URL%/}/rest/v1/${PUBLISH_TABLE}?on_conflict=${PUBLISH_CONFLICT_COL:-slug}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates,return=minimal" \
    --data @- \
    -o /dev/null -w '%{http_code}')" || code="000"
  echo "$code"
}

payload="$(build_payload)"
http_code="$(publish "$payload")"

case "$http_code" in
  2??) jq -nc --arg slug "$SLUG" --arg table "$PUBLISH_TABLE" \
         '{status:"ok", slug:$slug, table:$table}'
       ;;
  *)   echo "publish-post: upsert failed for $SLUG (HTTP $http_code)" >&2
       exit 1
       ;;
esac
