#!/usr/bin/env bash
# fm-account-failover.sh - move a Claude worker that hit its account's usage
# limit onto another signed-in Claude account that still has room.
#
# Usage:
#   fm-account-failover.sh record <config-dir> <state-dir> <task-id> <busy-gen>
#   fm-account-failover.sh choose --map <file> --snapshot <file>
#                                 [--current <account>] [--model <id>]
#   fm-account-failover.sh run <task-id>
#   fm-account-failover.sh tick
#
# Opt-in through config/claude-failover (docs/configuration.md "Claude account
# failover"; bin/fm-worker-account-lib.sh owns its format). A home without that
# file behaves exactly as before: `record` writes nothing, so `tick` and `run`
# find nothing to do.
#
# Detection. Every Claude ship and scout launched by bin/fm-spawn.sh runs
# `record` from its StopFailure hook, the turn end Claude reports for an API
# error. `record` reads the hook's JSON from stdin and, only for
# `"error": "rate_limit"`, writes state/<id>.usage-limit naming the busy
# generation that hook belongs to, the CLAUDE_CONFIG_DIR the worker actually
# runs under (the hook inherits Claude's own environment), and the limit text
# Claude printed. It never fails the hook.
#
# The move. `tick` (run by bin/fm-watch.sh once per cycle) hands each recorded
# task to `run`, which enters the control plane's gate, lease, and lifecycle
# boundary before consuming the generation-bound record exactly once, then:
#   1. Drops the record silently when it is stale (another incarnation, a task
#      no longer a canonical claude ship or scout) or the rendered usage-limit
#      prompt is absent.
#   2. Answers Claude's usage-limit prompt with its
#      cancel key (Escape), which leaves the session stopped exactly as the
#      prompt's "Stop and wait for limit to reset" option does. That key cannot
#      select any option, so no paid choice (usage credits, extra usage, an
#      upgrade) can ever be picked, whatever order the prompt lists them in.
#   3. Takes one fresh `quota-axi --all-accounts --json` snapshot and picks an
#      account of the map through `choose`.
#   4. With no qualifying account, leaves the worker stopped at its prompt and
#      appends one `blocked:` line to the task's status naming each account's
#      quota and reset time.
#   5. For a ship whose own no-mistakes run is still active, aborts that run
#      through `no-mistakes axi abort --run <id>` and proves it terminal before
#      anything moves; a run it cannot read or stop blocks the move instead.
#   6. Relaunches the worker through bin/fm-control.sh relaunch
#      --claude-account <name> with a handoff note, so the replacement resumes
#      from the task's instructions and durable records and the task record
#      carries claude_account=<name>. It never resumes the old conversation:
#      prompt caching does not carry across accounts, so resuming would resend
#      the whole transcript uncached on the new account, while a fresh agent
#      reads only the instructions, the local copy, and a short note.
# `run` prints one line for its caller: `moved <id> <from> <to>`,
# `blocked <id> <reason>`, or `skipped <id> <reason>`. Secondmates are not
# moved: they carry no StopFailure hook, and a supervisor's account is also the
# account every worker it spawns inherits.
#
# Choice. `choose` reads the map's account names in order and one snapshot,
# and qualifies an account only when exactly one fresh, unreused claude row carries its
# name, every quota scope that applies to the worker's model (all_models plus
# each legacy or model-identity scope its alias or full id can use, including
# both opusplan phases and best choices; unresolved scope identities always
# apply, and every model scope applies when the worker's family is unresolved)
# is known, none of those scopes is exhausted now or bounded
# by a credits window, paid extra usage is disabled, its root is usable and
# signed in, and the lowest scope is above the fixed 5 percent safety margin.
# The worker's current account never qualifies. Qualifying accounts rank by
# spendPriority
# (quota-axi's own spend-first ranker, known before unknown), then remaining
# percent, then map order. It prints `pick<TAB><account><TAB><percent>` and
# exits 0, or `none<TAB><summary>` and exits 1; a malformed input exits 2.
#
# Environment knobs:
#   FM_ACCOUNT_FAILOVER_QUOTA_SECONDS  bound on the quota snapshot (90)
#   FM_ACCOUNT_FAILOVER_MENU_WAIT      seconds to wait for the prompt to render
#                                      or to close after Escape (5)
#   FM_ACCOUNT_FAILOVER_NM_SECONDS     bound on each no-mistakes call (20)
#   FM_ACCOUNT_FAILOVER_SETTLE_WAIT    seconds to wait for the endpoint to read
#                                      positively alive or dead before the
#                                      relaunch (20); Herdr reports Claude's
#                                      status as unknown for a moment after the
#                                      prompt closes, and the control plane
#                                      refuses an unclassified endpoint
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# The two rendered signals of Claude's usage-limit prompt (verified on Claude
# Code 2.1.287; docs/verification/runtime-backends.md): its stop option and its
# cancel hint. Both must be on screen before Escape is sent, so the key never
# lands on a screen that is not this prompt.
FM_ACCOUNT_FAILOVER_MENU_STOP_RE='Stop and wait for limit to reset'
FM_ACCOUNT_FAILOVER_MENU_CANCEL_RE='Esc to cancel'

