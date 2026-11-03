#!/usr/bin/env bash
# Automatically attempt ordinary teardown of completed tasks in an opted-in home.
# Usage: fm-auto-teardown.sh [<task-id>] | --help
# Internal locked check: fm-auto-teardown.sh --eligible <task-id> <spawn-gen>
# config/auto-teardown is a presence flag, absent by default. Metadata with any
# keep_open=1 row is skipped; remove that row to restore automatic cleanup.
# Called after main-actor wake presentation and successful local-only landing.
# Ships require an identity-matched merge-poll notification, or a local-only
# branch reachable from the project's checked-out main/master default branch.
# Scouts require their report and the existing captain-call verify gate.
# All kinds require current-state done from fm-crew-state.sh.
# fm-teardown.sh rechecks eligibility and incarnation under its lifecycle locks
# and owns every ordinary safety check.
# Refusals are reduced to one output line; no force, retries, or discard here.
# Successful teardown retires metadata, making subsequent calls no-ops.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  exit 0
fi
CHECK_ONLY=0
if [ "${1:-}" = --eligible ]; then CHECK_ONLY=1; shift; fi
[ -e "$CONFIG/auto-teardown" ] || exit "$CHECK_ONLY"
# Main owns cleanup; branch drains must not mutate tasks outside their grants.
[ "${FM_SUPERVISION_ACTOR:-main}" = main ] || exit "$CHECK_ONLY"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
if [ "$CHECK_ONLY" -eq 1 ]; then
  [ "$#" -eq 2 ] && [ -n "$2" ] || exit 2
else
  [ "$#" -le 1 ] || exit 2
fi
[ "$#" -eq 0 ] || fm_pr_task_id_valid "$1" || exit 2

meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
eligible() {
  local meta=$1 id=$2 kind mode project branch default ref current
  grep -qx 'keep_open=1' "$meta" && return 1
  current=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-crew-state.sh" "$id") || return 1
  case "$current" in "state: done "*) ;; *) return 1 ;; esac
  kind=$(meta_value "$meta" kind)
  case "$kind" in
    scout)
      [ -f "$DATA/$id/report.md" ] || return 1
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" verify "$id" >/dev/null 2>&1
      return $?
      ;;
    ship|crewmate|'') ;;
    *) return 1 ;;
  esac
  mode=$(meta_value "$meta" mode)
  if [ "$mode" = local-only ]; then
    project=$(meta_value "$meta" project)
    branch=$(meta_value "$meta" branch)
    branch=${branch:-fm/$id}
    git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1
    ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    default=${ref#origin/}
    if [ -z "$default" ]; then
      for default in main master; do
        git -C "$project" show-ref --verify --quiet "refs/heads/$default" && break
      done
    fi
    [ "$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$default" ] || return 1
    git -C "$project" merge-base --is-ancestor "refs/heads/$branch" "refs/heads/$default" 2>/dev/null
  else
    fm_pr_metadata_identity_parse "$meta" || return 1
    fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_META_PROVIDER" \
      "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER"
  fi
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || exit 1
  [ "$(meta_value "$meta" spawn_gen)" = "$2" ] || exit 1
  eligible "$meta" "$1"
  exit $?
fi

attempt() {
  local meta=$1 id output gen rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  id=${meta##*/}; id=${id%.meta}
  fm_pr_task_id_valid "$id" || return 0
  gen=$(meta_value "$meta" spawn_gen)
  [ -n "$gen" ] || return 0
  eligible "$meta" "$id" || return 0
  output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-teardown.sh" "$id" --auto "$gen" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'auto-teardown: %s complete\n' "$id"
  else
    printf 'auto-teardown: %s: %s\n' "$id" "$(printf '%s\n' "$output" | awk '/^(REFUSED|error:|Error:)/ {print; found=1; exit} NF {last=$0} END {if (!found) print last}')"
  fi
}
if [ "$#" -eq 1 ]; then
  attempt "$STATE/$1.meta"
else
  for meta in "$STATE"/*.meta; do attempt "$meta"; done
fi
