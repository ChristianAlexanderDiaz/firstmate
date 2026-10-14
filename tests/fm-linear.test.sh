#!/usr/bin/env bash
# Linear sync through its event CLI and actual lifecycle producers. All network
# calls are stubbed; backlog mutations use tasks-axi against disposable homes.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-linear)
command -v jq >/dev/null || { echo 'skip: jq unavailable'; exit 0; }
command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi unavailable'; exit 0; }
TEAM=00000000-0000-4000-8000-000000000001
STARTED=00000000-0000-4000-8000-000000000002
DONE=00000000-0000-4000-8000-000000000003
TODO=00000000-0000-4000-8000-000000000005
LABEL=00000000-0000-4000-8000-000000000004
PR=https://github.com/example/sample/pull/7

make_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  cat > "$HOME_DIR/config/linear" <<CONFIG
project=sample|$TEAM
waiting_label=$LABEL
CONFIG
  FAKEBIN=$(fm_fakebin "$CASE")
  fm_test_fake_tmux_spawn "$FAKEBIN"
  fm_fake_exit0 "$FAKEBIN" treehouse no-mistakes
  cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LINEAR/forge-argv"
[ ! -f "$FM_TEST_LINEAR/forge-fail" ] || exit 1
case "$*" in *'--repo example/sample --hostname github.com --full'*) ;; *) exit 1 ;; esac
cat "$FM_TEST_LINEAR/pr-body"
SH
  cat > "$FAKEBIN/curl" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FM_TEST_LINEAR'])
argv = sys.argv[1:]
with (root / 'argv').open('a') as f:
    f.write(json.dumps(argv) + '\n')
header = sys.stdin.read()
assert argv[0] == '-q'
assert argv[argv.index('--header') + 1] == '@-'
assert argv[argv.index('--max-time') + 1] == '10'
assert header == 'Authorization: fake-secret-value\n'
assert 'fake-secret-value' not in json.dumps(argv)
assert 'FM_LINEAR_API_KEY' not in os.environ
payload = json.loads(argv[argv.index('--data-binary') + 1])
with (root / 'requests').open('a') as f:
    f.write(json.dumps(payload) + '\n')
if (root / 'slow').exists():
    time.sleep(30)
if (root / 'error').exists():
    print(json.dumps({'errors': [{'message': 'fake-secret-value'}]}))
    sys.exit(0)
if (root / 'http-error').exists():
    print('fake-secret-value', file=sys.stderr)
    sys.exit(22)
q, v = payload['query'], payload['variables']
team = '00000000-0000-4000-8000-000000000001'
started = '00000000-0000-4000-8000-000000000002'
done = '00000000-0000-4000-8000-000000000003'
todo = '00000000-0000-4000-8000-000000000005'
relationfile = root / 'relations.json'
relations = json.loads(relationfile.read_text()) if relationfile.exists() else []
issuefile = root / 'issues.json'
issues = json.loads(issuefile.read_text())
if q.startswith('query Teams'):
    states = [{'id': 'fallback', 'name': 'Working', 'type': 'started'},
              {'id': started, 'name': 'In Progress', 'type': 'started'},
              {'id': done, 'name': 'Done', 'type': 'completed'},
              {'id': todo, 'name': 'Todo', 'type': 'unstarted'}]
    if (root / 'fallback').exists():
        states = states[:1] + states[2:]
    data = {'teams': {'nodes': [{'id': team, 'key': 'ABC', 'states': {
        'nodes': states, 'pageInfo': {'hasNextPage': False}}}],
        'pageInfo': {'hasNextPage': False}}}
elif q.startswith('query Relations'):
    nodes = [dict(id=r['id'], type=r['type'], issue=next(i for i in issues if i['id'] == r['issueId']))
             for r in relations if r['relatedIssueId'] == v['id']]
    data = {'issue': {'inverseRelations': {'nodes': nodes, 'pageInfo': {'hasNextPage': False}}}}
elif q.startswith('mutation Block'):
    assert not any(r['id'] == v['input']['id'] for r in relations)
    relations.append(v['input'])
    data = {'issueRelationCreate': {'success': True}}
elif q.startswith('mutation Unblock'):
    relations = [r for r in relations if r['id'] != v['id']]
    data = {'issueRelationDelete': {'success': True}}
elif q.startswith('mutation Comment'):
    data = {'commentCreate': {'success': True}}
