#!/usr/bin/env bash
# Quota-plan public-library admission and real refill adapter regressions.
# Vendor JSON is fixture-backed because published quota-axi lacks --all-accounts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-plan)
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
export FM_DATA_OVERRIDE="$FM_HOME/data" FM_PROJECTS_OVERRIDE="$FM_HOME/projects"
mkdir -p "$FM_HOME"/{state,config,data,projects} "$TMP_ROOT/fakebin"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$ROOT/bin/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-plan-lib.sh
. "$ROOT/bin/fm-quota-plan-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$ROOT/bin/fm-procevent-lib.sh"
export FM_TEST_QUOTA_FILE="$TMP_ROOT/quota.json" FM_TEST_QUOTA_CALLS="$TMP_ROOT/calls"
cat > "$TMP_ROOT/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "$*" = '--all-accounts --json' ] || exit 2
printf 'read\n' >> "$FM_TEST_QUOTA_CALLS"
[ ! -e "$FM_TEST_QUOTA_FILE.fail" ] || exit 2
cat "$FM_TEST_QUOTA_FILE"
SH
chmod +x "$TMP_ROOT/fakebin/quota-axi"
export PATH="$TMP_ROOT/fakebin:$PATH"
plan() {
  printf '%s\n' 'reserve claude 15' 'reserve codex 0' 'lane carryrank until 2099-10-20' 'lane lounge-card' > "$FM_HOME/config/quota-plan"
  fm_quota_plan_load "$FM_HOME/config" || fail 'valid plan rejected'
}
fixture() { # <now> <reset> <remaining>
  jq -n --argjson now "$1" --argjson reset "$2" --argjson left "$3" '
    {generatedAt:($now|todateiso8601),claudeCombined:[
      {scope:"all_models",window:"seven_day",remaining:$left,resetsAt:($reset|todateiso8601),
       pace:"ahead",burnMultiple:1,projectedLeftAtLaterReset:15,runway:"through_reset"}],
     claudeCombinedAccounts:[],providers:[{provider:"codex",state:{status:"fresh",stale:false},
       windows:[{id:"weekly",kind:"weekly",percentRemaining:$left,resetsAt:($reset|todateiso8601)}]}]}' > "$FM_TEST_QUOTA_FILE"
  jq -n --argjson now "$1" --slurpfile snapshot "$FM_TEST_QUOTA_FILE" \
    '{fetchedAt:$now,snapshot:$snapshot[0]}' > "$FM_HOME/state/quota-plan-snapshot.json"
  FM_QUOTA_PLAN_CACHE="$FM_HOME/state/quota-plan-snapshot.json"
}
expect_defer() {
  local rc=0
  fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" "$@" || rc=$?
  [ "$rc" = 75 ] || fail "expected defer for $*, got $rc"
  [ -n "$FM_QUOTA_PLAN_ERROR" ] || fail 'deferral lacks diagnostic'
}
plan
now=1900000000
reset=$((now+604800))
fixture "$now" "$reset" 88
fm_quota_plan_verdict claude "$now" || fail 'day one under line'
fixture "$now" "$reset" 87
if fm_quota_plan_verdict claude "$now"; then fail 'day one over line admitted'; fi
fixture "$((now+86399))" "$reset" 80
if fm_quota_plan_verdict claude "$((now+86399))"; then fail 'early day two allowance'; fi
fixture "$((now+86400))" "$reset" 80
fm_quota_plan_verdict claude "$((now+86400))" || fail 'day two boundary did not release allowance'
fixture "$((reset-1))" "$reset" 15
if fm_quota_plan_verdict claude "$((reset-1))"; then fail 'reserve line equality admitted'; fi
fixture "$((reset-1))" "$reset" 15.001
fm_quota_plan_verdict claude "$((reset-1))" || fail 'unused allowance did not roll forward'
fixture "$reset" "$reset" 100
if fm_quota_plan_verdict claude "$reset"; then fail 'expired cycle admitted'; fi
fixture "$reset" "$((reset+604800))" 100
fm_quota_plan_verdict claude "$reset" || fail 'new cycle refused'
# Tolerated combined reader variants remain explicit, never arbitrary fallbacks.
jq '.snapshot.claudeCombined[0] |= (.remaining = "100%" | .window = {id:"weekly",resetAt:.resetsAt} | del(.resetsAt))' \
  "$FM_QUOTA_PLAN_CACHE" > "$TMP_ROOT/variant"
