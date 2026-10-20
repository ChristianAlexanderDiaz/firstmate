#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# fleet-level validation that the backlog backend cannot know, then DELEGATES
# the actual item move to `tasks-axi mv`, the single owner of the backlog
# format. Delegating the move is the durability end-state: it removes the awk
# that used to re-implement block extraction and insertion here, so the format
# has exactly one parser and cannot drift out of sync (the body-orphaning class
# of bug fixed in PR #401 was exactly that drift).
#
# What this script still owns (never delegated):
#   - resolving the secondmate home from data/secondmates.md;
#   - proving the destination is a genuine seeded secondmate home
#     (.fm-secondmate-home marker, AGENTS.md + bin/), never a project clone, the
#     active home, or the firstmate repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which must stay with their home for pruning or
#     archiving;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the secondmate backlog is reported and skipped, and if
#     any key matches neither backlog nothing is moved;
#   - warning, after a successful move, when a moved key still owes a public
#     relay reply bound to main/<key>, or when this home has an open public loop
#     with nothing owed, because routing work out does not close that loop. The
#     move is not blocked: rebinding or rechain is a relay-side decision the
#     caller makes.
#
# What `tasks-axi mv <id>... --to <dest>` owns: moving each full item BLOCK
# with task content preserved (header, body lines, and indented pseudo-headings
# such as `  ## Intent`), preserving destination section placement, and moving a
# whole connected set (a blocker and its dependents) atomically with blocked-by
# links preserved. It refuses a move that would strand a dependency across the
# two files; that error is surfaced verbatim and nothing is moved. Separator
# whitespace may be normalized by tasks-axi and is not a receipt identity.
#
# Item bodies must use at least two leading spaces. The helper refuses a selected
# item with a single-space or tab-indented continuation rather than risk leaving
# it orphaned, because tasks-axi treats only two-or-more-space lines as body.
# The move needs compatible `tasks-axi` on PATH, including atomic multi-ID `mv`
# support. Bootstrap requires a compatible build fleet-wide, so this works
# everywhere; the `config/backlog-backend=manual` knob only governs firstmate's
# own hand-editing of its own backlog, not this validated helper. Idempotent:
# re-running converges. Atomic: on any move failure nothing moves.
# See AGENTS.md project management and task lifecycle.
# Remote routes use an outbox handoff: one atomic local tasks-axi mv removes the
# selected set from the dispatchable backlog into data/handoff/<id>.outbox.md,
# then an idempotent confined transfer and fm-backlog-receive.sh deliver it.
# A present outbox remains the remote retry trigger only until backlog receipt
# is confirmed, then it is released independently of the best-effort receiver
# wake. The wake remains separately tracked by one pending-reply correlation and
# is retried by later resumes and handoffs without blocking new backlog work.
# An undelivered wake stays retryable under that same correlation even after the
# watcher escalates its unknown delivery; only confirmed delivery prevents a
# resend. A prepared local wake is bound to the exact sorted
# requested-key batch; an unrelated handoff to that mate refuses until the
# original batch is retried, so it cannot discard wake intent for work that
# already moved. No two-phase journal exists.
# Every newly durable backlog delivery attempts one marked wake to the receiving
# endpoint. A local route moves directly into the destination backlog, and a
# missing or rejected local wake makes that command fail with the move intact so
# rerunning the same handoff retries its prepared wake intent. After a durable
# remote receipt, the outbox is released and the handoff succeeds regardless of
# the best-effort wake outcome; an undelivered remote wake remains separately
# tracked in wake-pending state and is retried under the same correlation by
# later resumes and handoffs. If wake-pending state cannot be recorded, the wake
# is reported as DROPPED and marker removal is attempted while the mate still
# owns reconciliation from its durable backlog. Any unsafe, invalid, delivered,
# or undeletable stale marker is reported and ignored by later resumes and
# handoffs, so wake-state cleanup neither suppresses a new wake nor fails a
# completed remote handoff.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...
#        fm-backlog-handoff.sh --resume-pending
#        fm-backlog-handoff.sh --from-secondmate <local-id> <destination-id> <key>...
#        fm-backlog-handoff.sh --from-secondmate <local-id> --to-parent <key>...
# New forms require markdown + automatic source dispatch gating, validate parent
# bindings and operational records under task-set locks, and use strict receipts.
# Parent-owned data/handoff/transfers/<random-id>.record is immutable provenance:
# schema, id, source id, source home, source identity, route digest, destination,
# key-set digest, pinned payload digest, then sorted keys (one per line).
# The matching .payload pins the batch; .accepted is published only on receipt.
# Unknown receipt keeps provenance and payload; never restore rows automatically.
# Resume revalidates the original source and route. An ambiguous local commit
# needs supervised reconciliation; no force or accept-anyway flag exists.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

# shellcheck source=bin/fm-handoff-record-lib.sh
. "$SCRIPT_DIR/fm-handoff-record-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

RECEIVER_WAKE_MESSAGE='New routed work is in your backlog. Run bin/fm-session-start.sh now, then act on the routed task.'

ACTIVE_SOURCE_LOCK=
ACTIVE_DEST_LOCK=
STRICT_TRANSFER=
SOURCE_ID=
TO_PARENT=0
WORK_HOME=main
ACTIVE_HANDOFF_LOCK=
ACTIVE_REGISTRY_LOCK=
RECEIVER_WAKE_IGNORE_ID=
release_remote_locks() {
  if [ -n "$ACTIVE_DEST_LOCK" ]; then fm_lock_release "$ACTIVE_DEST_LOCK"; ACTIVE_DEST_LOCK=; fi
  if [ -n "$ACTIVE_SOURCE_LOCK" ]; then fm_lock_release "$ACTIVE_SOURCE_LOCK"; ACTIVE_SOURCE_LOCK=; fi
  if [ -n "$ACTIVE_HANDOFF_LOCK" ]; then
    fm_lock_release "$ACTIVE_HANDOFF_LOCK"
    ACTIVE_HANDOFF_LOCK=
  fi
  STRICT_TRANSFER=
  SOURCE_ID=
  WORK_HOME=main
  if [ -n "$ACTIVE_REGISTRY_LOCK" ]; then
    fm_lock_release "$ACTIVE_REGISTRY_LOCK"
    ACTIVE_REGISTRY_LOCK=
  fi
}
trap release_remote_locks EXIT
trap 'exit 1' HUP INT TERM

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

if [ "${1:-}" = --help ]; then sed -n '2,100p' "$0" | sed 's/^# *//'; exit 0; fi
if [ "${1:-}" = --from-secondmate ]; then
  [ "$#" -ge 4 ] || { echo 'error: explicit source, destination and keys required' >&2; exit 1; }
  SOURCE_ID=$2
  case "$SOURCE_ID" in ''|.|..|*[!A-Za-z0-9._-]*) exit 1 ;; esac
  WORK_HOME="secondmate:$SOURCE_ID"
  shift 2
  if [ "$1" = --to-parent ]; then TO_PARENT=1; set -- parent "${@:2}"; fi
fi
RESUME_PENDING=0
if [ "${1:-}" = --resume-pending ]; then
  [ "$#" -eq 1 ] || {
    echo "usage: fm-backlog-handoff.sh --resume-pending" >&2
    exit 1
  }
  RESUME_PENDING=1
  ID=
  shift
