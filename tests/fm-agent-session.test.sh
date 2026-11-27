#!/usr/bin/env bash
# Saved-session identity and native notification contract, without credentials.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agent-session-lib.sh
. "$ROOT/bin/fm-agent-session-lib.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-session.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
UUID=11111111-2222-4333-8444-555555555555
OTHER=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
mkdir -p "$LAB/state" "$LAB/codex/sessions/2026/11/26" "$LAB/claude/projects/project" "$LAB/work"
CWD=$(cd "$LAB/work" && pwd -P)
CODEX_FILE="$LAB/codex/sessions/2026/11/26/rollout-date-$UUID.jsonl"
jq -cn --arg id "$UUID" --arg cwd "$CWD" \
  '{type:"session_meta",payload:{id:$id,cwd:$cwd}}' > "$CODEX_FILE"
jq -cn --arg id "$UUID" --arg cwd "$CWD" \
  '{type:"user",sessionId:$id,cwd:$cwd}' > "$LAB/claude/projects/project/$UUID.jsonl"
for harness in claude codex; do
  fm_agent_session_file "$harness" "$LAB/$harness" "$UUID" "$CWD" >/dev/null
  if fm_agent_session_file "$harness" "$LAB/$harness" "$UUID" /wrong >/dev/null; then fail 'accepted the wrong cwd'; fi
  if fm_agent_session_file "$harness" "$LAB/$harness" "$OTHER" "$CWD" >/dev/null; then fail 'accepted a missing session'; fi
  if fm_agent_session_file "$harness" "$LAB/$harness" '../latest' "$CWD" >/dev/null; then fail 'accepted an invalid session ID'; fi
done
mkdir -p "$LAB/linked-account"
ln -s "$LAB/claude/projects" "$LAB/linked-account/projects"
fm_agent_session_file claude "$LAB/linked-account" "$UUID" "$CWD" >/dev/null
printf 'ok - saved conversations bind UUID, account root and original cwd\n'
cat > "$LAB/state/worker.meta" <<EOF
harness=codex
worktree=$CWD
spawn_gen=g1
agent_session_id=
agent_session_root=$LAB/codex
pr=https://example.invalid/pull/1
pr_head=abc
EOF
PAYLOAD=$(jq -cn --arg id "$UUID" '{type:"agent-turn-complete","thread-id":$id}')
bash "$ROOT/bin/fm-agent-session-notify.sh" "$LAB/state" worker g1 "$PAYLOAD"
grep -qx "agent_session_id=$UUID" "$LAB/state/worker.meta"
[ -f "$LAB/state/worker.turn-ended" ]
[ "$(tail -2 "$LAB/state/worker.meta")" = $'pr=https://example.invalid/pull/1\npr_head=abc' ]
cp "$LAB/state/worker.meta" "$LAB/prior"
rm "$LAB/state/worker.turn-ended"
if bash "$ROOT/bin/fm-agent-session-notify.sh" "$LAB/state" worker old "$PAYLOAD"; then fail 'accepted a stale notification'; fi
cmp "$LAB/prior" "$LAB/state/worker.meta"
[ ! -e "$LAB/state/worker.turn-ended" ]
printf 'ok - native notification records session before turn signal and rejects stale generations\n'
mv "$CODEX_FILE" "$CODEX_FILE.saved"
bash "$ROOT/bin/fm-agent-session-notify.sh" "$LAB/state" worker g1 "$PAYLOAD"
if fm_agent_session_file codex "$LAB/codex" "$UUID" "$CWD" >/dev/null; then fail 'accepted an unflushed transcript'; fi
printf 'ok - native identity survives delayed flush but missing transcript remains unavailable\n'
