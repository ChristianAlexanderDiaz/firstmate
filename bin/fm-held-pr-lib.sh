#!/usr/bin/env bash
# Slow GitHub polling for structured task holds; source from poll consumers.
# config/held-pr-poll-interval is seconds (1..86400), default 3600.
# fm_held_pr_due <state> <consumer> <url> <task...> returns false only when
# every owner is held and this exact task/status/hold generation was observed
# successfully inside the interval. Call fm_held_pr_observed after success.
# Holds use fm-captain-hold open; declared external waits use the classifier.
# Unknown hold evidence keeps ordinary polling. No reason prose is inspected.
# Two consumers each use 256 fixed slots under state/held-pr-poll; collisions
# cause extra reads, never suppress another PR. Failed/quota reads do not stamp.
# A due held observation must bypass success caching so an older OPEN cannot
# restart a full slow interval after the forge has merged the PR.
# FM_TEST_SEAM=1 and FM_TEST_HELD_PR_NOW provide a deterministic epoch clock.

_FM_HELD_PR_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_HELD_PR_BIN/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_HELD_PR_BIN/fm-timeout-lib.sh"

fm_held_pr_signature() { # <state> <task>; stdout is the hold generation
  local state=$1 task=$2 wait identity
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  wait=$(status_declared_wait_line "$state/$task.status")
  if status_is_paused "$wait"; then
    printf '%s\n' "$wait"
  else
    identity=$(fm_run_timed 5 "$_FM_HELD_PR_BIN/fm-captain-hold.sh" open "$task" --identity 2>/dev/null) || return 1
    printf '%s\n' "$identity"
  fi
  # A new status or metadata generation must not inherit the old hold's delay.
  for identity in "$state/$task.meta" "$state/$task.status"; do
    if [ -f "$identity" ]; then cksum "$identity" || return 1
    else printf 'absent %s\n' "$identity"; fi
  done
}

fm_held_pr_due() {
  local state=$1 consumer=$2 url=$3 task signatures='' signature interval=3600
  local config now key slot stored_key='' stored_at='' extra=''
  shift 3
  FM_HELD_PR_STAMP=
  FM_HELD_PR_RECORD=
  [ ! -L "$state/held-pr-poll" ] || return 0
  [ "$#" -gt 0 ] || return 0
  case "$consumer" in merge|contributions) ;; *) return 0 ;; esac
  case "$url" in https://github.com/*/pull/*) ;; *) return 0 ;; esac
  config=${FM_CONFIG_OVERRIDE:-${FM_HOME:-${state%/state}}/config}
  if [ -f "$config/held-pr-poll-interval" ]; then
    IFS= read -r interval < "$config/held-pr-poll-interval" || :
    case "$interval" in ''|*[!0-9]*|????????*) interval=3600 ;; esac
    interval=$((10#$interval))
    [ "$interval" -ge 1 ] && [ "$interval" -le 86400 ] || interval=3600
  fi
  key=$(printf '%s\n' "$url" "$@" | cksum)
  slot=${key%% *}; slot=$((slot % 256))
  FM_HELD_PR_STAMP="$state/held-pr-poll/$consumer-$slot"
  for task in "$@"; do
    if ! signature=$(fm_held_pr_signature "$state" "$task"); then
      rm -f -- "$FM_HELD_PR_STAMP"
      FM_HELD_PR_STAMP=
      return 0
    fi
    signatures="$signatures$signature"$'\n'
  done
  key=$(printf '%s\n' "$key" "$signatures" | cksum)
  now=$(date +%s)
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then now=${FM_TEST_HELD_PR_NOW:-$now}; fi
  if [ -f "$FM_HELD_PR_STAMP" ] && [ ! -L "$FM_HELD_PR_STAMP" ]; then
    IFS='|' read -r stored_key stored_at extra < "$FM_HELD_PR_STAMP" || :
    case "$stored_at" in ''|*[!0-9]*|????????????*) stored_at=0 ;; esac
    stored_at=$((10#$stored_at))
    if [ "$stored_key" = "$key" ] && [ -z "$extra" ] \
      && [ "$now" -ge "$stored_at" ] && [ "$((now - stored_at))" -lt "$interval" ]; then
      return 1
    fi
  fi
  FM_HELD_PR_RECORD="$key|$now"
  return 0
}

fm_held_pr_observed() {
  local dir tmp
  [ -n "${FM_HELD_PR_STAMP:-}" ] && [ -n "${FM_HELD_PR_RECORD:-}" ] || return 0
  dir=${FM_HELD_PR_STAMP%/*}
  [ ! -L "$dir" ] || return 0
  mkdir -p "$dir" || return 0
  tmp=$(mktemp "$dir/.stamp.XXXXXX") || return 0
  printf '%s\n' "$FM_HELD_PR_RECORD" > "$tmp" && mv -f -- "$tmp" "$FM_HELD_PR_STAMP"
  rm -f -- "$tmp"
}
