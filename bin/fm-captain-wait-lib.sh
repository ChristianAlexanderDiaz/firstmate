#!/usr/bin/env bash
# Deliberate captain-wait parking, called by fm-control under its task lock.
# The watcher samples every WAIT_AGENT_CHECK_SECS using the exited-wait probe.
# Only a direct captain hold or an explicit [wait=captain] pause qualifies.
# Unrouted needs-decision lines belong to firstmate and never qualify alone.
# A generation-bound semantic idle record must remain unchanged for 1800s of
# observation. Missing generations, unknown busy state, and secondmates refuse.
# state/<id>.captain-wait is an atomic journal: observing -> stopping -> parked
# -> launching -> complete. It binds the full metadata (except retired busy_gen),
# generation, decision occurrence and status prefix. Answers are saved before
# launch. An interrupted launch is never retried automatically: the existing
# exited-wait recovery wake and once-per-gate marker request reconciliation.
# No lifecycle implementation lives here; exit/relaunch remain fm-control's.

fm_captain_wait_meta() {  # <meta>
  sed '/^busy_gen=/d' "$1"
}

fm_captain_wait_save() {  # <record> <json>
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" && mv "$tmp" "$1"
}

fm_captain_wait_phase() {  # <record> <phase>
  local json
  json=$(jq --arg phase "$2" '.phase=$phase' "$1") || return 1
  fm_captain_wait_save "$1" "$json"
}

fm_captain_wait_decision() {  # <task> -> JSON
  local task=$1 call line key open position rc=0
  if call=$("$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --identity 2>/dev/null); then
    [ -n "${call%#*}" ] || return 1
    jq -cn --arg call "$call" '{type:"hold",identity:$call}'
    return
  else
    rc=$?
  fi
  [ "$rc" != 2 ] || return 2
  line=$(status_declared_wait_line "$STATE/$task.status")
  [ "$(status_declared_wait_owner "$line")" = captain ] || return 1
  key=$(_fm_decision_key "$line") || return 1
  # A different unanswered item is not licensed by this captain pause.
  open=$(status_own_open_decisions "$STATE/$task.status")
  [ -z "$(printf '%s\n' "$open" | awk -F '\t' -v key="$key" 'NF && $1 != key')" ] || return 1
  position=$(FM_CAPTAIN_WAIT_LINE="$line" awk '$0 == ENVIRON["FM_CAPTAIN_WAIT_LINE"] { position=NR } END { print position+0 }' "$STATE/$task.status") || return 2
  [ "$position" -gt 0 ] || return 2
  jq -cn --arg line "$line" --arg key "$key" --argjson position "$position" \
    '{type:"status",identity:$line,key:$key,position:$position}'
}

fm_captain_wait_matches() {  # <record> <meta> <task>
  local gen saved
  [ -f "$1" ] && [ -f "$2" ] || return 1
  [ "$(jq -r '.meta' "$1")" = "$(fm_captain_wait_meta "$2")" ] || return 1
  gen=$(fm_busy_current_gen "$STATE" "$3" 2>/dev/null) || gen=
  saved=$(jq -er '.gen | select(type == "string" and length > 0)' "$1") || return 1
  [ -n "$saved" ] && { [ "$gen" = "$saved" ] || [ -z "$gen" ]; }
}

fm_captain_wait_answer() {  # <record> <task> -> answer, only for the same occurrence
  local record=$1 task=$2 type identity prefix current key line verb found=0
  type=$(jq -r '.decision.type' "$record") || return 1
  identity=$(jq -r '.decision.identity' "$record") || return 1
  if [ "$type" = hold ]; then
    "$SCRIPT_DIR/fm-captain-hold.sh" answer-for "$task" "$identity"
    return
  fi
  [ "$type" = status ] || return 1
  prefix=$(jq -r '.status' "$record") || return 1
  current=$(cat "$STATE/$task.status") || return 1
  # Truncation/replacement is not an answer. Search only the appended suffix.
  case "$current" in
    "$prefix") return 1 ;;
    "$prefix"$'\n'*) current=${current#"$prefix"$'\n'} ;;
    *) return 2 ;;
  esac
  key=$(jq -r '.decision.key' "$record") || return 1
  while IFS= read -r line; do
    [ "$(_fm_decision_key "$line")" = "$key" ] || continue
    status_line_verb "$line" verb
    case "$verb" in
      resolved)
        _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" || continue
        identity=$line; found=1 ;;
      needs-decision|blocked|paused|captain-held) return 2 ;;
    esac
  done <<< "$current"
  [ "$found" = 1 ] || return 1
  printf '%s\n' "$identity"
}

