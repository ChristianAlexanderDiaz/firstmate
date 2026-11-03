#!/usr/bin/env bash
# Automatic cleanup eligibility and real teardown, local landing, and wake entrypoints.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-teardown)
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/state" "$CASE/config" "$CASE/data/task-a" "$CASE/user-home"
  FAKEBIN=$(fm_fakebin "$CASE")
  fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-task-a\n' ;;
esac
exit 0
SH
  fm_git_worktree "$CASE/project" "$CASE/wt" fm/task-a
  printf 'manual\n' > "$CASE/config/backlog-backend"
  : > "$CASE/config/supervision-host-off"
  : > "$CASE/config/auto-teardown"
  touch "$CASE/state/.last-watcher-beat"
  fm_write_meta "$CASE/state/task-a.meta" \
    window=firstmate:fm-task-a endpoint_task_id=task-a \
    "project=$CASE/project" "worktree=$CASE/wt" kind=ship mode=local-only \
    branch=fm/task-a spawn_gen=auto-teardown-test harness=claude
  printf 'done: ready in branch fm/task-a\n' > "$CASE/state/task-a.status"
  printf 'change\n' > "$CASE/wt/change"
  git -C "$CASE/wt" add change
  git -C "$CASE/wt" -c user.name=Tests -c user.email=tests@example.invalid commit -qm change
  in_home "$ROOT/bin/fm-busy-event.sh" arm "$CASE/state" task-a --state idle --source claude-hook --event Stop >/dev/null
}
in_home() {
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$CASE" \
    HOME="$CASE/user-home" FM_STATE_OVERRIDE="$CASE/state" FM_CONFIG_OVERRIDE="$CASE/config" \
    FM_DATA_OVERRIDE="$CASE/data" FM_SUPERVISION_ACTOR=main PATH="$FAKEBIN:$PATH" "$@"
}
run_auto() { in_home "$ROOT/bin/fm-auto-teardown.sh"; }
retained() { [ -f "$CASE/state/task-a.meta" ] && [ -d "$CASE/wt" ] || fail 'task was removed'; }
retired() { [ ! -e "$CASE/state/task-a.meta" ] || fail "task was retained: ${OUT:-}"; }
land() { git -C "$CASE/project" merge --ff-only fm/task-a >/dev/null; }

make_case default-off
land
rm "$CASE/config/auto-teardown"
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'default-off emitted output'

make_case local-not-landed
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'unlanded branch triggered teardown'

make_case resumed-local
land
printf 'working: resumed after the old done event\n' >> "$CASE/state/task-a.status"
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'historical done event closed a resumed worker'

make_case local-landing
OUT=$(in_home "$ROOT/bin/fm-merge-local.sh" task-a 2>&1)
retired
case "$OUT" in *'auto-teardown: task-a complete'*) ;; *) fail "local landing did not trigger cleanup: $OUT" ;; esac

make_case branch-actor
land
OUT=$(in_home env FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-auto-teardown.sh"); retained
[ -z "$OUT" ] || fail 'branch actor attempted cleanup'

make_case keep-open
land
printf 'keep_open=1\n' >> "$CASE/state/task-a.meta"
OUT=$(run_auto); retained
sed '/^keep_open=/d' "$CASE/state/task-a.meta" > "$CASE/meta"
mv "$CASE/meta" "$CASE/state/task-a.meta"
OUT=$(run_auto); retired

make_case refusal
land
printf 'uncommitted\n' >> "$CASE/wt/change"
OUT=$(run_auto); retained
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "refusal was not one line: $OUT"
case "$OUT" in *'auto-teardown: task-a:'*) ;; *) fail "refusal not reported: $OUT" ;; esac
grep -q uncommitted "$CASE/wt/change" || fail 'refusal discarded work'

make_case merged-pr
# Real landed-work safety is independent of the poll trigger.
land
sed 's/mode=local-only/mode=direct-PR/' "$CASE/state/task-a.meta" > "$CASE/meta"
mv "$CASE/meta" "$CASE/state/task-a.meta"
printf 'pr=https://github.com/example/sample/pull/7\n' >> "$CASE/state/task-a.meta"
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'open PR triggered teardown'
fm_pr_poll_merge_mark_notified "$CASE/state" task-a github github.com example/sample 8
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'different PR notification triggered teardown'
fm_pr_poll_merge_mark_notified "$CASE/state" task-a github github.com example/sample 7
printf 'done: PR https://github.com/example/sample/pull/7\n' > "$CASE/state/task-a.status"
PR_HEAD=$(git -C "$CASE/wt" rev-parse HEAD)
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\\t%s\\t%s\\n' MERGED '$PR_HEAD' 'https://github.com/example/sample/pull/7'
SH
printf 'keep_open=1\n' >> "$CASE/state/task-a.meta"
fm_pr_poll_prepare "$CASE/state" task-a github https://github.com/example/sample/pull/7 github.com example/sample 7 "$ROOT/bin/fm-pr-poll.sh"
fm_pr_poll_publish_prepared
fm_pr_poll_snapshot_capture "$CASE/state" task-a "$ROOT/bin/fm-pr-poll.sh" || fail 'retention disabled merge polling'
OUT=$(run_auto); retained
sed '/^keep_open=/d' "$CASE/state/task-a.meta" > "$CASE/meta"
mv "$CASE/meta" "$CASE/state/task-a.meta"
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a busy --current-gen --source claude-hook --event UserPromptSubmit
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'merged PR evidence closed a busy worker'
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a idle --current-gen --source claude-hook --event Stop
OUT=$(run_auto); retired

