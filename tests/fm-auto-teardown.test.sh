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
for change in busy incarnation retention steering; do
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
    steering) in_home bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" task-a "iterate again"' _ "$ROOT" "$CASE/state" >/dev/null ;;
  esac
  fm_lock_release "$CASE/state/.meta-task-a.lock"
  wait "$auto_pid"
  OUT=$(cat "$CASE/auto.out"); retained
  case "$OUT" in *'no longer eligible'*) ;; *) fail "locked eligibility was not rechecked: $OUT" ;; esac
done

for queue in empty presented reserved; do
  for failure in snapshot lock history-lock unsafe-history rebuild index budget; do
    make_case "presentation-$queue-$failure"
    land
    if [ "$queue" != empty ]; then
      in_home bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal task-a.status "signal: task-a.status"' _ "$ROOT"
    fi
    if [ "$queue" = reserved ]; then
      in_home "$ROOT/bin/fm-wake-grant.sh" activate "$$" auto-test
      in_home "$ROOT/bin/fm-wake-grant.sh" publish auto-test 1
    fi
    case "$failure" in
      history-lock)
        : > "$CASE/state/branch-outcomes.jsonl"
        fm_lock_try_acquire "$CASE/state/.branch-outcomes.lock" || fail 'could not hold outcome lock'
        ;;
      unsafe-history) mkdir "$CASE/state/branch-outcomes.jsonl" ;;
      rebuild) printf 'invalid history\n' > "$CASE/state/branch-outcomes.jsonl" ;;
      index) mkdir "$CASE/state/.task-a.branch-outcome-index" ;;
      budget)
        printf 'done: ready in branch fm/task-a %0300d\n' 0 > "$CASE/state/task-a.status"
        i=1
        while [ "$i" -le 25 ]; do
          printf 'done: outcome %s %0300d\n' "$i" 0 > "$CASE/state/aaa-$i.status"
          i=$((i + 1))
        done
        ;;
    esac
    if [ "$failure" = snapshot ]; then
      printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE/identity-reader"
      chmod +x "$CASE/identity-reader"
      OUT=$(in_home env FM_STATUS_IDENTITY_READER="$CASE/identity-reader" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
      case "$OUT" in *'STATUS PRESENTATION INCOMPLETE'*) ;; *) fail "snapshot failure not exercised: $OUT" ;; esac
    elif [ "$failure" = lock ]; then
      fm_lock_try_acquire "$CASE/state/.status-presentation-lock" || fail 'could not hold presentation lock'
      OUT=$(in_home env FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$ROOT/bin/fm-wake-drain.sh" 2>&1)
      fm_lock_release "$CASE/state/.status-presentation-lock"
      case "$OUT" in *'STATUS PRESENTATION SKIPPED'*) ;; *) fail "lock skip not exercised: $OUT" ;; esac
    else
      OUT=$(in_home env FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$ROOT/bin/fm-wake-drain.sh" 2>&1)
      case "$OUT" in
        *'STATUS OUTCOME BACKSTOP SKIPPED:'*|*'more omitted (byte cap)'*) ;;
        *) fail "outcome deferral not exercised: $OUT" ;;
      esac
      case "$failure" in
        history-lock) fm_lock_release "$CASE/state/.branch-outcomes.lock" ;;
        unsafe-history) rmdir "$CASE/state/branch-outcomes.jsonl" ;;
        rebuild) rm "$CASE/state/branch-outcomes.jsonl" ;;
        index) rmdir "$CASE/state/.task-a.branch-outcome-index" ;;
      esac
    fi
    retained
    [ -s "$CASE/state/task-a.status" ] || fail 'failed presentation erased unread outcome'
    OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
    retired
    case "$OUT" in *'task-a done: ready in branch fm/task-a'*) ;; *) fail "outcome not retried: $OUT" ;; esac
  done
done

for kind in scout local pr; do
  for delivery in '' fire-and-forget; do
    make_case "steering-$kind-${delivery:-ordinary}"
    land
    case "$kind" in
      scout)
        sed 's/kind=ship/kind=scout/' "$CASE/state/task-a.meta" > "$CASE/meta"
        mv "$CASE/meta" "$CASE/state/task-a.meta"
        printf 'Findings.\n' > "$CASE/data/task-a/report.md"
        in_home "$ROOT/bin/fm-captain-hold.sh" complete task-a --none >/dev/null
        ;;
      pr)
        sed 's/mode=local-only/mode=direct-PR/' "$CASE/state/task-a.meta" > "$CASE/meta"
        mv "$CASE/meta" "$CASE/state/task-a.meta"
        printf 'pr=https://github.com/example/sample/pull/7\n' >> "$CASE/state/task-a.meta"
        printf 'done: PR https://github.com/example/sample/pull/7\n' > "$CASE/state/task-a.status"
        fm_pr_poll_merge_mark_notified "$CASE/state" task-a github github.com example/sample 7
        PR_HEAD=$(git -C "$CASE/wt" rev-parse HEAD)
        cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\\t%s\\t%s\\n' MERGED '$PR_HEAD' 'https://github.com/example/sample/pull/7'
