# shellcheck shell=bash
# Machine-wide quota-paced admission. Usage: source after fm-wake-lib.sh,
# fm-project-capacity-lib.sh, and fm-timeout-lib.sh. No source-time effects.
# docs/configuration.md "Quota plan" owns the declaration schema.
#
# fm_quota_plan_load <config-dir> validates the whole declaration into
# FM_QUOTA_PLAN_JSON; absent means off. Every failure sets FM_QUOTA_PLAN_ERROR.
# fm_quota_plan_admit <home> <config> <resolved-harness> <relaunch> <kind>
# returns 0 or 75, before any launch mutation. Relaunches/secondmates are exempt.
# Its machine admission lock supplements the existing project lock, and stays
# held until fm_quota_plan_release after publication or on the spawn EXIT path.
# An admitted attempt invalidates the shared cache, forcing the next admission
# to read account-wide usage again. Neither lock can reserve future token spend:
# running workers and other machines can cross the line after admission.
#
# Snapshot: root-home state/quota-plan-snapshot.json, {fetchedAt,snapshot}.
# A successful bounded quota-axi --all-accounts --json read is cached for <=300s.
# Refresh failures never fall back to expired data. Provider freshness and reset
# validity are also checked by the reader. No ordinary --json fallback is used.
#
# fm_quota_plan_read <cache-file> <claude|codex> <now-epoch> is the ONLY quota
# field reader. The combined Claude shape is from a local quota-axi build;
# published 0.1.55 does not support it. Until a producer sample is available,
# fixtures assume all_models/all-models + seven_day/seven-day/weekly/7d,
# remaining as numeric percentage (or percentRemaining/remaining.percent), and
# resetsAt/resetAt as UTC ISO time or epoch seconds, on the row or its window.
# An ambiguous row, missing reset, unknown unit, stale reading, or missing
# claudeCombined refuses rather than guessing or combining account seats.
# Codex uses the sole provider row's weekly window, never a model-name guess.
# Account selection and the overflow seat are outside this library: it never
# changes credentials or selects an account. The configured worker pin remains
# authoritative; the combined reading is admission evidence only.