mv "$TMP_ROOT/variant" "$FM_QUOTA_PLAN_CACHE"
fm_quota_plan_verdict claude "$reset" || fail 'documented combined variant refused'
jq '.snapshot.claudeCombined += .snapshot.claudeCombined' "$FM_QUOTA_PLAN_CACHE" > "$TMP_ROOT/duplicate"
mv "$TMP_ROOT/duplicate" "$FM_QUOTA_PLAN_CACHE"
if fm_quota_plan_verdict claude "$reset"; then fail 'ambiguous combined row admitted'; fi
pass 'day boundaries, rollover, unused allowance, exact reserve line and explicit reader variants'

for bad in 'reserve claude -1' 'reserve claude 101' 'reserve claude 15
reserve claude 20
reserve codex 0' 'reserve claude 15
reserve codex 0
lane test until 2026-02-30' 'reserve claude 15
reserve codex 0
lane ../escape' ''; do
  printf '%s\n' "$bad" > "$FM_HOME/config/quota-plan"
  expect_defer claude 0 ship
  fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" claude 1 ship || fail 'relaunch not exempt'
  fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" claude 0 secondmate || fail 'secondmate not exempt'
done
rm "$FM_HOME/config/quota-plan"
fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" unknown 0 scout || fail 'absent plan changed behavior'
pass 'malformed declarations defer; absent plan and lifecycle exemptions preserve behavior'

plan
now=$(date +%s)
fixture "$((now-301))" "$((now+500000))" 100
touch "$FM_TEST_QUOTA_FILE.fail"
expect_defer claude 0 ship
rm "$FM_TEST_QUOTA_FILE.fail"
fixture "$now" "$((now+500000))" 100
fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" claude 0 ship || fail 'fresh admission'
[ ! -f "$FM_QUOTA_PLAN_CACHE" ] || fail 'admission reused quota sample for next start'
# A separate process cannot acquire admission while the first launch owns it.
if bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$FM_HOME/state/.quota-plan-admission.lock"'; then
  fail 'concurrent admission acquired held machine lock'
fi
fm_quota_plan_release
fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" claude 0 ship || fail 'second serialized admission'
fm_quota_plan_release
[ "$(wc -l < "$FM_TEST_QUOTA_CALLS" | tr -d ' ')" -ge 2 ] || fail 'quota was not re-read'
fixture "$now" "$((now+500000))" 100
jq 'del(.snapshot.claudeCombined)' "$FM_QUOTA_PLAN_CACHE" > "$TMP_ROOT/missing"
mv "$TMP_ROOT/missing" "$FM_QUOTA_PLAN_CACHE"
expect_defer claude 0 ship
fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" codex 0 ship || fail 'codex needs unrelated combined Claude data'
fm_quota_plan_release
pass 'stale outage refuses, admission lock serializes, next start refreshes, providers stay separate'

