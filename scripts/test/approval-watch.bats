#!/usr/bin/env bats
# Tests for scripts/approval-watch.sh — the deterministic Linear-approval gate.
# A fake `animus` is placed earlier in PATH; it logs invocations to $CALL_LOG
# and returns canned animus.cli.v1 envelopes chosen by FIXTURE_* env vars.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/approval-watch.sh"

  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/.animus/state" "$WORK/bin"
  cd "$WORK"

  export CALL_LOG="$WORK/calls.log"
  : > "$CALL_LOG"
  export FIXTURE_LIST="$WORK/list.json"
  export LINEAR_DISCOVERY_PROJECT_ID="PROJ-1"
  # Keep state writes/lock inside $WORK; the script uses relative .animus/state.

  # --- fake animus ---
  cat > "$WORK/bin/animus" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
cmd="$1 $2"
emit() { printf '%s' "$1"; }
case "$cmd" in
  "subject list")
    cat "$FIXTURE_LIST" ;;
  "subject create")
    if [ "${FIXTURE_CREATE:-ok}" = "fail" ]; then
      emit '{"schema":"animus.cli.v1","ok":false,"error":{"code":"unavailable","exit_code":5,"message":"no backend for kind blogtask"}}'; exit 5
    fi
    emit '{"schema":"animus.cli.v1","ok":true,"data":{"id":"BT-1"}}' ;;
  "queue enqueue")
    if printf '%s\n' "$@" | grep -q -- "--task-id"; then
      case "${FIXTURE_ENQUEUE_TASKID:-ok}" in
        ok)          emit '{"schema":"animus.cli.v1","ok":true,"data":{"queued":true}}' ;;
        reject)      emit '{"schema":"animus.cli.v1","ok":false,"error":{"code":"invalid","exit_code":2,"message":"task-id kind not accepted"}}'; exit 2 ;;
        unavailable) emit '{"schema":"animus.cli.v1","ok":false,"error":{"code":"unavailable","exit_code":5,"message":"daemon down"}}'; exit 5 ;;
      esac
    else
      case "${FIXTURE_ENQUEUE_ADHOC:-ok}" in
        ok)   emit '{"schema":"animus.cli.v1","ok":true,"data":{"queued":true}}' ;;
        fail) emit '{"schema":"animus.cli.v1","ok":false,"error":{"code":"unavailable","exit_code":5}}'; exit 5 ;;
      esac
    fi ;;
  *) emit '{"schema":"animus.cli.v1","ok":false,"error":{"code":"unknown","exit_code":1}}'; exit 1 ;;
esac
FAKE
  chmod +x "$WORK/bin/animus"
  export PATH="$WORK/bin:$PATH"
}

# helper: write a subject-list envelope from compact subject JSONs.
# Mirrors the REAL CLI shape: subjects at .data.result.subjects, cursor at
# .data.result.next_cursor. Optional 2nd arg sets next_cursor (default null).
write_list() {
  local subjects="$1" cursor="${2:-null}"
  printf '{"schema":"animus.cli.v1","ok":true,"data":{"kind":"issue","verb":"list","method":"issue/list","plugin_count":1,"result":{"next_cursor":%s,"subjects":%s}}}' \
    "$cursor" "$subjects" > "$FIXTURE_LIST"
}

enqueue_count() { grep -c "queue enqueue" "$CALL_LOG" || true; }
state_file() { echo "$WORK/.animus/state/approval-seen.json"; }

# 1
@test "missing approval-seen.json: first in-progress approval enqueues once" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 1 ]
  [ -f "$(state_file)" ]
  run jq -r '.subjects["BLG-1"].last_status' "$(state_file)"
  [ "$output" = "in-progress" ]
}

# 2
@test "no in-progress subjects: skip, zero enqueues, last_status recorded" {
  write_list '[{"subject_id":"BLG-9","title":"D","status":"done","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason":"no_approvals"'* ]]
  [ "$(enqueue_count)" -eq 0 ]
  run jq -r '.subjects["BLG-9"].last_status' "$(state_file)"
  [ "$output" = "done" ]
}

# 3
@test "duplicate run: same in-progress subject does not enqueue twice" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  : > "$CALL_LOG"
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 4
@test "newer transition_ts re-enqueues" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1","state_updated_at":"2026-06-01T00:00:00Z"}]'
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  : > "$CALL_LOG"
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1","state_updated_at":"2026-06-02T00:00:00Z"}]'
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 1 ]
}