fm_quota_plan_load() {
  local file="$1/quota-plan" dir="$1"
  FM_QUOTA_PLAN_JSON=
  FM_QUOTA_PLAN_ERROR=
  while :; do
    if { [ -e "$dir" ] || [ -L "$dir" ]; } && { [ ! -d "$dir" ] || [ ! -x "$dir" ]; }; then
      FM_QUOTA_PLAN_ERROR="quota declaration cannot be inspected: $file"
      return 1
    fi
    case "$dir" in /|.) break ;; esac
    fm_dirname_to dir "$dir"
  done
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_QUOTA_PLAN_ERROR="unreadable quota declaration: $file"
    return 1
  fi
  if ! FM_QUOTA_PLAN_JSON=$(jq -Rs '
    def invalid: error("invalid quota-plan declaration");
    def date_ok:
      . as $d | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") and
      (try (($d + "T00:00:00Z" | fromdateiso8601 | strftime("%Y-%m-%d")) == $d) catch false);
    reduce (split("\n")[] | gsub("^\\s+|\\s+$"; "") |
      select(length > 0 and (startswith("#") | not)) | [scan("[^[:space:]]+")]) as $w
      ({reserves:{},lanes:[]};
      if $w[0] == "reserve" and ($w|length) == 3 and
        ($w[1] == "claude" or $w[1] == "codex") and
        ($w[2] | test("^(0|[1-9][0-9]*)(\\.[0-9]+)?$")) then
        if .reserves[$w[1]] != null or ($w[2]|tonumber) > 100 then invalid
        else .reserves[$w[1]] = ($w[2]|tonumber) end
      elif $w[0] == "lane" and ($w[1] | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (($w|length) == 2 or (($w|length) == 4 and $w[2] == "until" and ($w[3]|date_ok))) then
        if any(.lanes[]; .project == $w[1]) then invalid
        else .lanes += [{project:$w[1],until:($w[3] // null)}] end
      else invalid end)
    | if .reserves.claude == null or .reserves.codex == null then invalid else . end
  ' "$file" 2>/dev/null); then
    FM_QUOTA_PLAN_ERROR="malformed quota declaration: $file (see docs/configuration.md Quota plan)"
    return 1
  fi
}

fm_quota_plan_read() {  # <cache-file> <provider> <now>
  jq -er --arg provider "$2" --argjson now "$3" '
    def epoch:
      if type == "number" then .
      elif type == "string" then sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601
      else error("missing reset") end;
    def fresh:
      (.state.stale // false) == false and
      ((.state.status // "fresh") == "fresh") and
      (if .refreshedAt? then (.refreshedAt | epoch) as $t | $t <= $now and $now-$t <= 300 else true end);
    def weekly:
      . == "seven_day" or . == "seven-day" or . == "weekly" or . == "7d";
    def window_id:
      if type == "object" then (.id // .kind // .name) else . end;
    select((.fetchedAt|type) == "number" and .fetchedAt <= $now and $now - .fetchedAt <= 300) | .snapshot |
    select(if .generatedAt? then (.generatedAt|epoch) as $t | $t <= $now and $now-$t <= 300 else true end) |
    (if $provider == "claude" then
       [.claudeCombined[]? | select((.scope == "all_models" or .scope == "all-models") and
         (.window | window_id | weekly))]
     elif $provider == "codex" then
       [.providers[]? | select(.provider == "codex")] |
       if length != 1 or (.[0] | fresh | not) then []
       else [.[0].windows[]? | select((.id | weekly) or (.kind | weekly))] end
     else [] end) |
    select(length == 1) | .[0] | select(fresh) |
    (if (.remaining|type) == "number" then .remaining
     elif (.remaining|type) == "string" and (.remaining|test("^[0-9]+(\\.[0-9]+)?%$")) then (.remaining|rtrimstr("%")|tonumber)
     elif (.remaining|type) == "object" then (.remaining.percent // .remaining.percentRemaining)
     else (.percentRemaining // .effectivePercentRemaining) end) as $left |
    (.resetsAt // .resetAt // (if (.window|type) == "object" then (.window.resetsAt // .window.resetAt) else null end) | epoch) as $reset |
    select(($left|type) == "number" and $left >= 0 and $left <= 100 and
      $reset > $now and $reset <= $now + 604800) |
    {used:(100-$left),reset:$reset,day:((($now-($reset-604800))/86400|floor)+1)}
  ' "$1" 2>/dev/null
}

fm_quota_plan_snapshot() {  # <root-state> <now>
  local state=$1 now=$2 tmp raw
  FM_QUOTA_PLAN_CACHE="$state/quota-plan-snapshot.json"
  if [ -f "$FM_QUOTA_PLAN_CACHE" ] && jq -e --argjson now "$now" \
    '(.fetchedAt|type)=="number" and .fetchedAt <= $now and $now - .fetchedAt <= 300 and (.snapshot|type)=="object"' \
    "$FM_QUOTA_PLAN_CACHE" >/dev/null 2>&1; then
    return 0
  fi
  if ! raw=$(QUOTA_AXI_MAX_AGE=0 fm_run_timed 30 quota-axi --all-accounts --json 2>/dev/null </dev/null); then
    FM_QUOTA_PLAN_ERROR='quota-axi --all-accounts --json failed or is unsupported; fresh spawns remain queued'
    return 1
  fi
  tmp=$(umask 077; mktemp "$state/.quota-plan-snapshot.XXXXXX") || return 1
  if ! printf '%s\n' "$raw" | jq -se --argjson now "$now" \
    'select(length == 1 and (.[0]|type)=="object") | {fetchedAt:$now,snapshot:.[0]}' > "$tmp"; then
    rm -f "$tmp"
    FM_QUOTA_PLAN_ERROR='quota-axi returned unreadable JSON'
    return 1
  fi
  mv -f "$tmp" "$FM_QUOTA_PLAN_CACHE"
}

fm_quota_plan_verdict() {  # <provider> <now>; after load + snapshot
  local reading reserve
  FM_QUOTA_PLAN_VERDICT=
  if ! reading=$(fm_quota_plan_read "$FM_QUOTA_PLAN_CACHE" "$1" "$2"); then
    FM_QUOTA_PLAN_ERROR="unreadable $1 account-wide weekly quota (missing combined row, stale data, or invalid reset)"
    return 1
  fi
  reserve=$(printf '%s\n' "$FM_QUOTA_PLAN_JSON" | jq -er --arg p "$1" '.reserves[$p]') || return 1
  FM_QUOTA_PLAN_VERDICT=$(printf '%s\n' "$reading" | jq -c --argjson reserve "$reserve" \
    '. + {line:((100-$reserve)*.day/7)} | . + {open:(.used < .line)}') || return 1
  if ! printf '%s\n' "$FM_QUOTA_PLAN_VERDICT" | jq -e '.open' >/dev/null; then
    FM_QUOTA_PLAN_ERROR=$(printf '%s\n' "$FM_QUOTA_PLAN_VERDICT" | jq -r --arg p "$1" \
      '"\($p) used \(.used)% is at or above day \(.day) allowance \(.line)%"')
    return 1
  fi
}

fm_quota_plan_release() {
  [ -n "${FM_QUOTA_PLAN_LOCK_HELD:-}" ] || return 0
  fm_lock_release "$FM_QUOTA_PLAN_LOCK_HELD" || return 1
  FM_QUOTA_PLAN_LOCK_HELD=
}

fm_quota_plan_admit() {
  local home=$1 config=$2 harness=$3 relaunch=$4 kind=$5 root now
  [ "$relaunch" = 0 ] && [ "$kind" != secondmate ] || return 0
  fm_quota_plan_load "$config" || return 75
  [ -n "$FM_QUOTA_PLAN_JSON" ] || return 0
  case "$harness" in claude|codex) ;; *)
    FM_QUOTA_PLAN_ERROR="quota-plan cannot map resolved harness $harness to claude or codex"
    return 75 ;;
  esac
  root=$(fm_firstmate_root_home "$home") || return 75
  mkdir -p "$root/state" || return 75
  if ! fm_lock_try_acquire "$root/state/.quota-plan-admission.lock"; then
    FM_QUOTA_PLAN_ERROR='another quota admission is in progress; retry the queued ticket'
    return 75
  fi
  FM_QUOTA_PLAN_LOCK_HELD="$root/state/.quota-plan-admission.lock"
  now=$(date +%s)
  if ! fm_quota_plan_snapshot "$root/state" "$now" || ! fm_quota_plan_verdict "$harness" "$now"; then
    fm_quota_plan_release || true
    return 75
  fi
  # The next admission must re-observe usage, not reuse this admission's sample.
  rm -f "$FM_QUOTA_PLAN_CACHE" || { fm_quota_plan_release; return 75; }
}