elif q.startswith('query CreatedIssue'):
    data = {'issues': {'nodes': [i for i in issues if i['id'] == v['id']]}}
elif q.startswith('query Issue'):
    data = {'issue': next((i for i in issues if i['identifier'] == v['id'] or i.get('alias') == v['id']), None)}
elif q.startswith('mutation CreateIssue'):
    value = v['input']
    assert not any(i['id'] == value['id'] for i in issues), 'duplicate create'
    issue = {'id': value['id'], 'identifier': 'ABC-101', 'team': {'id': team},
             'state': {'id': value['stateId'], 'type': 'started'}, 'labels': ['unrelated']}
    issues.append(issue)
    data = {'issueCreate': {'success': True, 'issue': issue}}
elif q.startswith('mutation UpdateIssue'):
    issue = next(i for i in issues if i['id'] == v['id'])
    assert issue['state']['type'] != 'triage'
    value = v['input']
    assert set(value) <= {'stateId', 'addedLabelIds', 'removedLabelIds'}
    if 'stateId' in value:
        issue['state'] = {'id': value['stateId'], 'type': 'completed' if value['stateId'] == done else 'unstarted' if value['stateId'] == todo else 'started'}
    issue['labels'] = sorted(set(issue.get('labels', []) + value.get('addedLabelIds', [])) - set(value.get('removedLabelIds', [])))
    data = {'issueUpdate': {'success': not (root / 'mutation-fail').exists()}}
elif q.startswith('mutation AttachPR'):
    data = {'attachmentCreate': {'success': True}}
else:
    raise AssertionError(q)
issuefile.write_text(json.dumps(issues))
relationfile.write_text(json.dumps(relations))
if (root / 'lost-create').exists() and q.startswith('mutation CreateIssue'):
    sys.exit(28)
print(json.dumps({'data': data}))
PY
  chmod +x "$FAKEBIN/curl" "$FAKEBIN/gh-axi"
  printf '[]\n' > "$CASE/issues.json"
  : > "$CASE/requests"
  : > "$CASE/argv"
  : > "$CASE/pr-body"
  TASK=work
  tasks add "$TASK" 'Sample work' --repo sample --kind ship --body 'Original body' >/dev/null
}

tasks() { (cd "$HOME_DIR" && tasks-axi "$@"); }
run() {
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_LINEAR_API_KEY=fake-secret-value \
    FM_TEST_LINEAR="$CASE" PATH="$FAKEBIN:$PATH" "$@"
}
sync_event() { run bash "$ROOT/bin/fm-linear-lib.sh" "$@"; }
seed_issue() {
  jq -n --arg type "${1:-unstarted}" --arg team "$TEAM" --arg started "$STARTED" \
    '[{id:"00000000-0000-4000-8000-000000000010",identifier:"ABC-42",team:{id:$team},
       state:{id:(if $type == "started" then $started else "old" end),type:$type},labels:["unrelated"]}]' > "$CASE/issues.json"
}
mutations() { jq -sr '[.[] | select(.query | startswith("mutation"))] | length' "$CASE/requests"; }

make_case create
sync_event spawn "$TASK"
assert_equals 1 "$(jq length "$CASE/issues.json")" 'spawn creates one issue'
assert_contains "$(tasks show "$TASK" --full)" 'Linear issue: ABC-101' 'created linkage recorded'
sync_event spawn "$TASK"
assert_equals 1 "$(jq length "$CASE/issues.json")" 'spawn retry reuses linkage'
sync_event merge "$TASK" "$PR"
assert_equals "$DONE" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'merge completes issue'
assert_equals "$PR" "$(jq -sr '[.[] | select(.query | startswith("mutation AttachPR"))][0].variables.input.url' "$CASE/requests")" 'merge attaches PR URL'
assert_not_contains "$(cat "$CASE/argv")" fake-secret-value 'key absent from curl argv'
pass 'spawn creates, persists, reuses; merge completes and attaches'

make_case lost-response
touch "$CASE/lost-create"
out=$(sync_event spawn "$TASK" 2>&1)
assert_contains "$out" 'sync failed' 'lost response is best effort'
rm "$CASE/lost-create"
sync_event spawn "$TASK"
assert_equals 1 "$(jq length "$CASE/issues.json")" 'ambiguous create retry finds stable UUID'
assert_contains "$(tasks show "$TASK" --full)" 'Linear issue: ABC-101' 'recovered linkage recorded'
pass 'ambiguous creation is recovered without duplicate tickets'