# Real snapshot parser, capacity count, source registration and durable capture.
fm_git_init_commit "$FM_HOME/projects/carryrank"
fm_git_add_origin "$FM_HOME/projects/carryrank" "$TMP_ROOT/carryrank.git"
fm_git_init_commit "$FM_HOME/projects/lounge-card"
fm_git_add_origin "$FM_HOME/projects/lounge-card" "$TMP_ROOT/lounge.git"
printf '%s\n' 'carryrank 2' 'lounge-card 1' > "$FM_HOME/config/project-capacity"
cat > "$FM_HOME/data/backlog.md" <<'MD'
# Backlog
## Queued
- [ ] lounge-1 - Lounge task (repo: lounge-card, kind: ship)
- [ ] carry-1 - Carry task (repo: carryrank, kind: ship)
- [ ] held-1 - Held task (repo: carryrank, kind: ship, hold: approval, hold-kind: captain)
- [ ] blocked-1 - Blocked task blocked-by: missing (repo: carryrank, kind: ship)
- [ ] dots-1 - Dots task (repo: dots, kind: ship)
## Done
MD
fm_write_meta "$FM_HOME/state/active.meta" "project=$FM_HOME/projects/carryrank" 'kind=ship'
now=$(date +%s)
fixture "$now" "$((now+500000))" 100
REFILL="$ROOT/bin/fm-procevent-refill.sh"
"$REFILL" arm > "$TMP_ROOT/arm"
[ -f "$FM_HOME/state/procevent/quota-refill.source" ] || fail 'refill not registered'
"$REFILL" check > "$TMP_ROOT/result" || fail 'refill missing'
assert_contains "$(cat "$TMP_ROOT/result")" 'refill: 2 places open; next ready: carryrank: carry-1@' 'priority and occupancy'
assert_contains "$(cat "$TMP_ROOT/result")" 'Codex-to-Claude validation fallback: open' 'fallback visibility'
if grep -Eq 'held-1|blocked-1|dots-1' "$TMP_ROOT/result"; then fail 'ineligible work suggested'; fi
captured=$(fm_procevent_capture "$FM_HOME/state" quota-refill refill "$TMP_ROOT/result")
rc=0; "$REFILL" check > "$TMP_ROOT/repeat" || rc=$?
[ "$rc" = 75 ] && [ ! -s "$TMP_ROOT/repeat" ] || fail 'unchanged condition fired again'
printf '%s\n' 'pr=https://example.invalid/org/project/pull/1' >> "$FM_HOME/state/active.meta"
"$REFILL" notify
[ -s "$FM_HOME/state/quota-refill-trigger" ] || fail 'handoff notification absent'
"$REFILL" check > "$TMP_ROOT/result" || fail 'handoff did not refill'
assert_contains "$(cat "$TMP_ROOT/result")" 'refill: 3 places open' 'PR handoff frees place'
captured=$(fm_procevent_capture "$FM_HOME/state" quota-refill refill "$TMP_ROOT/result")
fixture "$now" "$((now+500000))" 0
rc=0; "$REFILL" check > "$TMP_ROOT/closed" || rc=$?
[ "$rc" = 75 ] && [ ! -s "$TMP_ROOT/closed" ] || fail 'closed gate woke'
fixture "$now" "$((now+500000))" 100
"$REFILL" check > "$TMP_ROOT/result" || fail 'reopened gate did not fire'
captured=$(fm_procevent_capture "$FM_HOME/state" quota-refill refill "$TMP_ROOT/result")
[ "$("$REFILL" classify "$captured")" = refill ] || fail 'captured result classification'
rc=0; "$REFILL" check > "$TMP_ROOT/repeat" || rc=$?
[ "$rc" = 75 ] || fail 'reopened episode repeated'
pass 'registered refill reports ready lanes once per transition and PR handoff frees capacity'

# Cleanup frees a place even without a PR; expired lanes and empty queues stay quiet.
fm_write_meta "$FM_HOME/state/another.meta" "project=$FM_HOME/projects/carryrank" 'kind=scout'
"$REFILL" check > "$TMP_ROOT/result" || fail 'occupancy transition did not fire'
captured=$(fm_procevent_capture "$FM_HOME/state" quota-refill refill "$TMP_ROOT/result")
mv "$FM_HOME/state/another.meta" "$TMP_ROOT/cleaned.meta"
"$REFILL" notify
"$REFILL" check > "$TMP_ROOT/result" || fail 'cleanup did not refill'
assert_contains "$(cat "$TMP_ROOT/result")" 'refill: 3 places open' 'cleanup capacity'
captured=$(fm_procevent_capture "$FM_HOME/state" quota-refill refill "$TMP_ROOT/result")
sed 's/2099-10-20/2000-01-01/' "$FM_HOME/config/quota-plan" > "$TMP_ROOT/expired"
mv "$TMP_ROOT/expired" "$FM_HOME/config/quota-plan"
"$REFILL" check > "$TMP_ROOT/result" || fail 'remaining lane did not refill'
assert_contains "$(cat "$TMP_ROOT/result")" 'refill: 1 places open; next ready: lounge-card:' 'expired priority'
if grep -q 'carry-1' "$TMP_ROOT/result"; then fail 'expired lane still suggested'; fi
printf '# Backlog\n## Queued\n' > "$FM_HOME/data/backlog.md"
rc=0; "$REFILL" check > "$TMP_ROOT/empty" || rc=$?
[ "$rc" = 75 ] && [ ! -s "$TMP_ROOT/empty" ] || fail 'empty queue woke'
pass 'cleanup frees capacity, dated lanes expire, empty queues do not wake'
