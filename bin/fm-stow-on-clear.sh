#!/usr/bin/env bash
# fm-stow-on-clear.sh - keep a Claude /clear of the main firstmate session from
# losing what only that session knew because /stow was forgotten first.
#
# A Claude SessionEnd hook cannot block, prompt, or reach the model, so the
# stow itself cannot run at clear time. Instead the clear leaves a durable
# pending-stow record naming the ended session's transcript, and the next
# session start in this home surfaces it so the new session runs the stow skill
# against that transcript before taking new work. The stow skill owns the pass;
# this command owns only the record.
#
# Usage:
#   fm-stow-on-clear.sh hook               SessionEnd hook entry; reads the
#                                          Claude JSON payload on stdin.
#   fm-stow-on-clear.sh pending            Print the PENDING STOW digest block
#                                          (nothing when no record is pending).
#   fm-stow-on-clear.sh done <id>         Clear that record once stow has run.
#
# Records live in state/.pending-stow/<session-id>, one key=value file each
# (session=, transcript=, ended=<epoch>), written atomically. A record persists
# until `done` clears it, so a session that ignored it, crashed, or never ran
# leaves it for the next session start.
#
# hook records only when every one of these holds, and is otherwise a silent
# no-op, because the tracked .claude/settings.json also loads in secondmate
# homes, task worktrees, and under other harnesses that read Claude settings:
#   - the payload is Claude's own SessionEnd with reason `clear` (a Cursor
#     payload, and any other event or reason, is ignored);
#   - this process is not a no-mistakes gate agent;
#   - the root is a primary home (fm_primary_scope_matches), so a linked task
#     worktree is excluded, and it carries no secondmate-home marker;
#   - the ending session owns this home's session lock
#     (fm_session_lock_owned_by_self), which is what makes it the main firstmate
#     session rather than a read-only second session or a headless helper.
#
# Failure direction: every subcommand exits 0 on every path except a usage
# error, and hook prints at most one stderr diagnostic. A /clear or a session
# start must never break because of this record. pending drops a record whose
# transcript is no longer readable (a stale record, or a clear of a session that
# never wrote one) and says so in the block, so a dead record cannot nag forever.
#
# Ordering: Claude Code 2.1.296 was observed awaiting the SessionEnd hook before
# running the SessionStart hook for the cleared session, so the clear's own
# digest normally carries the record. That ordering is undocumented; a record
# that lands late is still surfaced by the next session start.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PENDING_DIR="$STATE/.pending-stow"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-stow-on-clear.sh" | sed 's/^# \{0,1\}//; $d'
}

diag() { printf 'fm-stow-on-clear: %s\n' "$*" >&2; }

valid_session_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

record_field() {  # <record-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

cmd_hook() {
  local payload session transcript reason event tmp
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"

  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || return 0
  fm_hook_payload_is_foreign_host "$payload" && return 0
  fm_is_gate_agent "$FM_ROOT" && return 0
  fm_root_is_secondmate_home "$FM_ROOT" && return 0
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  if ! command -v jq >/dev/null 2>&1; then
    # Only a clear is worth a diagnostic; every other session end stays silent.
    printf '%s' "$payload" | grep -Eq '"reason"[[:space:]]*:[[:space:]]*"clear"' \
      && diag "jq is not installed, so the cleared session's transcript was not recorded for a pending stow"
    return 0
  fi
  event=$(printf '%s' "$payload" | jq -r 'if type == "object" then (.hook_event_name // "") else "" end' 2>/dev/null) || event=
  reason=$(printf '%s' "$payload" | jq -r 'if type == "object" then (.reason // "") else "" end' 2>/dev/null) || reason=
  [ "$event" = SessionEnd ] && [ "$reason" = clear ] || return 0
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" || return 0

  session=$(printf '%s' "$payload" | jq -r '.session_id // "" | tostring' 2>/dev/null) || session=
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // "" | tostring' 2>/dev/null) || transcript=
  if ! valid_session_id "$session"; then
    diag "the cleared session's id was missing or malformed, so no pending stow was recorded"
    return 0
  fi
  case "$transcript" in
    /*) : ;;
    *) diag "the cleared session reported no absolute transcript path, so no pending stow was recorded"; return 0 ;;
  esac
  case "$transcript" in
    *"
"*) diag "the cleared session's transcript path spans lines, so no pending stow was recorded"; return 0 ;;
  esac

  if ! mkdir -p "$PENDING_DIR" 2>/dev/null; then
    diag "could not create $PENDING_DIR, so no pending stow was recorded"
    return 0
  fi
  tmp=$(mktemp "$PENDING_DIR/.tmp.XXXXXX" 2>/dev/null) || tmp=
  if [ -z "$tmp" ] \
    || ! printf 'session=%s\ntranscript=%s\nended=%s\n' "$session" "$transcript" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$PENDING_DIR/$session" 2>/dev/null; then
    [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
    diag "could not write the pending stow record in $PENDING_DIR"
  fi
  return 0
}

cmd_pending() {
  local rec id transcript ended when listed='' dropped=''
  [ -d "$PENDING_DIR" ] || return 0
  # An interrupted hook can leave only its own temp file behind; it never
  # became a record, so it is removed once it is clearly abandoned.
  find "$PENDING_DIR" -maxdepth 1 -name '.tmp.*' -mmin +60 -exec rm -f {} + 2>/dev/null || true
  for rec in "$PENDING_DIR"/*; do
    [ -f "$rec" ] || continue
    id=${rec##*/}
    transcript=$(record_field "$rec" transcript)
    ended=$(record_field "$rec" ended)
    if ! valid_session_id "$id" || [ -z "$transcript" ] || [ ! -r "$transcript" ] || [ ! -s "$transcript" ]; then
      rm -f "$rec" 2>/dev/null || true
      dropped="$dropped- session $id: transcript ${transcript:-(none recorded)} is missing or unreadable, so there is nothing to stow from it; its record was cleared.
"
      continue
    fi
    when=unknown
    case "$ended" in
      ''|*[!0-9]*) : ;;
      *) when=$(date -u -d "@$ended" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -r "$ended" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || printf 'epoch %s' "$ended") ;;
    esac
    listed="$listed- session $id, cleared $when
  transcript: $transcript
  after its stow pass: bin/fm-stow-on-clear.sh done $id
"
  done
  [ -n "$listed$dropped" ] || return 0
  if [ -n "$listed" ]; then
    cat <<'EOF'
A /clear ended an earlier session of this home before /stow ran, so its
uncaptured knowledge and open work records exist only in its transcript.
Before taking new work, load the stow skill and run its pass for each session
below as the swept session (handling the wake queue above may come first).
EOF
    printf '%s' "$listed"
  fi
  if [ -n "$dropped" ]; then
    printf 'Skipped stale pending-stow records:\n%s' "$dropped"
  fi
}

cmd_done() {
  local id=${1:-}
  if ! valid_session_id "$id"; then
    diag "usage: fm-stow-on-clear.sh done <session-id>"
    return 2
  fi
  if [ -f "$PENDING_DIR/$id" ]; then
    rm -f "$PENDING_DIR/$id" 2>/dev/null || { diag "could not clear the pending stow record for session $id"; return 0; }
    printf 'Cleared the pending stow record for session %s.\n' "$id"
  else
    printf 'No pending stow record for session %s; nothing to clear.\n' "$id"
  fi
}

case "${1:-}" in
  hook) cmd_hook ;;
  pending) cmd_pending ;;
  done) shift; cmd_done "$@"; exit $? ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
exit 0