for source in task title body pr; do
  make_case "link-$source"
  seed_issue
  case "$source" in
    task) TASK=fix-ABC-42-now; tasks add "$TASK" 'Fix issue' --repo sample --kind ship >/dev/null ;;
    title) tasks update "$TASK" --title 'Fix ABC-42' >/dev/null ;;
    body) tasks update "$TASK" --body 'Issue ABC-42 needs work' >/dev/null ;;
    pr) printf 'pull_request:\n  body: "Fixes\\nABC-42"\n' > "$CASE/pr-body" ;;
  esac
  sync_event merge "$TASK" "$PR"
  assert_equals "$DONE" "$(jq -r '.[0].state.id' "$CASE/issues.json")" "$source linkage"
  assert_contains "$(tasks show "$TASK" --full)" 'Linear issue: ABC-42' "$source persists linkage"
done
pass 'task id, title, body and PR linkage use mapped team keys'

make_case ambiguous
seed_issue
tasks update "$TASK" --body 'ABC-42 and ABC-43' >/dev/null
out=$(sync_event spawn "$TASK" 2>&1)
assert_contains "$out" ambiguous 'multiple mapped identifiers refuse'
assert_equals 0 "$(mutations)" 'ambiguous linkage never mutates'
pass 'ambiguous linkage is safe'

make_case persisted
seed_issue
tasks update "$TASK" --body 'Other reference ABC-43

Linear issue: ABC-42' >/dev/null
sync_event spawn "$TASK"
assert_equals "$STARTED" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'saved linkage takes priority'
make_case identifier-change
seed_issue
jq '.[0].alias="ABC-41"' "$CASE/issues.json" > "$CASE/new"
mv "$CASE/new" "$CASE/issues.json"
tasks update "$TASK" --body 'Keep this note.

Linear issue: ABC-41' >/dev/null
sync_event spawn "$TASK"
assert_contains "$(tasks show "$TASK" --full)" 'Linear issue: ABC-42' 'canonical identifier is refreshed'
assert_not_contains "$(tasks show "$TASK" --full)" 'Linear issue: ABC-41' 'obsolete marker is replaced'
assert_contains "$(tasks show "$TASK" --full)" 'Keep this note.' 'refresh preserves other notes'
sync_event merge "$TASK" "$PR"
assert_equals "$DONE" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'refreshed linkage remains usable'
pass 'a changed identifier replaces the saved marker without losing notes'

make_case boundary
seed_issue
tasks update "$TASK" --body 'Not an identifier: XABC-42 or ABC-42suffix; reference ABC-42.' >/dev/null
sync_event spawn "$TASK"
assert_equals "$STARTED" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'identifier token boundaries'
make_case unknown-team
tasks update "$TASK" --body 'XYZ-42 is outside configured teams' >/dev/null
sync_event spawn "$TASK"
assert_equals ABC-101 "$(jq -r '.[0].identifier' "$CASE/issues.json")" 'unmapped key never links'
make_case failed-forge
touch "$CASE/forge-fail"
sync_event merge "$TASK" "$PR" 2>/dev/null
assert_equals 0 "$(mutations)" 'failed PR read never creates'
make_case malformed-config
printf 'exclude_task work\n' >> "$HOME_DIR/config/linear"
sync_event spawn "$TASK" 2>/dev/null
assert_equals 0 "$(wc -l < "$CASE/requests" | tr -d ' ')" 'malformed exclusion fails closed'
pass 'saved linkage, token boundaries and invalid input are handled safely'

for event in spawn merge; do
  make_case "incidental-$event"
  seed_issue completed
  if [ "$event" = spawn ]; then
    tasks update "$TASK" --body 'Regression from ABC-42' >/dev/null
  else
    printf 'pull_request:\n  body: "Related: ABC-42"\n' > "$CASE/pr-body"
  fi
  sync_event "$event" "$TASK" "$PR" 2>/dev/null
  assert_equals completed "$(jq -r '.[0].state.type' "$CASE/issues.json")" "$event leaves incidentally mentioned finished work"
  assert_equals 0 "$(mutations)" "$event incidental mention never mutates"
  assert_not_contains "$(tasks show "$TASK" --full)" 'Linear issue:' "$event incidental mention is not saved"
