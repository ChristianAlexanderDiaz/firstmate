#!/usr/bin/env bash
# Keep a Herdr ship's attributed no-mistakes run beside its chat.
# Ported from https://github.com/kunchenguid/firstmate/pull/3751's separate presentation record
# and session-locked lifecycle; run selection stays with fm-crew-state.sh.
#
# Usage: fm-nm-review-pane.sh <task-id>
# Asks fm-crew-state.sh --sync-review-pane, without forge reads, to reconcile a
# proven run. Ordinary crew-state reads remain side-effect free. The existing
# watcher invokes this on a bounded cadence; there is no additional daemon.
# Task teardown closes the viewer through fm_nm_review_pane_close_locked.
# Non-Herdr and remote tasks are no-ops. Unknown run evidence preserves the pane.
#
# state/<id>.nm-review-pane is an atomic key=value presentation record:
# session, worker, worktree, workspace, tab bind the task endpoint; pane is the
# separate viewer pane, run its attributed run id, started is 1 after pane run.
# An empty pane retains the last run as a tombstone, preventing repeated reads
# of a finished run from reopening it. No worker metadata is changed.
# The named-session presentation lock serializes splits, close, and teardown.
# A record is owned by its task's session and worktree. A pane is closed only
# when its exact id, workspace and tab match the record, and it differs from
# both the recorded and current chat panes. A record from an earlier endpoint,
# such as after a relaunch, is closed and dropped before a new viewer opens.
# Unknown presence retains the record.
# _close_locked requires the caller to hold that same session lock.
#
# Splits use down, ratio 0.55, no focus; right is selected only when pane layout
# proves at least 240 columns, leaving about 108 for attach. Missing layout
# support or dimensions keeps the stacked default. Layout is chosen on split.
# A terminal run closes its pane; task teardown removes the tombstone too.
# Already absent panes close successfully. Failed commands retain retry state.
# Exit 0 after a reconciliation attempt; a failed or unsafe one warns on stderr
# and retains the record. Exit 2: usage error.
set -u

FM_NM_REVIEW_PANE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_NM_REVIEW_PANE_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_NM_REVIEW_PANE_LIB_DIR/fm-wake-lib.sh"

fm_nm_review_pane_record_write() {  # <record> <pane> <run> <started>
  local record=$1 tmp
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'session=%s\nworker=%s\nworktree=%s\nworkspace=%s\ntab=%s\n' \
      "$FM_NM_REVIEW_SESSION" "$FM_NM_REVIEW_WORKER" "$FM_NM_REVIEW_WORKTREE" \
      "$FM_NM_REVIEW_WORKSPACE" "$FM_NM_REVIEW_TAB"
    printf 'pane=%s\nrun=%s\nstarted=%s\n' "$2" "$3" "$4"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

fm_nm_review_pane_identity() {  # <meta> <task-id>
  local meta=$1 id=$2
  [ "$(fm_meta_get "$meta" backend)" = herdr ] || return 1
  case "$(fm_meta_get "$meta" kind)" in ''|ship) ;; *) return 1 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  FM_NM_REVIEW_SESSION=$(fm_meta_get "$meta" herdr_session)
  FM_NM_REVIEW_WORKER=$(fm_meta_get "$meta" herdr_pane_id)
  FM_NM_REVIEW_WORKTREE=$(fm_meta_get "$meta" worktree)
  FM_NM_REVIEW_WORKSPACE=$(fm_meta_get "$meta" herdr_workspace_id)
  FM_NM_REVIEW_TAB=$(fm_meta_get "$meta" herdr_tab_id)
}

fm_nm_review_pane_record_owned() {  # <record>
  local record=$1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  [ "$(fm_meta_get "$record" session)" = "$FM_NM_REVIEW_SESSION" ] \
    && [ "$(fm_meta_get "$record" worktree)" = "$FM_NM_REVIEW_WORKTREE" ]
}

fm_nm_review_pane_record_current() {  # <record>
  [ "$(fm_meta_get "$1" worker)" = "$FM_NM_REVIEW_WORKER" ] \
    && [ "$(fm_meta_get "$1" workspace)" = "$FM_NM_REVIEW_WORKSPACE" ] \
    && [ "$(fm_meta_get "$1" tab)" = "$FM_NM_REVIEW_TAB" ]
}

