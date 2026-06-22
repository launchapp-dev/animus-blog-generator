#!/usr/bin/env bash
# register-post.sh — Append a post entry to content/manifest.json
#
# Usage: ./scripts/register-post.sh <slug>
# Optional env: LINEAR_SUBJECT_ID, SOURCE_TRANSCRIPT_ID, BRANCH
# Stdout (last line): the commit message — captured by the calling phase
# to satisfy its commit_message output contract field.

set -euo pipefail

SLUG="${1:?slug argument required}"
POST_FILE="content/${SLUG}.md"
MANIFEST="content/manifest.json"

[ -f "$POST_FILE" ] || { echo "post not found: $POST_FILE" >&2; exit 1; }

FM="$(awk '/^---$/{c++; next} c==1{print}' "$POST_FILE")"
[ -n "$FM" ] || { echo "no frontmatter found in $POST_FILE" >&2; exit 1; }

title="$(echo "$FM" | yq -r '.title // ""')"
[ -n "$title" ] || { echo "frontmatter missing title" >&2; exit 1; }
pillar="$(echo "$FM" | yq -r '.content_pillar // ""')"
target_keyword="$(echo "$FM" | yq -r '.target_keyword // ""')"
word_count="$(echo "$FM" | yq -r '.word_count // 0')"
excerpt="$(echo "$FM" | yq -r '.excerpt // ""')"
date_str="$(echo "$FM" | yq -r '.date // ""')"
tags_json="$(echo "$FM" | yq -o=json -I=0 '.keywords // []')"

LINEAR_SUBJECT_ID="${LINEAR_SUBJECT_ID:-}"
SOURCE_TRANSCRIPT_ID="${SOURCE_TRANSCRIPT_ID:-}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"

if [ ! -f "$MANIFEST" ]; then
  echo '{"version":1,"posts":[]}' > "$MANIFEST"
fi

existing="$(jq --arg s "$SLUG" '[.posts[] | select(.slug == $s)] | length' "$MANIFEST")"
COMMIT_MSG="Register ${SLUG} in content manifest"
if [ "$existing" -gt 0 ]; then
  # Idempotent: same slug already present. Emit the commit message anyway
  # so the calling phase's output contract is satisfied; no git activity.
  echo "manifest already contains slug: $SLUG (skipping)" >&2
  echo "$COMMIT_MSG (no-op — already registered)"
  exit 0
fi

NEW_ENTRY="$(jq -n \
  --arg slug "$SLUG" \
  --arg title "$title" \
  --arg published_at "$date_str" \
  --arg pillar "$pillar" \
  --arg target_keyword "$target_keyword" \
  --argjson word_count "$word_count" \
  --arg summary "$excerpt" \
  --arg linear_subject_id "$LINEAR_SUBJECT_ID" \
  --arg source_transcript_id "$SOURCE_TRANSCRIPT_ID" \
  --arg branch "$BRANCH" \
  --argjson tags "$tags_json" \
  '{
    slug: $slug,
    title: $title,
    published_at: $published_at,
    pillar: $pillar,
    target_keyword: $target_keyword,
    tags: $tags,
    word_count: $word_count,
    summary: $summary,
    linear_subject_id: $linear_subject_id,
    source_transcript_id: $source_transcript_id,
    branch: $branch
  }')"

TMP="$(mktemp "${MANIFEST}.XXXXXX")"
jq --argjson entry "$NEW_ENTRY" '.posts += [$entry]' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

git add "$MANIFEST"
git commit -m "$COMMIT_MSG" --quiet

# Final stdout line: the commit message (parsed by the calling phase).
echo "$COMMIT_MSG"
