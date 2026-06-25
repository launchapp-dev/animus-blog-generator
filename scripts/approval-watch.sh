#!/usr/bin/env bash
# approval-watch.sh — deterministic Linear-approval gate for blog-from-ticket.
#
# Polls Linear-backed Animus subjects and dispatches `blog-from-ticket` exactly
# once per approval (a human moving an issue to status `in-progress`). Dedup
# state lives in .animus/state/approval-seen.json. Designed to run as a command
# phase with `worktree: skip` so the gitignored state persists in the project
# root across runs.
#
# Env:
#   LINEAR_DISCOVERY_PROJECT_ID                     (required)
#   APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED=1  (opt-in: keep subjects with no project_id)
#   ANIMUS_SQLITE_KINDS=blogtask                    (enables the sqlite wrapper; ad-hoc fallback otherwise)
#   APPROVAL_WATCH_LIST_LIMIT                        (default 500)
#
# Exit codes: 0 ok; 1 hard error; 2 missing required env; 75 lock contention.
#
# See docs/superpowers/plans/2026-06-23-deterministic-approval-watcher.md

set -euo pipefail

STATE_DIR=".animus/state"
STATE="$STATE_DIR/approval-seen.json"
LOCK="$STATE_DIR/approval-watch.lock"
LIST_LIMIT="${APPROVAL_WATCH_LIST_LIMIT:-500}"

die() { echo "approval-watch: $*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- 1. required env ---
if [ -z "${LINEAR_DISCOVERY_PROJECT_ID:-}" ]; then
  echo "approval-watch: LINEAR_DISCOVERY_PROJECT_ID is required" >&2
  exit 2
fi

mkdir -p "$STATE_DIR"

# --- 2. lock (with stale reclaim) ---
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || { echo "approval-watch: lock contended" >&2; exit 75; }
  else
    echo "approval-watch: another run holds the lock ($LOCK)" >&2
    exit 75
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

# --- 3. load state (fail closed on unknown version / corruption) ---
if [ -f "$STATE" ]; then
  if ! STATE_JSON=$(jq -ce . "$STATE" 2>/dev/null); then
    die "state file $STATE is unparseable; refusing to reset (migrate or remove it manually)"
  fi
  ver=$(jq -r '.version // empty' <<<"$STATE_JSON")
  if [ "$ver" != "1" ]; then
    die "state file $STATE has unrecognized version '${ver:-none}'; refusing to reset"
  fi
else
  STATE_JSON='{"version":1,"updated_at":null,"subjects":{}}'
fi

persist_state() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/.approval-seen.XXXXXX")
  printf '%s\n' "$STATE_JSON" >"$tmp"
  mv "$tmp" "$STATE"
}

# --- 4. fetch (explicit high limit; fail loud on truncation) ---
resp=$(animus subject list --kind issue --limit "$LIST_LIMIT" --json) || true
if [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null || echo false)" != "true" ]; then
  die "subject list failed: $(jq -r '.error.code // "unknown"' <<<"$resp" 2>/dev/null || echo unknown)"
fi
count=$(jq '.data // [] | length' <<<"$resp")
if [ "$count" -ge "$LIST_LIMIT" ]; then
  die "subject list returned $count >= limit $LIST_LIMIT — pagination required (resolve in smoke test before enabling)"
fi

# enqueue one subject; sets global ENQ_OK=1 on success. Tries the sqlite blogtask
# wrapper first, falls back to an ad-hoc queue entry. Both paths are envelope-aware.
do_enqueue() {
  local id="$1" title="$2" input="$3"
  local task q ec
  ENQ_OK=0

  task=$(animus subject create --kind blogtask --title "Blog: $title" \
           --body "Wraps Linear subject $id for blog-from-ticket" \
           --status ready --json) || true
  if [ "$(jq -r '.ok // false' <<<"$task" 2>/dev/null || echo false)" = "true" ]; then
    local task_id
    task_id=$(jq -r '.data.id' <<<"$task")
    q=$(animus queue enqueue --task-id "$task_id" \
          --workflow-ref blog-from-ticket --input-json "$input" --json) || true
    if [ "$(jq -r '.ok // false' <<<"$q" 2>/dev/null || echo false)" = "true" ]; then
      ENQ_OK=1; return 0
    fi
    # Only retry ad-hoc on a CLEAN rejection (typed exit 2 invalid / 3 not-found /
    # 4 conflict — nothing was enqueued). Never on 5 unavailable / 1 internal.
    ec=$(jq -r '.error.exit_code // 1' <<<"$q" 2>/dev/null || echo 1)
    case "$ec" in
      2|3|4) : ;;            # fall through to ad-hoc
      *) return 0 ;;         # ENQ_OK stays 0 → caller treats as failure
    esac
  fi

  # ad-hoc fallback (create failed, or a clean task-id rejection)
  q=$(animus queue enqueue --title "Blog: $title" \
        --description "Linear subject: $id" \
        --workflow-ref blog-from-ticket --input-json "$input" --json) || true
  if [ "$(jq -r '.ok // false' <<<"$q" 2>/dev/null || echo false)" = "true" ]; then
    ENQ_OK=1
  fi
  return 0
}