done
make_case saved-finished
seed_issue completed
tasks update "$TASK" --body 'Linear issue: ABC-42' >/dev/null
sync_event spawn "$TASK"
assert_equals "$STARTED" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'saved linkage may restart finished work'
make_case pr-without-keyword
seed_issue
printf 'pull_request:\n  body: "See ABC-42"\n' > "$CASE/pr-body"
sync_event merge "$TASK" "$PR" 2>/dev/null
assert_equals 0 "$(mutations)" 'PR mention without a closing keyword never links'
pass 'finished issues move only through saved linkage; PR bodies link only through closing keywords'

make_case hold
seed_issue
tasks update "$TASK" --body 'Issue ABC-42' >/dev/null
run bash "$ROOT/bin/fm-captain-hold.sh" hold "$TASK" --reason 'Choose an option' >/dev/null
assert_equals true "$(jq --arg label "$LABEL" '.[0].labels | index($label) != null' "$CASE/issues.json")" 'real hold adds label'
printf 'Proceed.\n' > "$CASE/answer"
run bash "$ROOT/bin/fm-captain-hold.sh" answer "$TASK" --decision-file "$CASE/answer" --release >/dev/null
assert_equals '["unrelated"]' "$(jq -c '.[0].labels' "$CASE/issues.json")" 'release removes only waiting label'
run bash "$ROOT/bin/fm-captain-hold.sh" hold "$TASK" --reason 'Choose again' >/dev/null
printf 'Finish this call.\n' > "$CASE/answer"
run bash "$ROOT/bin/fm-captain-hold.sh" answer "$TASK" --decision-file "$CASE/answer" >/dev/null
assert_equals '["unrelated"]' "$(jq -c '.[0].labels' "$CASE/issues.json")" 'answer removes label'
assert_equals unstarted "$(jq -r '.[0].state.type' "$CASE/issues.json")" 'holds never change issue state'
pass 'real hold, release and answer preserve unrelated labels and workflow state'

for event in spawn merge hold release idle teardown dependencies; do
  make_case "triage-$event"
  seed_issue triage
  tasks update "$TASK" --body 'ABC-42' >/dev/null
  out=$(sync_event "$event" "$TASK" "$PR" 2>&1)
  assert_contains "$out" triage 'triage diagnostic'
  assert_equals 0 "$(mutations)" 'triage never mutates'
done
pass 'every event leaves Triage untouched'

for skip in pattern scout unmapped config key; do
  make_case "skip-$skip"
  case "$skip" in
    pattern) printf 'exclude_task=w*\n' >> "$HOME_DIR/config/linear" ;;
    scout) tasks update "$TASK" --kind scout >/dev/null ;;
    unmapped) tasks update "$TASK" --repo other >/dev/null ;;
    config) rm "$HOME_DIR/config/linear" ;;
  esac
  if [ "$skip" = key ]; then
    out=$(run env -u FM_LINEAR_API_KEY bash "$ROOT/bin/fm-linear-lib.sh" spawn "$TASK" 2>&1)
  else
    out=$(sync_event spawn "$TASK" 2>&1)
  fi
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'one quiet diagnostic'
  assert_equals 0 "$(wc -l < "$CASE/requests" | tr -d ' ')" "$skip makes no API call"
done
pass 'task exclusions, scouts, missing mapping/config/key skip before API access'

make_case no-config-lifecycle
rm "$HOME_DIR/config/linear"
tasks add prerequisite 'Prerequisite' --repo sample --kind ship >/dev/null
out=$(run bash "$ROOT/bin/fm-tasks-axi.sh" block "$TASK" --by prerequisite 2>&1)
assert_not_contains "$out" 'linear:' 'lifecycle command without config is silent'
pass 'a home without config/linear sees no Linear output from lifecycle commands'

make_case key-command
printf 'fake-secret-value\n' > "$CASE/secret"
printf 'key_command=cat "%s"\n' "$CASE/secret" >> "$HOME_DIR/config/linear"
out=$(run env -u FM_LINEAR_API_KEY bash -x "$ROOT/bin/fm-linear-lib.sh" spawn "$TASK" 2>&1)
assert_equals 1 "$(jq length "$CASE/issues.json")" 'key command works'
assert_not_contains "$out$(cat "$CASE/argv")" fake-secret-value 'key absent from trace and argv'
pass 'key command supports secure header stdin and tracing does not disclose it'

for error in error http-error mutation-fail; do
  make_case "$error"
  touch "$CASE/$error"
  out=$(sync_event spawn "$TASK" 2>&1)
  assert_contains "$out" 'sync failed' 'API errors do not fail lifecycle hook'
  assert_not_contains "$out" fake-secret-value 'errors never disclose response/credentials'
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'one failure diagnostic'
done
pass 'GraphQL, HTTP and unsuccessful mutations are tolerated without leaking errors'

