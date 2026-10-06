#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for the default-on disposable single-task
# presentation projection, its explicit opt-out, and the best-effort
# presentation order across primary and secondmate homes.
# The test drives the real spawn and teardown scripts, a real Treehouse pool,
# and the guarded named-session lab helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-presentation.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
TREEHOUSE_CALL_LOG="$TMP_ROOT/treehouse-calls.log"
TREEHOUSE_LOCK_DIR="$TMP_ROOT/treehouse-call.lock"
MOVE_CALL_LOG="$TMP_ROOT/workspace-move-calls.log"
FOCUS_AUDIT_LOG="$TMP_ROOT/focus-audit.log"
ACTIVE_SEEDED_CONTROL="$TMP_ROOT/active-seeded-control"
POST_CREATE_ABORT_CONTROL="$TMP_ROOT/post-create-abort-control"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
: > "$TREEHOUSE_CALL_LOG"
: > "$MOVE_CALL_LOG"
: > "$FOCUS_AUDIT_LOG"
REAL_MOVER="$ROOT/bin/backends/herdr-workspace-move.py"
export REAL_HERDR REAL_TREEHOUSE REAL_MOVER HERDR_CALL_LOG TREEHOUSE_CALL_LOG TREEHOUSE_LOCK_DIR MOVE_CALL_LOG FOCUS_AUDIT_LOG HERDR_ORIGINAL_PATH HERDR_LAB_HELPER
export ACTIVE_SEEDED_CONTROL POST_CREATE_ABORT_CONTROL TMP_ROOT

# Log every production-adapter call, remove its already-validated trailing
# session flag, and send the operation through the lab helper so that helper
# remains the sole process which appends the real trailing session flag.
# The adapter's deliberately session-independent version read cannot pass the
# helper's leading-option guard, so the wrapper sends only that read straight
# to the absolute real binary with the same explicit trailing lab session.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last_index=$((${#args[@]} - 1))
flag_index=$((last_index - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag_index]}" = --session ] \
   && [ "${args[$last_index]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last_index]" "args[$flag_index]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}

arg_value() {
  local want=$1 previous= arg
  shift
  for arg in "$@"; do
    if [ "$previous" = "$want" ]; then
      printf '%s' "$arg"
      return 0
    fi
    previous=$arg
  done
  return 1
}

label=$(arg_value --label "$@" || true)
if [ "${1:-} ${2:-}" = "workspace list" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ]; then
  stage=$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)
  if [ "$stage" = task-created ]; then
    printf '%s\n' post-task-snapshot > "$ACTIVE_SEEDED_CONTROL/stage"
  elif [ "$stage" = post-task-snapshot ]; then
    seeded_tab=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-tab")
    inject_before=$(focus_snapshot || printf ambiguous/ambiguous)
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab focus "$seeded_tab" >/dev/null
    inject_after=$(focus_snapshot || printf ambiguous/ambiguous)
    printf 'active-seeded-inject\t%s\t%s\t%s\n' "$inject_before" "$inject_after" "$seeded_tab" >> "$FOCUS_AUDIT_LOG"
    printf '%s\n' injected > "$ACTIVE_SEEDED_CONTROL/stage"
  fi
fi

mutation=
mutation_target=${3:-}
case "${1:-} ${2:-}" in
  "workspace create") mutation=workspace-create; mutation_target=$label ;;
  "tab create") mutation=tab-create; mutation_target=$label ;;
  "pane close") mutation=pane-close ;;
  "tab focus") mutation=tab-focus ;;
esac
refusal_probe=0
if [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ] \
   && [ "$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)" = injected ] \
   && [ "${3:-}" = "$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane" 2>/dev/null || true)" ]; then
  refusal_probe=1
  refusal_before=$(focus_snapshot || printf ambiguous/ambiguous)
fi
before=
[ -z "$mutation" ] || before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"); then
  status=0
else
  status=$?