SH
        ;;
    esac
    RECORD=$(in_home bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" task-a "iterate again" "$3"' _ "$ROOT" "$CASE/state" "$delivery")
    OUT=$(run_auto); retained
    [ -f "$RECORD" ] || fail 'pending steer was discarded'
    mv "$RECORD" "$CASE/state/task-a.inbox/handled/"
    OUT=$(run_auto); retired
  done
done

make_case passed-run-active-harness
land
HEAD_SHA=$(git -C "$CASE/wt" rev-parse HEAD)
cat > "$CASE/run.toon" <<EOF
run:
  id: "01RUN"
  branch: fm/task-a
  status: completed
  head: "$HEAD_SHA"
  pr: ""
  findings: none
outcome: passed
EOF
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  axi:|axi:status) cat "$FM_HOME/run.toon" ;;
esac
exit 0
SH
for activity in busy unknown; do
  in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a "$activity" --current-gen --source claude-hook --event UserPromptSubmit
  CURRENT=$(in_home "$ROOT/bin/fm-crew-state.sh" task-a)
  case "$CURRENT" in 'state: done '*'source: run-step'*) ;; *) fail "passed run did not override harness state: $CURRENT" ;; esac
  OUT=$(run_auto); retained
  OUT=$(in_home "$ROOT/bin/fm-teardown.sh" task-a --auto auto-teardown-test 2>&1) && fail 'locked auto teardown accepted a non-idle harness'
  retained
done
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a idle --current-gen --source claude-hook --event Stop
OUT=$(run_auto); retired

REAL_MV=$(command -v mv)
for queue in empty presented reserved; do
  for mutation in append replace; do
    make_case "completion-race-$queue-$mutation"
    land
    if [ "$mutation" = append ]; then
      printf 'working: finishing the landed work\n' > "$CASE/state/task-a.status"
      in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a busy --current-gen --source claude-hook --event UserPromptSubmit
    fi
    if [ "$queue" != empty ]; then
      in_home bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal task-a.status "signal: task-a.status"' _ "$ROOT"
    fi
    if [ "$queue" = reserved ]; then
      in_home "$ROOT/bin/fm-wake-grant.sh" activate "$$" completion-race
      in_home "$ROOT/bin/fm-wake-grant.sh" publish completion-race 1
    fi
    cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do destination=$arg; done
if [ "$destination" = "$FM_STATE_OVERRIDE/.status-presentation-cursor" ] && [ ! -e "$FM_HOME/mutated" ]; then
  "$FM_TEST_REAL_MV" "$@" || exit 1
  : > "$FM_HOME/mutated"
  if [ "$FM_TEST_STATUS_MUTATION" = replace ]; then
    printf 'done: ready in branch fm/task-a\n' > "$FM_HOME/replacement.status"
    "$FM_TEST_REAL_MV" "$FM_HOME/replacement.status" "$FM_STATE_OVERRIDE/task-a.status" || exit 1
  else
    printf 'done: ready in branch fm/task-a\n' >> "$FM_STATE_OVERRIDE/task-a.status"
  fi
  "$FM_TEST_ROOT/bin/fm-busy-event.sh" apply "$FM_STATE_OVERRIDE" task-a idle --current-gen --source claude-hook --event Stop || exit 1
  . "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
  fm_wake_append signal task-a.status 'signal: task-a.status'
  exit $?
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
    chmod +x "$FAKEBIN/mv"
    OUT=$(in_home env FM_TEST_REAL_MV="$REAL_MV" FM_TEST_ROOT="$ROOT" FM_TEST_STATUS_MUTATION="$mutation" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
    [ -f "$CASE/mutated" ] || fail 'completion race was not exercised'
    retained
    grep -q '^done:' "$CASE/state/task-a.status" || fail 'unpresented completion was erased'
    grep -q 'signal: task-a.status' "$CASE/state/.wake-queue" || fail 'new completion signal was pruned'
    OUT=$(in_home env FM_TEST_REAL_MV="$REAL_MV" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
    retired
    case "$OUT" in *'done: ready in branch fm/task-a'*) ;; *) fail "new completion was not presented: $OUT" ;; esac
  done
done

