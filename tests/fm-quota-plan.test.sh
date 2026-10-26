#!/usr/bin/env bash
# Quota-plan public-library admission and real refill adapter regressions.
# Vendor JSON is fixture-backed because the combined Claude shape requires a local quota-axi build.
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
[ "$*" = "--all-accounts --json --max-age ${QUOTA_AXI_MAX_AGE:?}" ] || exit 2
printf 'read\n' >> "$FM_TEST_QUOTA_CALLS"
printf '%s\n' "$QUOTA_AXI_MAX_AGE" >> "$FM_TEST_QUOTA_CALLS.ages"
[ ! -e "$FM_TEST_QUOTA_FILE.fail" ] || exit 2
cat "$FM_TEST_QUOTA_FILE"
SH
chmod +x "$TMP_ROOT/fakebin/quota-axi"
export PATH="$TMP_ROOT/fakebin:$PATH"
plan() {
  printf '%s\n' 'reserve claude 15' 'reserve codex 0' 'lane carryrank until 2099-10-20' 'lane lounge-card' > "$FM_HOME/config/quota-plan"
  fm_quota_plan_load "$FM_HOME/config" || fail 'valid plan rejected'
}
# Times use the fractional Z and +00:00 forms the established quota-axi emits.
fixture() { # <now> <reset> <remaining>
  jq -n --argjson now "$1" --argjson reset "$2" --argjson left "$3" '
    def offset: todateiso8601 | sub("Z$"; ".617813+00:00");
    {generatedAt:($now|todateiso8601|sub("Z$"; ".437Z")),claudeCombined:[
      {scope:"all_models",window:"seven_day",remaining:$left,resetsAt:($reset|offset),
       pace:"ahead",burnMultiple:1,projectedLeftAtLaterReset:15,runway:"through_reset"}],
     claudeCombinedAccounts:[],providers:[{provider:"codex",state:{status:"fresh",stale:false},
       windows:[{id:"weekly",kind:"weekly",percentRemaining:$left,resetsAt:($reset|offset)}]}]}' > "$FM_TEST_QUOTA_FILE"
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
fm_quota_plan_verdict codex "$now" || fail 'codex offset-formatted weekly reset refused'
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
# Only the one documented shape is read; other spellings refuse, never guess.
for variant in '.snapshot.claudeCombined[0].remaining = "100%"' \
  '.snapshot.claudeCombined[0].scope = "all-models"' \
  '.snapshot.claudeCombined[0].window = {id:"seven_day"}' \
  '.snapshot.claudeCombined[0] |= (.resetAt = .resetsAt | del(.resetsAt))' \
  ".snapshot.claudeCombined[0].resetsAt = $((reset+604800))" \
  '.snapshot.claudeCombined += .snapshot.claudeCombined'; do
  fixture "$reset" "$((reset+604800))" 100
  jq "$variant" "$FM_QUOTA_PLAN_CACHE" > "$TMP_ROOT/variant"
  mv "$TMP_ROOT/variant" "$FM_QUOTA_PLAN_CACHE"
  if fm_quota_plan_verdict claude "$reset"; then fail "undocumented combined shape admitted: $variant"; fi
done
for variant in '.snapshot.providers[0].windows[0] |= (.effectivePercentRemaining = .percentRemaining | del(.percentRemaining))' \
  '.snapshot.providers[0].windows[0].kind = "seven_day"'; do
  fixture "$reset" "$((reset+604800))" 100
  jq "$variant" "$FM_QUOTA_PLAN_CACHE" > "$TMP_ROOT/variant"
  mv "$TMP_ROOT/variant" "$FM_QUOTA_PLAN_CACHE"
  if fm_quota_plan_verdict codex "$reset"; then fail "undocumented codex shape admitted: $variant"; fi
done
pass 'day boundaries, rollover, unused allowance, exact reserve line and one exact reader shape'

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
rm -f "$FM_HOME/state/quota-plan-snapshot.json"
fm_quota_plan_snapshot "$FM_HOME/state" "$now" || fail 'default shared-cache read'
[ "$(tail -1 "$FM_TEST_QUOTA_CALLS.ages")" = 60 ] || fail 'quota plan lost default reuse bound'
rm -f "$FM_HOME/state/quota-plan-snapshot.json"
QUOTA_AXI_MAX_AGE=2m fm_quota_plan_snapshot "$FM_HOME/state" "$now" || fail 'override shared-cache read'
[ "$(tail -1 "$FM_TEST_QUOTA_CALLS.ages")" = 2m ] || fail 'quota plan lost operator override'
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
fixture "$now" "$((now+500000))" 100
jq 'del(.snapshot.claudeCombined)' "$FM_QUOTA_PLAN_CACHE" > "$TMP_ROOT/missing"
mv "$TMP_ROOT/missing" "$FM_QUOTA_PLAN_CACHE"
out=$(fm_quota_plan_admit "$FM_HOME" "$FM_HOME/config" pi 0 ship 2>&1) || fail 'undeclared harness was not admitted unpaced'
assert_contains "$out" 'harness pi is not paced by config/quota-plan' 'unpaced harness diagnostic'
assert_absent "$FM_HOME/state/.quota-plan-admission.lock" 'unpaced harness took the admission lock'
pass 'stale outage refuses, admission lock serializes, next start refreshes, providers stay separate, undeclared harnesses run unpaced'

# The account picker and admission reader consume one captured launch decision.
fixture "$now" "$((now+500000))" 100
rm -f "$FM_QUOTA_PLAN_CACHE"
reads_before=$(wc -l < "$FM_TEST_QUOTA_CALLS" | tr -d ' ')
fm_worker_account_decision_start "$FM_HOME/config"
snapshot=$(fm_worker_account_snapshot "$FM_HOME/config") || fail 'account snapshot failed'
fm_quota_plan_snapshot "$FM_HOME/state" "$now" || fail 'quota plan could not share the launch snapshot'
fm_quota_plan_verdict claude "$now" || fail 'shared combined reading was not admitted'
assert_equals "$((reads_before + 1))" "$(wc -l < "$FM_TEST_QUOTA_CALLS" | tr -d ' ')" 'account selection and quota admission must share one vendor request'
fm_worker_account_decision_finish 0

# A standalone admission retains endpoint throttling and its retry measurement.
fixture "$now" "$((now+500000))" 100
jq --argjson now "$now" '
  .providers[0].account = "example" |
  .providers[0].state = {status:"stale",stale:true,retryAfter:"2099-10-25T18:00:00Z",refreshedAt:($now-120|todateiso8601)}' \
  "$FM_TEST_QUOTA_FILE" > "$TMP_ROOT/throttled"
mv "$TMP_ROOT/throttled" "$FM_TEST_QUOTA_FILE"
rm -f "$FM_QUOTA_PLAN_CACHE"
fm_quota_plan_snapshot "$FM_HOME/state" "$now" || fail 'throttled snapshot was not retained'
if fm_quota_plan_verdict codex "$now"; then fail 'stale rate-limited Codex row was admitted'; fi
assert_contains "$FM_QUOTA_PLAN_ERROR" 'quota endpoint rate limited until 2099-10-25T18:00:00Z, reading from 120s ago' 'quota plan refusal must name the endpoint retry and age'
assert_grep '"account":"example","retryAfter":"2099-10-25T18:00:00Z"' "$FM_HOME/state/.supervision-host.log" 'quota admission must record the exact retry measurement'
: > "$FM_HOME/state/.supervision-host.log"
fm_quota_plan_snapshot "$FM_HOME/state" "$now" || fail 'cached throttled snapshot was not retained'
assert_grep '"account":"example","retryAfter":"2099-10-25T18:00:00Z"' "$FM_HOME/state/.supervision-host.log" 'cached admission evidence must retain the retry measurement too'
fixture "$now" "$((now+500000))" 100
pass 'quota plan shares the launch snapshot and retains endpoint retry diagnostics and measurements'

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
# A busy admission lock is retried promptly, not consumed as a quiet sample.
fm_lock_try_acquire "$FM_HOME/state/.quota-plan-admission.lock" || fail 'could not hold admission lock'
rc=0; "$REFILL" check > "$TMP_ROOT/busy" || rc=$?
[ "$rc" = 73 ] && [ ! -s "$TMP_ROOT/busy" ] || fail "busy admission lock was not reported as busy: $rc"
"$REFILL" poll > "$TMP_ROOT/polled" &
poll_pid=$!
sleep 1
fm_lock_release "$FM_HOME/state/.quota-plan-admission.lock"
for _ in $(seq 40); do kill -0 "$poll_pid" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$poll_pid" 2>/dev/null; then kill "$poll_pid"; fail 'poll deferred a busy sample to the next interval'; fi
wait "$poll_pid" || fail 'poll did not report the retried refill'
assert_contains "$(cat "$TMP_ROOT/polled")" 'refill: 2 places open' 'retried poll refill'
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

# Without Linear configuration, refill ranks the existing intake/dispatch snapshots.
cp "$FM_HOME/data/backlog.md" "$TMP_ROOT/backlog-before-grid"
cat > "$FM_HOME/data/backlog.md" <<'MD'
# Backlog
## Queued
- [ ] deprioritize - Medium impact high cost (repo: carryrank, kind: ship)
  Loop: agent
  Loop finish: benchmark proves p95 under 300ms
  Linear priority: 3
  Linear estimate: 3
  Loop cycle: 2026-10-19
- [ ] small - Low impact low cost (repo: carryrank, kind: ship)
  Loop: agent
  Loop finish: script exits zero and never prints a key
  Linear priority: 4
  Linear estimate: 1
  Loop cycle: 2026-10-19
- [ ] quick - Medium impact low cost (repo: carryrank, kind: ship)
  Loop: agent
  Loop finish: pgTAP denies the expired invite
  Linear priority: 3
  Linear estimate: 1
  Loop cycle: 2026-10-19
- [ ] strong - High impact medium cost (repo: carryrank, kind: ship)
  Loop: agent-reviewed
  Linear priority: 2
  Linear estimate: 2
  Loop cycle: 2026-10-19
- [ ] security - Explicit high priority correction (repo: carryrank, kind: ship)
  Loop: agent
  Loop finish: Playwright proves rate limits
  Linear priority: 2
  Linear estimate: 1
  Loop cycle: 2026-10-19
- [ ] later-cycle - Urgent but next week (repo: carryrank, kind: ship)
  Loop: agent
  Loop finish: CI rejects the vulnerable package
  Linear priority: 1
  Linear estimate: 1
  Loop cycle: 2026-10-26
- [ ] no-check - Vague finish (repo: carryrank, kind: ship)
  Loop: agent
- [ ] human - Personal judgment (repo: carryrank, kind: ship)
  Loop: Christian
- [ ] milestone - Phone observation (repo: carryrank, kind: ship)
  Loop: milestones
## Done
MD
"$REFILL" check > "$TMP_ROOT/grid" || fail 'grid refill missing'
order=$(sed -n 's/^fingerprint: //p' "$TMP_ROOT/grid" | jq -r '.lanes[0].ready | map(.id) | join(",")')
assert_equals security,strong,quick,small,deprioritize "$order" 'cycle then grid order; Deprioritize last and correction wins'
if grep -Eq 'no-check@|human@|milestone@|later-cycle@' "$TMP_ROOT/grid"; then fail 'ineligible or later cycle suggested ahead of current cycle'; fi
# The next wake after a start offers the next ticket in the same sorted queue.
fm_write_meta "$FM_HOME/state/security.meta" "project=$FM_HOME/projects/carryrank" 'kind=ship'
"$REFILL" check > "$TMP_ROOT/next-grid" || fail 'next agent not offered'
assert_contains "$(cat "$TMP_ROOT/next-grid")" 'next ready: carryrank: strong@' 'next eligible agent in grid order'
mv "$FM_HOME/state/security.meta" "$TMP_ROOT/security-finished.meta"
cat > "$FM_HOME/data/backlog.md" <<'MD'
# Backlog
## Queued
- [ ] first - Earlier unclassified ticket with saved metadata (repo: carryrank, kind: ship)
  Loop cycle: 2026-10-26
  Loop sort: 90
  Linear priority: 4
  Linear estimate: 3
- [ ] second - Later unclassified ticket without metadata (repo: carryrank, kind: ship)
- [ ] third - Last unclassified ticket with earlier cycle (repo: carryrank, kind: ship)
  Loop cycle: 2026-10-19
  Loop sort: 1
  Linear priority: 1
  Linear estimate: 1
## Done
MD
"$REFILL" check > "$TMP_ROOT/unclassified" || fail 'unclassified refill missing'
order=$(sed -n 's/^fingerprint: //p' "$TMP_ROOT/unclassified" | jq -r '.lanes[0].ready | map(.id) | join(",")')
assert_equals first,second,third "$order" 'unclassified backlog order ignores all metadata sort keys'
mv "$TMP_ROOT/backlog-before-grid" "$FM_HOME/data/backlog.md"
pass 'refill advances in cycle/grid order, respects priority corrections and excludes human loops and agents without checks'

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
