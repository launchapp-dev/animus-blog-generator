#!/usr/bin/env bats

setup() {
  TMPDIR="$(mktemp -d)"
  export TEST_REPO="$TMPDIR/repo"
  mkdir -p "$TEST_REPO/content" "$TEST_REPO/scripts"
  cp "$BATS_TEST_DIRNAME/../register-post.sh" "$TEST_REPO/scripts/register-post.sh"
  chmod +x "$TEST_REPO/scripts/register-post.sh"
  cd "$TEST_REPO"
  git init -q
  git config user.email "test@test"
  git config user.name "Test"
}

teardown() {
  rm -rf "$TMPDIR"
}

write_post() {
  local slug="$1"
  cat > "content/$slug.md" <<EOF
---
title: Test Post About $slug
slug: $slug
meta_description: A short description for $slug
date: 2026-06-05
author: Test Author
keywords: [test, $slug]
schema_type: Article
content_pillar: Test Pillar
target_keyword: "$slug keyword"
word_count: 1500
featuredImage: assets/$slug.webp
excerpt: One paragraph excerpt about $slug.
seoTitle: SEO Title for $slug
seoDescription: SEO meta for $slug
---

# Body

Lorem ipsum.
EOF
}

@test "creates manifest with first post when manifest is missing" {
  write_post "first-post"
  run ./scripts/register-post.sh first-post
  [ "$status" -eq 0 ]
  [ -f content/manifest.json ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "appends a second post" {
  write_post "first-post"
  ./scripts/register-post.sh first-post
  write_post "second-post"
  run ./scripts/register-post.sh second-post
  [ "$status" -eq 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "2" ]
}

@test "extracts required frontmatter fields" {
  write_post "fields-test"
  ./scripts/register-post.sh fields-test
  run jq -r '.posts[0].title' content/manifest.json
  [ "$output" = "Test Post About fields-test" ]
  run jq -r '.posts[0].pillar' content/manifest.json
  [ "$output" = "Test Pillar" ]
  run jq -r '.posts[0].word_count' content/manifest.json
  [ "$output" = "1500" ]
}

@test "is idempotent for the same slug" {
  write_post "idem-post"
  ./scripts/register-post.sh idem-post
  run ./scripts/register-post.sh idem-post
  [ "$status" -eq 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "fails on broken frontmatter without corrupting manifest" {
  write_post "atomic-post"
  ./scripts/register-post.sh atomic-post
  echo "broken" > content/atomic-post.md
  run ./scripts/register-post.sh atomic-post
  [ "$status" -ne 0 ]
  run jq '.posts | length' content/manifest.json
  [ "$output" = "1" ]
}

@test "commits the manifest change" {
  write_post "commit-post"
  ./scripts/register-post.sh commit-post
  run git log --oneline
  [[ "$output" == *"Register commit-post"* ]]
}

@test "emits commit_message to stdout in a parseable form" {
  write_post "stdout-post"
  run ./scripts/register-post.sh stdout-post
  [ "$status" -eq 0 ]
  # The script's last stdout line must contain the commit message so the
  # phase can capture it as the output contract's `commit_message` field.
  [[ "$output" == *"Register stdout-post in content manifest"* ]]
}

@test "honors LINEAR_SUBJECT_ID and SOURCE_TRANSCRIPT_ID env" {
  write_post "env-post"
  LINEAR_SUBJECT_ID="BLG-42" SOURCE_TRANSCRIPT_ID="krisp-xyz" \
    ./scripts/register-post.sh env-post
  run jq -r '.posts[0].linear_subject_id' content/manifest.json
  [ "$output" = "BLG-42" ]
  run jq -r '.posts[0].source_transcript_id' content/manifest.json
  [ "$output" = "krisp-xyz" ]
}
