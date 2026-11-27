#!/usr/bin/env bash
# Codex notify callback: <state> <task> <spawn-gen> <native-notification-json>.
# The native thread-id binds the saved conversation on its first completed turn.
# Stale callbacks cannot change a replacement's session or signal its turn end.
# Existing conversation IDs are immutable within one spawn generation.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-agent-session-lib.sh
. "$SCRIPT_DIR/fm-agent-session-lib.sh"
STATE=${1:?state required}
ID=${2:?task required}
GEN=${3:?spawn generation required}
PAYLOAD=${4:?notification required}
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
META="$STATE/$ID.meta"
SESSION=$(printf '%s' "$PAYLOAD" | jq -er 'select(.type == "agent-turn-complete") | .["thread-id"]') || exit 1
fm_agent_session_uuid "$SESSION" || exit 1
LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$LOCK"
TMP=
trap 'rm -f "${TMP:-}"; fm_lock_release "$LOCK"' EXIT
[ "$(fm_meta_get "$META" spawn_gen)" = "$GEN" ] || exit 1
[ "$(fm_meta_get "$META" harness)" = codex ] || exit 1
PRIOR=$(fm_meta_get "$META" agent_session_id)
[ -z "$PRIOR" ] || [ "$PRIOR" = "$SESSION" ] || exit 1
# Codex owns this launch callback and may still be flushing its rollout.
# Record the native identity now; resume separately proves the file is usable.
TMP=$(mktemp "$META.session.XXXXXX")
awk -F= -v session="$SESSION" 'BEGIN { print "agent_session_id=" session }
  $1 != "agent_session_id" { print }' "$META" > "$TMP"
mv "$TMP" "$META"
TMP=
touch "$STATE/$ID.turn-ended"
