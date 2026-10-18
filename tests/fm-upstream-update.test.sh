#!/usr/bin/env bash
# Upstream catch-up: real local remotes, weekly proposal gates, and safe merges.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-update)
CHECK="$ROOT/bin/fm-upstream-update.sh"
UPDATE="$ROOT/bin/fm-update.sh"
fm_git_identity fmtest fmtest@example.invalid
export TZ=UTC
NOW=$(python3 -c 'import datetime; print(int(datetime.datetime(2026,10,17,15,tzinfo=datetime.timezone.utc).timestamp()))')

world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W/home/config" "$W/home/state" "$W/nm"
  git init -q --initial-branch=main "$W/seed"
  printf 'base\n' > "$W/seed/file"
  git -C "$W/seed" add file
  git -C "$W/seed" commit -qm base
  git clone -q --bare "$W/seed" "$W/fork.git"
  git clone -q --bare "$W/seed" "$W/upstream.git"
  git clone -q "$W/fork.git" "$W/checkout"
  git -C "$W/seed" remote add upstream "$W/upstream.git"
  git -C "$W/seed" checkout -qb trunk
  printf 'upstream\n' > "$W/seed/new"
  git -C "$W/seed" add new
  git -C "$W/seed" commit -qm upstream
  git -C "$W/seed" push -q upstream trunk
  git -C "$W/upstream.git" symbolic-ref HEAD refs/heads/trunk
  git -C "$W/checkout" remote add upstream "$W/upstream.git"
  printf '{"upstream":"upstream"}\n' > "$W/home/config/upstream-update.json"
  python3 - "$W/nm/state.sqlite" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE runs(status TEXT)')
PY
}

run_check() {
  FM_HOME="$W/home" FM_ROOT_OVERRIDE="$W/checkout" NM_HOME="$W/nm" \
    FM_UPSTREAM_NOW="${1:-$NOW}" "$CHECK" check
}

set_status() {
  python3 - "$W/nm/state.sqlite" "$1" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('DELETE FROM runs')
    if sys.argv[2]:
        db.execute('INSERT INTO runs VALUES (?)', (sys.argv[2],))
PY
}

world detection
# The checkout can already contain upstream; detection must compare origin.
git -C "$W/checkout" fetch -q upstream trunk
git -C "$W/checkout" checkout -qb feature FETCH_HEAD
before=$(git -C "$W/checkout" show-ref)
fetch_before=$(cat "$W/checkout/.git/FETCH_HEAD")
out=$(run_check)
assert_contains "$out" 'upstream is 1 commits ahead' 'count compares remote defaults'
[ "$before" = "$(git -C "$W/checkout" show-ref)" ] || fail 'check moved refs'
[ "$fetch_before" = "$(cat "$W/checkout/.git/FETCH_HEAD")" ] || fail 'check overwrote FETCH_HEAD'
[ -z "$(run_check "$((NOW + 3600))")" ] || fail 'same slot repeated'
[ -z "$(run_check "$((NOW + 604799))")" ] || fail 'next proposal before Saturday 15:00'
assert_contains "$(run_check "$((NOW + 604800))")" 'upstream is 1 commits ahead' 'next weekly slot'
pass 'remote defaults, no ref writes, and weekly cadence'

world configurable
printf '{"upstream":"%s","weekday":7,"hour":18}\n' "$W/upstream.git" > "$W/home/config/upstream-update.json"
first=$((NOW + 97200)) # Sunday 18:00
assert_contains "$(run_check "$first")" 'upstream is 1 commits ahead' 'URL configuration'
[ -z "$(run_check "$((first + 604799))")" ] || fail 'configured Sunday hour ignored'
assert_contains "$(run_check "$((first + 604800))")" 'upstream is 1 commits ahead' 'configured weekly slot'
pass 'configurable weekday, hour, and URL'

world active
for status in pending running fixing awaiting_approval ci unknown; do
  set_status "$status"
  [ -z "$(run_check)" ] || fail "proposal during $status run"
  [ ! -e "$W/home/state/.upstream-update" ] || fail 'busy gate consumed cadence'
