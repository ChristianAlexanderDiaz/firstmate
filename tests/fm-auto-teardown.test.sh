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
  fm_git_worktree "$CASE/project" "$CASE/wt" fm/task-a
  printf 'manual\n' > "$CASE/config/backlog-backend"
  : > "$CASE/config/supervision-host-off"
  : > "$CASE/config/auto-teardown"
  touch "$CASE/state/.last-watcher-beat"
  fm_write_meta "$CASE/state/task-a.meta" \
    window=firstmate:fm-task-a endpoint_task_id=task-a \
    "project=$CASE/project" "worktree=$CASE/wt" kind=ship mode=local-only \
    branch=fm/task-a spawn_gen=auto-teardown-test
  printf 'done: ready in branch fm/task-a\n' > "$CASE/state/task-a.status"
  printf 'change\n' > "$CASE/wt/change"
  git -C "$CASE/wt" add change
  git -C "$CASE/wt" -c user.name=Tests -c user.email=tests@example.invalid commit -qm change
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
PR_HEAD=$(git -C "$CASE/wt" rev-parse HEAD)
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\\t%s\\t%s\\n' MERGED '$PR_HEAD' 'https://github.com/example/sample/pull/7'
SH
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
OUT=$(in_home "$ROOT/bin/fm-wake-drain.sh" 2>&1)
retired
[ -f "$CASE/data/task-a/report.md" ] || fail 'scout report was removed'

printf 'PASS: automatic cleanup, real teardown, landing and wake entrypoints\n'