# 5
@test "left in-progress then returns (no timestamp) re-enqueues" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  write_list '[{"subject_id":"BLG-1","title":"A","status":"done","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  : > "$CALL_LOG"
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"; [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 1 ]
}

# 6
@test "wrong project_id is ignored" {
  write_list '[{"subject_id":"BLG-2","title":"X","status":"in-progress","project_id":"OTHER"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 7
@test "missing project_id fails closed without the flag" {
  write_list '[{"subject_id":"BLG-3","title":"Y","status":"in-progress"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 8
@test "missing project_id kept with APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED=1" {
  write_list '[{"subject_id":"BLG-3","title":"Y","status":"in-progress"}]'
  APPROVAL_WATCH_ASSUME_BACKEND_PROJECT_SCOPED=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 1 ]
}

# 9
@test "malformed in-progress subject (no title) fails loud, no enqueue" {
  write_list '[{"subject_id":"BLG-4","status":"in-progress","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 10
@test "subject list ok:false fails loud, no enqueue, state untouched" {
  printf '{"schema":"animus.cli.v1","ok":false,"error":{"code":"unavailable","exit_code":5}}' > "$FIXTURE_LIST"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(enqueue_count)" -eq 0 ]
  [ ! -f "$(state_file)" ]
}

# 11
@test "missing LINEAR_DISCOVERY_PROJECT_ID exits 2" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  unset LINEAR_DISCOVERY_PROJECT_ID
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

# 12
@test "blogtask create fails: ad-hoc fallback enqueue used, single dispatch" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  FIXTURE_CREATE=fail run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c -- "--task-id" "$CALL_LOG"; [ "$output" -eq 0 ]
  run grep -c "queue enqueue --title" "$CALL_LOG"; [ "$output" -eq 1 ]
}

# 13
@test "task-id enqueue clean rejection falls back to ad-hoc, single dispatch" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  FIXTURE_ENQUEUE_TASKID=reject run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c "queue enqueue --title" "$CALL_LOG"; [ "$output" -eq 1 ]
}

# 14
@test "task-id enqueue unavailable does NOT retry ad-hoc and fails; state not updated" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  FIXTURE_ENQUEUE_TASKID=unavailable run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -c "queue enqueue --title" "$CALL_LOG"; [ "$output" -eq 0 ]
  run jq -r '.subjects["BLG-1"].enqueued_at // "none"' "$(state_file)"
  [ "$output" = "none" ]
}

# 15
@test "fresh lock present: exits 75, no work" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  mkdir -p "$WORK/.animus/state/approval-watch.lock"
  run bash "$SCRIPT"
  [ "$status" -eq 75 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 16
@test "stale lock (>10 min) is reclaimed and run proceeds" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  mkdir -p "$WORK/.animus/state/approval-watch.lock"
  touch -t 202601010000 "$WORK/.animus/state/approval-watch.lock"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 1 ]
}

# 17
@test "unparseable state file fails closed (no reset)" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  echo 'not json' > "$(state_file)"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 18
@test "unknown state version fails closed (no reset)" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]'
  echo '{"version":99,"updated_at":null,"subjects":{}}' > "$(state_file)"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 19
@test "underscore in_progress does NOT match (only hyphen)" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in_progress","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 20
@test "non-in-progress last_status persists via end-of-run write even with zero enqueues" {
  write_list '[{"subject_id":"BLG-7","title":"Z","status":"blocked","project_id":"PROJ-1"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run jq -r '.subjects["BLG-7"].last_status' "$(state_file)"
  [ "$output" = "blocked" ]
}

# 21 — real envelope shape: a non-null next_cursor (more than one page) fails loud
@test "next_cursor present fails closed (no silent truncation)" {
  write_list '[{"subject_id":"BLG-1","title":"A","status":"in-progress","project_id":"PROJ-1"}]' '"CURSOR123"'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(enqueue_count)" -eq 0 ]
}

# 22 — regression: subjects are read from .data.result.subjects, not .data[]
@test "ignores wrapper fields and reads .data.result.subjects" {
  # An empty subjects array under the real wrapper must yield no_approvals,
  # proving the script does not iterate wrapper keys (kind/verb/method/...).
  write_list '[]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason":"no_approvals"'* ]]
  [ "$(enqueue_count)" -eq 0 ]
}