fi
if [ "$status" -eq 0 ] && [ "$mutation" = workspace-create ]; then
  case "$label" in
    $'└ active-seeded · p:'*)
      mkdir -p "$ACTIVE_SEEDED_CONTROL"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$ACTIVE_SEEDED_CONTROL/workspace"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-tab"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-pane"
      ;;
    $'└ abort-a · p:'*|$'└ abort-b · p:'*)
      task=${label#$'└ '}; task=${task%% *}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$POST_CREATE_ABORT_CONTROL/$task/workspace"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "$mutation" = tab-create ]; then
  case "$label" in
    fm-active-seeded)
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/task-pane"
      printf '%s\n' task-created > "$ACTIVE_SEEDED_CONTROL/stage"
      ;;
    fm-abort-a|fm-abort-b)
      task=${label#fm-}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$POST_CREATE_ABORT_CONTROL/$task/task-pane"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$POST_CREATE_ABORT_CONTROL" ]; then
  for task_dir in "$POST_CREATE_ABORT_CONTROL"/abort-*; do
    [ -d "$task_dir" ] || continue
    [ "${3:-}" = "$(cat "$task_dir/task-pane" 2>/dev/null || true)" ] || continue
    out=$(printf '%s' "$out" | jq --arg cwd "$POST_CREATE_ABORT_CONTROL/not-a-worktree" '.result.pane.foreground_cwd = $cwd')
    break
  done
fi
if [ -n "$mutation" ]; then
  after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf '%s\t%s\t%s\t%s\n' "$mutation" "$before" "$after" "$mutation_target" >> "$FOCUS_AUDIT_LOG"
fi
if [ "$refusal_probe" -eq 1 ]; then
  refusal_after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf 'seeded-prune-refusal\t%s\t%s\t%s\n' "$refusal_before" "$refusal_after" "${3:-}" >> "$FOCUS_AUDIT_LOG"
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$TREEHOUSE_CALL_LOG"
if [ -d "$POST_CREATE_ABORT_CONTROL" ] && [ "${1:-}" = get ]; then
  exit 0
fi
# Treehouse's pool allocator is outside the Herdr concurrency contract under
# test. Serialize its calls so simultaneous recovery spawns cannot race for
# one pool slot before reaching the Herdr session lock exercised below.
while ! mkdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null; do
  sleep 0.01
done
release_treehouse_lock() { rmdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null || true; }
trap release_treehouse_lock EXIT
trap 'exit 1' HUP INT TERM
"$REAL_TREEHOUSE" "$@"
exit $?
SH

cat > "$FAKEBIN/herdr-workspace-mover" <<'SH'
#!/usr/bin/env bash
set -u
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MOVE_CALL_LOG"
before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$("$REAL_MOVER" "$@"); then
  status=0
else
  status=$?
fi
after=$(focus_snapshot || printf ambiguous/ambiguous)
printf 'workspace-move\t%s\t%s\t%s\n' "$before" "$after" "$2" >> "$FOCUS_AUDIT_LOG"
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN/herdr-workspace-mover"
export PATH="$FAKEBIN:$PATH"
export FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAKEBIN/herdr-workspace-mover"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity. Every projection below is anchored on the
# parent this suite sets up, not on the developer's own workspace.
herdr_forget_inherited_pane

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" name fm-herdr-presentation-projection)
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
LAB_READY=0
RECORDED_WORKTREES=""
LOCK_CONTENTION_OWNER_PID=
cleanup_all() {
  local wt
  if [ -n "$LOCK_CONTENTION_OWNER_PID" ]; then
    kill "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    wait "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    LOCK_CONTENTION_OWNER_PID=
  fi
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" \
      "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

focus_snapshot() {
  local list row workspace tab tabs
  list=$(lab workspace list) || fail "could not read the active workspace for focus instrumentation"
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || fail "could not parse the active workspace and tab"
  [ -n "$row" ] || fail "focus instrumentation found an ambiguous active workspace"
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(lab tab list --workspace "$workspace") || fail "could not verify the active tab"
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || fail "workspace active_tab_id disagreed with the focused tab"
  printf '%s/%s' "$workspace" "$tab"
}

assert_focus_is() {  # <expected> <case-name>
  local expected=$1 case_name=$2 actual
  actual=$(focus_snapshot)
  [ "$actual" = "$expected" ] || fail "$case_name changed active workspace/tab from $expected to $actual"
}

focus_audit_line_count() { wc -l < "$FOCUS_AUDIT_LOG" | tr -d '[:space:]'; }

assert_raw_presentation_mutations_preserved_since() {  # <line-count> <case-name>
  local start=$1 case_name=$2 changed
  changed=$(sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' '
    ($1 == "workspace-create" || $1 == "tab-create" || $1 == "workspace-move" || $1 == "pane-close") && $2 != $3 {
      print $0
    }
  ')
  [ -z "$changed" ] || fail "$case_name changed active workspace/tab inside a create, move, or seeded cleanup: $changed"
}

# The focus-safe emptying-close plan removes a last pane through Herdr's
# pane-death path with no pane.close mutation at all (the raw explicit-close
# defect is demonstrated by tests/fm-backend-herdr-focus-flash-e2e.test.sh);
# a fallback plain close must preserve or immediately restore exact focus.
assert_cleanup_focus_preserved() {  # <line-count> <pane-id> <expected-focus>
  local start=$1 pane_id=$2 expected=$3
  sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v pane="$pane_id" -v expected="$expected" '
    $1 == "pane-close" && $4 == pane {
      saw_close = 1
      if ($2 != expected) { bad = 1 }
      else if ($3 == expected) { preserved = 1 }
      else { drift = $3 }
      next
    }
    saw_close && drift != "" && $1 == "tab-focus" && $2 == drift && $3 == expected {
      preserved = 1
    }
    END { exit(bad || (saw_close && !preserved) ? 1 : 0) }
  ' || fail "projected pane close did not preserve or restore the exact active workspace and tab"
  if lab pane get "$pane_id" >/dev/null 2>&1; then
    fail "projected cleanup left exact pane $pane_id alive"
  fi
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" | cut -d= -f2-)
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
  printf '%s' "$wt"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr projection E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {  # <home> <id> [description]
  local home=$1 id=$2 description=${3:-Herdr presentation fixture $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$description

## Firstmate spec
Verify projected workspace behavior for $id.
EOF
}

spawn_task() {  # <id> <home> <project>
  local id=$1 home=$2 project=$3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/code-root" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}

# finish_same_project_spawn: wait for one of several concurrent spawns on the
# same project. Same-project spawns refuse rather than race for a Treehouse
# slot, so a refused spawn is rerun once the others have finished.
finish_same_project_spawn() {  # <pid> <id> <home> <project> <stdout> <stderr> <case>
  local pid=$1 id=$2 home=$3 project=$4 out=$5 err=$6 case_name=$7
  wait "$pid" && return 0
  grep -F "another Treehouse slot allocation or return is in progress" "$err" >/dev/null 2>&1 \
    || fail "$case_name failed: $(cat "$err")"
  SAME_PROJECT_RETRY+=("$id|$home|$project|$out|$err|$case_name")
}

retry_same_project_spawns() {
  local entry id home project out err case_name
  for entry in ${SAME_PROJECT_RETRY[@]+"${SAME_PROJECT_RETRY[@]}"}; do
    IFS='|' read -r id home project out err case_name <<<"$entry"
    spawn_task "$id" "$home" "$project" > "$out" 2> "$err" \
      || fail "$case_name retry failed: $(cat "$err")"
  done
  SAME_PROJECT_RETRY=()
}
SAME_PROJECT_RETRY=()

finish_concurrent_spawn() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  grep -F "task set is locked" "$err" >/dev/null 2>&1 \
    || fail "concurrent projected spawn $id failed unexpectedly: $(cat "$err")"
  spawn_task "$id" "$HOME_DIR" "$PROJECT_DIR" > "$out" 2> "$err" \
    || fail "projected spawn $id retry failed after task-set publication completed: $(cat "$err")"
}

finish_concurrent_expected_abort() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || fail "post-create abort fixture $id unexpectedly succeeded"
  if grep -F "task set is locked" "$err" >/dev/null 2>&1; then
    if spawn_task "$id" "$HOME_DIR" "$PROJECT_DIR" > "$out" 2> "$err"; then
      fail "post-create abort fixture $id unexpectedly succeeded after task-set publication completed"
    fi
  fi
}

spawn_secondmate_task() {
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$TMP_ROOT/code-root" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "sh -c 'while :; do sleep 60; done'" --secondmate --backend herdr
}

teardown_task() {  # <id> <home>
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$TMP_ROOT/code-root" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

finish_concurrent_teardown() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  if ! grep -F "session presentation lock is contended" "$err" >/dev/null 2>&1 \
     && ! grep -F "another Treehouse slot allocation or return is in progress" "$err" >/dev/null 2>&1; then
    fail "projected teardown $id failed unexpectedly: $(cat "$err")"
  fi
  teardown_task "$id" "$HOME_DIR" > "$out" 2> "$err" \
    || fail "projected teardown $id retry failed after presentation cleanup completed: $(cat "$err")"
}

normalize_meta() {  # <meta>
  sed -E \
    -e 's|^window=.*$|window=<herdr-container-id>|' \
    -e 's|^herdr_workspace_id=.*$|herdr_workspace_id=<herdr-container-id>|' \
    -e 's|^herdr_tab_id=.*$|herdr_tab_id=<herdr-container-id>|' \
    -e 's|^herdr_pane_id=.*$|herdr_pane_id=<herdr-container-id>|' \
    -e 's|^spawn_gen=.*$|spawn_gen=<spawn-incarnation>|' \
    "$1"
}

log_line_count() { wc -l < "$HERDR_CALL_LOG" | tr -d '[:space:]'; }

projection_labels_from_log() {  # <start-line>
  local start=$1
  sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG" | awk -F '\t' '
    $1 == "workspace" && $2 == "create" {
      for (i = 1; i < NF; i += 1) {
        if ($i == "--label" && $(i + 1) ~ /^└ /) {
          print $(i + 1)
        }
      }
    }
  '
}

session_presentation_lock_path() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_presentation_session_lock_path "$1"
  ' "$ROOT" "$HERDR_LAB_SESSION"
}

assert_no_ordering_lifecycle_calls_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(close|rename)|tab\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name introduced a workspace/tab/session lifecycle or label mutation call"
  fi
}

assert_no_projection_mutation_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(create|close|rename)|tab\t(create|close)|pane\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name performed a create, close, delete, rename, or lifecycle call during recovery inspection"
  fi
}

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
RECOVERY_PROJECT_DIR="$TMP_ROOT/recovery-project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$TMP_ROOT/code-root"
ln -s "$ROOT/bin" "$TMP_ROOT/code-root/bin"
ln -s "$ROOT/docs" "$TMP_ROOT/code-root/docs"
ln -s "$ROOT/.agents" "$TMP_ROOT/code-root/.agents"
touch "$HOME_DIR/state/.last-watcher-beat"
make_project "$PROJECT_DIR"
make_project "$RECOVERY_PROJECT_DIR"
write_ship_brief "$HOME_DIR" anchor
write_ship_brief "$HOME_DIR" fm-hibit-resume-r1
write_ship_brief "$HOME_DIR" wheelhouse-healing-r1
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
spawn_task anchor "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/anchor.out" 2> "$TMP_ROOT/anchor.err" || fail "could not create main-home anchor"
ANCHOR_META="$HOME_DIR/state/anchor.meta"
remember_meta_worktree "$ANCHOR_META" >/dev/null
printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
SECOND_ONE_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-alpha --no-focus)
SECOND_TWO_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-bravo --focus)
SECOND_TWO_WSID=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.workspace.workspace_id')
SECOND_TWO_TAB=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.tab.tab_id')
CAPTAIN_FOCUS="$SECOND_TWO_WSID/$SECOND_TWO_TAB"
SECOND_HOME_A="$TMP_ROOT/home-2ndmate-alpha"
SECOND_HOME_B="$TMP_ROOT/home-2ndmate-bravo"
mkdir -p "$SECOND_HOME_A/state" "$SECOND_HOME_A/config" "$SECOND_HOME_A/data" \
  "$SECOND_HOME_B/state" "$SECOND_HOME_B/config" "$SECOND_HOME_B/data"