done
for status in completed failed cancelled; do
  set_status "$status"
  rm -f "$W/home/state/.upstream-update"
  assert_contains "$(run_check)" 'upstream is 1 commits ahead' 'terminal run permits proposal'
done
rm -f "$W/home/state/.upstream-update" "$W/nm/state.sqlite"
[ -z "$(run_check)" ] || fail 'missing database must defer'
[ ! -e "$W/nm/state.sqlite" ] || fail 'read-only gate created database'
printf 'broken\n' > "$W/nm/state.sqlite"
[ -z "$(run_check)" ] || fail 'corrupt database must defer'
pass 'active and unknown run states defer without consuming the weekly slot'

world delayed
set_status running
[ -z "$(run_check)" ] || fail 'busy scheduled slot produced a proposal'
set_status completed
assert_contains "$(run_check "$((NOW + 518400))")" 'upstream is 1 commits ahead' 'Friday catch-up after validation'
[ -z "$(run_check "$((NOW + 604800))")" ] || fail 'delayed Friday proposal repeated Saturday'
[ -z "$(run_check "$((NOW + 1036800))")" ] || fail 'spacing-blocked slot proposed mid-week'
[ -z "$(run_check "$((NOW + 1209599))")" ] || fail 'spacing-blocked slot proposed before the next slot'
assert_contains "$(run_check "$((NOW + 1209600))")" 'upstream is 1 commits ahead' 'later weekly proposal'
pass 'a delayed proposal skips the nearby weekly slot and resumes on schedule'

world off
rm "$W/home/config/upstream-update.json"
rm -rf "$W/home/state"
out=$(FM_HOME="$W/home" FM_ROOT_OVERRIDE="$W/checkout" "$CHECK" check)
[ -z "$out" ] && [ ! -e "$W/home/state" ] || fail 'off mode changed state'
pass 'absent configuration is a silent no-op'

world current
git -C "$W/checkout" fetch -q upstream trunk
git -C "$W/checkout" push -q origin FETCH_HEAD:main
[ -z "$(run_check)" ] || fail 'current fork reported drift'
git -C "$W/seed" commit -qm later --allow-empty
git -C "$W/seed" push -q upstream trunk
[ -z "$(run_check "$((NOW + 3600))")" ] || fail 'zero-count slot was not consumed'
assert_contains "$(run_check "$((NOW + 604800))")" 'upstream is 1 commits ahead' 'next batch after current check'
pass 'current fork waits until the next batch'

world failed_probe
git -C "$W/checkout" remote set-url upstream "$W/missing.git"
assert_contains "$(run_check)" 'comparison unavailable' 'network failure is not current'
[ -z "$(run_check "$((NOW + 3600))")" ] || fail 'repeated failure in one slot woke firstmate again'
git -C "$W/checkout" remote set-url upstream "$W/upstream.git"
[ -z "$(run_check "$((NOW + 7199))")" ] || fail 'failure retried too soon'
assert_contains "$(run_check "$((NOW + 7200))")" 'upstream is 1 commits ahead' 'silent hourly retry'
git -C "$W/checkout" remote set-url upstream "$W/missing.git"
assert_contains "$(run_check "$((NOW + 604800))")" 'comparison unavailable' 'next slot reports a lasting failure'
pass 'comparison failure is reported once per slot and retried silently'

world registration
FM_HOME="$W/home" FM_ROOT_OVERRIDE="$W/checkout" "$CHECK" arm
# Validate through the same public snapshot interface the watcher consumes.
(
  . "$ROOT/bin/fm-pr-lib.sh"
  . "$ROOT/bin/fm-check-lib.sh"
  fm_custom_check_snapshot_prepare "$W/home/state" upstream-update || fail 'untrusted check'
  out=$(NM_HOME="$W/nm" FM_UPSTREAM_NOW="$NOW" bash "$FM_CUSTOM_CHECK_SNAPSHOT")
  fm_custom_check_snapshot_cleanup
  assert_contains "$out" 'upstream is 1 commits ahead' 'registered watcher shim executes'
)
rm "$W/home/config/upstream-update.json"
FM_HOME="$W/home" "$CHECK" arm
[ ! -e "$W/home/state/upstream-update.check.sh" ] || fail 'removed config left check armed'
pass 'watcher registration and opt-out'

