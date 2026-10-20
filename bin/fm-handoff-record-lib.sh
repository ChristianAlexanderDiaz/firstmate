#!/usr/bin/env bash
# Shared strict-transfer receipts and operational-record refusals.
# Usage: source after fm-wake-lib.sh and fm-tasks-axi-lib.sh.
# Retirement checks also require fm-backlog-transition-lib.sh.
# Receipt v1 is five newline-terminated fields: schema, transfer id, payload
# SHA-256, canonical destination home + marker identity, sorted key-set SHA-256.
# Files are private, atomically published below state/handoff/receipts only.
# Lock order: parent registry, parent handoff, source task-set, destination
# task-set, receiver upload. tasks-axi owns its own file locks inside this order.
# A committed move without an accepted receipt remains ambiguous on retry.

fm_handoff_error() { printf 'error: %s\n' "$*" >&2; return 1; }

fm_handoff_file() {
  local links
  if [ "$(uname)" = Darwin ]; then links=$(stat -f '%l' "$1" 2>/dev/null) || return 1
  else links=$(stat -c '%h' "$1" 2>/dev/null) || return 1; fi
  [ ! -L "$1" ] && [ -f "$1" ] && [ -r "$1" ] && [ "$links" = 1 ] \
    || fm_handoff_error "unsafe or unreadable handoff record: $1"
}

fm_handoff_dir() {
  local path=$1
  [ ! -L "$path" ] || { fm_handoff_error "symlinked operational directory: $path"; return 1; }
  [ ! -e "$path" ] || [ -d "$path" ] || return 1
  (umask 077; mkdir -p "$path") || return 1
  [ -r "$path" ] && [ -x "$path" ]
}

