#!/usr/bin/env bash
# tests/fm-backend-herdr-presentation-order-e2e.test.sh - isolated real-Herdr
# end-to-end test for the presentation order across a primary home and two
# second mates (docs/herdr-backend.md "Ordering").
#
# The guarantee under test: after every spawn and teardown the sidebar reads,
# top to bottom, the firstmate home; each second mate followed by its own
# workers and by any primary worker whose project that second mate alone
# covers in data/secondmates.md; the primary's other workers; then every other
# space in its existing relative order. The firstmate home is the pane the
# primary runs in, so it keeps the top after the captain renames it. A worker
# also keeps its own workspace when the shared presentation lock is busy for
# longer than a moment.
#
# This drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh against a named
# lab session. Lab provisioning, inspection, and retirement use bin/fm-herdr-lab.sh,
# which verifies the default fleet session is unchanged after teardown
# (tests/herdr-test-safety.sh).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required for workspace ordering)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-order-e2e.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-order) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"

WORKTREES=()
LAST_ERR=/dev/null
LOCK_HOLDER_PID=
CLEANED=0
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  if [ -n "$LOCK_HOLDER_PID" ]; then
    kill "$LOCK_HOLDER_PID" 2>/dev/null || true
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
  fi
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  WORKTREES=()
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# order fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

make_workspace() {  # <label> -> "<workspace_id> <tab_id>"
  lab workspace create --cwd "$TMP_ROOT" --label "$1" --no-focus 2>/dev/null \
    | jq -r '[.result.workspace.workspace_id, .result.tab.tab_id] | @tsv' 2>/dev/null | tr '\t' ' '
}

