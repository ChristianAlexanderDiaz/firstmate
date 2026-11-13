#!/usr/bin/env bash
# Named-lab presentation retirement, preservation, refusal and relaunch.
# FM_PRESENTATION_STUB=1 uses a recording CLI and private tmux, never Herdr.
# FM_PRESENTATION_BASELINE_ROOT optionally measures a baseline watcher first.
# FM_PRESENTATION_PROOF_DIR retains raw output and preservation snapshots.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ "${FM_PRESENTATION_STUB:-0}" = 1 ] || command -v herdr >/dev/null || { echo 'skip: herdr missing'; exit 0; }
command -v jq >/dev/null || { echo 'skip: jq missing'; exit 0; }
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
TMP_ROOT=$(mktemp -d)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/transport"
AGENTBIN="$TMP_ROOT/agentbin"
mkdir -p "$FAKEBIN" "$AGENTBIN"
HERDR_ORIGINAL_PATH="$AGENTBIN:$PATH"
if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
  HERDR_LAB_SESSION=fixture-presentation
else
  HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name presentation-close)
fi
export HERDR_LAB_HELPER HERDR_ORIGINAL_PATH HERDR_LAB_SESSION
unset TMUX TMUX_PANE HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH \
  FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
  FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
export SHELL=/bin/bash
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
    [ ! -f "$FM_HERDR_FIXTURE/calls.jsonl" ] || cp "$FM_HERDR_FIXTURE/calls.jsonl" "$PROOF/herdr-calls.jsonl"
    cp -R "$HOME_DIR/state" "$PROOF/final-state"
    [ -z "${TMUX_TMPDIR:-}" ] || "$FM_FIXTURE_TMUX" -L "$FM_FIXTURE_SOCKET" kill-server 2>/dev/null || rc=1
  else
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fi
  "$LAB_HOME_HELPER" teardown "$HOME_DIR" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null
PROOF=${FM_PRESENTATION_PROOF_DIR:-$TMP_ROOT/proof}
mkdir -p "$PROOF"
if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
  FM_FIXTURE_TMUX=$(command -v tmux)
  TMUX_TMPDIR=$("$LAB_HOME_HELPER" tmux-dir "$HOME_DIR")
  FM_HERDR_FIXTURE="$TMP_ROOT/fixture"
  FM_FIXTURE_SOCKET=presentation
  FM_PRESENTATION_FIXTURE="$ROOT/tests/herdr-presentation-fixture.py"
  export FM_PRESENTATION_STUB FM_FIXTURE_TMUX TMUX_TMPDIR FM_HERDR_FIXTURE FM_FIXTURE_SOCKET FM_PRESENTATION_FIXTURE
  mkdir -p "$FM_HERDR_FIXTURE"
  printf '{"next":1,"tabs":[],"workspaces":[]}\n' > "$FM_HERDR_FIXTURE/state.json"
fi
# Only a process stand-in, not a claim that a real model completed work.
cat > "$AGENTBIN/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'codex-cli 0.0.0'; exit; fi
printf 'proceeded\n' > "$FM_TASK_INBOX/proceeded"
if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
  python3 "$FM_PRESENTATION_FIXTURE" pane report-agent "$HERDR_PANE_ID" --source fixture --agent codex --state working --session "$HERDR_LAB_SESSION" >/dev/null
else
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
    pane report-agent "$HERDR_PANE_ID" --source fixture --agent codex --state working >/dev/null