make_case fallback
touch "$CASE/fallback"
sync_event spawn "$TASK"
assert_equals fallback "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'fallback started state'
make_case retired-state-directive
printf 'state=%s|started|fallback\n' "$TEAM" >> "$HOME_DIR/config/linear"
sync_event spawn "$TASK" 2>/dev/null
assert_equals 0 "$(wc -l < "$CASE/requests" | tr -d ' ')" 'unknown state directive fails closed'
pass 'state mapping prefers names and falls back by type'

for origin in self poll; do
  make_case "merge-$origin"
  seed_issue
  tasks update "$TASK" --body 'ABC-42' >/dev/null
  run bash -c '
    . "$1/bin/fm-merge-outcome-lib.sh"
    if [ "$4" = poll ]; then
      . "$1/bin/fm-wake-lib.sh"
      lock="$FM_STATE_OVERRIDE/.control-$2.lock"
      fm_lock_acquire_wait "$lock"
      trap '\''fm_lock_release "$lock"'\'' EXIT
      export FM_LINEAR_CONTROL_LOCK_HELD=1
    fi
    fm_merge_outcome_report "$FM_HOME" "$FM_STATE_OVERRIDE" "$2" "$3" "$4"
  ' \
    _ "$ROOT" "$TASK" "$PR" "$origin"
  assert_equals "$DONE" "$(jq -r '.[0].state.id' "$CASE/issues.json")" "$origin recorded merge syncs"
done
pass 'both performed and externally observed merge outcomes sync'

make_case watcher-merge
seed_issue
tasks update "$TASK" --body 'ABC-42' >/dev/null
fm_test_track_watcher_state "$HOME_DIR/state"
fm_write_meta "$HOME_DIR/state/$TASK.meta" "window=fm-$TASK" \
  "worktree=$CASE/wt" 'kind=ship' "pr=$PR"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'pr view https://github.com/example/sample/pull/7 --json state -q .state' ] || exit 1
printf 'MERGED\n'
SH
chmod +x "$FAKEBIN/gh"
run bash -c '
  . "$1/bin/fm-pr-lib.sh"
  fm_pr_poll_prepare "$FM_STATE_OVERRIDE" "$2" github "$3" github.com example/sample 7 "$1/bin/fm-pr-poll.sh"
  fm_pr_poll_publish_prepared
' _ "$ROOT" "$TASK" "$PR"
# shellcheck disable=SC2016 # The child shell expands its own positional arguments.
run env FM_CHECK_INTERVAL=0 FM_POLL=0.1 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  bash -c '. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 30 bash "$1/bin/fm-watch.sh"' _ "$ROOT" \
  > "$CASE/watch.out" 2> "$CASE/watch.err"
assert_equals "$DONE" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'watcher syncs while holding its control lock'
assert_not_contains "$(cat "$CASE/watch.err")" 'timed out' 'watcher does not deadlock with Linear sync'
pass 'real watcher syncs an externally merged PR under its existing control lock'