make_home() {  # <dir> [<secondmate-id>]
  local home=$1 id=${2:-}
  mkdir -p "$home/state" "$home/config" "$home/data"
  touch "$home/state/.last-watcher-beat"
  # An explicit opt-in keeps projection on whatever the lab's release.
  printf 'on\n' > "$home/config/herdr-presentation-spaces"
  if [ -n "$id" ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PRIMARY_HOME" > "$home/.fm-secondmate-parent"
    printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  fi
}

spawn_task() {  # <home> <id> <project>
  local home=$1 id=$2 project=$3
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nOrder fixture %s.\n\n## Firstmate spec\nVerify workspace order.\n' "$id" > "$home/data/$id/brief.md"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" \
    --mode no-mistakes --yolo off --backend herdr > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" \
    || fail "spawn $id failed: $(cat "$TMP_ROOT/$id.err")"
  WORKTREES+=("$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)")
  LAST_ERR="$TMP_ROOT/$id.err"
}

# spawn_task_from_pane <pane> <home> <id> <project>: the same spawn, run the way
# Herdr runs a firstmate agent, with the injected identity of the pane it is in.
spawn_task_from_pane() {
  local pane=$1 home=$2 id=$3 project=$4
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nOrder fixture %s.\n\n## Firstmate spec\nVerify workspace order.\n' "$id" > "$home/data/$id/brief.md"
  env HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_SOCKET_PATH="$LAB_SOCKET" \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" \
    --mode no-mistakes --yolo off --backend herdr > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" \
    || fail "spawn $id from pane $pane failed: $(cat "$TMP_ROOT/$id.err")"
  WORKTREES+=("$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)")
  LAST_ERR="$TMP_ROOT/$id.err"
}

teardown_task() {  # <home> <id>
  local home=$1 id=$2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force > "$TMP_ROOT/$id-teardown.out" 2> "$TMP_ROOT/$id-teardown.err" \
    || fail "teardown $id failed: $(cat "$TMP_ROOT/$id-teardown.err")"
  LAST_ERR="$TMP_ROOT/$id-teardown.err"
}

# The sidebar as one line: home labels verbatim, each projected worker by its
# task id, and every other space by its label.
sidebar() {
  lab workspace list | jq -r '
    [.result.workspaces[].label
      | if startswith("└ ") then (ltrimstr("└ ") | split(" · ")[0]) else . end]
    | join(" ")'
}

focused_workspace() {
  lab workspace list | jq -r '[.result.workspaces[] | select(.focused == true) | .workspace_id][0] // empty'
}

assert_sidebar() {  # <expected> <case>
  local actual
  actual=$(sidebar)
  [ "$actual" = "$1" ] \
    || fail "$2: sidebar was '$actual', expected '$1'; last warnings: $(grep -i 'herdr presentation' "$LAST_ERR")"
}

PRIMARY_HOME="$TMP_ROOT/primary"
ALPHA_HOME="$TMP_ROOT/alpha-home"
BRAVO_HOME="$TMP_ROOT/bravo-home"
make_home "$PRIMARY_HOME"
make_home "$ALPHA_HOME" alpha
make_home "$BRAVO_HOME" bravo
{
  printf -- '- alpha - Alpha fixture second mate. (home: %s; scope: alpha app work; projects: alpha-app; added 2026-09-30)\n' "$ALPHA_HOME"
  printf -- '- bravo - Bravo fixture second mate. (home: %s; scope: bravo app work; projects: bravo-app; added 2026-09-30)\n' "$BRAVO_HOME"
} > "$PRIMARY_HOME/data/secondmates.md"
make_project "$TMP_ROOT/projects/alpha-app"
make_project "$TMP_ROOT/projects/bravo-app"
make_project "$TMP_ROOT/projects/fleet-tools"

# The captain's own personal space starts on top and keeps focus throughout;
# another personal space sits below the fleet.
read -r LIFE_WS LIFE_TAB <<EOF
$(make_workspace life)
EOF
[ -n "$LIFE_WS" ] || fail "could not create the captain's personal space"
for label in firstmate 2ndmate-alpha 2ndmate-bravo dotfiles; do
  made=$(make_workspace "$label")
  [ -n "$made" ] || fail "could not create the $label space"
  [ "$label" != firstmate ] || MAIN_WS=${made%% *}
done
MAIN_PANE=$(lab pane list --workspace "$MAIN_WS" | jq -r '.result.panes[0].pane_id // empty')
[ -n "$MAIN_PANE" ] || fail "could not read the pane in the firstmate space"
LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"
lab tab focus "$LIFE_TAB" >/dev/null 2>&1 || fail "could not focus the captain's personal space"

# 1. The reported drift: a primary worker for a project a second mate covers
#    must sit under that second mate, not above the second mates.
spawn_task "$PRIMARY_HOME" pa "$TMP_ROOT/projects/alpha-app"
assert_sidebar "firstmate 2ndmate-alpha pa 2ndmate-bravo life dotfiles" \
  "a primary worker for a second mate's project"
spawn_task "$PRIMARY_HOME" po "$TMP_ROOT/projects/fleet-tools"
spawn_task "$PRIMARY_HOME" pb "$TMP_ROOT/projects/bravo-app"
spawn_task "$ALPHA_HOME" a1 "$TMP_ROOT/projects/alpha-app"
spawn_task "$BRAVO_HOME" b1 "$TMP_ROOT/projects/bravo-app"
assert_sidebar "firstmate 2ndmate-alpha pa a1 2ndmate-bravo pb b1 po life dotfiles" \
  "primary and second mate spawns"
[ "$(focused_workspace)" = "$LIFE_WS" ] || fail "ordering moved focus off the captain's personal space"
pass "real Herdr lab: firstmate, each second mate with its own and its covered primary workers, primary work, then personal spaces"

# 2. A teardown leaves the rest of the order intact.
teardown_task "$PRIMARY_HOME" pa
teardown_task "$BRAVO_HOME" b1
assert_sidebar "firstmate 2ndmate-alpha a1 2ndmate-bravo pb po life dotfiles" "after teardowns"
[ "$(focused_workspace)" = "$LIFE_WS" ] || fail "teardown ordering moved focus off the captain's personal space"
pass "real Herdr lab: teardowns keep the sorted order"

# 3. A busy presentation lock is waited out: the worker still gets its own
#    workspace in its place instead of a tab in its secondmate home.
# shellcheck disable=SC2016 # the inner script expands its own positional arguments.
LOCK_PATH=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path "$1"' \
  "$ROOT" "$HERDR_LAB_SESSION") || fail "could not resolve the lab session's presentation lock"
ROOT="$ROOT" LOCK="$LOCK_PATH" READY="$TMP_ROOT/lock-ready" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  sleep 8
  fm_lock_release "$LOCK"
' &
LOCK_HOLDER_PID=$!
while [ ! -e "$TMP_ROOT/lock-ready" ] && kill -0 "$LOCK_HOLDER_PID" 2>/dev/null; do sleep 0.05; done
[ -e "$TMP_ROOT/lock-ready" ] || fail "could not hold the lab session's presentation lock"
spawn_task "$BRAVO_HOME" b2 "$TMP_ROOT/projects/bravo-app"
wait "$LOCK_HOLDER_PID" || fail "the presentation lock holder failed"
LOCK_HOLDER_PID=
if grep -F "flat layout" "$TMP_ROOT/b2.err" >/dev/null 2>&1; then
  fail "a busy presentation lock put the worker in its home's shared workspace: $(cat "$TMP_ROOT/b2.err")"
fi
[ -f "$BRAVO_HOME/state/b2.herdr-presentation" ] || fail "a busy presentation lock skipped the worker's own workspace"
assert_sidebar "firstmate 2ndmate-alpha a1 2ndmate-bravo pb b2 po life dotfiles" "after a busy lock"
pass "real Herdr lab: a busy presentation lock is waited out and the worker still gets its own sorted workspace"

teardown_task "$PRIMARY_HOME" po
teardown_task "$PRIMARY_HOME" pb
teardown_task "$ALPHA_HOME" a1
teardown_task "$BRAVO_HOME" b2
assert_sidebar "firstmate 2ndmate-alpha 2ndmate-bravo life dotfiles" "after all teardowns"
[ "$(focused_workspace)" = "$LIFE_WS" ] || fail "cleanup moved focus off the captain's personal space"

# 4. The captain renames the firstmate space and it drifts to the bottom. The
#    primary's own pane, not its label, still puts it back on top, and a second
#    mate's pass or a pass outside any pane finds it from the primary's record.
lab workspace rename "$MAIN_WS" captain >/dev/null 2>&1 || fail "could not rename the firstmate space"
sink_main() {
  python3 "$ROOT/bin/backends/herdr-workspace-move.py" "$LAB_SOCKET" "$MAIN_WS" 5 >/dev/null 2>&1 \
    || fail "could not move the renamed firstmate space to the bottom"
}
sink_main
assert_sidebar "2ndmate-alpha 2ndmate-bravo life dotfiles captain" "the renamed space at the bottom"
spawn_task_from_pane "$MAIN_PANE" "$PRIMARY_HOME" pm "$TMP_ROOT/projects/fleet-tools"
assert_sidebar "captain 2ndmate-alpha 2ndmate-bravo pm life dotfiles" "a primary spawn from the renamed space"
sink_main
spawn_task "$BRAVO_HOME" b3 "$TMP_ROOT/projects/bravo-app"
assert_sidebar "captain 2ndmate-alpha 2ndmate-bravo b3 pm life dotfiles" "a second mate spawn after the rename"
sink_main
teardown_task "$PRIMARY_HOME" pm
assert_sidebar "captain 2ndmate-alpha 2ndmate-bravo b3 life dotfiles" "a primary teardown outside any pane after the rename"
teardown_task "$BRAVO_HOME" b3
assert_sidebar "captain 2ndmate-alpha 2ndmate-bravo life dotfiles" "after the rename teardowns"
[ "$(focused_workspace)" = "$LIFE_WS" ] || fail "renamed-space ordering moved focus off the captain's personal space"
pass "real Herdr lab: a renamed firstmate space keeps the top, primary workers stay below the second mates"
pass "real Herdr lab: presentation order validation completed on $(herdr --version 2>/dev/null) with the default-session tripwire intact"