# Seeded homes carry a parent binding and a primary registry route, which the
# presentation order reads to place every home's workers.
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$SECOND_HOME_A/.fm-secondmate-parent"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$SECOND_HOME_B/.fm-secondmate-parent"
printf 'alpha\n' > "$SECOND_HOME_A/.fm-secondmate-home"
printf 'bravo\n' > "$SECOND_HOME_B/.fm-secondmate-home"
{
  printf -- '- alpha - Alpha presentation fixture. (home: %s; scope: alpha fixture work; projects: alpha-only; added 2026-09-30)\n' "$SECOND_HOME_A"
  printf -- '- bravo - Bravo presentation fixture. (home: %s; scope: bravo fixture work; projects: bravo-only; added 2026-09-30)\n' "$SECOND_HOME_B"
} > "$HOME_DIR/data/secondmates.md"
touch "$SECOND_HOME_A/state/.last-watcher-beat" "$SECOND_HOME_B/state/.last-watcher-beat"
# Ensure the secondmate homes look like gitignored firstmate homes so inheritance
# may write config/herdr-presentation-spaces.
git -C "$SECOND_HOME_A" init -q
git -C "$SECOND_HOME_B" init -q
printf 'config/herdr-presentation-spaces\nconfig/crew-harness\nconfig/crew-dispatch.json\nconfig/backlog-backend\nconfig/backend\nconfig/startup-memory-budget\n' \
  > "$SECOND_HOME_A/.gitignore"
