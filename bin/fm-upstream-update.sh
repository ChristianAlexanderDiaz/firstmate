#!/usr/bin/env bash
# Opt-in upstream-to-fork catch-up mechanics for /updatefirstmate.
# Usage: fm-upstream-update.sh check|arm|merge|--help
# Public update entrypoint: fm-update.sh --upstream-merge.
# config/upstream-update.json schema is owned by docs/configuration.md.
#
# check is silent when off, before the weekly slot, already checked this slot,
# or local no-mistakes runs cannot be proven idle (all repositories, including
# parked gates). The slot is in the host's local timezone (TZ is respected).
# A delayed check catches the most recent weekly slot; notifications are also
# separated by at least three and a half days to tolerate daylight-saving
# transitions, and a slot reached sooner after a proposal is consumed without
# probing, so a proposal up to that late still keeps the next weekly slot.
# A failed network probe is reported once per slot and retried silently after
# each hour; successful checks, including zero drift, consume the slot.
# FM_UPSTREAM_NOW overrides the epoch for tests.
# Four bounded git probes plus the idle read fit inside the default 30s check
# budget. Fetches download objects only: no refs, tags, or FETCH_HEAD are moved.
# No credentials, URL, subjects, or branch text are printed in notifications.
# state/.upstream-update holds four space-separated epochs: last successful
# slot, last probe attempt, last proposal, and last slot whose failure was
# reported. The proposal epoch prevents a delayed Friday proposal from being
# repeated at the next Saturday slot.
# It is serialized by .upstream-update.lock; interrupted checks retry safely.
#
# arm registers state/upstream-update.check.sh with the normal watcher; startup
# calls it only for an opted-in home or an existing shim. Without the config,
# arm (and therefore startup) retires that shim and retains the cadence record.
#
# merge must run in a clean isolated linked task worktree, on its already
# created ship branch at exactly the freshly fetched origin default tip.
# It makes a --no-ff merge of the upstream default tip, never pushes, and leaves
# conflicts intact for reporting (exit 1), with no automatic resolution/abort.
# Firstmate delegates this command only after explicit catch-up authorization;
# its selected delivery path owns validation and the PR against the fork.
set -eu
export LC_ALL=C GIT_TERMINAL_PROMPT=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/upstream-update.json"
RECORD="$STATE/.upstream-update"
CHECK_ID=upstream-update
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

fail() { printf 'upstream update: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,35{s/^# \{0,1\}//;p;}' "$0"; }

read_config() {
  # Parse data, never source operator-controlled shell text.
  local fields
  fields=$(python3 - "$CONFIG" "${FM_UPSTREAM_NOW:-$(date +%s)}" <<'PY'
import datetime
import json
import sys
import time

try:
    with open(sys.argv[1]) as source:
        config = json.load(source)
    remote = config['upstream']
    weekday = config.get('weekday', 6)
    hour = config.get('hour', 15)
    if (not isinstance(remote, str) or not remote or remote.startswith('-')
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in remote)
            or type(weekday) is not int or not 1 <= weekday <= 7
            or type(hour) is not int or not 0 <= hour <= 23
            or set(config) - {'upstream', 'weekday', 'hour'}):
        raise ValueError()
    now = int(sys.argv[2])
    local = datetime.datetime.fromtimestamp(now)
    slot = (local - datetime.timedelta(days=(local.isoweekday() - weekday) % 7)
            ).replace(hour=hour, minute=0, second=0, microsecond=0)
    if slot > local:
        slot -= datetime.timedelta(days=7)
    print(remote, int(time.mktime(slot.timetuple())), now, sep='\t')
except (OSError, ValueError, TypeError, KeyError, OverflowError):
    sys.exit('upstream update: invalid config/upstream-update.json or clock')
PY
  ) || return 1
  IFS=$'\t' read -r UPSTREAM SLOT NOW <<< "$fields"
}

# Capture each remote's actual default branch and its advertised tip; a moving
# remote or missing advertised object fails rather than comparing stale refs.
fetch_tip() {  # <remote-or-url>; sets TIP and DEFAULT_BRANCH
  local advertised
  advertised=$(fm_run_timed 4 git -C "$FM_ROOT" ls-remote --symref "$1" HEAD) || return 1
  DEFAULT_BRANCH=$(printf '%s\n' "$advertised" | awk '$1 == "ref:" && $3 == "HEAD" {sub(/^refs\/heads\//,"",$2); print $2}')
  TIP=$(printf '%s\n' "$advertised" | awk '$2 == "HEAD" && $1 != "ref:" {print $1}')
  [ -n "$DEFAULT_BRANCH" ] && [ -n "$TIP" ] || return 1
  git check-ref-format "refs/heads/$DEFAULT_BRANCH" >/dev/null || return 1
  git -C "$FM_ROOT" cat-file -e "$TIP^{commit}" 2>/dev/null && return 0
  fm_run_timed 5 git -C "$FM_ROOT" -c fetch.writeCommitGraph=false -c maintenance.auto=false fetch --quiet \
    --no-tags --no-write-fetch-head --refmap= "$1" "refs/heads/$DEFAULT_BRANCH" || return 1
  git -C "$FM_ROOT" cat-file -e "$TIP^{commit}" || return 1
}