for failure in no landed zero-work yes; do
  make_case "real-spawn-$failure"
  fm_test_spawn_home "$HOME_DIR" claude
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  fm_test_spawn_brief "$HOME_DIR" "$TASK" 'Exercise automatic issue sync.'
  fm_git_worktree "$CASE/sample" "$CASE/wt" "fm/$TASK"
  [ "$failure" != yes ] || touch "$CASE/error"
  out=$(run env FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE/wt" TMUX=fake,1,0 \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    bash "$ROOT/bin/fm-spawn.sh" "$TASK" "$CASE/sample" --mode direct-PR --yolo off 2>&1) \
    || fail "real spawn failed: $out"
  assert_contains "$out" 'spawned work' 'spawn succeeds after sync attempt'
  if [ "$failure" = no ]; then
    assert_equals 1 "$(jq length "$CASE/issues.json")" 'actual ship spawn creates ticket'
    printf 'unlanded change\n' > "$CASE/wt/change"
    git -C "$CASE/wt" add change
    git -C "$CASE/wt" -c user.name=Test -c user.email=test@example.invalid commit -qm 'Test change'
    out=$(run env FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE/wt" TMUX=fake,1,0 \
      bash "$ROOT/bin/fm-teardown.sh" "$TASK" --force 2>&1) || fail "real teardown failed: $out"
    assert_equals "$TODO" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'successful unlanded teardown queues issue'
  elif [ "$failure" = landed ]; then
    # Harness leftovers are not unlanded work under teardown's own rule, and
    # pushed commits are on a remote.
    printf 'pushed change\n' > "$CASE/wt/change"
    git -C "$CASE/wt" add change
    git -C "$CASE/wt" -c user.name=Test -c user.email=test@example.invalid commit -qm 'Test change'
    git -C "$CASE/wt" push -q origin "HEAD:refs/heads/fm/$TASK"
    mkdir -p "$CASE/wt/.claude"
    printf '{}\n' > "$CASE/wt/.claude/settings.local.json"
    out=$(run env FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE/wt" TMUX=fake,1,0 \
      bash "$ROOT/bin/fm-teardown.sh" "$TASK" --force 2>&1) || fail "real teardown failed: $out"
    assert_equals "$STARTED" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'forced teardown of landed work keeps status'
  elif [ "$failure" = zero-work ]; then
    out=$(run env FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE/wt" TMUX=fake,1,0 \
      bash "$ROOT/bin/fm-teardown.sh" "$TASK" 2>&1) || fail "real teardown failed: $out"
    assert_equals "$TODO" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'teardown of a ship without commits queues issue'
    assert_equals 1 "$(jq -s '[.[] | select(.query | startswith("mutation Comment"))] | length' "$CASE/requests")" 'zero-work teardown comments once'
  else
    assert_contains "$out" 'sync failed' 'actual spawn tolerates API failure'
  fi
done
pass 'real ship spawn calls sync after dispatch and survives API failure; teardown demotes only unlanded work'


for event in idle teardown; do
  make_case "$event"
  seed_issue started
  tasks update "$TASK" --body 'Linear issue: ABC-42' >/dev/null
  sync_event "$event" "$TASK"
  assert_equals "$TODO" "$(jq -r '.[0].state.id' "$CASE/issues.json")" "$event queues inactive work"
  assert_equals 1 "$(jq -s '[.[] | select(.query | startswith("mutation Comment"))] | length' "$CASE/requests")" 'reason comment'
  before=$(mutations)
  sync_event "$event" "$TASK"
  assert_equals "$before" "$(mutations)" 'repeat does not comment again'
  seed_issue completed
  sync_event "$event" "$TASK"
  assert_equals completed "$(jq -r '.[0].state.type' "$CASE/issues.json")" 'completed work stays completed'
done
pass 'inactive and unlanded work returns to Todo with one reason; repeats and completed issues are safe'

for guard in review held; do
  make_case "keep-$guard"
  seed_issue started
  tasks update "$TASK" --body 'Linear issue: ABC-42' >/dev/null
  if [ "$guard" = review ]; then
    jq '.[0].state.id="review"' "$CASE/issues.json" > "$CASE/new"
    mv "$CASE/new" "$CASE/issues.json"
  else
    run bash "$ROOT/bin/fm-captain-hold.sh" hold "$TASK" --reason 'Choose an option' >/dev/null
  fi
  for event in idle teardown; do
    sync_event "$event" "$TASK"
    assert_equals started "$(jq -r '.[0].state.type' "$CASE/issues.json")" "$guard issue survives $event"
  done
  assert_equals 0 "$(jq -s '[.[] | select(.query | startswith("mutation Comment"))] | length' "$CASE/requests")" "$guard issue gets no reason comment"
done
pass 'other started states and captain-held work keep their status'

make_case dependencies
seed_issue started
tasks update "$TASK" --body 'Linear issue: ABC-42' >/dev/null
tasks add prerequisite 'ABC-43 prerequisite' --repo sample --kind ship >/dev/null
jq '. + [.[0] | .id="00000000-0000-4000-8000-000000000011" | .identifier="ABC-43"]' "$CASE/issues.json" > "$CASE/new"
mv "$CASE/new" "$CASE/issues.json"
run bash "$ROOT/bin/fm-tasks-axi.sh" block "$TASK" --by prerequisite >/dev/null
assert_equals 1 "$(jq length "$CASE/relations.json")" 'real backlog block creates relation'
assert_equals '00000000-0000-4000-8000-000000000011' "$(jq -r '.[0].issueId' "$CASE/relations.json")" 'blocker is the source'
assert_equals '00000000-0000-4000-8000-000000000010' "$(jq -r '.[0].relatedIssueId' "$CASE/relations.json")" 'dependent is the target'
run bash "$ROOT/bin/fm-tasks-axi.sh" block "$TASK" --by prerequisite >/dev/null
assert_equals 1 "$(jq length "$CASE/relations.json")" 'repeat block is idempotent'
run bash "$ROOT/bin/fm-tasks-axi.sh" unblock "$TASK" --by prerequisite >/dev/null
assert_equals 0 "$(jq length "$CASE/relations.json")" 'explicit unblock removes owned relation'
run bash "$ROOT/bin/fm-tasks-axi.sh" block "$TASK" --by prerequisite >/dev/null
tasks "done" prerequisite >/dev/null
sync_event tick
assert_equals 0 "$(jq length "$CASE/relations.json")" 'heartbeat removes dependency cleared by completion'
# A manually authored relation is outside this integration's ownership.
printf '[{"id":"manual","type":"blocks","issueId":"00000000-0000-4000-8000-000000000011","relatedIssueId":"00000000-0000-4000-8000-000000000010"}]' > "$CASE/relations.json"
tasks reopen prerequisite >/dev/null
run bash "$ROOT/bin/fm-tasks-axi.sh" block "$TASK" --by prerequisite >/dev/null
run bash "$ROOT/bin/fm-tasks-axi.sh" unblock "$TASK" --by prerequisite >/dev/null
assert_equals manual "$(jq -r '.[0].id' "$CASE/relations.json")" 'unrelated relation is preserved'
assert_equals started "$(jq -r '.[0].state.type' "$CASE/issues.json")" 'dependencies leave workflow state unchanged'
pass 'real block/unblock and dependency completion sync directional owned relations without changing status'


for guard in triage unmapped unlinked; do
  make_case "dependency-$guard"
  seed_issue started
  tasks update "$TASK" --body 'Linear issue: ABC-42' >/dev/null
  tasks add prerequisite 'ABC-43 prerequisite' --repo sample --kind ship >/dev/null
  jq '. + [.[0] | .id="00000000-0000-4000-8000-000000000011" | .identifier="ABC-43"]' "$CASE/issues.json" > "$CASE/new"
  mv "$CASE/new" "$CASE/issues.json"
  case "$guard" in
    triage)
      jq '.[1].state.type="triage"' "$CASE/issues.json" > "$CASE/new"
      mv "$CASE/new" "$CASE/issues.json"
      ;;
    unmapped) tasks update prerequisite --repo private-sample >/dev/null ;;
    unlinked) tasks update prerequisite --title 'Unlinked prerequisite' >/dev/null ;;
  esac
  run bash "$ROOT/bin/fm-tasks-axi.sh" block "$TASK" --by prerequisite >/dev/null
  assert_equals 0 "$(mutations)" "$guard dependency never mutates Linear"
done
pass 'Triage, unmapped and unlinked dependencies never mutate Linear'

make_case periodic-idle
seed_issue started
tasks update "$TASK" --body 'Linear issue: ABC-42' >/dev/null
fm_write_meta "$HOME_DIR/state/$TASK.meta" 'kind=ship' 'backend=tmux' 'window=fm-work' 'harness=claude' 'spawn_gen=example'
# A sorted-earlier non-ship record must not consume the heartbeat.
fm_write_meta "$HOME_DIR/state/aaa-scout.meta" 'kind=scout' 'backend=tmux' 'window=fm-aaa-scout'
printf 'example\n' > "$HOME_DIR/state/$TASK.busy-gen"
printf 'v1 gen=example seq=1 state=idle source=claude-hook event=Stop ts=1\n' > "$HOME_DIR/state/$TASK.busy-state"
sync_event tick
assert_equals started "$(jq -r '.[0].state.type' "$CASE/issues.json")" 'first idle observation waits a day'
[ -f "$HOME_DIR/state/$TASK.linear-idle" ] || fail 'idle observation missing'
# Age only the observed idle interval; the classifier still reads real fixture records.
{ head -1 "$HOME_DIR/state/$TASK.linear-idle"; echo 1; } > "$CASE/idle"
mv "$CASE/idle" "$HOME_DIR/state/$TASK.linear-idle"
fm_test_track_watcher_state "$HOME_DIR/state"
# Exercise the actual heartbeat hook, bounded even when there is nothing to wake.
watch_rc=0
# shellcheck disable=SC2016 # The child expands its own positional arguments.
run env FM_HEARTBEAT=0 FM_HEARTBEAT_MAX=0 FM_POLL=0.1 FM_CHECK_INTERVAL=999999 \
  bash -c '. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 15 bash "$1/bin/fm-watch.sh"' _ "$ROOT" \
  > "$CASE/idle-watch.out" 2> "$CASE/idle-watch.err" || watch_rc=$?
case "$watch_rc" in 0|124|137) ;; *) fail 'idle heartbeat watcher failed' ;; esac
assert_equals "$TODO" "$(jq -r '.[0].state.id' "$CASE/issues.json")" 'day-old idle is returned to Todo'
seed_issue started
printf 'v1 gen=example seq=2 state=busy source=claude-hook event=UserPromptSubmit ts=2\n' > "$HOME_DIR/state/$TASK.busy-state"
sync_event tick
assert_equals started "$(jq -r '.[0].state.type' "$CASE/issues.json")" 'busy worker stays started'
[ ! -e "$HOME_DIR/state/$TASK.linear-idle" ] || fail 'busy activity did not reset idle interval'
printf 'v1 gen=wrong seq=2 state=idle source=claude-hook event=Stop ts=2\n' > "$HOME_DIR/state/$TASK.busy-state"
sync_event tick
[ ! -e "$HOME_DIR/state/$TASK.linear-idle" ] || fail 'unknown state counted as idle'
printf 'v1 gen=example seq=3 state=idle source=claude-hook event=Stop ts=3\n' > "$HOME_DIR/state/$TASK.busy-state"
for skip in 'harness=grok' "pr=$PR"; do
  fm_write_meta "$HOME_DIR/state/$TASK.meta" 'kind=ship' 'backend=tmux' 'window=fm-work' 'harness=claude' 'spawn_gen=example' "$skip"
  sync_event tick
  [ ! -e "$HOME_DIR/state/$TASK.linear-idle" ] || fail "$skip counted toward idle"