# --- record -----------------------------------------------------------------

# record never fails and never writes outside <state-dir>/<id>.usage-limit.
cmd_record() {
  local config=${1:-} state=${2:-} id=${3:-} gen=${4:-} payload fields error message tmp
  [ -n "$config" ] && [ -n "$state" ] && [ -n "$id" ] || return 0
  [ -e "$config/$FM_WORKER_ACCOUNT_FAILOVER_FILE" ] || [ -L "$config/$FM_WORKER_ACCOUNT_FAILOVER_FILE" ] || return 0
  case "$id" in '' | *[!A-Za-z0-9._-]* | .*) return 0 ;; esac
  [ -d "$state" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  payload=$(head -c 65536)
  fields=$(printf '%s' "$payload" | jq -r '
    [(.error // "" | tostring),
     (.last_assistant_message // "" | tostring | explode | map(if . < 32 or . == 127 then 32 else . end) | implode | .[0:300])]
    | @tsv' 2>/dev/null) || return 0
  error=${fields%%$'\t'*}
  message=${fields#*$'\t'}
  [ "$error" = rate_limit ] || return 0
  tmp="$state/.$id.usage-limit.$$"
  {
    echo "v1"
    echo "ts=$(date +%s)"
    echo "gen=$gen"
    if [ -n "${CLAUDE_CONFIG_DIR+x}" ]; then
      echo "config_dir_set=1"
      echo "config_dir=$CLAUDE_CONFIG_DIR"
    else
      echo "config_dir_set=0"
      echo "config_dir="
    fi
    echo "message=$message"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$state/$id.usage-limit" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# --- choose -----------------------------------------------------------------

cmd_choose() {
  local map_file='' snapshot='' current='' model='' map verdicts want
  while [ $# -gt 0 ]; do
    want=${1:-}
    case "$want" in
      --map | --snapshot | --current | --model)
        [ $# -ge 2 ] || { echo "error: $want requires a value" >&2; return 2; }
        case "$want" in
          --map) map_file=$2 ;;
          --snapshot) snapshot=$2 ;;
          --current) current=$2 ;;
          --model) model=$2 ;;
        esac
        shift 2
        ;;
      *) echo "error: unexpected argument '$want'" >&2; return 2 ;;
    esac
  done
  [ -n "$map_file" ] && [ -n "$snapshot" ] || { echo "error: choose needs --map and --snapshot" >&2; return 2; }
  [ -f "$snapshot" ] || { echo "error: snapshot '$snapshot' is not a readable file" >&2; return 2; }
  map=$(fm_worker_account_failover_read "$map_file") || {
    echo "error: map '$map_file' is absent, unreadable, or malformed" >&2
    return 2
  }
  verdicts=$(fm_worker_account_failover_quota "$map" "$(cat "$snapshot")" "$current" "$model" 2>/dev/null) || {
    echo "error: snapshot '$snapshot' is not a quota-axi --all-accounts --json snapshot" >&2
    return 2
  }
  verdicts=$(choose_usable "$verdicts" "$map" "$(cat "$snapshot")" "$(dirname "$map_file")" "$model") || return 2
  choose_print "$verdicts"
}

choose_usable() {
  local verdicts=$1 map=$2 snapshot=$3 config=$4 model=$5 name reason
  while IFS= read -r name; do
    if ! reason=$(fm_worker_account_failover_select "$config" "$name" claude "$model" "$snapshot" "$map" 2>&1); then
      verdicts=$(printf '%s' "$verdicts" | jq -c --arg n "$name" --arg r "$reason" \
        'map(if .name == $n then .ok = false | .why = $r else . end)') || return 1
    fi
  done < <(printf '%s' "$verdicts" | jq -r '.[] | select(.ok) | .name')
  printf '%s\n' "$verdicts"
}

# choose_print <verdicts-json>: the pick/none line and its exit status.
choose_print() {
  local pick
  pick=$(printf '%s' "$1" | jq -r '
    [ .[] | select(.ok) ] | sort_by([(if .spend == null then 1 else 0 end), -(.spend // 0), -.percent, .order])
    | first // empty | "pick\t\(.name)\t\(.percent)"')
  if [ -n "$pick" ]; then
    printf '%s\n' "$pick"
    return 0
  fi
  printf 'none\t%s\n' "$(printf '%s' "$1" | jq -r '
    [ .[] | "\(.name): " +
      (if .percent != null then "\(.percent)% left, " else "" end) + .why +
      (if .resets != null then ", resets \(.resets)" else "" end) ] | join("; ")')"
  return 1
}

# --- run --------------------------------------------------------------------

die() {
  echo "error: $1" >&2
  exit 1
}

marker_field() {  # <marker-text> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# status_blocked <reason>: the one supervisor-actionable line for this limit.
status_blocked() {
  printf 'blocked: %s\n' "$1" >> "$STATE/$ID.status" \
    || echo "error: could not append the blocked line to $STATE/$ID.status: $1" >&2
  printf 'blocked %s %s\n' "$ID" "$1"
  exit 0
}

skipped() {
  printf 'skipped %s %s\n' "$ID" "$1"
  exit 0
}

menu_visible() {
  local screen
  screen=$(fm_backend_visible_capture "$BACKEND" "$T" "fm-$ID" 2>/dev/null) || return 1
  printf '%s\n' "$screen" | grep -Fq -- "$FM_ACCOUNT_FAILOVER_MENU_STOP_RE" \
    && printf '%s\n' "$screen" | grep -Fq -- "$FM_ACCOUNT_FAILOVER_MENU_CANCEL_RE"
}

# wait_menu <want: shown|gone> <seconds>
wait_menu() {
  local want=$1 limit=$2 elapsed=0
  while :; do
    if menu_visible; then
      [ "$want" = shown ] && return 0
    else
      [ "$want" = gone ] && return 0
    fi
    awk -v e="$elapsed" -v t="$limit" 'BEGIN{exit !(e < t)}' || return 1
    sleep 0.5
    elapsed=$(awk -v e="$elapsed" 'BEGIN{printf "%.1f", e + 0.5}')
  done
}

# wait_classified <seconds>: until the endpoint reads alive or dead.
wait_classified() {
  local limit=$1 elapsed=0
  while :; do
    case "$(fm_backend_agent_state "$BACKEND" "$T" 2>/dev/null)" in
      alive | dead) return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$limit" 'BEGIN{exit !(e < t)}' || return 1
    sleep 0.5
    elapsed=$(awk -v e="$elapsed" 'BEGIN{printf "%.1f", e + 0.5}')
  done
}

# current_account <marker-text>: the map account the worker ran under, or empty.
current_account() {
  local marker=$1 set dir name declared root real want
  set=$(marker_field "$marker" config_dir_set)
  dir=$(marker_field "$marker" config_dir)
  if [ "$set" = 1 ] || [ "$set" = 0 ]; then
    want=
    if [ "$set" = 1 ]; then
      want=$(cd "$dir" 2>/dev/null && pwd -P) || want=$dir
    fi
    while IFS=$'\t' read -r _ name declared; do
      [ -n "$name" ] || continue
      root=$declared
      [ "$declared" != ordinary ] || root=
      if [ "$set" = 0 ]; then
        [ -z "$root" ] && { printf '%s\n' "$name"; return 0; }
      elif [ -n "$root" ]; then
        real=$(cd "$root" 2>/dev/null && pwd -P) || real=$root
        [ "$real" = "$want" ] && { printf '%s\n' "$name"; return 0; }
      fi
    done < <(printf '%s\n' "$MAP" | awk -F'\t' '$1 == "account"')
  fi
  fm_meta_get "$META" claude_account
}

# nm_active_run: prints this ship's own active no-mistakes run id, nothing when
# it has none, and returns 1 when that cannot be established.
nm_active_run() {
  local branch overview selection id detail
  [ "$KIND" = ship ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 0
  [ -n "$branch" ] || return 0
  overview=$(fm_nm_run_bounded "$WT" "$NM_SECONDS" axi 2>&1) || {
    case "$overview" in *"repo not initialized"*) return 0 ;; esac
    return 1
  }
  selection=$(fm_nm_select_run "$branch" "$overview" "$WT" "$NM_SECONDS")
  case "$selection" in
    absent) return 0 ;;
    selected\|*) ;;
    *) return 1 ;;
  esac
  id=${selection#selected|}
  id=${id%%|*}
  detail=$(fm_nm_run_checked "$WT" "$NM_SECONDS" axi status --run "$id") || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$detail" id)")" = "$id" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$detail" branch)")" = "$branch" ] || return 1
  fm_nm_run_is_active "$detail" || return 0
  printf '%s\n' "$id"
}

nm_run_terminal() {  # <run-id>
  local detail
  detail=$(fm_nm_run_checked "$WT" "$NM_SECONDS" axi status --run "$1") || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$detail" id)")" = "$1" ] || return 1
  ! fm_nm_run_is_active "$detail"
}

cmd_run() {
  exec "$SCRIPT_DIR/fm-control.sh" "${1:-}" relaunch --usage-limit
}

fm_account_failover_recover() {
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  NM_SECONDS=${FM_ACCOUNT_FAILOVER_NM_SECONDS:-20}
  local marker_file="$STATE/$ID.usage-limit" marker message gen
  local snapshot current pick choice to run_id
  local menu_wait=${FM_ACCOUNT_FAILOVER_MENU_WAIT:-5} quota_seconds=${FM_ACCOUNT_FAILOVER_QUOTA_SECONDS:-90}

  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$SCRIPT_DIR/fm-nm-run-lib.sh"

  [ -f "$marker_file" ] || skipped "no usage-limit record"
  marker=$(cat "$marker_file" 2>/dev/null) || marker=
  gen=$(marker_field "$marker" gen)
  if [ -z "$gen" ] || [ "$gen" != "$(fm_meta_get "$META" busy_gen)" ]; then
    rm -f "$marker_file" || die "could not consume $marker_file"
    skipped "the usage-limit record belongs to an earlier incarnation"
  fi
  rm -f "$marker_file" || die "could not consume $marker_file"

  MAP=$(fm_worker_account_failover_load "$CONFIG" 2>/dev/null) || MAP=invalid
  [ -n "$MAP" ] || skipped "this home has no config/$FM_WORKER_ACCOUNT_FAILOVER_FILE"
  [ "$RECORDED_HARNESS" = claude ] || skipped "not a canonical claude worker"
  case "$KIND" in ship | scout) ;; *) skipped "a $KIND is not moved between accounts" ;; esac
  message=$(marker_field "$marker" message)

  wait_menu shown "$menu_wait" || skipped "the rate-limit turn end shows no usage-limit prompt"
  local limit_text=${message:-Claude usage limit reached}

  # Answer the prompt with its stop outcome before anything else. Escape is the
  # one key that can never select a paid option.
  fm_backend_send_key "$BACKEND" "$T" Escape "fm-$ID" >/dev/null 2>&1 \
    || status_blocked "Claude usage limit reached ($limit_text); its limit prompt could not be answered, so the worker was not moved"
  wait_menu gone "$menu_wait" \
    || status_blocked "Claude usage limit reached ($limit_text); its limit prompt stayed open after Escape, so the worker was not moved"

  [ "$MAP" != invalid ] \
    || status_blocked "Claude usage limit reached ($limit_text); config/$FM_WORKER_ACCOUNT_FAILOVER_FILE is malformed, so the worker was left stopped"
  if [ -e "$CONFIG/claude-account" ] || [ -L "$CONFIG/claude-account" ]; then
    status_blocked "Claude usage limit reached ($limit_text); config/claude-account pins every Claude worker to one account, so the worker was left stopped"
  fi

  command -v quota-axi >/dev/null 2>&1 \
    || status_blocked "Claude usage limit reached ($limit_text); quota-axi is not installed, so no other account could be checked and the worker was left stopped"
  snapshot="$STATE/.$ID.account-failover-quota.$$.json"
  if ! fm_run_timed "$quota_seconds" env -u QUOTA_AXI_MAX_AGE quota-axi --all-accounts --json > "$snapshot" 2>/dev/null </dev/null; then
    rm -f "$snapshot"
    status_blocked "Claude usage limit reached ($limit_text); the quota-axi --all-accounts snapshot failed, so the worker was left stopped"
  fi
  current=$(current_account "$marker")
  choice=$(fm_worker_account_failover_quota "$MAP" "$(cat "$snapshot")" "$current" "$(fm_meta_get "$META" model)" 2>/dev/null) || {
    rm -f "$snapshot"
    status_blocked "Claude usage limit reached ($limit_text); the quota-axi --all-accounts snapshot was unreadable, so the worker was left stopped"
  }
  choice=$(choose_usable "$choice" "$MAP" "$(cat "$snapshot")" "$CONFIG" "$(fm_meta_get "$META" model)") || {
    rm -f "$snapshot"
    status_blocked "Claude usage limit reached ($limit_text); account eligibility could not be checked"
  }
  rm -f "$snapshot"
  if ! pick=$(choose_print "$choice"); then
    status_blocked "Claude usage limit reached ($limit_text); no other Claude account has room (${pick#none$'\t'}), so the worker was left stopped"
  fi
  to=$(printf '%s' "$pick" | cut -f2)

  run_id=
  if ! run_id=$(nm_active_run); then
    status_blocked "Claude usage limit reached ($limit_text); this task's no-mistakes run could not be read, so the worker was left stopped rather than moved under a possibly active run"
  fi
  if [ -n "$run_id" ]; then
    fm_nm_run_checked "$WT" "$NM_SECONDS" axi abort --run "$run_id" >/dev/null 2>&1 || true
    nm_run_terminal "$run_id" \
      || status_blocked "Claude usage limit reached ($limit_text); no-mistakes run $run_id did not stop after its abort, so the worker was left stopped"
  fi

  NOTE=$({
    echo "Your previous agent stopped at its Claude account's usage limit (\"$limit_text\")."
    echo "Firstmate chose that limit's stop option and moved this task to another signed-in Claude account with room; nothing was paid for."
    if [ -n "$run_id" ]; then
      echo "This task's no-mistakes run $run_id was aborted cleanly before the move; when you reach validation again, start a fresh run as your Definition of done describes."
    fi
    echo "Re-read your instructions and durable records, inspect git status and git log in this local copy, and continue the task from where the work stands."
  })
  NOTE_SET=1
  NEW_CLAUDE_ACCOUNT=$to
  CLAUDE_ACCOUNT_SET=1
  wait_classified "${FM_ACCOUNT_FAILOVER_SETTLE_WAIT:-20}" || true
  do_relaunch >/dev/null
  printf 'moved %s %s %s\n' "$ID" "${current:-unknown}" "$to"
}

# --- tick -------------------------------------------------------------------

cmd_tick() {
  local state marker id
  [ -n "${FM_HOME:-}" ] || return 0
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  [ -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/$FM_WORKER_ACCOUNT_FAILOVER_FILE" ] || return 0
  for marker in "$state"/*.usage-limit; do
    [ -f "$marker" ] || continue
    id=${marker##*/}
    id=${id%.usage-limit}
    "$0" run "$id" 2>/dev/null || printf 'skipped %s the failover run failed\n' "$id"
  done
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
  record) shift; cmd_record "$@" ;;
  choose) shift; cmd_choose "$@" ;;
  run) shift; cmd_run "$@" ;;
  tick) shift; cmd_tick ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
fi