cp "$SECOND_HOME_A/.gitignore" "$SECOND_HOME_B/.gitignore"
git -C "$SECOND_HOME_A" add .gitignore
git -C "$SECOND_HOME_B" add .gitignore
git -C "$SECOND_HOME_A" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
git -C "$SECOND_HOME_B" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
mkdir -p "$SECOND_HOME_A/bin"
printf '# Firstmate secondmate fixture\n' > "$SECOND_HOME_A/AGENTS.md"
printf 'Secondmate alpha charter.\n' > "$SECOND_HOME_A/data/charter.md"

# Primary setting only; real inheritance must push it into both secondmate homes.
[ -f "$HOME_DIR/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting disappeared before multi-home inheritance"
[ ! -e "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate A unexpectedly had a local presentation setting before inheritance"
[ ! -e "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "secondmate B unexpectedly had a local presentation setting before inheritance"
SECOND_SPAWN_LOG_START=$(log_line_count)
spawn_secondmate_task alpha "$SECOND_HOME_A" > "$TMP_ROOT/alpha.out" 2> "$TMP_ROOT/alpha.err" \
  || fail "secondmate alpha spawn failed: $(cat "$TMP_ROOT/alpha.err")"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate spawn did not inherit the presentation setting"
[ ! -e "$HOME_DIR/state/alpha.herdr-presentation" ] \
  || fail "secondmate spawn published a presentation journal"
SECOND_META="$HOME_DIR/state/alpha.meta"
[ "$(grep '^kind=' "$SECOND_META" | cut -d= -f2-)" = secondmate ] \
  || fail "secondmate spawn did not record kind=secondmate"
SECOND_WSID=$(grep '^herdr_workspace_id=' "$SECOND_META" | cut -d= -f2-)
SECOND_LABEL=$(lab workspace get "$SECOND_WSID" | jq -r '.result.workspace.label')
[ "$SECOND_LABEL" = 2ndmate-alpha ] \
  || fail "secondmate spawn did not use its flat parent workspace: $SECOND_LABEL"
[ -z "$(projection_labels_from_log "$SECOND_SPAWN_LOG_START")" ] \
  || fail "secondmate spawn created a corner projection workspace"
# A second mate's own workspace takes part in the presentation order too.
[ "$(lab workspace list | jq -r '[.result.workspaces[].label | select(. == "firstmate" or startswith("2ndmate-"))] | join(" ")')" \
  = "firstmate 2ndmate-alpha 2ndmate-bravo" ] \
  || fail "secondmate spawn left the home workspaces out of the presentation order"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_A/config" \
  || fail "inheritance into secondmate A failed"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_B/config" \
  || fail "inheritance into secondmate B failed"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate A"
[ -f "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate B"
pass "real Herdr lab: the primary presentation setting inherits into real secondmate homes"
# Give one primary worker to alpha's covered project, then remove alpha.
python3 - "$HOME_DIR/data/secondmates.md" <<'REGISTRY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('projects: alpha-only;', 'projects: project;'))
REGISTRY
write_ship_brief "$HOME_DIR" covered
spawn_task covered "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/covered.out" 2> "$TMP_ROOT/covered.err" || fail "covered primary worker spawn failed"
BEFORE=$(lab workspace list | jq -r '[.result.workspaces[].label | if startswith("└ ") then (ltrimstr("└ ") | split(" · ")[0]) else . end] | join(" ")')
[ "$BEFORE" = "firstmate 2ndmate-alpha covered 2ndmate-bravo" ] || fail "covered worker was not under alpha before removal: $BEFORE"
assert_focus_is "$CAPTAIN_FOCUS" "before secondmate removal"
teardown_task alpha "$HOME_DIR" > "$TMP_ROOT/alpha-teardown.out" 2> "$TMP_ROOT/alpha-teardown.err" || fail "isolated secondmate removal failed: $(cat "$TMP_ROOT/alpha-teardown.err")"
AFTER=$(lab workspace list | jq -r '[.result.workspaces[].label | if startswith("└ ") then (ltrimstr("└ ") | split(" · ")[0]) else . end] | join(" ")')
[ "$AFTER" = "firstmate 2ndmate-alpha 2ndmate-bravo covered" ] || fail "covered worker did not return to primary group while preserving the pre-existing seeded home space: $AFTER"
assert_focus_is "$CAPTAIN_FOCUS" "secondmate removal"
[ ! -d "$SECOND_HOME_A" ] || fail "secondmate removal retained its disposable home"
! grep -F -- '- alpha -' "$HOME_DIR/data/secondmates.md" >/dev/null || fail "secondmate removal retained alpha's registry route"
pass "real Herdr lab: secondmate removal retires its home and registry route, reroutes its covered primary worker, and preserves exact focus"
teardown_task covered "$HOME_DIR" > "$TMP_ROOT/covered-teardown.out" 2> "$TMP_ROOT/covered-teardown.err" || fail "covered worker teardown failed"
teardown_task anchor "$HOME_DIR" > "$TMP_ROOT/anchor-teardown.out" 2> "$TMP_ROOT/anchor-teardown.err" || fail "anchor teardown failed"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || fail "secondmate-removal lab teardown failed"
LAB_READY=0
pass "real Herdr lab: secondmate-removal lab retired with default-session tripwire intact"
cleanup_all
trap - EXIT
