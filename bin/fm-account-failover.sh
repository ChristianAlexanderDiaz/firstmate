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
# task to `run`, which consumes the record first so a limit is handled exactly
# once, then:
#   1. Drops the record silently when it is stale (another incarnation, a task
#      no longer a canonical claude ship or scout) or names no usage limit: the
#      hook's limit text and the rendered limit prompt are two independent
#      signals, and either one confirms it.
#   2. Answers Claude's usage-limit prompt, when it is on screen, with its
#      cancel key (Escape), which leaves the session stopped exactly as the
#      prompt's "Stop and wait for limit to reset" option does. That key cannot
#      select any option, so no paid choice (usage credits, extra usage, an
#      upgrade) can ever be picked, whatever order the prompt lists them in.
#   3. Takes one `quota-axi --all-accounts --json` snapshot and picks an
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
#   7. Refuses a second move of the same task within
#      FM_ACCOUNT_FAILOVER_REPEAT_SECS (1800) of the last one, raising the same
#      blocked line instead, so a misread account can never ping-pong a worker.
# `run` prints one line for its caller: `moved <id> <from> <to>`,
# `blocked <id> <reason>`, or `skipped <id> <reason>`. Secondmates are not
# moved: they carry no StopFailure hook, and a supervisor's account is also the
# account every worker it spawns inherits.
#
# Choice. `choose` reads the map's account names in order and one snapshot,
# and qualifies an account only when exactly one fresh claude row carries its
# name, every quota scope that applies to the worker's model (all_models plus
# each model:<family> scope the model id names; every model scope when the
# model is unknown) is known, none of those scopes is exhausted now or bounded
# by a credits window, and the lowest of them is above the map's floor
# (default 5 percent). The worker's current account never qualifies. Above the
# floor, the plan windows still have room, so the next turns draw on the plan
# rather than on paid extra usage. Qualifying accounts rank by spendPriority
# (quota-axi's own spend-first ranker, known before unknown), then remaining
# percent, then map order. It prints `pick<TAB><account><TAB><percent>` and
# exits 0, or `none<TAB><summary>` and exits 1; a malformed input exits 2.
#
# Environment knobs:
#   FM_ACCOUNT_FAILOVER_QUOTA_SECONDS  bound on the quota snapshot (90)
#   FM_ACCOUNT_FAILOVER_REPEAT_SECS    no second move inside this window (1800)
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
# Claude's own limit text, as the hook's last_assistant_message and the
# transcript render it ("You've hit your weekly limit · resets ...").
FM_ACCOUNT_FAILOVER_LIMIT_RE='[Ll]imit'

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

