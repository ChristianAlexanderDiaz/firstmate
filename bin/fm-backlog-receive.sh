#!/usr/bin/env bash
# Receive one delivered remote-secondmate outbox into this home's backlog.
#
# Usage:
#   fm-backlog-receive.sh state/handoff/<secondmate-id>.outbox.md <bytes> <sha256> <generation>
#   fm-backlog-receive.sh --capabilities
#   fm-backlog-receive.sh --strict-transfer <32-lowercase-hex-id> state/handoff/<id>.outbox.md <bytes> <sha256> <generation>
# Strict mode uses accepted receipts, refuses unknown duplicate keys, and keeps
# post-commit/pre-receipt crashes ambiguous; see fm-handoff-record-lib.sh.
#
# The delivered file must be a non-symlink backlog-format scratch file confined
# to FM_HOME/state/handoff. Every item must be Queued. Legacy mode skips keys
# already in data/backlog.md; strict mode requires its matching accepted receipt
# for a retry and refuses destination-present keys without one. New keys move
# in one dependency-closed `tasks-axi mv` under tasks-axi's own file locks.
#
# If tasks-axi reports a lock failure, this host may remove and retry once only
# for its own backlog or delivered lock whose pid is dead and whose mtime is at
# least 30 seconds old. No live or uncertain lock is touched. On confirmed
# receipt the delivered scratch file is removed; no other path is deletable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DEST="$FM_HOME/data/backlog.md"
LOCK_STALE_SECS=30

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# shellcheck source=bin/fm-handoff-record-lib.sh
. "$SCRIPT_DIR/fm-handoff-record-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

backlog_key_section() { # <file> <key>
  awk -v key="$2" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ { section=$0; sub(/^##[[:space:]]+/, "## ", section); sub(/[[:space:]]+$/, "", section); next }
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id == key) { print section; found=1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

list_keys() { # <file>
  awk '
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id != "" && !seen[id]++) print id
    }
  ' "$1"
}

lock_age() {
  local modified now
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    modified=$(/usr/bin/stat -f '%m' "$1" 2>/dev/null) || return 1
  else
    modified=$(stat -c '%Y' "$1" 2>/dev/null) || return 1
  fi
  now=$(date +%s) || return 1
  case "$modified$now" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - modified))"
}