done
pass 'periodic semantic idle check requires a full day and resets on activity, unknown state, hookless harness or recorded PR'

make_case heartbeat-quiet
printf 'exclude_task=private-*\n' >> "$HOME_DIR/config/linear"
tasks add private-work 'Private work' --repo sample --kind ship >/dev/null
fm_write_meta "$HOME_DIR/state/private-work.meta" 'kind=ship' 'backend=tmux' 'window=fm-private-work' 'harness=claude' 'spawn_gen=example'
touch "$HOME_DIR/state/gone.linear-dependencies"
out=$(sync_event tick 2>&1)
assert_equals '' "$out" 'heartbeat skips excluded work quietly'
[ ! -e "$HOME_DIR/state/gone.linear-dependencies" ] || fail 'dependency record for a removed task was kept'
rm -f "$HOME_DIR/state/.linear-cursor"
touch "$HOME_DIR/state/$TASK.linear-dependencies" "$CASE/slow"
sync_event tick 2>/dev/null
assert_equals "$TASK" "$(cat "$HOME_DIR/state/.linear-cursor")" 'timed-out task does not hold the rotation'
pass 'heartbeat is quiet for expected skips, retires orphaned records, and moves past a timed-out task'

make_case heartbeat-lock
fm_write_meta "$HOME_DIR/state/$TASK.meta" 'kind=ship' 'backend=tmux' 'window=fm-work' 'harness=claude' 'spawn_gen=example'
# shellcheck disable=SC2016 # The child expands its own positional arguments.
run bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2"; touch "$3"; exec sleep 30' \
  _ "$ROOT" "$HOME_DIR/state/.control-$TASK.lock" "$CASE/locked" &
holder=$!
until [ -e "$CASE/locked" ]; do sleep 0.1; done
before=$SECONDS
out=$(sync_event tick 2>&1)
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
assert_equals '' "$out" 'heartbeat with nothing due ignores a held lifecycle lock'
[ "$((SECONDS - before))" -lt 5 ] || fail 'heartbeat waited on a held lifecycle lock'
pass 'heartbeat takes the lifecycle lock only when a task has work due'

make_case timeout
touch "$CASE/slow"
before=$SECONDS
out=$(sync_event spawn "$TASK" 2>&1)
assert_contains "$out" 'timed out' 'whole event timeout'
[ "$((SECONDS - before))" -le 15 ] || fail 'sync exceeded whole-event bound'
pass 'hung API is bounded and cannot fail the lifecycle'

printf '\nAll Linear sync tests passed.\n'