# --- 5. process subjects ---
enq='[]'
fail=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  id=$(jq -r '.subject_id // .id // empty' <<<"$s")
  title=$(jq -r '.title // empty' <<<"$s")
  status=$(jq -r '.status // empty' <<<"$s")
  pid=$(jq -r '.project_id // .projectId // .custom.project_id // empty' <<<"$s")
  ts=$(jq -r '.state_updated_at // .stateUpdatedAt // .status_updated_at // empty' <<<"$s")

  # project filter
  if [ -n "$pid" ]; then
    [ "$pid" = "$LINEAR_DISCOVERY_PROJECT_ID" ] || continue
  elif [ "${APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED:-}" != "1" ]; then
    die "subject ${id:-<no-id>} has no project_id and backend scoping is unconfirmed; set APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED=1 if your backend scopes subject/list by config.project_id"
  fi

  if [ "$status" != "in-progress" ]; then
    if [ -n "$id" ]; then
      STATE_JSON=$(jq -c --arg id "$id" --arg st "$status" \
        '.subjects[$id] = ((.subjects[$id] // {}) + {last_status:$st})' <<<"$STATE_JSON")
    fi
    continue
  fi

  # in-progress: malformed guard
  { [ -n "$id" ] && [ -n "$title" ]; } || die "in-progress subject missing id or title: $s"

  if [ -n "$ts" ]; then key="subject:$id:transition:$ts"; else key="subject:$id:status:in-progress"; fi
  prev_key=$(jq -r --arg id "$id" '.subjects[$id].approval_key // empty' <<<"$STATE_JSON")
  prev_status=$(jq -r --arg id "$id" '.subjects[$id].last_status // empty' <<<"$STATE_JSON")

  # skip ONLY if already enqueued for this exact approval episode
  if [ "$prev_key" = "$key" ] && [ "$prev_status" = "in-progress" ]; then
    continue
  fi

  input=$(jq -nc --arg id "$id" '{linear_subject_id:$id}')
  do_enqueue "$id" "$title" "$input"
  if [ "$ENQ_OK" = "1" ]; then
    if [ -n "$ts" ]; then ts_json=$(jq -nc --arg t "$ts" '$t'); else ts_json=null; fi
    STATE_JSON=$(jq -c --arg id "$id" --arg key "$key" --arg now "$(now)" --argjson ts "$ts_json" \
      '.subjects[$id] = {last_status:"in-progress", approval_key:$key, transition_ts:$ts, enqueued_at:$now} | .updated_at=$now' <<<"$STATE_JSON")
    persist_state
    enq=$(jq -c --arg id "$id" --arg key "$key" '. + [{subject_id:$id, approval_key:$key}]' <<<"$enq")
  else
    echo "approval-watch: enqueue failed for $id" >&2
    fail=1
  fi
done < <(jq -c '.data[]?' <<<"$resp")

# --- 6. end-of-run persist (captures non-in-progress last_status observations) ---
STATE_JSON=$(jq -c --arg now "$(now)" '.updated_at=$now' <<<"$STATE_JSON")
persist_state

# --- 7. verdict ---
if [ "$(jq 'length' <<<"$enq")" -eq 0 ]; then
  echo '{"status":"skip","reason":"no_approvals","enqueued":[]}'
else
  jq -nc --argjson e "$enq" '{status:"ok", enqueued:$e}'
fi

[ "$fail" -eq 0 ] || exit 1