remove_dead_stale_lock() { # <lock-path>
  local lock=$1 token pid age
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  IFS= read -r token < "$lock" || return 1
  pid=${token%%:*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1
  age=$(lock_age "$lock") || return 1
  [ "$age" -ge "$LOCK_STALE_SECS" ] || return 1
  rm -f -- "$lock"
}

run_move() { # <keys...>
  tasks-axi mv "$@" --file "$DELIVERED" --to "$DEST"
}

STRICT_TRANSFER=
if [ "${1:-}" = --capabilities ]; then
  [ "$#" -eq 1 ] || usage
  [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] || die "receiver is not a seeded home"
  fm_handoff_markdown "$FM_HOME" || die "strict receiver requires markdown"
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || die "invalid receiver parent binding"
  printf 'binding:%s\n' "$FM_SECONDMATE_PARENT_ROUTE"
  [ -d "$FM_HOME/data" ] && [ ! -L "$FM_HOME/data" ] && [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || die "unsafe receiver operational directories"
  printf 'strict-transfer-v1\n'
  printf 'marker:%s\nhome:%s\n' "$(cat "$FM_HOME/.fm-secondmate-home")" "$(cd "$FM_HOME" && pwd -P)"
  if [ -e "$FM_HOME/data/projects.md" ]; then
    fm_handoff_file "$FM_HOME/data/projects.md" || die "unsafe project registry"
    sed -n 's/^- \([^ ][^ ]*\) .*/project:\1/p' "$FM_HOME/data/projects.md"
  fi
  exit 0
fi
if [ "${1:-}" = --strict-transfer ]; then
  [ "$#" -eq 6 ] || usage
  STRICT_TRANSFER=$2
  fm_handoff_id_valid "$STRICT_TRANSFER" || die "strict transfer id must be 32 lowercase hexadecimal characters"
  shift 2
fi
[ "$#" -eq 4 ] || usage
REL=$1
EXPECTED_BYTES=$2
EXPECTED_HASH=$3
GENERATION=$4
case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
[ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes are outside the supported range"
[ "$EXPECTED_BYTES" -le 1048576 ] || die "expected bytes are outside the supported range"
case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
case "$REL" in state/handoff/*.outbox.md) ;; *) die "delivered outbox path is outside state/handoff: $REL" ;; esac
case "/$REL/" in */../*|*/./*) die "delivered outbox path contains traversal" ;; esac
case "$REL" in *'//'*) die "delivered outbox path is malformed" ;; esac
[ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
  || die "FM_HOME is not a seeded secondmate home"
[ -f "$FM_HOME/AGENTS.md" ] && [ -d "$FM_HOME/bin" ] || die "FM_HOME is not a Firstmate home"
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME cannot be resolved"
PARENT=$(dirname "$FM_HOME/$REL")
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" 2>/dev/null && pwd -P) || die "delivered outbox parent is unavailable"
case "$PARENT_REAL" in "$HOME_REAL/state/handoff") ;; *) die "delivered outbox escapes the remote scratch directory" ;; esac
DELIVERED="$PARENT_REAL/$(basename "$REL")"
NAME=$(basename "$REL")
ID=${NAME%.outbox.md}
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "delivered outbox id is unsafe" ;; esac
TRANSFER_LOCK="$PARENT_REAL/.$ID.upload.lock"
TASK_SET_LOCK=
release_receipt_locks() {
  fm_lock_release "$TRANSFER_LOCK" || true
  [ -z "$TASK_SET_LOCK" ] || fm_lock_release "$TASK_SET_LOCK" || true
}
trap release_receipt_locks EXIT
TASK_SET_LOCK=$(fm_task_set_lock_path "$FM_HOME/state") || die "invalid destination task-set lock"
fm_lock_acquire_wait "$TASK_SET_LOCK" || die "cannot lock destination task set"
fm_lock_acquire_wait "$TRANSFER_LOCK" || die "cannot lock delivered outbox"
[ -f "$DELIVERED" ] && [ ! -L "$DELIVERED" ] || die "delivered outbox is not a non-symlink regular file"
GENERATION_FILE="$PARENT_REAL/.$ID.upload-generation"
[ -f "$GENERATION_FILE" ] && [ ! -L "$GENERATION_FILE" ] || die "delivered outbox generation is unavailable or unsafe"
{
  IFS= read -r STORED_GENERATION \
    && IFS= read -r STORED_BYTES \
    && IFS= read -r STORED_HASH \
    && ! IFS= read -r
} < "$GENERATION_FILE" || die "delivered outbox generation is malformed"
case "$STORED_GENERATION" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_GENERATION}" -le 18 ] || die "delivered outbox generation is malformed"
case "$STORED_BYTES" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
case "$STORED_HASH" in ''|*[!A-Fa-f0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_HASH}" -eq 64 ] || die "delivered outbox generation is malformed"
[ "$STORED_GENERATION" = "$GENERATION" ] \
  && [ "$STORED_BYTES" = "$EXPECTED_BYTES" ] \
  && [ "$STORED_HASH" = "$EXPECTED_HASH" ] \
  || die "delivered outbox generation is superseded or conflicting"
ACTUAL_BYTES=$(LC_ALL=C wc -c < "$DELIVERED" | tr -d ' ')
[ "$ACTUAL_BYTES" -eq "$EXPECTED_BYTES" ] || die "delivered outbox length does not match its commitment"
ACTUAL_HASH=$(sha256_file "$DELIVERED") || die "cannot hash delivered outbox"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "delivered outbox digest does not match its commitment"
[ ! -L "$DEST" ] || die "destination backlog must not be a symlink"
if [ -e "$DEST" ] && [ ! -f "$DEST" ]; then die "destination backlog is not a regular file"; fi

KEYS=()
while IFS= read -r key; do
  [ -n "$key" ] && KEYS+=("$key")
done < <(list_keys "$DELIVERED")
if [ -n "$STRICT_TRANSFER" ]; then
  fm_handoff_markdown "$FM_HOME" || die "unsupported receiver backlog backend"
  STRICT_KEYS=$(fm_handoff_keys "$FM_HOME" "$DELIVERED") || die "cannot parse delivered backlog"
  KEYS=()
  while IFS= read -r key; do [ -z "$key" ] || KEYS+=("$key"); done <<< "$STRICT_KEYS"
  [ "${#KEYS[@]}" -gt 0 ] || die "strict transfer is empty"
  KEY_HASH=$(printf '%s\n' "${KEYS[@]}" | LC_ALL=C sort | fm_handoff_digest) || die "cannot bind key set"
  RECEIPT_RC=0
  fm_handoff_receipt_check "$FM_HOME" "$STRICT_TRANSFER" "$EXPECTED_HASH" "$KEY_HASH" || RECEIPT_RC=$?
  case "$RECEIPT_RC" in
    0) rm -f -- "$DELIVERED"; printf 'received: %s accepted retry\n' "$ID"; exit 0 ;;
    3) ;;
    *) die "conflicting or unsafe strict receipt; delivered outbox preserved" ;;
  esac
fi
for key in "${KEYS[@]}"; do
  section=$(backlog_key_section "$DELIVERED" "$key") || die "delivered key disappeared during classification: $key"
  [ "$section" = '## Queued' ] || die "delivered outbox contains non-Queued item $key under $section"
done

mkdir -p "$FM_HOME/data"
DEST_CREATED=0
if [ ! -f "$DEST" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$DEST"
  DEST_CREATED=1
fi
TO_MOVE=()
ALREADY=()
for key in "${KEYS[@]}"; do
  if backlog_key_section "$DEST" "$key" >/dev/null 2>&1; then
    if [ -n "$STRICT_TRANSFER" ]; then
      die "ambiguous strict transfer: destination key $key exists without an accepted receipt; preserve the parent outbox and reconcile destination task bodies/history"
    fi
    ALREADY+=("$key")
  else
    TO_MOVE+=("$key")
  fi
done

if [ "${#TO_MOVE[@]}" -gt 0 ]; then
  fm_tasks_axi_compatible || die "a compatible tasks-axi is required for atomic backlog receipt; run bin/fm-bootstrap.sh for the required version"
  if ! MOVE_OUT=$(run_move "${TO_MOVE[@]}" 2>&1); then
    recovered=0
    for lock in "$DELIVERED.lock" "$DEST.lock"; do
      if remove_dead_stale_lock "$lock"; then recovered=1; fi
    done
    if [ "$recovered" -ne 1 ] || ! MOVE_OUT=$(run_move "${TO_MOVE[@]}" 2>&1); then
      [ "$DEST_CREATED" -eq 0 ] || rm -f -- "$DEST"
      [ -z "$MOVE_OUT" ] || printf '%s\n' "$MOVE_OUT" >&2
      die "atomic backlog receipt failed; delivered outbox is preserved for retry"
    fi
  fi
fi

for key in "${KEYS[@]}"; do
  backlog_key_section "$DEST" "$key" >/dev/null 2>&1 \
    || die "receipt verification failed for $key; delivered outbox is preserved"
done
if [ -n "$STRICT_TRANSFER" ]; then
  fm_handoff_receipt_accept "$FM_HOME" "$STRICT_TRANSFER" "$EXPECTED_HASH" "$KEY_HASH" \
    || die "move committed but accepted receipt could not be published; preserve parent outbox for reconciliation"
fi
rm -f -- "$DELIVERED" || die "receipt succeeded but delivered scratch cleanup failed"
fm_lock_release "$TRANSFER_LOCK" || die "receipt succeeded but transfer lock cleanup failed"
[ -z "$TASK_SET_LOCK" ] || fm_lock_release "$TASK_SET_LOCK"
trap - EXIT
printf 'received: %s moved=%s already=%s\n' "$(basename "$REL" .outbox.md)" "${#TO_MOVE[@]}" "${#ALREADY[@]}"