else
  [ "$#" -ge 2 ] || {
    echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>..." >&2
    exit 1
  }
  ID=$1
  case "$ID" in '' | *[!A-Za-z0-9._-]*)
    echo "error: unsafe secondmate id: $ID" >&2
    exit 1
    ;;
  esac
  shift
fi

secondmate_home() {
  local id=$1 home
  [ -f "$REG" ] || {
    echo "error: no secondmate registry at $REG" >&2
    return 1
  }
  home=$(secondmate_registry_field "$REG" "$id" home || true)
  [ -n "$home" ] || {
    echo "error: secondmate $id has no home in $REG" >&2
    return 1
  }
  printf '%s\n' "$home"
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
  "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || {
    echo "error: firstmate home does not exist or is not a directory: $path" >&2
    return 1
  }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.fm-secondmate-home" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

# Classify a single key by the section it lives under (## In flight /
# ## Queued / ## Done), or return non-zero if no `- [ ] <key>` / `- [x] <key>`
# header exists in the file. This reads only section headings and item header
# lines - never item bodies - so it drives the fleet-level classification (in-
# flight refusal, already-present idempotency, missing-key abort) without
# re-implementing the block/body move semantics that tasks-axi mv owns.
backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

backlog_key_noncanonical_body_lines() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

seed_backlog_scaffold() { # <path>
  mkdir -p "$(dirname "$1")"
  [ -f "$1" ] || printf '## In flight\n\n## Queued\n\n## Done\n' >"$1"
}

# A public commitment made through the relay binds its work by home AND id, so an
# item that leaves this home takes that binding out of sync: reconciliation would
# still look for main/<key> while the work now lives in the secondmate's home.
# The move itself stays safe and is never blocked - rebinding is a relay-side
# decision the caller owns - but this is the one moment the staleness is
# detectable, so report it loudly instead of letting the promise go quiet.
# A home that never opted into the relay pays one presence check per key here.
warn_stale_public_commitments() { # <secondmate-id> <moved-key>...
  local id=$1 key out rc target_home="secondmate:$1"
  [ "$TO_PARENT" != 1 ] || target_home=main
  shift
  for key in "$@"; do
    rc=0
    out=$("$SCRIPT_DIR/fm-public-followup.sh" guard-work "$WORK_HOME" "$key" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ] || continue
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'warning: %s still owes a public reply bound to %s/%s; rebind it to %s (bin/fm-tasks-axi.sh public-followup bind-work, then bin/fm-public-followup.sh register <obligation-id> --relation <relation-id> --work-home %s --work-id %s --generation <n>) or the promised reply will be reconciled against work this home no longer owns.\n' \
      "$key" "$WORK_HOME" "$key" "$target_home" "$target_home" "$key" >&2
  done
  if fm_pf_relay_active "$FM_HOME" && fm_pf_has_delivered_open_loops "$STATE"; then
    printf 'warning: this home has an open public loop with nothing owed; routing work to %s does not close it. Hand it on with bin/fm-public-followup.sh rechain or close it with retire --reason.\n' \
      "$target_home" >&2
  fi
  # Reporting never changes the handoff's own success: the move already landed.
  return 0
}

# Wake a live receiver after its backlog has become durable. The marked message
# uses the normal endpoint route and verified submit for both placements. A
# failed local wake fails that local handoff, while a failed remote wake is
# handled as the best-effort state described in the script contract above. A
# seeded but not-yet-spawned home is a valid handoff destination, but its missing
# endpoint is reported rather than pretending the task was started.
receiver_wake_batch_id() { # <item-key>...
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$({ [ -z "$SOURCE_ID" ] || printf '%s\n' "$WORK_HOME"; printf '%s\n' "$@"; } | LC_ALL=C sort | shasum -a 256 2>/dev/null | awk '{print $1}')
  else
    digest=$({ [ -z "$SOURCE_ID" ] || printf '%s\n' "$WORK_HOME"; printf '%s\n' "$@"; } | LC_ALL=C sort | sha256sum 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
  printf '%s' "${digest:0:16}"
}

receiver_wake_state_write() { # <secondmate-id> <state>
  local id=$1 value=$2 marker="$STATE/.backlog-handoff-$1.wake-pending" tmp
  case "$id" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$value" in
  pending | confirmed) ;;
  prepared:*) printf '%s' "$value" | grep -Eq '^prepared:[a-f0-9]{16}:[a-f0-9]{16}$' || return 1 ;;
  pending:*) printf '%s' "$value" | grep -Eq '^pending:[a-f0-9]{16}$' || return 1 ;;
  confirmed:*) printf '%s' "$value" | grep -Eq '^confirmed:[a-f0-9]{16}$' || return 1 ;;
  *) return 1 ;;
  esac
  tmp=$(
    umask 077
    mktemp "$STATE/.backlog-handoff-wake.XXXXXX"
  ) || return 1
  if ! printf '%s\n' "$value" >"$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

receiver_wake_mark() { # <secondmate-id> <prepared|pending> [batch-id]
  local id=$1 wake_phase=$2 batch=${3:-} marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec
  local wake_state
  case "$wake_phase" in prepared | pending) ;; *) return 1 ;; esac
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    value=$(cat "$marker" 2>/dev/null || true)
    case "$value" in
    prepared:*)
      corr=${value#*:}
      corr=${corr%%:*}
      rec=$(fm_pending_reply_path "$STATE" "$corr")
      [ -f "$rec" ] && [ ! -L "$rec" ] &&
        [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ]
      return $?
      ;;
    pending:*)
      receiver_wake_pending_valid "$id"
      return $?
      ;;
    pending) ;;
    *) return 1 ;;
    esac
  fi
  corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" "$RECEIVER_WAKE_MESSAGE") || return 1
  wake_state="$wake_phase:$corr"
  if [ "$wake_phase" = prepared ]; then
    printf '%s' "$batch" | grep -Eq '^[a-f0-9]{16}$' || return 1
    wake_state="$wake_state:$batch"
  fi
  if ! receiver_wake_state_write "$id" "$wake_state"; then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" || true
    return 1
  fi
}

receiver_wake_mark_pending() { # <secondmate-id>
  receiver_wake_mark "$1" pending
}

receiver_wake_mark_prepared() { # <secondmate-id> <batch-id>
  receiver_wake_mark "$1" prepared "$2"
}

receiver_wake_discard_prepared() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
  prepared:*)
    corr=${value#prepared:}
    corr=${corr%%:*}
    ;;
  *) return 1 ;;
  esac
  fm_pending_reply_discard_undelivered "$STATE" "$corr" || return 1
  rm -f -- "$marker"
}

receiver_wake_promote_prepared() { # <secondmate-id> <batch-id>
  local id=$1 batch=$2 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
  prepared:*:"$batch")
    corr=${value#prepared:}
    corr=${corr%%:*}
    ;;
  pending:*) return 0 ;;
  *) return 1 ;;
  esac
  receiver_wake_state_write "$id" "pending:$corr"
}

