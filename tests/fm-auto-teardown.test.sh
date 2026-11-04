#!/usr/bin/env bash
# Task-scoped cleanup after handling acknowledgements and ordinary teardown safety.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-teardown)
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$ROOT/bin/fm-gate-refuse-lib.sh"
LAB_MODE=0

make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE"
  if [ "$LAB_MODE" -eq 1 ]; then
    fm_gate_lab_mark "$CASE" || fail 'could not mark empty lab home'
    mkdir -p "$CASE/projects"
  fi
  mkdir -p "$CASE/state" "$CASE/config" "$CASE/data/task-a" "$CASE/user-home"
  FAKEBIN=$(fm_fakebin "$CASE")
  fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-task-a\nfm-task-b\n' ;;
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
  local lab_env=()
  if [ "$LAB_MODE" -eq 1 ]; then
    lab_env=(env -u FM_DATA_OVERRIDE FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE=test)
  fi
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$CASE" \
    HOME="$CASE/user-home" FM_STATE_OVERRIDE="$CASE/state" FM_CONFIG_OVERRIDE="$CASE/config" \
    FM_DATA_OVERRIDE="$CASE/data" FM_SUPERVISION_ACTOR=main PATH="$FAKEBIN:$PATH" "${lab_env[@]}" "$@"
}
run_auto() { in_home "$ROOT/bin/fm-auto-teardown.sh" task-a; }
retained() { [ -f "$CASE/state/task-a.meta" ] && [ -d "$CASE/wt" ] || fail 'task was removed'; }
retired() { [ ! -e "$CASE/state/task-a.meta" ] || fail "task was retained: ${OUT:-}"; }
land() { git -C "$CASE/project" merge --ff-only fm/task-a >/dev/null; }

enqueue() {
  # shellcheck disable=SC2016 # The child shell expands its positional arguments.
  in_home bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append "$2" "$3" "$4"' _ "$ROOT" "$1" "$2" "${3:-wake}"
}
present_wakes() {
  OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  CUTOFF=$(printf '%s\n' "$OUT" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  GENERATION=$(printf '%s\n' "$OUT" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  [ -n "$CUTOFF" ] && [ -n "$GENERATION" ] || fail "drain did not provide an acknowledgement: $OUT"
}
ack_wakes() {
  OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" --ack-through "${1:-$CUTOFF}" --recovery-generation "$GENERATION" 2>&1)
}
ack_task() {
  enqueue signal task-a.status 'signal: task-a.status'
  present_wakes
  retained
  ack_wakes
}
neighbor() {
  fm_git_worktree "$CASE/neighbor-project" "$CASE/neighbor-wt" fm/task-b
  fm_write_meta "$CASE/state/task-b.meta" window=firstmate:fm-task-b endpoint_task_id=task-b \
    "project=$CASE/neighbor-project" "worktree=$CASE/neighbor-wt" kind=ship mode=local-only \
    branch=fm/task-b spawn_gen=neighbor-generation harness=claude
  printf 'done: ready in branch fm/task-b\n' > "$CASE/state/task-b.status"
  in_home "$ROOT/bin/fm-busy-event.sh" arm "$CASE/state" task-b --state idle --source claude-hook --event Stop >/dev/null
  in_home "$ROOT/bin/fm-auto-teardown.sh" --eligible task-b neighbor-generation || fail 'neighbor is not independently eligible'
}
neighbor_retained() { [ -f "$CASE/state/task-b.meta" ] && [ -d "$CASE/neighbor-wt" ] || fail 'unacknowledged neighbor was removed'; }

# Exercise both acknowledgement entrypoints with the real marked-lab guard.
# Tool shims isolate runtime/forge dependencies; teardown and its guard are real.
LAB_MODE=1
for acknowledgement in wake outcome; do
  make_case "lab-$acknowledgement"
  land
  if [ "$acknowledgement" = wake ]; then
    ack_task
  else
    SEQ=$(in_home "$ROOT/bin/fm-branch-outcome.sh" append --task task-a --verdict captain --summary handled)
    in_home "$ROOT/bin/fm-branch-outcome.sh" present >/dev/null
    in_home "$ROOT/bin/fm-branch-outcome.sh" mark-read --through "$SEQ"
    retained
    OUT=$(in_home "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$SEQ" 2>&1)
  fi
  retired
done
LAB_MODE=0

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
retained
ack_task
retired

make_case branch-actor
land
OUT=$(in_home env FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-auto-teardown.sh" task-a); retained
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
enqueue check "$CASE/state/task-a.check.sh" merged
present_wakes
retained
ack_wakes
retired

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
ack_task
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
    steering)
      # shellcheck disable=SC2016 # The child shell expands its positional arguments.
      in_home bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" task-a "iterate again"' _ "$ROOT" "$CASE/state" >/dev/null
      ;;
  esac
  fm_lock_release "$CASE/state/.meta-task-a.lock"
  wait "$auto_pid"
  OUT=$(cat "$CASE/auto.out"); retained
  case "$OUT" in *'no longer eligible'*) ;; *) fail "locked eligibility was not rechecked: $OUT" ;; esac
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
    # shellcheck disable=SC2016 # The child shell expands its positional arguments.
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


make_case no-scan
land
neighbor
OUT=$(in_home "$ROOT/bin/fm-auto-teardown.sh" 2>&1) && fail 'cleanup accepted an unscoped fleet scan'
retained; neighbor_retained
OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
retained; neighbor_retained