fi
exec -a codex /bin/sleep 300
SH
cat > "$AGENTBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$AGENTBIN/"*
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
last=$((${#args[@]}-1)); flag=$((last-1))
if [ "$flag" -ge 0 ] && [ "${args[$flag]}" = --session ]; then
  [ "${args[$last]}" = "$HERDR_LAB_SESSION" ] || exit 9
  unset 'args[last]' 'args[flag]'
fi
for arg in "${args[@]}"; do case "$arg" in --session|--session=*) exit 9 ;; esac; done
# Only the fixture launch substitutes its inert executable, even if a user's
# interactive shell startup reset PATH. The actual source file is unchanged.
if [ "${args[0]:-}" = pane ] && [ "${args[1]:-}" = send-text ]; then
  case "${args[3]:-}" in
    '. '*)
      printf -v fixture_path '%q' "$HERDR_ORIGINAL_PATH"
      args[3]="export PATH=$fixture_path; ${args[3]}"
      if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
        printf -v fixture_pane '%q' "${args[2]}"
        args[3]="export HERDR_PANE_ID=$fixture_pane; ${args[3]}"
      fi
      ;;
  esac
fi
if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
  if [ "${args[0]:-}" = --version ]; then args=(status --json); fi
  exec python3 "$FM_PRESENTATION_FIXTURE" "${args[@]}" --session "$HERDR_LAB_SESSION"
fi
# Production version checks are read-only and are routed to lab status too.
if [ "${args[0]:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH"
lab() {
  if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
    python3 "$FM_PRESENTATION_FIXTURE" "$@" --session "$HERDR_LAB_SESSION"
  else
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
  fi
}
if [ "${FM_PRESENTATION_STUB:-0}" = 1 ]; then
  "$FM_FIXTURE_TMUX" -L "$FM_FIXTURE_SOCKET" -f /dev/null new-session -d -s fixture
else
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
fi
export FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf '## In flight\n- [ ] sample - Waiting for review\n' > "$HOME_DIR/data/backlog.md"
PROJECT="$TMP_ROOT/project"
mkdir "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.name=Tests -c user.email=tests@example.invalid commit --allow-empty -qm initial
# Independent fixture clones avoid administering the real worktree pool.
for id in sample extra live foreign; do
  wt="$TMP_ROOT/$id"
  git clone -q "$PROJECT" "$wt"
  git -C "$wt" checkout -qb "fm/$id"
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/state/$id.inbox/handled"
  printf 'retained artifact\n' > "$HOME_DIR/data/$id/artifact.txt"
  printf 'preserve\n' > "$HOME_DIR/state/$id.inbox/handled/1.msg"
  printf '# Task\n\nContinue the isolated fixture.\n' > "$HOME_DIR/data/$id/brief.md"
  created=$(lab workspace create --cwd "$wt" --label "fm-$id" --no-focus)
  ws=$(printf '%s' "$created" | jq -er '.result.workspace.workspace_id')
  seed=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
  created=$(lab tab create --workspace "$ws" --cwd "$wt" --label "fm-$id" --no-focus)
  tab=$(printf '%s' "$created" | jq -er '.result.tab.tab_id')
  pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
  lab pane close "$seed" >/dev/null
  cat > "$HOME_DIR/state/$id.meta" <<META
window=$HERDR_LAB_SESSION:$pane
endpoint_task_id=$id
worktree=$wt
project=$PROJECT
harness=codex
kind=ship
mode=local-only
yolo=off
branch=fm/$id
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
META
  printf 'paused: waiting for review\n' > "$HOME_DIR/state/$id.status"
  cp "$HOME_DIR/state/$id.meta" "$PROOF/$id.meta.before"
done
# Both protected spaces carry waiting declarations, so process/topology proof
# (not a status shortcut) must keep them open during the same heartbeat.
field() { sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta"; }
lab pane run "$(field live herdr_pane_id)" 'exec -a codex /bin/sleep 300' >/dev/null
lab pane report-agent "$(field live herdr_pane_id)" --source fixture --agent codex --state idle >/dev/null
lab tab create --workspace "$(field foreign herdr_workspace_id)" --cwd "$TMP_ROOT" --label foreign --no-focus >/dev/null
anchor=$(lab workspace create --cwd "$TMP_ROOT" --label anchor --focus)
anchor_tab=$(printf '%s' "$anchor" | jq -er '.result.tab.tab_id')
field() { sed -n "s/^$2=//p" "$HOME_DIR/state/$1.meta"; }
count_open() {
  local id count=0
  for id in sample extra; do
    if lab workspace get "$(field "$id" herdr_workspace_id)" >/dev/null 2>&1; then count=$((count+1)); fi
  done
  printf '%s\n' "$count"
}
# Suppress only already-reported fixture status, so the real watcher reaches
# its first heartbeat without an unrelated initial signal ending the turn.
. "$ROOT/bin/fm-wake-lib.sh"
for id in sample extra live foreign; do
  f="$HOME_DIR/state/$id.status"
  fm_wake_status_reported_commit "$HOME_DIR/state" "$f" "$(fm_wake_signal_sig "$f")"
done
heartbeat() {
  local root=$1 rc=0
  rm -f "$HOME_DIR/state/.last-heartbeat"
  touch "$HOME_DIR/state/.last-nm-review-pane" "$HOME_DIR/state/home-summary.json"
  FM_HEARTBEAT=999999 FM_HEARTBEAT_MAX=999999 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$root/bin/fm-watch-checkpoint.sh" --seconds 25 > "$PROOF/heartbeat.log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 124 ] || { cat "$PROOF/heartbeat.log"; fail "watcher exit $rc"; }
  [ -e "$HOME_DIR/state/.last-heartbeat" ] || { cat "$PROOF/heartbeat.log"; fail 'heartbeat did not complete'; }
}
if [ -n "${FM_PRESENTATION_BASELINE_ROOT:-}" ]; then
  printf 'baseline_before=%s\n' "$(count_open)"
  heartbeat "$FM_PRESENTATION_BASELINE_ROOT"
  cp "$PROOF/heartbeat.log" "$PROOF/baseline-heartbeat.log"
  printf 'baseline_after=%s\n' "$(count_open)"
  [ "$(count_open)" = 2 ] || fail 'baseline unexpectedly closed waiting workspaces'
fi
printf 'branch_before=%s\n' "$(count_open)"
heartbeat "$ROOT"
printf 'branch_after=%s\n' "$(count_open)"
for id in live foreign; do
  lab workspace get "$(field "$id" herdr_workspace_id)" > "$PROOF/$id.workspace.json" || fail "$id protection failed"
  cmp "$PROOF/$id.meta.before" "$HOME_DIR/state/$id.meta" || fail "$id metadata changed"
done
printf 'protected_before=2\nprotected_after=2\n'
[ "$(count_open)" = 0 ] || { cat "$HOME_DIR/state/"*.presentation-close.log; fail 'waiting workspaces survived'; }
for id in sample extra; do
  [ "$(field "$id" presentation)" = closed ] || fail 'closure not durable'
  sed '/^presentation=/d; /^presentation_closed_at=/d' "$HOME_DIR/state/$id.meta" > "$PROOF/$id.meta.after"
  cmp "$PROOF/$id.meta.before" "$PROOF/$id.meta.after" || fail 'task metadata changed beyond presentation'
done
cp "$HOME_DIR/data/backlog.md" "$PROOF/backlog.before"
cp "$HOME_DIR/state/sample.inbox/handled/1.msg" "$PROOF/inbox.before"
git -C "$TMP_ROOT/sample" rev-parse HEAD > "$PROOF/head.before"
git -C "$TMP_ROOT/sample" symbolic-ref HEAD > "$PROOF/branch.before"
cp "$HOME_DIR/state/sample.meta" "$PROOF/closed.meta"
"$ROOT/bin/fm-presentation-close.sh" --heartbeat
cmp "$PROOF/closed.meta" "$HOME_DIR/state/sample.meta" || fail 'repeat changed closed metadata'
state=$("$ROOT/bin/fm-crew-state.sh" sample)
case "$state" in 'state: paused '*'presentation: closed'*) ;; *) fail "closed task lost its wait: $state" ;; esac
printf 'crew_state=%s\n' "$state"
pass 'two exited waiting tasks close; task records and repeated cycles are preserved'
# Reproduce interruption after the close but before metadata publication.
cp "$HOME_DIR/state/extra.meta" "$HOME_DIR/state/extra.presentation-close.pending"
cp "$PROOF/extra.meta.before" "$HOME_DIR/state/extra.meta"
cksum < "$HOME_DIR/state/extra.meta" > "$HOME_DIR/state/extra.presentation-close.checksum"
"$ROOT/bin/fm-presentation-close.sh" extra
[ "$(field extra presentation)" = closed ] || fail 'interrupted publication did not converge'
pass 'interrupted close publication recovers against the unchanged task record'