receiver_wake_discard_pending() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
  pending:*)
    corr=${value#pending:}
    fm_pending_reply_discard_undelivered "$STATE" "$corr" || return 1
    ;;
  pending) ;;
  *) return 1 ;;
  esac
  rm -f -- "$marker"
}

receiver_wake_pending_valid() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec delivered
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in pending:*) corr=${value#pending:} ;; *) return 1 ;; esac
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || return 1
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] || return 1
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  fm_pending_reply_corr_reusable "$STATE" "$corr" "$id"
}

receiver_wake_pending_delivered_valid() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in pending:*) corr=${value#pending:} ;; *) return 1 ;; esac
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || return 1
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] &&
    [ -n "$(fm_pending_reply_get "$rec" delivered_epoch)" ]
}

receiver_wake_confirmed_valid() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  [ "$value" != confirmed ] || return 0
  case "$value" in confirmed:*) corr=${value#confirmed:} ;; *) return 1 ;; esac
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || return 1
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] &&
    [ -n "$(fm_pending_reply_get "$rec" delivered_epoch)" ]
}

receiver_wake_drop_marker() { # <secondmate-id> <reason>
  local id=$1 reason=$2 marker="$STATE/.backlog-handoff-$1.wake-pending"
  printf 'receiver wake state: DROPPED marker=%s\n' "$marker"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    if rm -f -- "$marker"; then
      printf 'warning: best-effort receiver wake for secondmate %s was dropped; removed stale wake marker %s because %s\n' "$id" "$marker" "$reason" >&2
    else
      printf 'warning: best-effort receiver wake for secondmate %s was dropped; stale wake marker remains at %s because %s\n' "$id" "$marker" "$reason" >&2
    fi
  else
    printf 'warning: best-effort receiver wake for secondmate %s was dropped; no wake marker remains at %s because %s\n' "$id" "$marker" "$reason" >&2
  fi
  return 0
}

receiver_wake_clear_confirmed() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending"
  RECEIVER_WAKE_IGNORE_ID=
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  if receiver_wake_pending_valid "$id"; then
    return 0
  fi
  if receiver_wake_pending_delivered_valid "$id" || receiver_wake_confirmed_valid "$id"; then
    if ! rm -f -- "$marker"; then
      RECEIVER_WAKE_IGNORE_ID=$id
      printf 'warning: confirmed receiver wake left a stale marker at %s; later handoffs will ignore it\n' "$marker" >&2
    fi
    return 0
  fi
  receiver_wake_drop_marker "$id" 'wake-pending state is unsafe or invalid'
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    RECEIVER_WAKE_IGNORE_ID=$id
  fi
}

wake_secondmate_receiver() { # <secondmate-id> <correlation-id>
  local id=$1 corr=$2 meta="$STATE/$1.meta" out rc=0
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    printf 'error: handed off work to secondmate %s, but no live receiver endpoint is recorded; the destination backlog is durable and the receiver was not woken\n' "$id" >&2
    return 1
  fi
  [ "$(grep '^kind=' "$meta" | cut -d= -f2-)" = secondmate ] || {
    printf 'error: secondmate %s has non-secondmate endpoint metadata; backlog is durable but the receiver was not woken\n' "$id" >&2
    return 1
  }
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$RECEIVER_WAKE_MESSAGE" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'error: backlog delivery to secondmate %s succeeded, but its receiver wake failed; retry a tracked remote wake with --resume-pending or a later new handoff, and retry a local wake by rerunning its handoff\n' "$id" >&2
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

wake_pending_secondmate_receiver() { # <secondmate-id> [retain-confirmed]
  local id=$1 retain=${2:-0} marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec delivered
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    printf 'error: receiver wake state for secondmate %s is unsafe or invalid\n' "$id" >&2
    return 1
  fi
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
  confirmed | confirmed:*) return 0 ;;
  prepared | prepared:*)
    printf 'error: receiver wake for secondmate %s was prepared before its backlog became durable\n' "$id" >&2
    return 1
    ;;
  pending)
    receiver_wake_mark_pending "$id" || return 1
    value=$(cat "$marker" 2>/dev/null || true)
    ;;
  esac
  case "$value" in pending:*) corr=${value#pending:} ;; *)
    printf 'error: receiver wake state for secondmate %s is unsafe or invalid\n' "$id" >&2
    return 1
    ;;
  esac
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] &&
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] || return 1
  fm_pending_reply_reconcile_delivery "$STATE" "$corr" >/dev/null 2>&1 || true
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    fm_pending_reply_corr_reusable "$STATE" "$corr" "$id" || {
      printf 'error: receiver wake delivery for secondmate %s is unresolved; refusing to resend correlation %s\n' "$id" "$corr" >&2
      return 1
    }
    wake_secondmate_receiver "$id" "$corr" || return 1
  fi
  if [ "$retain" = 1 ]; then
    receiver_wake_state_write "$id" "confirmed:$corr" || {
      printf 'error: receiver wake for secondmate %s was confirmed, but confirmed state could not be recorded\n' "$id" >&2
      return 1
    }
  else
    rm -f -- "$marker" || {
      printf 'error: receiver wake for secondmate %s was confirmed, but pending state could not be cleared\n' "$id" >&2
      return 1
    }
  fi
}

outbox_item_count() { # <path>
  awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$1"
}