fm_handoff_publish() { # <path> ; stdin is data, never executable
  local path=$1 tmp
  [ ! -e "$path" ] && [ ! -L "$path" ] || fm_handoff_file "$path" || return 1
  tmp=$(umask 077; mktemp "${path%/*}/.publish.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_handoff_digest() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

fm_handoff_id_valid() { [[ $1 =~ ^[a-f0-9]{32}$ ]]; }

fm_handoff_home_identity() {
  local home marker=parent
  home=$(cd "$1" && pwd -P) || return 1
  if [ -e "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ]; then
    fm_handoff_file "$home/.fm-secondmate-home" || return 1
    marker=$(cat "$home/.fm-secondmate-home") || return 1
  fi
  printf '%s\n%s\n' "$home" "$marker" | fm_handoff_digest
}

fm_handoff_receipt_path() {
  local home=$1 id=$2
  fm_handoff_id_valid "$id" || return 1
  fm_handoff_dir "$home/state" && fm_handoff_dir "$home/state/handoff" && fm_handoff_dir "$home/state/handoff/receipts" || return 1
  printf '%s/state/handoff/receipts/%s.receipt\n' "$home" "$id"
}

fm_handoff_receipt_body() { # <home> <id> <payload-hash> <key-hash>
  local identity
  identity=$(fm_handoff_home_identity "$1") || return 1
  printf 'fm-strict-transfer.v1\n%s\n%s\n%s\n%s\n' "$2" "$3" "$identity" "$4"
}

# 0 accepted, 3 absent, 1 unsafe/conflicting. Never infer acceptance from keys.
fm_handoff_receipt_check() {
  local path expected
  path=$(fm_handoff_receipt_path "$1" "$2") || return 1
  [ -e "$path" ] || [ -L "$path" ] || return 3
  fm_handoff_file "$path" || return 1
  [ "$(wc -l < "$path" | tr -d ' ')" = 5 ] || return 1
  [ "$(wc -c < "$path" | tr -d ' ')" -le 512 ] || return 1
  expected=$(fm_handoff_receipt_body "$@") || return 1
  [ "$(cat "$path")" = "$expected" ] || { fm_handoff_error "strict transfer receipt conflicts: $2"; return 1; }
}

fm_handoff_receipt_accept() {
  local path body
  path=$(fm_handoff_receipt_path "$1" "$2") || return 1
  body=$(fm_handoff_receipt_body "$@") || return 1
  printf '%s\n' "$body" | fm_handoff_publish "$path"
}

# Parse task data only through tasks-axi; no task block serialization lives here.
fm_handoff_show() { (cd "$1" && env -u TASKS_AXI_BACKEND tasks-axi show "$2" --file "$1/data/backlog.md" --full); }
fm_handoff_field() { sed -n "s/^  $2: //p" <<< "$1"; }
fm_handoff_keys() { # <home> [file]
  local out
  if [ "$#" -eq 2 ]; then
    out=$(cd "$1" && env -u TASKS_AXI_BACKEND tasks-axi list --file "$2") || { printf '%s\n' "$out" >&2; return 1; }
  else
    out=$(unset TASKS_AXI_BACKEND; fm_backlog_row_list "$1/data") || { printf '%s\n' "$out" >&2; return 1; }
  fi
  printf '%s\n' "$out" | sed -n '/^tasks\[[0-9]*\]{id.*}:$/,/^help\[/ { /^  / { s/^  //; s/,.*//; p; }; }'
}

fm_handoff_markdown() {
  local backend
  if [ -e "$1/.tasks.toml" ] || [ -L "$1/.tasks.toml" ]; then fm_handoff_file "$1/.tasks.toml" || return 1; fi
  backend=$(unset TASKS_AXI_BACKEND; fm_tasks_axi_backend_resolve "$1") || return 1
  [ "$backend" = markdown ] || { fm_handoff_error "source-secondmate handoff supports markdown backlogs only: $1"; return 1; }
}

fm_handoff_task_records_clear() { # <home> <key> [parent] [state-override]
  local home=$1 key=$2 file open
  local state=${4:-$1/state}
  local meta="$state/$key.meta"
  [ "${3:-}" != parent ] || meta="$state/$key.retirement-unused"
  file="$state/reconcile-requests"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -d "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  fi
  for file in "$meta" "$state/reconcile-requests/$key.request"; do
    [ ! -e "$file" ] && [ ! -L "$file" ] || { fm_handoff_error "task $key still owns operational records: $file"; return 1; }
  done
  file="$state/$key.status"
  if [ -e "$file" ] || [ -L "$file" ]; then
    fm_handoff_file "$file" || return 1
    open=$(status_open_decisions "$file") || return 1
    [ -z "$open" ] || { fm_handoff_error "task $key has an unresolved status decision"; return 1; }
  fi
  file="$state/$key.inbox"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -d "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
    for file in "$file"/*.msg; do
      [ ! -e "$file" ] && [ ! -L "$file" ] || { fm_handoff_error "task $key has unread steering"; return 1; }
    done
  fi
}

fm_handoff_retirement_clear() { # <target-home> <parent-home> <id> [parent-state] [parent-data]
  local home=$1 parent=$2 id=$3 keys key show file pending dir backend
  local parent_state=${4:-$2/state} parent_data=${5:-$2/data}
  for dir in data state config; do
    [ ! -e "$home/$dir" ] && [ ! -L "$home/$dir" ] && continue
    [ -d "$home/$dir" ] && [ ! -L "$home/$dir" ] && [ -r "$home/$dir" ] || return 1
  done
  for file in "$home/state"/*.meta "$home/data/handoff"/*.outbox.md; do
    [ ! -e "$file" ] && [ ! -L "$file" ] || { fm_handoff_error "secondmate $id has child work or an unfinished outbox: $file"; return 1; }
  done
  backend=$(unset TASKS_AXI_BACKEND; fm_tasks_axi_backend_resolve "$home") || return 1
  if [ "$backend" != markdown ] || [ -e "$home/data/backlog.md" ] || [ -L "$home/data/backlog.md" ]; then
    [ "$backend" != markdown ] || fm_handoff_file "$home/data/backlog.md" || return 1
    keys=$(fm_handoff_keys "$home") || return 1
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      show=$(unset TASKS_AXI_BACKEND; fm_backlog_row_show "$home/data" "$key") || return 1
      if [ "$(fm_handoff_field "$show" state)" != done ] || [ "$(fm_handoff_field "$show" held)" != no ]; then
        fm_handoff_error "secondmate $id still has open backlog task $key"; return 1
      fi
    done <<< "$keys"
  fi
  for file in "$home/state"/*.status; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    key=$(basename "$file" .status)
    fm_handoff_task_records_clear "$home" "$key" || return 1
  done
  fm_handoff_task_records_clear "$parent" "$id" parent "$parent_state" || return 1
  for dir in "$home/state"/*.inbox "$home/state/reconcile-requests"; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] || return 1
    for file in "$dir"/*.msg "$dir"/*.request; do
      [ ! -e "$file" ] && [ ! -L "$file" ] || { fm_handoff_error "secondmate $id has unread steering or reconciliation"; return 1; }
    done
  done
  dir="$home/state/procevent-inbox"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] || return 1
    for file in "$dir"/*; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      fm_handoff_file "$file" || return 1
    done
    pending=$(fm_procevent_pending "$home/state") || return 1
    [ -z "$pending" ] || { fm_handoff_error "secondmate $id has unhandled captured process-event results"; return 1; }
  fi
  dir="$parent_data/handoff/transfers"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] || return 1
    for file in "$dir"/*.record; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      fm_handoff_provenance "$file" || return 1
      if [ "$(sed -n '3p' "$file")" = "$id" ] || [ "$(sed -n '4p' "$file")" = "$home" ]; then
        fm_handoff_file "${file%.record}.accepted" && \
          [ "$(cat "${file%.record}.accepted")" = "$(sed -n '9p' "$file")" ] || { fm_handoff_error "secondmate $id owns an unfinished transfer: $file"; return 1; }
      fi
    done
  fi
}

# Immutable source provenance: bounded plain data, with no shell evaluation.
fm_handoff_provenance() {
  local file=$1 id hash keys_hash actual field
  fm_handoff_file "$file" || return 1
  [ "$(wc -c < "$file" | tr -d ' ')" -le 65536 ] || return 1
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  [ "$(sed -n '1p' "$file")" = fm-handoff-source.v1 ] || return 1
  id=$(sed -n '2p' "$file")
  fm_handoff_id_valid "$id" || return 1
  [ "${file##*/}" = "$id.record" ] || return 1
  for field in 5 6 8 9; do
    hash=$(sed -n "${field}p" "$file")
    [[ $hash =~ ^[a-f0-9]{64}$ ]] || return 1
  done
  keys_hash=$(sed -n '8p' "$file")
  actual=$(sed -n '10,$p' "$file" | fm_handoff_digest) || return 1
  [ "$keys_hash" = "$actual" ] || return 1
}