for mutation in append replace; do
  make_case "locked-coverage-$mutation"
  land
  rm "$CASE/config/auto-teardown"
  in_home "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1
  : > "$CASE/config/auto-teardown"
  fm_lock_try_acquire "$CASE/state/.meta-task-a.lock" || fail 'could not hold metadata lock'
  in_home env FM_AUTO_TEARDOWN_REQUIRE_PRESENTED=1 "$ROOT/bin/fm-auto-teardown.sh" > "$CASE/auto.out" 2>&1 &
  auto_pid=$!
  tries=0
  while [ ! -d "$CASE/state/.control-task-a.lock" ] && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -d "$CASE/state/.control-task-a.lock" ] || fail 'covered task never reached lifecycle lock'
  if [ "$mutation" = replace ]; then
    printf 'done: ready in branch fm/task-a\n' > "$CASE/replacement.status"
    mv "$CASE/replacement.status" "$CASE/state/task-a.status"
  else
    printf 'done: ready in branch fm/task-a after another iteration\n' >> "$CASE/state/task-a.status"
  fi
  fm_lock_release "$CASE/state/.meta-task-a.lock"
  wait "$auto_pid"
  OUT=$(cat "$CASE/auto.out"); retained
  case "$OUT" in *'no longer eligible'*) ;; *) fail "locked coverage was not rechecked: $OUT" ;; esac
  OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  retired
  case "$OUT" in *'done: ready in branch fm/task-a'*) ;; *) fail "changed completion was not presented: $OUT" ;; esac
done

for verdict in captain routine; do
  make_case "branch-outcome-delivery-$verdict"
  land
  ln "$CASE/state/task-a.status" "$CASE/state/task-b.status"
  OTHER_SEQ=$(in_home "$ROOT/bin/fm-branch-outcome.sh" append --task task-b --verdict captain --summary 'another task outcome')
  in_home "$ROOT/bin/fm-branch-outcome.sh" mark-read --through "$OTHER_SEQ"
  OUT=$(in_home env FM_AUTO_TEARDOWN_REQUIRE_PRESENTED=1 "$ROOT/bin/fm-auto-teardown.sh"); retained
  rm "$CASE/state/task-b.status"
  SEQ=$(in_home "$ROOT/bin/fm-branch-outcome.sh" append --task task-a --verdict "$verdict" --summary 'landed task ready for retirement')
  OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1); retained
  case "$OUT" in *'task-a done:'*) fail "unread branch outcome unexpectedly reached the status backstop: $OUT" ;; esac
  OUT=$(in_home env FM_AUTO_TEARDOWN_REQUIRE_PRESENTED=1 "$ROOT/bin/fm-auto-teardown.sh"); retained
  for cursor in invalid 999; do
    printf '%s\n' "$cursor" > "$CASE/state/.branch-outcomes-cursor"
    OUT=$(in_home env FM_AUTO_TEARDOWN_REQUIRE_PRESENTED=1 "$ROOT/bin/fm-auto-teardown.sh"); retained
  done
  rm "$CASE/state/.branch-outcomes-cursor"
  rm "$CASE/config/supervision-host-off"
  printf 'claude\n' > "$CASE/config/supervision-host"
  OUT=$(in_home env FM_TEST_HARNESS=claude "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  case "$OUT" in *'landed task ready for retirement'*) ;; *) fail "branch outcome was not presented: $OUT" ;; esac
  retired
done

for mutation in append replace; do
  make_case "branch-coverage-$mutation"
  land
  SEQ=$(in_home "$ROOT/bin/fm-branch-outcome.sh" append --task task-a --verdict captain --summary 'completion delivered through branch')
  OUT=$(in_home "$ROOT/bin/fm-branch-outcome.sh" present)
  case "$OUT" in *'completion delivered through branch'*) ;; *) fail 'branch delivery fixture omitted its outcome' ;; esac
  in_home "$ROOT/bin/fm-branch-outcome.sh" mark-read --through "$SEQ"
  in_home "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$SEQ"
  fm_lock_try_acquire "$CASE/state/.meta-task-a.lock" || fail 'could not hold metadata lock'
  in_home env FM_AUTO_TEARDOWN_REQUIRE_PRESENTED=1 "$ROOT/bin/fm-auto-teardown.sh" > "$CASE/auto.out" 2>&1 &
  auto_pid=$!
  tries=0
  while [ ! -d "$CASE/state/.control-task-a.lock" ] && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -d "$CASE/state/.control-task-a.lock" ] || fail 'delivered branch outcome did not establish eligibility'
  if [ "$mutation" = replace ]; then
    printf 'done: ready in branch fm/task-a\n' > "$CASE/replacement.status"
    mv "$CASE/replacement.status" "$CASE/state/task-a.status"
  else
    printf 'done: ready in branch fm/task-a after another iteration\n' >> "$CASE/state/task-a.status"
  fi
  fm_lock_release "$CASE/state/.meta-task-a.lock"
  wait "$auto_pid"
  OUT=$(cat "$CASE/auto.out"); retained
  case "$OUT" in *'no longer eligible'*) ;; *) fail "locked branch provenance was not checked: $OUT" ;; esac
  OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  retired
  case "$OUT" in *'done: ready in branch fm/task-a'*) ;; *) fail "new outcome was not presented: $OUT" ;; esac
done

printf 'PASS: automatic cleanup, real teardown, landing and wake entrypoints\n'
