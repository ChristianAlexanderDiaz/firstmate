#!/usr/bin/env bash
# Opt-in native conversation proof, exclusively in a named Herdr lab.
# Two facts are delivered in separate rounds, absent from the launch brief.
# The first answer after fm-control exit/resume must recall both without tools.
# FM_SESSION_PROOF_DIR retains captures outside the repository for delivery.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CONTROL_RESUME_LIVE claude codex herdr jq
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-resume-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
PROOF=${FM_SESSION_PROOF_DIR:-$LAB/proof}
mkdir -p "$PROOF"
HERDR_LAB_HELPER=${FM_SESSION_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${FM_SESSION_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name tool-134)
ORIGINAL_PATH=$PATH
export FM_HOME="$LAB/home"
LAB_PROVISIONED=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$LAB_PROVISIONED" = 1 ]; then
    PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fi
  "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  # Keep evidence even on failure; no live endpoint survives this trap.
  printf 'proof=%s\nlab=%s\n' "$PROOF" "$LAB"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null
LAB_PROVISIONED=1
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export HERDR_SESSION=$HERDR_LAB_SESSION
export FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE=$ROOT
printf 'herdr\n' > "$FM_HOME/config/backend"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'auto\n' > "$FM_HOME/config/claude-permission-mode"
if [ -n "${FM_SESSION_CLAUDE_PIN:-}" ]; then
  ln -s "$FM_SESSION_CLAUDE_PIN" "$FM_HOME/config/claude-account"
fi
# Current Claude also checks --add-dir grants. The existing marked-lab trust
# helper registers the throwaway instruction root before any worker starts.
cp "$ROOT/AGENTS.md" "$FM_HOME/AGENTS.md"
cp -R "$ROOT/bin" "$FM_HOME/bin"
git -C "$FM_HOME" init -q -b main
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"
lab_account=$(fm_worker_account_select claude "$FM_HOME/config" sonnet claude)
if [ -n "$lab_account" ]; then
  lab_account_root=${lab_account#*$'\t'}
  lab_account_root=${lab_account_root%%$'\t'*}
  CLAUDE_CONFIG_DIR=$lab_account_root "$ROOT/bin/fm-claude-trust.sh" --lab-home "$FM_HOME"
else
  "$ROOT/bin/fm-claude-trust.sh" --lab-home "$FM_HOME"
fi
# Route production backend commands through the exact lab helper too. Reject
# foreign scope; even the backend's unscoped health probe reaches the real
# binary only through the helper's explicit private --session argument.
mkdir -p "$LAB/shim"
export FM_RESUME_LAB_HELPER=$HERDR_LAB_HELPER FM_RESUME_LAB_SESSION=$HERDR_LAB_SESSION
export FM_RESUME_ORIGINAL_PATH=$ORIGINAL_PATH
cat > "$LAB/shim/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
session=
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session) session=${2:?}; shift 2 ;;
    --session=*) session=${1#*=}; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
[ -z "$session" ] || [ "$session" = "$FM_RESUME_LAB_SESSION" ] || { echo 'refusing non-lab Herdr call' >&2; exit 1; }
PATH=$FM_RESUME_ORIGINAL_PATH exec "$FM_RESUME_LAB_HELPER" run "$FM_RESUME_LAB_SESSION" "${args[@]}"
SH
chmod +x "$LAB/shim/herdr"
export PATH="$LAB/shim:$PATH"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-agent-session-lib.sh
. "$ROOT/bin/fm-agent-session-lib.sh"
fm_backend_source herdr
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
wait_reply() { # <marker>
  local n screen trusted=0
  for ((n=0; n<600; n++)); do
    screen=$(fm_backend_visible_capture herdr "$TARGET" "fm-$TASK" 2>/dev/null) || screen=
    printf '%s\n' "$screen" > "$PROOF/$harness.capture"
    # Codex's documented directory-trust choice is permitted only for this
    # freshly created fixture. Never accept a different dialog or directory.
    if [ "$harness" = codex ] && [ "$1" = READY ] && [ "$trusted" = 0 ] \
      && [[ $screen == *"$WT"* && $screen == *"$PROJECT"* \
        && $screen == *'Trust this folder?'* && $screen == *'› 1. Trust and continue'* ]]; then
      printf '\n--- fixture directory trust ---\n%s\n' "$screen" >> "$PROOF/$harness.transcript.txt"
      fm_backend_herdr_send_key "$TARGET" Enter || fail 'Codex fixture trust delivery failed'
      trusted=1
    fi
    if [ -f "$FM_HOME/state/$TASK.turn-ended" ] && [[ $screen == *"$1"* ]] \
      && [ "$(fm_backend_composer_state herdr "$TARGET" "fm-$TASK" 2>/dev/null)" = empty ]; then
      printf '\n--- %s ---\n%s\n' "$1" "$screen" >> "$PROOF/$harness.transcript.txt"
      return 0
    fi
    sleep 0.2
  done
  fail "$harness never produced $1; inspect $PROOF/$harness.capture"
}
send_prompt() {
  rm -f "$FM_HOME/state/$TASK.turn-ended"
  fm_backend_send_text_submit herdr "$TARGET" "$1" 3 0.5 1.2 "fm-$TASK" >/dev/null
}
for harness in claude codex; do
  TASK="recall-$harness"
  PROJECT="$LAB/project-$harness"
  WT="$LAB/worker-$harness"
  mkdir -p "$FM_HOME/data/$TASK"
  # Standard test fixture: a new repository and linked copy entirely under
  # this lab. Never use the task's repository or any shared worktree pool.
  fm_git_worktree "$PROJECT" "$WT" "fm/$TASK"
  mkdir -p "$WT/.claude"
  # A recall test needs no personal instructions or external imports. This
  # fixture-local setting excludes them rather than manufacturing consent or
  # changing the pinned account's global settings (Claude memory docs).
  printf '%s\n' '{"claudeMdExcludes":["**/CLAUDE.md","**/.claude/rules/**"]}' > "$WT/.claude/settings.json"
  container=$(fm_backend_herdr_container_ensure "$WT")
  seeded=${container#*$'\t'}
  container=${container%%$'\t'*}
  workspace=${container#*:}
  ids=$(fm_backend_herdr_create_task "$container" "fm-$TASK" "$WT" "$seeded")
  read -r tab PANE <<< "$ids"
  TARGET="$HERDR_LAB_SESSION:$PANE"
  model=sonnet
  [ "$harness" != codex ] || model=gpt-5.6-luna
  cat > "$FM_HOME/state/$TASK.meta" <<EOF
window=$TARGET
endpoint_task_id=$TASK
worktree=$WT
project=$PROJECT
harness=$harness
kind=ship
mode=local-only
yolo=off
model=$model
effort=low
branch=fm/$TASK
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$PANE
EOF
  cat > "$FM_HOME/data/$TASK/brief.md" <<EOF
# Task
You are an isolated conversation recall test worker. Do not inspect files or use tools.
Reply READY and wait for subsequent conversation messages. Do no project work.
Ship branch: fm/$TASK
Delivery contract: mode=local-only
EOF
  printf '%s\n' "$harness: $("$harness" --version)" > "$PROOF/$harness.transcript.txt"
  "$ROOT/bin/fm-control.sh" "$TASK" relaunch --note 'Reply READY and wait; do not use tools.' \
    >> "$PROOF/$harness.transcript.txt" 2>&1 || {
    fm_backend_visible_capture herdr "$TARGET" "fm-$TASK" > "$PROOF/$harness.capture" 2>&1 || true
    fail "$harness initial launch failed; inspect $PROOF/$harness.capture"
  }
  wait_reply READY
  send_prompt 'Round one: remember that the launch code is cobalt-731. Reply ROUND_ONE_STORED only. Do not use tools.'
  wait_reply ROUND_ONE_STORED
  send_prompt 'Round two: remember that the meeting place is orchard-29. Keep the prior fact too. Reply ROUND_TWO_STORED only. Do not use tools.'
  wait_reply ROUND_TWO_STORED
  native_id=$(fm_meta_get "$FM_HOME/state/$TASK.meta" agent_session_id)
  fm_agent_session_uuid "$native_id" || fail "$harness did not record its native session"
  cp "$FM_HOME/data/$TASK/brief.md" "$PROOF/$harness.brief-before"
  "$ROOT/bin/fm-control.sh" "$TASK" exit >> "$PROOF/$harness.transcript.txt" 2>&1
  "$ROOT/bin/fm-control.sh" "$TASK" resume >> "$PROOF/$harness.transcript.txt" 2>&1 \
    || {
    fm_backend_visible_capture herdr "$TARGET" "fm-$TASK" > "$PROOF/$harness.capture" 2>&1 || true
    fail "$harness saved session did not reopen; inspect $PROOF/$harness.capture"
  }
  [ "$(fm_meta_get "$FM_HOME/state/$TASK.meta" agent_session_id)" = "$native_id" ] \
    || fail "$harness changed native session identity"
  cmp "$FM_HOME/data/$TASK/brief.md" "$PROOF/$harness.brief-before" \
    || fail "$harness resume rewrote the brief"
  send_prompt 'Without tools or reading any file, what launch code and meeting place did I give you in the two earlier rounds? Reply RECALL followed by both values.'
  wait_reply RECALL
  grep -q 'cobalt-731' "$PROOF/$harness.capture" || fail "$harness forgot round one"
  grep -q 'orchard-29' "$PROOF/$harness.capture" || fail "$harness forgot round two"
  session_file=$(fm_agent_session_file "$harness" "$(fm_meta_get "$FM_HOME/state/$TASK.meta" agent_session_root)" "$native_id" "$WT")
  # Inspect only the native assistant answer after the recall prompt. Echoed
  # prompts and earlier viewport history must not make the assertion pass.
  if [ "$harness" = claude ]; then
    jq -s -e '
      map(select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text) |
      last | contains("RECALL") and contains("cobalt-731") and contains("orchard-29")
    ' "$session_file" >/dev/null || fail 'Claude native final answer did not recall both facts'
    jq -s -e '
      [to_entries[] | select(.value.type == "user" and (.value.message.content | tostring | contains("Without tools or reading any file"))) | .key] | last
    ' "$session_file" > "$PROOF/$harness.recall-offset"
    jq -s -e --argjson offset "$(cat "$PROOF/$harness.recall-offset")" '
      .[$offset:] | all(.[] | .message.content[]?; .type != "tool_use")
    ' "$session_file" >/dev/null || fail 'Claude used a tool after the recall question'
  else
    jq -s -e '
      map(select(.type == "response_item" and .payload.type == "message" and .payload.role == "assistant") |
        .payload.content[]? | .text // empty) | last |
      contains("RECALL") and contains("cobalt-731") and contains("orchard-29")
    ' "$session_file" >/dev/null || fail 'Codex native final answer did not recall both facts'
    jq -s -e '
      [to_entries[] | select(.value.type == "response_item" and .value.payload.role == "user" and
        (.value.payload.content | tostring | contains("Without tools or reading any file"))) | .key] | last
    ' "$session_file" > "$PROOF/$harness.recall-offset"
    jq -s -e --argjson offset "$(cat "$PROOF/$harness.recall-offset")" '
      .[$offset:] | all(.[]; .payload.type != "function_call" and .payload.type != "custom_tool_call")
    ' "$session_file" >/dev/null || fail 'Codex used a tool after the recall question'
  fi
  cp "$session_file" "$PROOF/$harness.native.jsonl"
  "$ROOT/bin/fm-control.sh" "$TASK" exit >> "$PROOF/$harness.transcript.txt" 2>&1
  printf 'ok - %s reopened %s and recalled both rounds without resubmitting the brief\n' "$harness" "$native_id"
done