# choose_json <map-text> <snapshot-file> <current> <model>
# Prints one JSON array of per-account verdicts in map order.
choose_json() {
  local map=$1 snapshot=$2 current=$3 model=$4 floor names
  floor=$(printf '%s\n' "$map" | awk -F'\t' '$1 == "floor" { print $2; exit }')
  names=$(printf '%s\n' "$map" | awk -F'\t' '$1 == "account" { print $2 }' | jq -R . | jq -sc .)
  jq -c --argjson names "$names" --argjson floor "${floor:-$FM_WORKER_ACCOUNT_FAILOVER_DEFAULT_FLOOR}" \
    --arg current "$current" --arg model "$model" '
    def short_time: if type == "string" then sub("\\.[0-9]+"; "") | sub(":[0-9]{2}(\\+00:00|Z)$"; "Z") else null end;
    (if ($model == "" or $model == "default") then null
     else ($model | ascii_downcase | [splits("[^a-z0-9]+")] | map(select(length > 0))) end) as $tokens |
    . as $snap |
    if (($snap | type) != "object") or (($snap.providers | type) != "array") then error("snapshot has no providers array") else . end |
    [ $names | to_entries[] | .key as $order | .value as $name |
      [ $snap.providers[] | select(type == "object" and .provider == "claude" and .account == $name) ] as $rows |
      { name: $name, order: $order } +
      (if ($rows | length) == 0 then { ok: false, why: "no quota reading for this account" }
      elif ($rows | length) > 1 then { ok: false, why: "more than one quota reading for this account" }
      else
        $rows[0] as $row |
        ([ ($row.windows // [])[] | select(type == "object") ]) as $windows |
        ([ ($row.quotaSemantics.effectiveAvailability // [])[] | select(type == "object") |
           select(.scope == "all_models" or
             ((.scope | type) == "string" and (.scope | startswith("model:")) and
              ($tokens == null or ((.scope[6:] | ascii_downcase) as $m | $tokens | index($m)) != null))) ]) as $scopes |
        if ($row.state.stale // false) == true then { ok: false, why: "its quota reading is stale" }
        elif ([ $scopes[] | select(.scope == "all_models") ] | length) != 1 then { ok: false, why: "its all-models quota is unknown" }
        elif any($scopes[]; .status != "known" or ((.effectivePercentRemaining | type) != "number")) then { ok: false, why: "its quota is unknown" }
        else
          ($scopes | min_by(.effectivePercentRemaining)) as $limiting |
          ($limiting.runway.limitingWindowId // (($limiting.limitingWindowIds // [])[0])) as $wid |
          ([ $windows[] | select(.id == $wid) ][0].resetsAt | short_time) as $resets |
          ([ $windows[] | select(.kind == "credits") | .id ]) as $credit_ids |
          { percent: $limiting.effectivePercentRemaining, resets: $resets,
            spend: (if ($limiting.selection.status // "") == "known" and (($limiting.selection.spendPriority | type) == "number")
                    then $limiting.selection.spendPriority else null end) } +
          if any($scopes[]; (.boundedBy // []) as $b | any($credit_ids[]; . as $c | ($b | index($c)) != null))
          then { ok: false, why: "its availability counts paid usage credits" }
          elif any($scopes[]; (.runway.status // "") == "exhausted_now") then { ok: false, why: "it is exhausted now" }
          elif $limiting.effectivePercentRemaining <= $floor then { ok: false, why: "at or below the \($floor)% floor" }
          else { ok: true } end
        end
      end) |
      if $name == $current then .ok = false | .why = "the account the worker just ran out on" else . end ]' "$snapshot"
}

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
  verdicts=$(choose_json "$map" "$snapshot" "$current" "$model" 2>/dev/null) || {
    echo "error: snapshot '$snapshot' is not a quota-axi --all-accounts --json snapshot" >&2
    return 2
  }
  choose_print "$verdicts"
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
  ID=${1:-}
  [ -n "$ID" ] || die "run needs a task id"
  [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || die "FM_HOME must name this firstmate home"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  case "$ID" in *[!A-Za-z0-9._-]* | .*) die "'$ID' is not a valid task id" ;; esac
  META="$STATE/$ID.meta"
  NM_SECONDS=${FM_ACCOUNT_FAILOVER_NM_SECONDS:-20}
  local marker_file="$STATE/$ID.usage-limit" marker message gen menu=0 now ledger last_ts
  local snapshot current pick choice to note run_id out recent=${FM_ACCOUNT_FAILOVER_REPEAT_SECS:-1800}
  local menu_wait=${FM_ACCOUNT_FAILOVER_MENU_WAIT:-5} quota_seconds=${FM_ACCOUNT_FAILOVER_QUOTA_SECONDS:-90}

  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$SCRIPT_DIR/fm-nm-run-lib.sh"

  local lock="$STATE/.account-failover-$ID.lock"
  fm_lock_try_acquire "$lock" || skipped "another failover is already running for this task"
  # shellcheck disable=SC2064  # The lock path is fixed now, by design.
  trap "fm_lock_release '$lock' >/dev/null 2>&1 || true" EXIT

  [ -f "$marker_file" ] || skipped "no usage-limit record"
  marker=$(cat "$marker_file" 2>/dev/null) || marker=
  rm -f "$marker_file" || die "could not consume $marker_file"

  MAP=$(fm_worker_account_failover_load "$CONFIG" 2>/dev/null) || MAP=invalid
  [ -n "$MAP" ] || skipped "this home has no config/$FM_WORKER_ACCOUNT_FAILOVER_FILE"
  [ -f "$META" ] || skipped "no task record"
  [ "$(fm_meta_get "$META" harness)" = claude ] || skipped "not a canonical claude worker"
  KIND=$(fm_meta_get "$META" kind)
  [ -n "$KIND" ] || KIND=ship
  case "$KIND" in ship | scout) ;; *) skipped "a $KIND is not moved between accounts" ;; esac
  [ -z "$(fm_meta_get "$META" remote_host)" ] || skipped "a remotely placed worker"
  gen=$(marker_field "$marker" gen)
  [ -n "$gen" ] && [ "$gen" = "$(fm_meta_get "$META" busy_gen)" ] \
    || skipped "the usage-limit record belongs to an earlier incarnation"
  WT=$(fm_meta_get "$META" worktree)
  message=$(marker_field "$marker" message)

  fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1 || skipped "the task endpoint does not validate"
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  T=$FM_BACKEND_VALIDATED_TARGET

  # Two independent signals confirm a usage limit rather than a transient 429.
  if wait_menu shown "$menu_wait"; then
    menu=1
  fi
  if [ "$menu" = 0 ] && ! printf '%s' "$message" | grep -Eq -- "$FM_ACCOUNT_FAILOVER_LIMIT_RE"; then
    skipped "the rate-limit turn end shows no usage limit"
  fi
  local limit_text=${message:-Claude usage limit reached}

  # Answer the prompt with its stop outcome before anything else. Escape is the
  # one key that can never select a paid option.
  if [ "$menu" = 1 ]; then
    fm_backend_send_key "$BACKEND" "$T" Escape "fm-$ID" >/dev/null 2>&1 \
      || status_blocked "Claude usage limit reached ($limit_text); its limit prompt could not be answered, so the worker was not moved"
    wait_menu gone "$menu_wait" \
      || status_blocked "Claude usage limit reached ($limit_text); its limit prompt stayed open after Escape, so the worker was not moved"
  fi

  [ "$MAP" != invalid ] \
    || status_blocked "Claude usage limit reached ($limit_text); config/$FM_WORKER_ACCOUNT_FAILOVER_FILE is malformed, so the worker was left stopped"
  if [ -e "$CONFIG/claude-account" ] || [ -L "$CONFIG/claude-account" ]; then
    status_blocked "Claude usage limit reached ($limit_text); config/claude-account pins every Claude worker to one account, so the worker was left stopped"
  fi

  ledger="$STATE/$ID.account-failover"
  now=$(date +%s)
  last_ts=$(tail -1 "$ledger" 2>/dev/null | awk '{print $1}')
  case "$last_ts" in
    '' | *[!0-9]*) ;;
    *)
      [ $((now - last_ts)) -ge "$recent" ] \
        || status_blocked "Claude usage limit reached ($limit_text) again within $((recent / 60)) minutes of moving this worker to another account, so it was left stopped rather than moved twice"
      ;;
  esac

  command -v quota-axi >/dev/null 2>&1 \
    || status_blocked "Claude usage limit reached ($limit_text); quota-axi is not installed, so no other account could be checked and the worker was left stopped"
  snapshot="$STATE/.$ID.account-failover-quota.$$.json"
  if ! fm_run_timed "$quota_seconds" quota-axi --all-accounts --json > "$snapshot" 2>/dev/null </dev/null; then
    rm -f "$snapshot"
    status_blocked "Claude usage limit reached ($limit_text); the quota-axi --all-accounts snapshot failed, so the worker was left stopped"
  fi
  current=$(current_account "$marker")
  choice=$(choose_json "$MAP" "$snapshot" "$current" "$(fm_meta_get "$META" model)" 2>/dev/null) || {
    rm -f "$snapshot"
    status_blocked "Claude usage limit reached ($limit_text); the quota-axi --all-accounts snapshot was unreadable, so the worker was left stopped"
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

  note="$STATE/.$ID.account-failover-note.$$"
  {
    echo "Your previous agent stopped at its Claude account's usage limit (\"$limit_text\")."
    echo "Firstmate chose that limit's stop option and moved this task to another signed-in Claude account with room; nothing was paid for."
    if [ -n "$run_id" ]; then
      echo "This task's no-mistakes run $run_id was aborted cleanly before the move; when you reach validation again, start a fresh run as your Definition of done describes."
    fi
    echo "Re-read your instructions and durable records, inspect git status and git log in this local copy, and continue the task from where the work stands."
  } > "$note" || die "could not write the handoff note"
  wait_classified "${FM_ACCOUNT_FAILOVER_SETTLE_WAIT:-20}" || true
  if ! out=$("$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --claude-account "$to" --note-file "$note" 2>&1); then
    rm -f "$note"
    status_blocked "Claude usage limit reached ($limit_text); the move to another Claude account failed: $(printf '%s\n' "$out" | grep -m1 '^error:' || printf '%s\n' "$out" | tail -1)"
  fi
  rm -f "$note"
  printf '%s %s %s\n' "$now" "${current:-unknown}" "$to" >> "$ledger" \
    || echo "error: could not append to $ledger" >&2
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

case "${1:-}" in
  record) shift; cmd_record "$@" ;;
  choose) shift; cmd_choose "$@" ;;
  run) shift; cmd_run "$@" ;;
  tick) shift; cmd_tick ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