compare_tips() {
  [ "$(git -C "$FM_ROOT" rev-parse --is-shallow-repository)" = false ] || return 1
  fetch_tip origin || return 1
  FORK_TIP=$TIP FORK_BRANCH=$DEFAULT_BRANCH
  fetch_tip "$UPSTREAM" || return 1
  UPSTREAM_TIP=$TIP UPSTREAM_BRANCH=$DEFAULT_BRANCH
  git -C "$FM_ROOT" merge-base "$FORK_TIP" "$UPSTREAM_TIP" >/dev/null || return 1
  COUNT=$(git -C "$FM_ROOT" rev-list --count "$FORK_TIP..$UPSTREAM_TIP")
}

write_record() {  # <successful-slot> <attempt-epoch> <proposal-epoch> <reported-slot>
  local tmp
  tmp=$(mktemp "$RECORD.XXXXXX") || return 1
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$tmp"
  mv -f -- "$tmp" "$RECORD"
}

check() {
  [ -f "$CONFIG" ] || return 0
  read_config || return 1
  # Load only after the opt-in gate: this library creates the state directory.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$STATE"
  fm_lock_try_acquire "$STATE/.upstream-update.lock" || return 0
  trap 'fm_lock_release "$STATE/.upstream-update.lock"' EXIT
  local last=0 attempt=0 proposal=0 reported=0 value
  if [ -f "$RECORD" ]; then
    read -r last attempt proposal reported < "$RECORD" || return 1
    for value in "$last" "$attempt" "$proposal" "$reported"; do
      case "$value" in ''|*[!0-9]*) fail 'invalid cadence record' ;; esac
    done
  fi
  [ "$last" -lt "$SLOT" ] || return 0
  if [ $((NOW - proposal)) -lt 302400 ]; then
    write_record "$SLOT" "$attempt" "$proposal" "$reported"
    return 0
  fi
  [ $((NOW - attempt)) -ge 3600 ] || return 0
  fm_nm_all_runs_idle "$FM_ROOT" || return 0
  write_record "$last" "$NOW" "$proposal" "$reported"
  if ! compare_tips >/dev/null 2>&1; then
    [ "$reported" -lt "$SLOT" ] || return 0
    printf 'upstream update: comparison unavailable; will retry silently each hour until it succeeds or the next weekly slot\n'
    write_record "$last" "$NOW" "$proposal" "$SLOT"
    return 0
  fi
  # A validation may have started during the fetch; defer the proposal without
  # consuming the weekly slot. The attempt backoff still bounds repeated fetches.
  fm_nm_all_runs_idle "$FM_ROOT" || return 0
  if [ "$COUNT" -gt 0 ]; then
    printf 'upstream update: upstream is %s commits ahead of the fork; propose /updatefirstmate upstream and wait for explicit approval\n' "$COUNT"
    proposal=$NOW
  fi
  write_record "$SLOT" "$NOW" "$proposal" "$reported"
}

arm() {
  if [ ! -f "$CONFIG" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null
    return
  fi
  read_config || return 1
  local home root tmp
  home=$(cd "$FM_HOME" && pwd -P)
  root=$(cd "$FM_ROOT" && pwd -P)
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  [ ! -L "$STATE/$CHECK_ID.check.sh" ] || fail 'check shim is a symlink'
  tmp=$(mktemp "$STATE/.upstream-update-shim.XXXXXX")
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export FM_HOME=%q FM_ROOT_OVERRIDE=%q\n' "$home" "$root"
    printf 'exec %q check\n' "$SCRIPT_DIR/fm-upstream-update.sh"
  } > "$tmp"
  chmod 700 "$tmp"
  mv -f -- "$tmp" "$STATE/$CHECK_ID.check.sh"
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null
    fail 'could not register upstream update check'
  fi
}

merge() {
  [ -f "$CONFIG" ] || fail 'upstream catch-up is not configured'
  read_config || return 1
  local root home gitdir common branch
  root=$(cd "$FM_ROOT" && pwd -P)
  home=$(cd "$FM_HOME" && pwd -P)
  gitdir=$(git -C "$root" rev-parse --absolute-git-dir)
  common=$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  [ "$root" != "$home" ] && [ "$gitdir" != "$common" ] \
    || fail 'merge requires an isolated linked task worktree, not the operating home'
  branch=$(git -C "$root" symbolic-ref --quiet --short HEAD) || fail 'create the ship branch first'
  [ -z "$(git -C "$root" status --porcelain)" ] || fail 'task worktree is dirty'
  [ ! -e "$gitdir/MERGE_HEAD" ] || fail 'a merge is already in progress'
  compare_tips || fail 'cannot compare fork and upstream defaults'
  [ "$branch" != "$FORK_BRANCH" ] && [ "$branch" != "$UPSTREAM_BRANCH" ] \
    || fail 'refusing to merge on a default branch'
  [ "$(git -C "$root" rev-parse HEAD)" = "$FORK_TIP" ] \
    || fail 'ship branch must start at the current origin default tip; preserve this branch and redispatch from that tip'
  [ "$COUNT" -gt 0 ] || { printf 'upstream update: fork already contains upstream\n'; return; }
  if ! git -C "$root" merge --no-ff --no-edit -m 'Merge upstream default branch into fork' "$UPSTREAM_TIP"; then
    printf 'upstream update: merge stopped; preserve the worktree and report conflicts:\n' >&2
    git -C "$root" diff --name-only --diff-filter=U >&2
    return 1
  fi
  printf 'upstream update: merge prepared on ship branch; selected delivery path must validate and open a PR against origin\n'
}

[ "$#" -le 1 ] || { usage >&2; exit 2; }
case "${1:-check}" in
  check) check ;;
  arm) arm ;;
  merge) merge ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