make_case scout
sed 's/kind=ship/kind=scout/' "$CASE/state/task-a.meta" > "$CASE/meta"
mv "$CASE/meta" "$CASE/state/task-a.meta"
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'scout without report triggered teardown'
printf 'Investigation findings.\n' > "$CASE/data/task-a/report.md"
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'scout without completion gate triggered teardown'
in_home "$ROOT/bin/fm-captain-hold.sh" complete task-a --none >/dev/null
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a busy --current-gen --source claude-hook --event UserPromptSubmit
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'reviewed scout report closed a busy worker'
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a idle --current-gen --source claude-hook --event Stop
OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
retired
[ -f "$CASE/data/task-a/report.md" ] || fail 'scout report was removed'

make_case silently-resumed-local
land
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a busy --current-gen --source claude-hook --event UserPromptSubmit
OUT=$(run_auto); retained
[ -z "$OUT" ] || fail 'historical local done event closed a busy worker'

FM_STATE_OVERRIDE="$CASE/state" . "$ROOT/bin/fm-wake-lib.sh"
for change in busy incarnation retention; do
  make_case "locked-$change"
  land
  fm_lock_try_acquire "$CASE/state/.meta-task-a.lock" || fail 'could not hold metadata lock'
  run_auto > "$CASE/auto.out" 2>&1 &
  auto_pid=$!
  tries=0
  while [ ! -d "$CASE/state/.control-task-a.lock" ] && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -d "$CASE/state/.control-task-a.lock" ] || fail 'teardown never reached lifecycle lock'
  case "$change" in
    busy) in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a busy --current-gen --source claude-hook --event UserPromptSubmit ;;
    incarnation)
      sed 's/spawn_gen=auto-teardown-test/spawn_gen=replacement/' "$CASE/state/task-a.meta" > "$CASE/meta"
      mv "$CASE/meta" "$CASE/state/task-a.meta"
      ;;
    retention) printf 'keep_open=1\n' >> "$CASE/state/task-a.meta" ;;
  esac
  fm_lock_release "$CASE/state/.meta-task-a.lock"
  wait "$auto_pid"
  OUT=$(cat "$CASE/auto.out"); retained
  case "$OUT" in *'no longer eligible'*) ;; *) fail "locked eligibility was not rechecked: $OUT" ;; esac
done

for queue in empty presented reserved; do
  for failure in snapshot lock; do
    make_case "presentation-$queue-$failure"
    land
    if [ "$queue" != empty ]; then
      in_home bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal task-a.status "signal: task-a.status"' _ "$ROOT"
    fi
    if [ "$queue" = reserved ]; then
      in_home "$ROOT/bin/fm-wake-grant.sh" activate "$$" auto-test
      in_home "$ROOT/bin/fm-wake-grant.sh" publish auto-test 1
    fi
    if [ "$failure" = snapshot ]; then
      printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE/identity-reader"
      chmod +x "$CASE/identity-reader"
      OUT=$(in_home env FM_STATUS_IDENTITY_READER="$CASE/identity-reader" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
      case "$OUT" in *'STATUS PRESENTATION INCOMPLETE'*) ;; *) fail "snapshot failure not exercised: $OUT" ;; esac
    else
      fm_lock_try_acquire "$CASE/state/.status-presentation-lock" || fail 'could not hold presentation lock'
      OUT=$(in_home env FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$ROOT/bin/fm-wake-drain.sh" 2>&1)
      fm_lock_release "$CASE/state/.status-presentation-lock"
      case "$OUT" in *'STATUS PRESENTATION SKIPPED'*) ;; *) fail "lock skip not exercised: $OUT" ;; esac
    fi
    retained
    [ -s "$CASE/state/task-a.status" ] || fail 'failed presentation erased unread outcome'
    OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
    retired
    case "$OUT" in *'task-a done: ready in branch fm/task-a'*) ;; *) fail "outcome not retried: $OUT" ;; esac
  done
done

printf 'PASS: automatic cleanup, real teardown, landing and wake entrypoints\n'