# 0 present in the bound tab, 3 structurally absent, 1 ambiguous.
# Herdr reports pane_not_found as JSON on stderr, so both streams are read.
fm_nm_review_pane_presence() {  # <pane> [workspace] [tab]
  local pane=$1 ws=${2:-$FM_NM_REVIEW_WORKSPACE} tab=${3:-$FM_NM_REVIEW_TAB} info code
  info=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane get "$pane" 2>&1) || true
  code=$(printf '%s' "$info" | jq -r '.error.code // empty' 2>/dev/null)
  [ "$code" != pane_not_found ] || return 3
  printf '%s' "$info" | jq -e --arg pane "$pane" --arg ws "$ws" --arg tab "$tab" '
    .result.pane | .pane_id == $pane and .workspace_id == $ws and .tab_id == $tab
  ' >/dev/null 2>&1
}

# Port of the upstream locked close, retaining its confirmed-gone boundary.
fm_nm_review_pane_close_locked() {  # <state-dir> <task-id> [keep-run]
  local state=$1 id=$2 keep=${3:-0} record pane ws tab presence
  record="$state/$id.nm-review-pane"
  [ -e "$record" ] || return 0
  fm_nm_review_pane_identity "$state/$id.meta" "$id" || return 1
  fm_nm_review_pane_record_owned "$record" || return 1
  pane=$(fm_meta_get "$record" pane)
  ws=$(fm_meta_get "$record" workspace)
  tab=$(fm_meta_get "$record" tab)
  if [ -n "$pane" ]; then
    [ "$pane" != "$FM_NM_REVIEW_WORKER" ] && [ "$pane" != "$(fm_meta_get "$record" worker)" ] || return 1
    [ -n "$ws" ] && [ -n "$tab" ] || return 1
    presence=0
    fm_nm_review_pane_presence "$pane" "$ws" "$tab" || presence=$?
    case "$presence" in
      0)
        fm_backend_herdr_kill_serialized "$FM_NM_REVIEW_SESSION" "$pane" || true
        presence=0
        fm_nm_review_pane_presence "$pane" "$ws" "$tab" || presence=$?
        ;;
      3) ;;
      *) return 1 ;;
    esac
    if [ "$presence" != 3 ]; then
      echo "warning: no-mistakes pane for $id is not confirmed gone; retaining $record" >&2
      return 1
    fi
  fi
  if [ "$keep" = 1 ]; then
    fm_nm_review_pane_record_write "$record" "" "$(fm_meta_get "$record" run)" 1
  else
    rm -f "$record"
  fi
}

# A failed pane run can leave started=0 even if attach started.
# Retry only at a structurally proven shell, never by typing into a viewer.
fm_nm_review_pane_shell_ready() {  # <pane>
  fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane process-info --pane "$1" 2>/dev/null \
    | jq -e --arg pane "$1" '
      .result.process_info | .pane_id == $pane
      and (.shell_pid | type) == "number"
      and .shell_pid == .foreground_process_group_id
    ' >/dev/null 2>&1
}

fm_nm_review_pane_direction() {
  local layout width
  layout=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane layout --pane "$FM_NM_REVIEW_WORKER" 2>/dev/null) || layout=
  width=$(printf '%s' "$layout" | jq -r --arg pane "$FM_NM_REVIEW_WORKER" '
    .result.layout.panes[]? | select(.pane_id == $pane) | .rect.width
  ' 2>/dev/null)
  case "$width" in ''|*[!0-9]*) printf down ;;
    *) if [ "$width" -ge 240 ]; then printf right; else printf down; fi ;;
  esac
}

# Public library entry point; only the run-attributing crew-state reader calls
# this with run evidence. Errors never change its authoritative state verdict.
fm_nm_review_pane_sync() {  # <meta> <state-dir> <task-id> <run-id> <active|terminal>
  local meta=$1 state=$2 id=$3 run=$4 phase=$5 lock rc=0
  fm_nm_review_pane_identity "$meta" "$id" || return 0
  [ -n "$run" ] || return 0
  fm_backend_source herdr || return 1
  lock=$(fm_backend_herdr_presentation_session_lock_path "$FM_NM_REVIEW_SESSION") || return 1
  fm_lock_try_acquire "$lock" || return 0
  # Re-read after taking the same lock teardown holds, so a captured fleet
  # snapshot cannot recreate a task whose live metadata was already retired.
  if [ "$meta" != "$state/$id.meta" ] || ! fm_nm_review_pane_identity "$state/$id.meta" "$id"; then
    fm_lock_release "$lock" || true
    return 0
  fi
  fm_nm_review_pane_sync_locked "$state" "$id" "$run" "$phase" || rc=$?
  fm_lock_release "$lock" || true
  return "$rc"
}