# Called immediately before exit submission too: never interrupt a newly busy
# worker or exit after its decision was answered during composer inspection.
fm_captain_wait_exit_guard() {
  local record="$STATE/$ID.captain-wait" decision busy
  fm_captain_wait_matches "$record" "$META" "$ID" || return 1
  [ "$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null)" = "$(jq -r '.gen' "$record")" ] || return 1
  busy=$(fm_busy_classify_meta "$META" "$ID" "$STATE")
  [ "${busy%% *}" = idle ] || return 1
  [ "$(fm_busy_record_read "$STATE" "$ID")" = "$(jq -r '.busy' "$record")" ] || return 1
  decision=$(fm_captain_wait_decision "$ID") || return 1
  [ "$decision" = "$(jq -c '.decision' "$record")" ]
}

fm_captain_wait_control() {
  local record="$STATE/$ID.captain-wait" phase gen busy decision json now since answer state rc
  case "$KIND" in ship|scout) ;; *) return 0 ;; esac
  now=$(date +%s)
  phase=$(jq -r '.phase // empty' "$record" 2>/dev/null) || phase=
  case "$phase" in
    complete)
      fm_captain_wait_matches "$record" "$META" "$ID" && return 0
      ;;
    stopping|parked|launching|failed)
      if ! fm_captain_wait_matches "$record" "$META" "$ID"; then
        # A separately recovered successor must not inherit this journal.
        gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null) || gen=
        if [ -n "$gen" ] && [ "$gen" != "$(jq -r '.gen' "$record")" ]; then
          rm -f "$record"
        fi
        return 0
      fi
      case "$phase" in launching|complete|failed) return 0 ;; esac
      state=$(agent_state)
      if [ "$state" != dead ]; then
        fm_captain_wait_phase "$record" failed
        return 1
      fi
      fm_captain_wait_phase "$record" parked || return 1
      rc=0
      decision=$(fm_captain_wait_decision "$ID") || rc=$?
      if [ "$rc" = 2 ] || { [ "$rc" = 0 ] && [ "$decision" != "$(jq -c '.decision' "$record")" ]; }; then
        fm_captain_wait_phase "$record" failed
        return 1
      fi
      rc=0
      answer=$(fm_captain_wait_answer "$record" "$ID") || rc=$?
      [ "$rc" != 1 ] || return 0
      if [ "$rc" != 0 ]; then
        fm_captain_wait_phase "$record" failed
        return 1
      fi
      [ "$VERB" = relaunch ] || return 0
      # Claim before invoking the existing transaction. Its own journal and
      # replacement generation resolve interruption; never launch twice blindly.
      json=$(jq --arg answer "$answer" '.answer=$answer | .phase="launching"' "$record") || return 1
      fm_captain_wait_save "$record" "$json" || return 1
      NOTE="Resume this task after its captain wait. The recorded answer is:
$answer"
      NOTE_SET=1
      if [ -f "$CONFIG/$FM_WORKER_ACCOUNT_FAILOVER_FILE" ]; then
        fm_worker_account_decision_start "$CONFIG" || return 1
      fi
      fm_captain_wait_matches "$record" "$META" "$ID" || return 1
      [ "$(agent_state)" = dead ] || return 1
      do_relaunch
      fm_captain_wait_phase "$record" complete
      return
      ;;
  esac
  [ "$VERB" = exit ] || return 0
  gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null) || return 0
  busy=$(fm_busy_classify_meta "$META" "$ID" "$STATE")
  if [ "${busy%% *}" != idle ] || ! decision=$(fm_captain_wait_decision "$ID"); then
    rm -f "$record"
    return 0
  fi
  busy=$(fm_busy_record_read "$STATE" "$ID") || return 0
  [ "${busy%% *}" = idle ] || return 0
  if ! fm_captain_wait_matches "$record" "$META" "$ID" \
    || [ "$(jq -r '.busy' "$record")" != "$busy" ] \
    || [ "$(jq -c '.decision' "$record")" != "$decision" ]; then
    json=$(jq -cn --arg meta "$(fm_captain_wait_meta "$META")" --arg gen "$gen" \
      --arg busy "$busy" --argjson decision "$decision" --argjson since "$now" \
      --arg status "$(cat "$STATE/$ID.status" 2>/dev/null || true)" \
      '{phase:"observing",meta:$meta,gen:$gen,busy:$busy,decision:$decision,since:$since,status:$status}') || return 1
    fm_captain_wait_save "$record" "$json" || return 1
    return 0
  fi
  since=$(jq -r '.since' "$record") || return 1
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((now - since))" -ge 1800 ] || return 0
  [ "$(agent_state)" = alive ] || return 0
  fm_captain_wait_exit_guard || return 0
  fm_captain_wait_phase "$record" stopping || return 1
  do_exit
  fm_captain_wait_phase "$record" parked
}
