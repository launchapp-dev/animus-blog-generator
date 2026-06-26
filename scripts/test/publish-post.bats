#!/usr/bin/env bats
#
# Tests for publish-post.sh — deterministic upsert of a finished post into a
# Supabase/PostgREST table. curl is stubbed on PATH (no network); yq + jq run
# for real so payload building / frontmatter parsing are exercised end to end.

setup() {
  TMPDIR="$(mktemp -d)"
  export TEST_REPO="$TMPDIR/repo"
  mkdir -p "$TEST_REPO/content" "$TEST_REPO/scripts" "$TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../publish-post.sh" "$TEST_REPO/scripts/publish-post.sh"
  chmod +x "$TEST_REPO/scripts/publish-post.sh"

  # fake curl: log args, capture the request body from stdin, echo an http code
  export CURL_LOG="$TMPDIR/curl.log"
  export CURL_BODY="$TMPDIR/curl.body"
  cat > "$TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
cat > "$CURL_BODY"
printf '%s' "${CURL_HTTP_CODE:-200}"
STUB
  chmod +x "$TMPDIR/bin/curl"
  export PATH="$TMPDIR/bin:$PATH"
  cd "$TEST_REPO"
}

teardown() { rm -rf "$TMPDIR"; }

configure() {
  export SUPABASE_URL="https://proj.supabase.co"
  export SUPABASE_SERVICE_ROLE_KEY="service-key"
}

write_post() {
  local slug="$1"
  cat > "content/$slug.md" <<EOF
---
title: Test Post About $slug
slug: $slug
meta_description: A short description for $slug
date: 2026-06-05
keywords: [test, $slug]
content_pillar: Test Pillar
target_keyword: "$slug keyword"
word_count: 1500
featuredImage: assets/$slug.webp
excerpt: One paragraph excerpt about $slug.
---

# Heading

Lorem ipsum body for $slug.
EOF
}

@test "missing slug argument exits 2" {
  run ./scripts/publish-post.sh
  [ "$status" -eq 2 ]
}

@test "skips (exit 0) when Supabase env is not configured — no curl call" {
  write_post "unconf"
  run ./scripts/publish-post.sh unconf
  [ "$status" -eq 0 ]
  [[ "$output" == *"publish_not_configured"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "configured but post file missing exits 1" {
  configure
  run ./scripts/publish-post.sh nope
  [ "$status" -eq 1 ]
}

@test "happy path: POSTs upsert to the right URL with the post payload" {
  configure
  write_post "good"
  run ./scripts/publish-post.sh good
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  grep -q "https://proj.supabase.co/rest/v1/posts" "$CURL_LOG"
  grep -q "Prefer: resolution=merge-duplicates" "$CURL_LOG"
  run jq -r '.slug' "$CURL_BODY";  [ "$output" = "good" ]
  run jq -r '.title' "$CURL_BODY"; [ "$output" = "Test Post About good" ]
  run jq -r '.body_markdown' "$CURL_BODY"; [[ "$output" == *"Lorem ipsum body for good"* ]]
}

@test "non-2xx response fails the phase (exit 1)" {
  configure
  export CURL_HTTP_CODE=500
  write_post "bad"
  run ./scripts/publish-post.sh bad
  [ "$status" -eq 1 ]
}

@test "PUBLISH_TABLE overrides the target table" {
  configure
  export PUBLISH_TABLE=articles
  write_post "tbl"
  run ./scripts/publish-post.sh tbl
  [ "$status" -eq 0 ]
  grep -q "/rest/v1/articles" "$CURL_LOG"
}

@test "special characters in title/body produce valid escaped JSON" {
  configure
  cat > "content/esc.md" <<'EOF'
---
title: 'He said "hi" & left'
slug: esc
meta_description: desc
date: 2026-06-05
keywords: [a, b]
content_pillar: P
target_keyword: k
word_count: 10
featuredImage: assets/esc.webp
excerpt: e
---

Line with "quotes" and a backslash \ and ampersand &.
EOF
  run ./scripts/publish-post.sh esc
  [ "$status" -eq 0 ]
  run jq -r '.title' "$CURL_BODY"; [ "$output" = 'He said "hi" & left' ]
  run jq -r '.body_markdown' "$CURL_BODY"; [[ "$output" == *'"quotes"'* ]]
}

@test "source_ref is taken from LINEAR_SUBJECT_ID env" {
  configure
  write_post "src"
  run env LINEAR_SUBJECT_ID=BLG-42 ./scripts/publish-post.sh src
  [ "$status" -eq 0 ]
  run jq -r '.source_ref' "$CURL_BODY"; [ "$output" = "BLG-42" ]
}

@test "upsert request includes on_conflict=slug (works for PK or plain UNIQUE)" {
  configure
  write_post "oc"
  run ./scripts/publish-post.sh oc
  [ "$status" -eq 0 ]
  grep -q "on_conflict=slug" "$CURL_LOG"
}

@test "partial Supabase config (exactly one var set) is a hard error, not a skip" {
  export SUPABASE_URL="https://proj.supabase.co"   # SERVICE_ROLE_KEY deliberately unset
  write_post "partial"
  run ./scripts/publish-post.sh partial
  [ "$status" -eq 2 ]
  [ ! -f "$CURL_LOG" ]
}

@test "selects the manifest entry matching the current branch, not just the last" {
  configure
  git init -q; git config user.email "t@t"; git config user.name "t"
  git commit -q --allow-empty -m init   # real runs have commits before publish
  git checkout -q -b run-current
  write_post "wanted"
  write_post "other"
  cat > content/manifest.json <<'EOF'
{"version":1,"posts":[
  {"slug":"wanted","branch":"run-current","linear_subject_id":""},
  {"slug":"other","branch":"some-other-branch","linear_subject_id":""}
]}
EOF
  run ./scripts/publish-post.sh
  [ "$status" -eq 0 ]
  run jq -r '.slug' "$CURL_BODY"; [ "$output" = "wanted" ]
}

@test "derives slug from the latest manifest entry when no slug arg is given" {
  configure
  write_post "auto"
  cat > content/manifest.json <<'EOF'
{"version":1,"posts":[{"slug":"auto","linear_subject_id":"","source_transcript_id":""}]}
EOF
  run ./scripts/publish-post.sh
  [ "$status" -eq 0 ]
  run jq -r '.slug' "$CURL_BODY"; [ "$output" = "auto" ]
}

@test "source_ref falls back to the manifest entry's linear_subject_id" {
  configure
  write_post "prov"
  cat > content/manifest.json <<'EOF'
{"version":1,"posts":[{"slug":"prov","linear_subject_id":"BLG-7","source_transcript_id":""}]}
EOF
  run ./scripts/publish-post.sh prov
  [ "$status" -eq 0 ]
  run jq -r '.source_ref' "$CURL_BODY"; [ "$output" = "BLG-7" ]
}