enqueue signal task-a.status 'signal: task-a.status'
enqueue signal task-b.status 'signal: task-b.status'
present_wakes
retained; neighbor_retained
OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" --ack-through 1 --recovery-generation ../invalid 2>&1) && fail 'invalid acknowledgement succeeded'
retained; neighbor_retained
ack_wakes 1
retired; neighbor_retained
grep -q 'task-b.status' "$CASE/state/.wake-queue" || fail 'later neighbor wake was pruned'
ack_wakes 2
[ ! -e "$CASE/state/task-b.meta" ] || fail 'acknowledged neighbor was retained'

make_case unrelated-ack
land
neighbor
enqueue check unrelated.check.sh 'unrelated check'
present_wakes
ack_wakes
retained; neighbor_retained
enqueue check "$CASE/state/task-a.check.sh" 'task poll result'
present_wakes
ack_wakes
retired; neighbor_retained

make_case reserved-ack
land
neighbor
enqueue signal task-a.status 'signal: task-a.status'
enqueue signal task-b.status 'signal: task-b.status'
in_home "$ROOT/bin/fm-wake-grant.sh" activate "$$" ack-scope
in_home "$ROOT/bin/fm-wake-grant.sh" publish ack-scope 1
present_wakes
ack_wakes
retained
[ ! -e "$CASE/state/task-b.meta" ] || fail 'main acknowledgement did not clean its own task'
OUT=$(in_home env FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-wake-drain.sh" --ack-through 1 --recovery-generation "$GENERATION" 2>&1)
retained
ack_task
retired

make_case default-off-ack
land
rm "$CASE/config/auto-teardown"
ack_task
retained

make_case default-off-processed
land
rm "$CASE/config/auto-teardown"
SEQ=$(in_home "$ROOT/bin/fm-branch-outcome.sh" append --task task-a --verdict captain --summary handled)
in_home "$ROOT/bin/fm-branch-outcome.sh" present >/dev/null
in_home "$ROOT/bin/fm-branch-outcome.sh" mark-read --through "$SEQ"
in_home "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$SEQ"
retained

make_case resumed-at-ack
land
enqueue signal task-a.status 'signal: task-a.status'
present_wakes
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a busy --current-gen --source claude-hook --event UserPromptSubmit
ack_wakes
retained
in_home "$ROOT/bin/fm-busy-event.sh" apply "$CASE/state" task-a idle --current-gen --source claude-hook --event Stop
# shellcheck disable=SC2016 # The child shell expands its positional arguments.
RECORD=$(in_home bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" task-a "new instruction"' _ "$ROOT" "$CASE/state")
ack_task
retained
mv "$RECORD" "$CASE/state/task-a.inbox/handled/"
ack_task
retired

for verdict in captain routine; do
  make_case "withheld-$verdict"
  land
  neighbor
  rm "$CASE/config/supervision-host-off"
  printf 'claude\n' > "$CASE/config/supervision-host"
  PAYLOAD=$(printf '%0600d' 0)
  if [ "$verdict" = captain ]; then first=task-b; last=task-a; else first=task-a; last=task-b; fi
  in_home "$ROOT/bin/fm-branch-outcome.sh" append --task "$first" --verdict "$verdict" --summary "$first $PAYLOAD" >/dev/null
  i=1
  while [ "$i" -le 6 ]; do
    printf 'done: filler complete\n' > "$CASE/state/filler-$i.status"
    in_home "$ROOT/bin/fm-branch-outcome.sh" append --task "filler-$i" --verdict "$verdict" --summary "filler-$i $PAYLOAD" >/dev/null
    i=$((i + 1))
  done
  in_home "$ROOT/bin/fm-branch-outcome.sh" append --task "$last" --verdict "$verdict" --summary "$last $PAYLOAD" >/dev/null
  OUT=$(in_home env FM_TEST_HARNESS=claude "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  case "$OUT" in *'held back (byte cap)'*|*'earlier routine outcome(s) not shown'*) ;; *) fail "budget omission was not exercised: $OUT" ;; esac
  retained; neighbor_retained
  if [ "$verdict" = captain ]; then
    THROUGH=$(printf '%s\n' "$OUT" | sed -n 's/^BRANCH OUTCOMES: after processing them run bin\/fm-branch-outcome.sh mark-processed --through \([0-9][0-9]*\).*/\1/p')
    [ -n "$THROUGH" ] && [ "$THROUGH" -lt 8 ] || fail 'withheld task was included in the offered acknowledgement'
    REAL_MV=$(command -v mv)
    cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do destination=$arg; done
case "$destination" in */.branch-outcomes-processed) exit 1 ;; esac
exec "$FM_TEST_REAL_MV" "$@"
SH
    chmod +x "$FAKEBIN/mv"
    OUT=$(in_home env FM_TEST_REAL_MV="$REAL_MV" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$THROUGH" 2>&1) && fail 'failed marker commit was accepted'
    retained; neighbor_retained
    rm "$FAKEBIN/mv"
    OUT=$(in_home "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$THROUGH" 2>&1)
    retained
    [ ! -e "$CASE/state/task-b.meta" ] || fail 'processed neighbor outcome did not trigger cleanup'
    OUT=$(in_home "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$THROUGH" 2>&1) && fail 'replayed outcome acknowledgement succeeded'
    retained
    in_home "$ROOT/bin/fm-branch-outcome.sh" present >/dev/null
    in_home "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 8 >/dev/null
    retired
  else
    OUT=$(in_home "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 8 2>&1) && fail 'routine row was accepted as a captain acknowledgement'
    retained; neighbor_retained
    ack_task
    retired; neighbor_retained
  fi
done

printf 'PASS: task-scoped acknowledgement cleanup and ordinary teardown safety\n'