# Recreate through the public control path, including its note contract.
# The agent fixture is placed on PATH by the named server and the replacement
# is checked as a process, without submitting a model prompt.
FM_CONTROL_LAUNCH_WAIT=15 "$ROOT/bin/fm-control.sh" sample relaunch --note 'Continue the fixture after presentation retirement.' \
  > "$PROOF/relaunch.log" 2>&1 || { cat "$PROOF/relaunch.log"; fail 'relaunch failed'; }
[ -z "$(field sample presentation)" ] || fail 'relaunch kept closed marker'
lab workspace get "$(field sample herdr_workspace_id)" > "$PROOF/relaunched-workspace.json"
[ -e "$HOME_DIR/state/sample.inbox/proceeded" ] || fail 'replacement did not process its launch'
cmp "$PROOF/backlog.before" "$HOME_DIR/data/backlog.md" || fail 'backlog changed'
cmp "$PROOF/inbox.before" "$HOME_DIR/state/sample.inbox/handled/1.msg" || fail 'inbox changed'
git -C "$TMP_ROOT/sample" rev-parse HEAD > "$PROOF/head.after"
git -C "$TMP_ROOT/sample" symbolic-ref HEAD > "$PROOF/branch.after"
cmp "$PROOF/head.before" "$PROOF/head.after" || fail 'worktree HEAD changed'
cmp "$PROOF/branch.before" "$PROOF/branch.after" || fail 'branch changed'
cp "$HOME_DIR/state/sample.meta" "$PROOF/sample.meta.relaunched"
preserved=0
while IFS='=' read -r key value; do
  case "$key" in window|herdr_workspace_id|herdr_tab_id|herdr_pane_id) continue ;; esac
  [ "$(field sample "$key")" = "$value" ] || fail "relaunch changed original identity field $key"
  preserved=$((preserved+1))