remote_deliver_outbox() { # <secondmate-id> <outbox-path>
  local id=$1 outbox=$2 remote_rel receive_out snapshot bytes hash generation counter counter_tmp current marker wake_rc=0 wake_state=pending
  [ -f "$outbox" ] && [ ! -L "$outbox" ] || {
    echo "error: pending outbox is unavailable or unsafe: $outbox" >&2
    return 1
  }
  snapshot=$(
    umask 077
    mktemp "${TMPDIR:-/tmp}/fm-handoff-payload.XXXXXX"
  ) || return 1
  if ! cp -p -- "$outbox" "$snapshot"; then
    rm -f -- "$snapshot"
    return 1
  fi
  bytes=$(LC_ALL=C wc -c <"$snapshot" | tr -d ' ')
  hash=$(sha256_file "$snapshot") || {
    rm -f -- "$snapshot"
    return 1
  }
  counter="$STATE/.remote-handoff-$id.generation"
  current=0
  if [ -e "$counter" ] || [ -L "$counter" ]; then
    [ -f "$counter" ] && [ ! -L "$counter" ] || {
      rm -f -- "$snapshot"
      return 1
    }
    IFS= read -r current <"$counter" || {
      rm -f -- "$snapshot"
      return 1
    }
    case "$current" in '' | *[!0-9]*)
      rm -f -- "$snapshot"
      return 1
      ;;
    esac
    [ "${#current}" -le 17 ] || {
      rm -f -- "$snapshot"
      return 1
    }
  fi
  generation=$((current + 1))
  counter_tmp=$(
    umask 077
    mktemp "$STATE/.remote-handoff-generation.XXXXXX"
  ) ||
    {
      rm -f -- "$snapshot"
      return 1
    }
  printf '%s\n' "$generation" >"$counter_tmp" ||
    {
      rm -f -- "$snapshot" "$counter_tmp"
      return 1
    }
  chmod 600 "$counter_tmp" ||
    {
      rm -f -- "$snapshot" "$counter_tmp"
      return 1
    }
  mv -f -- "$counter_tmp" "$counter" ||
    {
      rm -f -- "$snapshot" "$counter_tmp"
      return 1
    }
  remote_rel="state/handoff/$id.outbox.md"
  if ! "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-remote-file.sh put "$remote_rel" 1048576 \
    "$bytes" "$hash" "$generation" <"$snapshot"; then
    rm -f -- "$snapshot"
    echo "error: handoff transfer to $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  rm -f -- "$snapshot"
  if ! receive_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-backlog-receive.sh \
    ${STRICT_TRANSFER:+--strict-transfer} ${STRICT_TRANSFER:+"$STRICT_TRANSFER"} "$remote_rel" "$bytes" "$hash" "$generation" </dev/null 2>&1); then
    [ -z "$receive_out" ] || printf '%s\n' "$receive_out" >&2
    echo "error: handoff receipt by $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  marker="$STATE/.backlog-handoff-$id.wake-pending"
  if [ "$RECEIVER_WAKE_IGNORE_ID" = "$id" ]; then
    wake_state=dropped
    wake_rc=1
  elif ! receiver_wake_pending_valid "$id" && ! receiver_wake_confirmed_valid "$id"; then
    receiver_wake_mark_pending "$id" || {
      wake_state=dropped
      wake_rc=1
    }
  fi
  if [ "$wake_rc" -eq 0 ]; then
    wake_pending_secondmate_receiver "$id" 1 || wake_rc=$?
  fi
  rm -f -- "$outbox" || {
    echo "error: remote backlog is durable at $id, but local outbox cleanup failed: $outbox" >&2
    return 1
  }
  if [ "$wake_rc" -eq 0 ]; then
    if ! rm -f -- "$marker"; then
      RECEIVER_WAKE_IGNORE_ID=$id
      echo "warning: remote outbox and receiver wake completed, but a stale confirmed wake marker remains at $marker; later handoffs will ignore it" >&2
    fi
  elif [ "$wake_state" = dropped ]; then
    receiver_wake_drop_marker "$id" 'wake-pending state could not be recorded'
    echo "warning: remote backlog is durable at $id and its outbox was released after the best-effort receiver wake was dropped" >&2
  else
    echo "warning: remote backlog is durable at $id and its outbox was released; the best-effort receiver wake remains pending for a later resume or handoff" >&2
  fi
  printf '%s\n' "$receive_out"
}

remove_interrupted_source_duplicates() { # <outbox> <keys...>
  local outbox=$1 key progress remaining pass=0
  shift
  while :; do
    remaining=0
    progress=0
    for key in "$@"; do
      backlog_key_section "$outbox" "$key" >/dev/null 2>&1 || continue
      if backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1; then
        remaining=$((remaining + 1))
        if tasks-axi rm "$key" --file "$MAIN_BACKLOG" >/dev/null 2>&1; then
          progress=$((progress + 1))
        fi
      fi
    done
    [ "$remaining" -gt 0 ] || return 0
    [ "$progress" -gt 0 ] || {
      echo "error: could not complete interrupted source removal; outbox remains authoritative at $outbox" >&2
      return 1
    }
    pass=$((pass + 1))
    [ "$pass" -le "$#" ] || return 1
  done
}