world invalid_config
for config in '{"upstream":"upstream","weekday":0}' \
  '{"upstream":"upstream","hour":24}' '{"upstream":"-bad"}' \
  '{"upstream":"upstream","typo":true}'; do
  printf '%s\n' "$config" > "$W/home/config/upstream-update.json"
  if run_check > "$W/result" 2>&1; then fail 'invalid configuration accepted'; fi
  [ ! -e "$W/home/state/.upstream-update" ] || fail 'invalid config consumed cadence'
done
pass 'invalid configuration fails before probing'

run_merge() {
  FM_HOME="$W/home" FM_ROOT_OVERRIDE="$1" "$UPDATE" --upstream-merge
}

world merge
fork_tip=$(git -C "$W/fork.git" rev-parse main)
if run_merge "$W/checkout" > "$W/refusal" 2>&1; then fail 'primary checkout accepted'; fi
assert_contains "$(cat "$W/refusal")" 'isolated linked task worktree' 'primary refused'
# These worktrees belong only to disposable git-init fixtures, never the pool.
git -C "$W/checkout" worktree add -qb fm/catch-up "$W/task" main
out=$(run_merge "$W/task")
assert_contains "$out" 'merge prepared' 'merge succeeds on isolated ship branch'
[ "$(git -C "$W/task" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" = 3 ] || fail 'merge must preserve both parents'
[ "$(git -C "$W/fork.git" rev-parse main)" = "$fork_tip" ] || fail 'helper pushed to fork'
[ "$(git -C "$W/checkout" rev-parse main)" = "$fork_tip" ] || fail 'helper moved main'
[ -z "$(git -C "$W/task" status --porcelain)" ] || fail 'successful merge left dirty state'
pass 'isolated merge preserves history without pushing or moving main'

world conflict
printf 'fork\n' > "$W/checkout/file"
git -C "$W/checkout" commit -qam fork
git -C "$W/checkout" push -q origin main
printf 'upstream conflict\n' > "$W/seed/file"
git -C "$W/seed" commit -qam conflict
git -C "$W/seed" push -q upstream trunk
git -C "$W/checkout" worktree add -qb fm/conflict "$W/task" main
if run_merge "$W/task" > "$W/result" 2>&1; then fail 'conflicting merge succeeded'; fi
assert_contains "$(cat "$W/result")" 'merge stopped' 'conflict reported'
[ "$(git -C "$W/task" diff --name-only --diff-filter=U)" = file ] || fail 'conflicts were resolved or aborted'
pass 'conflicts remain intact for a scoped decision'

world unsafe
git -C "$W/checkout" worktree add -qb fm/unsafe "$W/task" main
printf 'dirty\n' > "$W/task/dirty"
if run_merge "$W/task" > "$W/result" 2>&1; then fail 'dirty merge accepted'; fi
assert_contains "$(cat "$W/result")" 'dirty' 'dirty work preserved'
rm "$W/task/dirty"
git -C "$W/task" commit -qm unique --allow-empty
if run_merge "$W/task" > "$W/result" 2>&1; then fail 'unique task changes accepted'; fi
assert_contains "$(cat "$W/result")" 'current origin default tip' 'unique history preserved'
pass 'dirty and stale-base task branches are refused'

git -C "$W/checkout" worktree add -qb trunk "$W/default-task" main
if run_merge "$W/default-task" > "$W/result" 2>&1; then fail 'default branch accepted'; fi
assert_contains "$(cat "$W/result")" 'default branch' 'default branch refused'
pass 'upstream default branch is never used as the ship branch'

echo '# all upstream-update tests passed'