done < "$PROOF/sample.meta.before"
printf 'preserved_original_metadata_fields=%s\n' "$preserved"
[ "$(cat "$HOME_DIR/data/sample/artifact.txt")" = 'retained artifact' ] || fail 'task artifact changed'
printf 'relaunched_workspaces=1\npreserved_head=1\npreserved_branch=1\npreserved_inbox=1\npreserved_backlog=1\n'
"$ROOT/bin/fm-presentation-close.sh" sample
lab workspace get "$(field sample herdr_workspace_id)" >/dev/null || fail 'live agent workspace closed'
pass 'public relaunch restores workspace and process, preserving work and task identity'
pass 'live process is never closed'
# Remove the live-process protection so the topology refusal stands alone.
lab pane send-keys "$(field sample herdr_pane_id)" ctrl+c >/dev/null
sleep 0.2
lab tab create --workspace "$(field sample herdr_workspace_id)" --cwd "$TMP_ROOT" --label foreign --no-focus >/dev/null
"$ROOT/bin/fm-presentation-close.sh" sample
lab workspace get "$(field sample herdr_workspace_id)" >/dev/null || fail 'foreign tab workspace closed'
pass 'workspace containing a foreign tab is never closed'
# Legacy/manual closure has no marker. The missing endpoint itself must be
# enough for the same exact, absence-proving relaunch path.
cp "$PROOF/extra.meta.before" "$HOME_DIR/state/extra.meta"
[ -z "$(field extra presentation)" ] || fail 'manual-close case still has a marker'
FM_CONTROL_LAUNCH_WAIT=15 "$ROOT/bin/fm-control.sh" extra relaunch --note 'Continue after a manually closed workspace.' \
  > "$PROOF/manual-relaunch.log" 2>&1 || { cat "$PROOF/manual-relaunch.log"; fail 'unmarked missing endpoint relaunch failed'; }
lab workspace get "$(field extra herdr_workspace_id)" > "$PROOF/manual-relaunched-workspace.json"
[ -e "$HOME_DIR/state/extra.inbox/proceeded" ] || fail 'manual-close replacement did not proceed'
[ "$(field extra worktree)" = "$TMP_ROOT/extra" ] || fail 'manual-close relaunch changed worktree'
[ "$(git -C "$TMP_ROOT/extra" rev-parse HEAD)" = "$(cat "$PROOF/head.before")" ] || fail 'manual-close relaunch changed HEAD'
[ "$(git -C "$TMP_ROOT/extra" symbolic-ref HEAD)" = refs/heads/fm/extra ] || fail 'manual-close relaunch changed branch'
cmp "$PROOF/backlog.before" "$HOME_DIR/data/backlog.md" || fail 'manual-close relaunch changed backlog'
cmp "$PROOF/inbox.before" "$HOME_DIR/state/extra.inbox/handled/1.msg" || fail 'manual-close relaunch changed inbox'
printf 'unmarked_missing_workspace_relaunched=1\n'
pass 'an unmarked manually closed workspace is recreated with its task and work intact'
lab tab focus "$anchor_tab" >/dev/null
lab status --json > "$PROOF/herdr-version.json"