remote_handoff() { # <secondmate-id> <keys...>
  local id=$1 outbox section main_section out_section key mv_out
  local -a requested to_move already missing in_flight done_items not_queued
  shift
  requested=("$@")
  local provenance
  for provenance in "$DATA/handoff/transfers"/*.record; do
    [ -e "$provenance" ] || [ -L "$provenance" ] || continue
    fm_handoff_provenance "$provenance" || return 1
    if [ "$(sed -n '7p' "$provenance")" = "$id" ] && [ ! -f "${provenance%.record}.accepted" ]; then
      fm_handoff_error 'strict source handoff pending; resume its original batch before a parent handoff'; return 1
    fi
  done
  outbox="$DATA/handoff/$id.outbox.md"
  validate_backlog_file "main backlog" "$MAIN_BACKLOG" || return 1
  validate_backlog_file "remote handoff outbox" "$outbox" || return 1
  if [ ! -e "$outbox" ] && [ ! -L "$outbox" ]; then
    receiver_wake_clear_confirmed "$id" || {
      echo "error: stale receiver wake state for secondmate $id could not be cleared" >&2
      return 1
    }
  fi
  fm_tasks_axi_compatible || {
    echo "error: a compatible tasks-axi with atomic multi-ID mv support is required to stage remote handoffs; run bin/fm-bootstrap.sh for the required version" >&2
    return 1
  }
  to_move=()
  already=()
  missing=()
  in_flight=()
  done_items=()
  not_queued=()
  for key in "${requested[@]}"; do
    out_section=$(backlog_key_section "$outbox" "$key" 2>/dev/null || true)
    main_section=$(backlog_key_section "$MAIN_BACKLOG" "$key" 2>/dev/null || true)
    if [ -n "$out_section" ]; then
      [ "$out_section" = '## Queued' ] || not_queued+=("$key")
      already+=("$key")
      continue
    fi
    case "$main_section" in
    '## Queued') to_move+=("$key") ;;
    '## In flight') in_flight+=("$key") ;;
    '## Done') done_items+=("$key") ;;
    '') missing+=("$key") ;;
    *) not_queued+=("$key") ;;
    esac
  done
  if [ "${#in_flight[@]}" -gt 0 ] || [ "${#done_items[@]}" -gt 0 ] ||
    [ "${#not_queued[@]}" -gt 0 ] || [ "${#missing[@]}" -gt 0 ]; then
    [ "${#in_flight[@]}" -eq 0 ] || echo "error: refusing to hand off in-flight backlog items: ${in_flight[*]}" >&2
    [ "${#done_items[@]}" -eq 0 ] || echo "error: refusing to hand off Done backlog items: ${done_items[*]}" >&2
    [ "${#not_queued[@]}" -eq 0 ] || echo "error: refusing to hand off non-Queued outbox or backlog items: ${not_queued[*]}" >&2
    [ "${#missing[@]}" -eq 0 ] || echo "error: no backlog or pending outbox item matched: ${missing[*]}" >&2
    echo "       nothing new was staged." >&2
    return 1
  fi
  for key in "${to_move[@]+"${to_move[@]}"}"; do
    while IFS= read -r line; do
      printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' "$key" "$line" >&2
      return 1
    done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
  done
  # Do not append a fresh handoff to an older recovery batch. In particular, a
  # confirmed wake can survive when outbox cleanup fails; if new work were
  # staged into that outbox, the old confirmation would suppress the wake for
  # the new work. Finish receipt, wake reconciliation, and cleanup for the old
  # batch first. A failure leaves the fresh items dispatchable in main.
  if [ "${#to_move[@]}" -gt 0 ] && [ -f "$outbox" ] &&
    [ "$(outbox_item_count "$outbox")" -gt 0 ]; then
    remote_deliver_outbox "$id" "$outbox" || {
      echo "error: previous remote handoff for secondmate $id could not be completed; nothing new was staged" >&2
      return 1
    }
  fi
  seed_backlog_scaffold "$outbox"
  if [ "${#to_move[@]}" -gt 0 ]; then
    if ! mv_out=$(tasks-axi mv "${to_move[@]}" --file "$MAIN_BACKLOG" --to "$outbox" 2>&1); then
      [ -z "$mv_out" ] || printf '%s\n' "$mv_out" >&2
      echo "error: atomic outbox staging failed; nothing new was handed off" >&2
      return 1
    fi
  fi
  # A hard local kill can land tasks-axi's target persist before its source
  # persist. The outbox is already authoritative in that state, so converge by
  # deleting only duplicates that tasks-axi itself confirms are dependency-safe.
  remove_interrupted_source_duplicates "$outbox" "${requested[@]}" || return 1
  remote_deliver_outbox "$id" "$outbox" || return 1
  echo "handed off ${#requested[@]} item(s) to remote secondmate $id: ${requested[*]}"
  [ "${#already[@]}" -eq 0 ] || echo "  already staged (recovered): ${already[*]}"
  warn_stale_public_commitments "$id" "${requested[@]}"
}

with_remote_route_locks() { # <secondmate-id> <function> <args...>
  local id=$1 operation=$2 rc
  shift 2
  case "$id" in '' | *[!A-Za-z0-9._-]*)
    echo "error: unsafe remote handoff id: $id" >&2
    return 1
    ;;
  esac
  ACTIVE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
  if [ "$(secondmate_registry_field "$REG" "$id" remote 2>/dev/null || true)" != 1 ]; then
    echo "error: pending outbox has no matching remote secondmate route: $id" >&2
    release_remote_locks
    return 1
  fi
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$id.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  if "$operation" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  return "$rc"
}

resume_remote_outbox() { # <secondmate-id> <outbox-path>
  local id=$1 outbox=$2
  if { [ -e "$outbox" ] || [ -L "$outbox" ]; } && { [ ! -f "$outbox" ] || [ -L "$outbox" ]; }; then
    echo "error: unsafe pending handoff outbox: $outbox" >&2
    return 1
  fi
  local provenance sid target keyset
  for provenance in "$DATA/handoff/transfers"/*.record; do
    [ -e "$provenance" ] || [ -L "$provenance" ] || continue
    fm_handoff_provenance "$provenance" || return 1
    target=$(sed -n '7p' "$provenance")
    [ "$target" = "$id" ] || continue
    [ ! -f "${provenance%.record}.accepted" ] || continue
    sid=$(sed -n '3p' "$provenance")
    SOURCE_ID=$sid
    WORK_HOME="secondmate:$sid"
    local -a resume_keys
    resume_keys=()
    while IFS= read -r keyset; do resume_keys+=("$keyset"); done < <(sed -n '10,$p' "$provenance")
    strict_source_handoff "$id" "${resume_keys[@]}"
    return $?
  done
  [ -e "$outbox" ] || return 0
  remote_deliver_outbox "$id" "$outbox"
}

resume_pending_outboxes() {
  local outbox id failed=0
  [ -d "$DATA/handoff" ] || return 0
  local record target resumed=$'\n'
  for record in "$DATA/handoff/transfers"/*.record; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    fm_handoff_provenance "$record" || return 1
    target=$(sed -n '7p' "$record")
    [ "$(secondmate_registry_field "$REG" "$target" remote 2>/dev/null || true)" = 1 ] || continue
    [ ! -f "${record%.record}.accepted" ] || continue
    with_remote_route_locks "$target" resume_remote_outbox "$target" "$DATA/handoff/$target.outbox.md" || failed=1
    resumed="$resumed$target"$'\n'
  done
  for outbox in "$DATA/handoff"/*.outbox.md; do
    [ -e "$outbox" ] || [ -L "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$resumed" in *$'\n'"$id"$'\n'*) continue ;; esac
    case "$id" in '' | *[!A-Za-z0-9._-]*)
      echo "error: unsafe pending handoff id: $id" >&2
      failed=1
      continue
      ;;
    esac
    with_remote_route_locks "$id" resume_remote_outbox "$id" "$outbox" || failed=1
  done
  return "$failed"
}

resume_remote_wake() { # <secondmate-id>
  local id=$1
  [ -e "$DATA/handoff/$id.outbox.md" ] || [ -L "$DATA/handoff/$id.outbox.md" ] || {
    receiver_wake_clear_confirmed "$id"
    receiver_wake_pending_valid "$id" || return 0
    wake_pending_secondmate_receiver "$id"
  }
}

resume_pending_wakes() {
  local marker name id failed=0
  [ -d "$STATE" ] || return 0
  for marker in "$STATE"/.backlog-handoff-*.wake-pending; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    name=$(basename "$marker")
    id=${name#.backlog-handoff-}
    id=${id%.wake-pending}
    case "$id" in '' | *[!A-Za-z0-9._-]*)
      echo "error: unsafe pending wake id: $id" >&2
      failed=1
      continue
      ;;
    esac
    [ "$(secondmate_registry_field "$REG" "$id" remote 2>/dev/null || true)" = 1 ] || continue
    with_remote_route_locks "$id" resume_remote_wake "$id" || failed=1
  done
  return "$failed"
}

# Validate a new local source/successor against the parent's durable binding.
strict_local_home() {
  local id=$1 home=$2 parent
  home=$(validate_secondmate_home "$id" "$home") || return 1
  fm_handoff_file "$home/.fm-secondmate-home" || return 1
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || { fm_handoff_error "invalid parent binding: $home"; return 1; }
  parent=$(cd "$FM_HOME" && pwd -P) || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ "$FM_SECONDMATE_PARENT_HOME" = "$parent" ] \
    || { fm_handoff_error "secondmate $id is bound to another parent"; return 1; }
  fm_handoff_markdown "$home" || return 1
  printf '%s\n' "$home"
}

strict_source_handoff() { # <destination> <keys...>; caller holds registry/handoff
  local id=$1 source dest route route_hash keys_hash record payload accepted file
  local transfer hash old_source old_work show key section cap rc present=0 batch tmp proof
  local -a keys
  shift
  keys=()
  while IFS= read -r key; do
    case "$key" in ''|.|..|*[!A-Za-z0-9._-]*) fm_handoff_error "unsafe task key: $key"; return 1 ;; esac
    keys+=("$key")
  done < <(printf '%s\n' "$@" | LC_ALL=C sort -u)
  [ "${#keys[@]}" -eq "$#" ] || { fm_handoff_error 'duplicate or missing explicit task keys'; return 1; }
  [ "$(secondmate_registry_field "$REG" "$SOURCE_ID" remote 2>/dev/null || true)" != 1 ] \
    || { fm_handoff_error 'remote source handoff is unsupported; use a registered local source'; return 1; }
  secondmate_registry_validate_bindings "$REG" resolved_existing_dir || { fm_handoff_error "$SECONDMATE_REGISTRY_ERROR"; return 1; }
  source=$(strict_local_home "$SOURCE_ID" "$(secondmate_home "$SOURCE_ID")") || return 1
  if [ -e "$source/config/backlog-backend" ] || [ -L "$source/config/backlog-backend" ]; then fm_handoff_file "$source/config/backlog-backend" || return 1; fi
  [ "$(fm_backlog_backend_value "$source/config")" = tasks-axi ] \
    || { fm_handoff_error 'source-secondmate handoff requires the ordinary tasks-axi dispatch gate; manual sources are unsupported'; return 1; }
  if [ "$TO_PARENT" = 1 ]; then
    dest=$(cd "$FM_HOME" && pwd -P) || return 1
    fm_handoff_markdown "$dest" || return 1
    route="parent:$dest"
  elif [ "$(secondmate_registry_field "$REG" "$id" remote 2>/dev/null || true)" = 1 ]; then
    dest=
    secondmate_registry_line_for_id "$REG" "$id" || return 1
    route=$SECONDMATE_REGISTRY_LINE
    if ! cap=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-backlog-receive.sh --capabilities </dev/null); then
      fm_handoff_error 'upgrade destination Firstmate for strict-transfer-v1 before handing off source work'; return 1
    fi
    printf '%s\n' "$cap" | grep -qx 'strict-transfer-v1' \
      || { fm_handoff_error 'upgrade destination Firstmate for strict-transfer-v1 before handing off source work'; return 1; }
    printf '%s\n' "$cap" | grep -Fxq binding:remote || { fm_handoff_error 'remote receiver parent binding is not remote'; return 1; }
    # shellcheck disable=SC2015
    printf '%s\n' "$cap" | grep -Fxq "marker:$id" && \
      printf '%s\n' "$cap" | grep -Fxq "home:$(secondmate_registry_field "$REG" "$id" home)" \
      || { fm_handoff_error 'remote receiver identity does not match destination route'; return 1; }
  else
    [ "$SOURCE_ID" != "$id" ] || { fm_handoff_error 'source and destination must differ'; return 1; }
    dest=$(strict_local_home "$id" "$(secondmate_home "$id")") || return 1
    case "$dest/" in "$source/"*) fm_handoff_error 'source and destination homes overlap'; return 1 ;; esac
    case "$source/" in "$dest/"*) fm_handoff_error 'source and destination homes overlap'; return 1 ;; esac
    route="local:$id:$dest:$(fm_handoff_home_identity "$dest")"
  fi
  route_hash=$(printf '%s\n' "$route" | fm_handoff_digest) || return 1
  keys_hash=$(printf '%s\n' "${keys[@]}" | fm_handoff_digest) || return 1
  fm_handoff_dir "$DATA/handoff" && fm_handoff_dir "$DATA/handoff/transfers" || return 1
  record=
  for file in "$DATA/handoff/transfers"/*.record; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    fm_handoff_provenance "$file" || return 1
    if [ "$(sed -n '3p' "$file")" = "$SOURCE_ID" ] && [ "$(sed -n '7p' "$file")" = "$id" ] && [ "$(sed -n '8p' "$file")" = "$keys_hash" ]; then
      [ -z "$record" ] || { fm_handoff_error 'multiple matching transfer records need reconciliation'; return 1; }
      record=$file
    elif [ "$(sed -n '7p' "$file")" = "$id" ] && [ ! -f "${file%.record}.accepted" ]; then
      fm_handoff_error "an unfinished transfer owns this destination; retry its original batch: $file"; return 1
    fi
  done
  ACTIVE_SOURCE_LOCK=$(fm_task_set_lock_path "$source/state") || return 1
  fm_lock_acquire_wait "$ACTIVE_SOURCE_LOCK" || return 1
  if [ -n "$dest" ]; then
    ACTIVE_DEST_LOCK=$(fm_task_set_lock_path "$dest/state") || return 1
    fm_lock_try_acquire "$ACTIVE_DEST_LOCK" || { fm_handoff_error 'destination task set is busy; retry this handoff after publication finishes'; ACTIVE_DEST_LOCK=; return 1; }
    validate_backlog_file 'destination backlog' "$dest/data/backlog.md" || return 1
  fi
  fm_handoff_file "$source/data/backlog.md" || return 1
  fm_tasks_axi_compatible || return 1
  for key in "${keys[@]}"; do
    if show=$(fm_handoff_show "$source" "$key" 2>/dev/null); then
      present=$((present + 1))
      [ "$(fm_handoff_field "$show" state)" = queued ] && [ "$(fm_handoff_field "$show" held)" = no ] \
        || { fm_handoff_error "source task $key must be Queued and unheld"; return 1; }
      # Expiry does not answer a captain call; the hold owner decides openness.
      rc=0
      env -u TASKS_AXI_BACKEND FM_HOME="$source" FM_ROOT_OVERRIDE="$FM_ROOT" \
        FM_DATA_OVERRIDE="$source/data" FM_STATE_OVERRIDE="$source/state" FM_CONFIG_OVERRIDE="$source/config" \
        bash "$SCRIPT_DIR/fm-captain-hold.sh" open "$key" --distinguish-absent >/dev/null || rc=$?
      case "$rc" in
        1) ;;
        0) fm_handoff_error "source task $key has an unresolved captain hold"; return 1 ;;
        *) fm_handoff_error "source task $key captain-hold evidence cannot be verified"; return 1 ;;
      esac
      fm_handoff_task_records_clear "$source" "$key" || return 1
      section=$(fm_handoff_field "$show" repo)
      case "$section" in ''|'"-"'|*[!A-Za-z0-9._-]*) fm_handoff_error "task $key needs a registered project"; return 1 ;; esac
      for file in "$source/data/projects.md" "$DATA/projects.md" ${dest:+"$dest/data/projects.md"}; do
        # shellcheck disable=SC2015
        [ -f "$file" ] && [ ! -L "$file" ] && awk -v name="$section" 'index($0, "- " name " [") == 1 || index($0, "- " name " - ") == 1 { found=1 } END { exit !found }' "$file" \
          || { fm_handoff_error "unregistered project $section in $file"; return 1; }
      done
      if [ -z "$dest" ]; then
        printf '%s\n' "$cap" | grep -Fxq "project:$section" || { fm_handoff_error "remote project $section is unregistered"; return 1; }
      fi
      if [ "$TO_PARENT" != 1 ]; then
        old_work=$(FM_DATA_OVERRIDE="$source/data" "$SCRIPT_DIR/fm-project-mode.sh" "$section") || return 1
        case "$old_work" in local-only*) fm_handoff_error 'local-only work stays with the parent'; return 1 ;; esac
      fi
      [ -z "$(backlog_key_noncanonical_body_lines "$source/data/backlog.md" "$key")" ] \
        || { fm_handoff_error "non-2-space continuation in $key"; return 1; }
    else
      if fm_backlog_row_probe "$source/data" "$key"; then
        fm_handoff_error "source task $key could not be read consistently"; return 1
      elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
        fm_handoff_error "$FM_BACKLOG_ROW_ERROR"; return 1
      elif [ -z "$record" ]; then
        fm_handoff_error "no source backlog task matched $key"; return 1
      fi
    fi
  done
  # Reconcile the previous local wake before publishing another transfer.
  # A prepared correlation belongs to its original source/key batch.
  if [ -n "$dest" ] && [ "$TO_PARENT" != 1 ]; then
    batch=$(receiver_wake_batch_id "${keys[@]}") || return 1
    file="$STATE/.backlog-handoff-$id.wake-pending"
    if [ -e "$file" ] || [ -L "$file" ]; then
      case "$(cat "$file" 2>/dev/null || true)" in
        prepared:*:"$batch") ;;
        prepared:*) fm_handoff_error 'prepared receiver wake belongs to a different source/batch; retry that original handoff'; return 1 ;;
        *) wake_pending_secondmate_receiver "$id" || return 1 ;;
      esac
    fi
  fi
  if [ -z "$record" ] && [ -z "$dest" ] && { [ -e "$DATA/handoff/$id.outbox.md" ] || [ -L "$DATA/handoff/$id.outbox.md" ]; }; then
    fm_handoff_error 'previous outbox owns this route; resume it before a new source batch'; return 1
  fi
  if [ -n "$record" ]; then
    transfer=$(sed -n '2p' "$record")
    fm_handoff_id_valid "$transfer" || return 1
    [ "$(sed -n '1p' "$record")" = fm-handoff-source.v1 ] && \
      [ "$(sed -n '4p' "$record")" = "$source" ] && \
      [ "$(sed -n '5p' "$record")" = "$(fm_handoff_home_identity "$source")" ] && \
      [ "$(sed -n '6p' "$record")" = "$route_hash" ] || { fm_handoff_error 'transfer source/route identity changed'; return 1; }
    payload="${record%.record}.payload"
    accepted="${record%.record}.accepted"
    fm_handoff_file "$payload" || return 1
    hash=$(sha256_file "$payload")
    [ "$hash" = "$(sed -n '9p' "$record")" ] || { fm_handoff_error 'pinned transfer payload changed'; return 1; }
    if [ -e "$accepted" ] || [ -L "$accepted" ]; then
      fm_handoff_file "$accepted" || return 1
      [ "$(cat "$accepted")" = "$hash" ] && [ "$present" = 0 ] \
        || { fm_handoff_error 'accepted transfer conflicts with source rows or receipt'; return 1; }
      echo "handoff accepted retry: $transfer"
      if [ "$TO_PARENT" != 1 ]; then
        batch=$(receiver_wake_batch_id "${keys[@]}") || return 1
        case "$(cat "$STATE/.backlog-handoff-$id.wake-pending" 2>/dev/null || true)" in
          prepared:*:"$batch") receiver_wake_promote_prepared "$id" "$batch" || return 1 ;;
        esac
        wake_pending_secondmate_receiver "$id" || return 1
      fi
      return 0
    fi
  else
    [ "$present" -eq "${#keys[@]}" ] || return 1
    transfer=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
    fm_handoff_id_valid "$transfer" || return 1
    record="$DATA/handoff/transfers/$transfer.record"
    payload="${record%.record}.payload"
    accepted="${record%.record}.accepted"
    [ ! -e "$record" ] && [ ! -L "$record" ] && [ ! -e "$payload" ] && [ ! -L "$payload" ] || return 1
    # Preview through tasks-axi on a private source copy to pin exactly the
    # payload that staging will produce, including its whitespace normalization.
    tmp=$(umask 077; mktemp -d "$DATA/handoff/.prepare.XXXXXX") || return 1
    cp "$source/data/backlog.md" "$tmp/source.md" || return 1
    seed_backlog_scaffold "$tmp/payload.md"
    if ! proof=$(env -u TASKS_AXI_BACKEND tasks-axi mv "${keys[@]}" --file "$tmp/source.md" --to "$tmp/payload.md" 2>&1); then
      printf '%s\n' "$proof" >&2; rm -rf -- "$tmp"; return 1
    fi
    hash=$(sha256_file "$tmp/payload.md") || return 1
    fm_handoff_publish "$payload" < "$tmp/payload.md" || return 1
    rm -rf -- "$tmp"
    { printf 'fm-handoff-source.v1\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$transfer" "$SOURCE_ID" "$source" "$(fm_handoff_home_identity "$source")" "$route_hash" "$id" "$keys_hash" "$hash"; printf '%s\n' "${keys[@]}"; } | fm_handoff_publish "$record" || return 1
  fi
  fm_handoff_provenance "$record" || { fm_handoff_error 'transfer provenance is invalid or exceeds its 65536-byte bound; nothing new was moved'; return 1; }
  if [ "$present" -gt 0 ]; then
    [ "$present" -eq "${#keys[@]}" ] || { fm_handoff_error 'partially removed source requires reconciliation'; return 1; }
    tmp=$(umask 077; mktemp -d "$DATA/handoff/.verify.XXXXXX") || return 1
    cp "$source/data/backlog.md" "$tmp/source.md" || return 1
    seed_backlog_scaffold "$tmp/payload.md"
    if ! proof=$(env -u TASKS_AXI_BACKEND tasks-axi mv "${keys[@]}" --file "$tmp/source.md" --to "$tmp/payload.md" 2>&1); then
      printf '%s\n' "$proof" >&2; rm -rf -- "$tmp"; return 1
    fi
    proof=$(sha256_file "$tmp/payload.md")
    rm -rf -- "$tmp"
    [ "$proof" = "$hash" ] || { fm_handoff_error 'source differs from pinned transfer; reconcile before removing rows'; return 1; }
  fi
  if [ -n "$dest" ]; then
    rc=0
    fm_handoff_receipt_check "$dest" "$transfer" "$hash" "$keys_hash" || rc=$?
    if [ "$rc" = 3 ]; then
      for key in "${keys[@]}"; do
        if [ -f "$dest/data/backlog.md" ] && fm_handoff_show "$dest" "$key" >/dev/null 2>&1; then
          fm_handoff_error "ambiguous strict transfer: destination key $key exists without accepted receipt; preserve transfer $transfer and reconcile destination bodies/history"; return 1
        fi
      done
      [ "$present" -eq "${#keys[@]}" ] || { fm_handoff_error 'incomplete source transfer needs reconciliation'; return 1; }
      if [ "$TO_PARENT" != 1 ]; then
        batch=$(receiver_wake_batch_id "${keys[@]}") || return 1
        receiver_wake_mark_prepared "$id" "$batch" || return 1
      fi
      seed_backlog_scaffold "$dest/data/backlog.md"
      env -u TASKS_AXI_BACKEND tasks-axi mv "${keys[@]}" --file "$source/data/backlog.md" --to "$dest/data/backlog.md" || return 1
      fm_handoff_receipt_accept "$dest" "$transfer" "$hash" "$keys_hash" \
        || { fm_handoff_error 'move committed; receipt publication failed; retain transfer for reconciliation'; return 1; }
    elif [ "$rc" != 0 ]; then return 1
    fi
    printf '%s\n' "$hash" | fm_handoff_publish "$accepted" || return 1
    echo "handoff durable: $transfer source=$SOURCE_ID destination=$id keys=${keys[*]}"
    fm_lock_release "$ACTIVE_DEST_LOCK"; ACTIVE_DEST_LOCK=
    fm_lock_release "$ACTIVE_SOURCE_LOCK"; ACTIVE_SOURCE_LOCK=
    if [ "$TO_PARENT" != 1 ]; then
      batch=$(receiver_wake_batch_id "${keys[@]}") || return 1
      receiver_wake_promote_prepared "$id" "$batch" && wake_pending_secondmate_receiver "$id" || return 1
    fi
  else
    file="$DATA/handoff/$id.outbox.md"
    validate_backlog_file 'strict outbox' "$file" || return 1
    if [ ! -e "$file" ]; then
      if [ "$present" -eq "${#keys[@]}" ]; then
        seed_backlog_scaffold "$file"
        env -u TASKS_AXI_BACKEND tasks-axi mv "${keys[@]}" --file "$source/data/backlog.md" --to "$file" || return 1
      elif [ "$present" = 0 ]; then
        fm_handoff_publish "$file" < "$payload" || return 1
      else fm_handoff_error 'partially removed source requires reconciliation'; return 1
      fi
    fi
    [ "$(sha256_file "$file")" = "$hash" ] || { fm_handoff_error 'outstanding outbox conflicts with pinned batch'; return 1; }
    old_source=$MAIN_BACKLOG
    MAIN_BACKLOG="$source/data/backlog.md"
    remove_interrupted_source_duplicates "$file" "${keys[@]}" || return 1
    MAIN_BACKLOG=$old_source
    fm_lock_release "$ACTIVE_SOURCE_LOCK"; ACTIVE_SOURCE_LOCK=
    STRICT_TRANSFER=$transfer
    remote_deliver_outbox "$id" "$file" || return 1
    printf '%s\n' "$hash" | fm_handoff_publish "$accepted" || return 1
    echo "handoff durable: $transfer source=$SOURCE_ID destination=$id keys=${keys[*]}"
  fi
  warn_stale_public_commitments "$id" "${keys[@]}"
}

if [ "$RESUME_PENDING" -eq 1 ]; then
  FAILED=0
  resume_pending_wakes || FAILED=1
  resume_pending_outboxes || FAILED=1
  exit "$FAILED"
fi

ACTIVE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
fm_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
if [ -n "$SOURCE_ID" ]; then
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK" || exit 1
  strict_source_handoff "$ID" "$@"
  exit $?
fi
REMOTE=$(secondmate_registry_field "$REG" "$ID" remote 2>/dev/null || true)
if [ "$REMOTE" = 1 ]; then
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  if remote_handoff "$ID" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  exit "$rc"
fi
ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
fm_lock_release "$ACTIVE_REGISTRY_LOCK"
ACTIVE_REGISTRY_LOCK=

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || {
  echo "error: secondmate $ID has no home in $REG" >&2
  exit 1
}
SUB_HOME=$(validate_secondmate_home "$ID" "$RAW_HOME") || exit 1
SUB_BACKLOG="$SUB_HOME/data/backlog.md"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "secondmate backlog" "$SUB_BACKLOG" || exit 1

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
DONE=()
NOT_QUEUED=()
for key in "$@"; do
  if backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    case "$section" in
    "## Queued") TO_MOVE+=("$key") ;;
    "## In flight") IN_FLIGHT+=("$key") ;;
    "## Done") DONE+=("$key") ;;
    *) NOT_QUEUED+=("$key") ;;
    esac
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  echo "error: refusing to hand off Done (historical) backlog items: ${DONE[*]}; handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived." >&2
  FAILED=1
fi
if [ "${#NOT_QUEUED[@]}" -gt 0 ]; then
  echo "error: refusing to hand off non-queued backlog items: ${NOT_QUEUED[*]}; handoffs move in-scope queued work only." >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

REQUESTED_BATCH=$(receiver_wake_batch_id "$@") || {
  echo "error: receiver wake batch identity could not be recorded; nothing was moved" >&2
  exit 1
}

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  WAKE_PENDING_MARKER="$STATE/.backlog-handoff-$ID.wake-pending"
  case "$(cat "$WAKE_PENDING_MARKER" 2>/dev/null || true)" in
  prepared:*:"$REQUESTED_BATCH") receiver_wake_promote_prepared "$ID" "$REQUESTED_BATCH" || exit 1 ;;
  prepared:*)
    echo "error: a prepared receiver wake for secondmate $ID belongs to a different routed batch; retry that original handoff before handling ${ALREADY[*]}" >&2
    exit 1
    ;;
  esac
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  wake_pending_secondmate_receiver "$ID" || exit 1
  exit 0
fi

FAILED=0
for key in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if ! fm_tasks_axi_compatible; then
  echo "error: a compatible tasks-axi with atomic multi-ID mv support is required to move backlog items; run bin/fm-bootstrap.sh for the required version" >&2
  exit 1
fi

WAKE_PENDING_MARKER="$STATE/.backlog-handoff-$ID.wake-pending"
if [ -e "$WAKE_PENDING_MARKER" ] || [ -L "$WAKE_PENDING_MARKER" ]; then
  case "$(cat "$WAKE_PENDING_MARKER" 2>/dev/null || true)" in
  prepared:*:"$REQUESTED_BATCH") receiver_wake_discard_prepared "$ID" || exit 1 ;;
  prepared:*)
    echo "error: a prepared receiver wake for secondmate $ID belongs to a different routed batch; retry that original handoff before moving ${TO_MOVE[*]}" >&2
    exit 1
    ;;
  *)
    wake_pending_secondmate_receiver "$ID" || {
      echo "error: previous receiver wake for secondmate $ID is unresolved; nothing new was moved" >&2
      exit 1
    }
    ;;
  esac
fi
receiver_wake_mark_prepared "$ID" "$REQUESTED_BATCH" || {
  echo "error: receiver wake state for secondmate $ID could not be recorded; nothing was moved" >&2
  exit 1
}

# Seed the destination with firstmate's standard three-section scaffold when it
# does not exist yet, so the moved item lands under the right section. (Left to
# create the file itself, tasks-axi mv writes its own `# Backlog` title format,
# which is not firstmate's home-backlog convention.)
mkdir -p "$SUB_HOME/data"
SUB_CREATED=0
if [ ! -f "$SUB_BACKLOG" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' >"$SUB_BACKLOG"
  SUB_CREATED=1
fi

# Delegate the move to tasks-axi. Passing the whole in-scope set to one call is a
# single atomic transaction, so a connected set (blocker + dependents) moves
# together and, on any failure, neither backlog's content changes - the only
# cleanup is a scaffold we just created. tasks-axi writes both its success and
# error output to stdout, so capture it and surface it only on failure.
if ! MV_OUT=$(tasks-axi mv "${TO_MOVE[@]}" --file "$MAIN_BACKLOG" --to "$SUB_BACKLOG" 2>&1); then
  if [ "$SUB_CREATED" -eq 1 ]; then
    rm -f "$SUB_BACKLOG"
  fi
  receiver_wake_discard_prepared "$ID" || {
    echo "error: tasks-axi mv failed and receiver wake state could not be cleared" >&2
    exit 1
  }
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  echo "error: tasks-axi mv failed; nothing was moved." >&2
  exit 1
fi

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_BACKLOG"
receiver_wake_promote_prepared "$ID" "$REQUESTED_BATCH" || {
  echo "error: handed off work to secondmate $ID, but durable receiver wake state could not be recorded" >&2
  exit 1
}
wake_pending_secondmate_receiver "$ID" || exit 1
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
warn_stale_public_commitments "$ID" "${TO_MOVE[@]}"