fm_nm_review_pane_sync_locked() {  # <state-dir> <task-id> <run-id> <active|terminal>
  local state=$1 id=$2 run=$3 phase=$4 record pane prior started presence direction cmd
  record="$state/$id.nm-review-pane"
  if [ -e "$record" ]; then
    fm_nm_review_pane_record_owned "$record" || return 1
    prior=$(fm_meta_get "$record" run)
    if [ "$phase" = terminal ]; then
      fm_nm_review_pane_close_locked "$state" "$id" 1
      return $?
    fi
    if [ "$prior" != "$run" ] || ! fm_nm_review_pane_record_current "$record"; then
      fm_nm_review_pane_close_locked "$state" "$id" || return 1
    fi
  fi
  [ "$phase" = active ] || return 0
  fm_nm_review_pane_presence "$FM_NM_REVIEW_WORKER" || return 0
  pane=$(fm_meta_get "$record" pane)
  started=$(fm_meta_get "$record" started)
  if [ -e "$record" ] && [ -z "$pane" ]; then return 0; fi
  if [ -n "$pane" ]; then
    [ "$pane" != "$FM_NM_REVIEW_WORKER" ] || return 1
    presence=0
    fm_nm_review_pane_presence "$pane" || presence=$?
    case "$presence" in
      0)
        [ "$started" != 1 ] || return 0
        fm_nm_review_pane_shell_ready "$pane" || return 1
        ;;
      3) fm_nm_review_pane_record_write "$record" "" "$run" 1; return $? ;;
      *) return 1 ;;
    esac
  else
    direction=$(fm_nm_review_pane_direction)
    pane=$(fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane split "$FM_NM_REVIEW_WORKER" \
      --direction "$direction" --ratio 0.55 --cwd "$FM_NM_REVIEW_WORKTREE" --no-focus 2>/dev/null \
      | jq -r '.result.pane.pane_id // empty' 2>/dev/null) || pane=
    [ -n "$pane" ] && [ "$pane" != "$FM_NM_REVIEW_WORKER" ] || return 1
    # Commit identity before starting attach, allowing a failed run to retry
    # in this same pane rather than creating another one.
    if ! fm_nm_review_pane_record_write "$record" "$pane" "$run" 0; then
      fm_backend_herdr_kill_serialized "$FM_NM_REVIEW_SESSION" "$pane" || true
      return 1
    fi
    fm_nm_review_pane_presence "$pane" || return 1
  fi
  fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane rename "$pane" no-mistakes >/dev/null 2>&1 || return 1
  printf -v cmd 'cd %q && no-mistakes attach --run %q' "$FM_NM_REVIEW_WORKTREE" "$run"
  fm_backend_herdr_cli "$FM_NM_REVIEW_SESSION" pane run "$pane" "$cmd" >/dev/null 2>&1 || return 1
  fm_nm_review_pane_record_write "$record" "$pane" "$run" 1
}

fm_nm_review_pane_main() {
  local id=${1:-} state
  case "$id" in
    -h|--help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; return 0 ;;
    ''|*[!A-Za-z0-9._-]*) echo 'usage: fm-nm-review-pane.sh <task-id>' >&2; return 2 ;;
  esac
  [ "$#" = 1 ] || { echo 'usage: fm-nm-review-pane.sh <task-id>' >&2; return 2; }
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$FM_NM_REVIEW_PANE_LIB_DIR/.." && pwd)}}/state}
  [ "$(fm_meta_get "$state/$id.meta" backend)" = herdr ] || return 0
  [ -z "$(fm_meta_get "$state/$id.meta" remote_host)" ] || return 0
  FM_CREW_STATE_NO_FORGE=1 "$FM_NM_REVIEW_PANE_LIB_DIR/fm-crew-state.sh" "$id" --sync-review-pane >/dev/null
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_nm_review_pane_main "$@"
fi
