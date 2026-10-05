#!/usr/bin/env bash
# tests/fm-backend-herdr-presentation-order-e2e.test.sh - isolated real-Herdr
# end-to-end test for the presentation order across a primary home and two
# second mates (docs/herdr-backend.md "Ordering").
#
# The guarantee under test: after every spawn and teardown the sidebar reads,
# top to bottom, the firstmate home; each second mate followed by its own
# workers and by any primary worker whose project that second mate alone
# covers in data/secondmates.md; the primary's other workers; then every other
# space in its existing relative order. A worker also keeps its own workspace
# when the shared presentation lock is busy for longer than a moment.
#
# This drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh against a named
# lab session. Every lifecycle operation goes through bin/fm-herdr-lab.sh,
# which verifies the default fleet session is unchanged after teardown
# (tests/herdr-test-safety.sh).
set -u

ROOT="/Users/christianalexanderdiaz/.no-mistakes/worktrees/8ef411716190/01M46QDNV1250V3J2NJPF2GK3V"

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
HERDR_LAB_HELPER="/Users/christianalexanderdiaz/.no-mistakes/worktrees/8ef411716190/01M46QDNV1250V3J2NJPF2GK3V/.test-phase/lab-capture.sh"
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
  local home=$1 id=$2 project=$3 state data
  state=$(home_state "$home"); data=$(home_data "$home")
  mkdir -p "$data/$id"
  printf '# Task\n## Captain'"'"'s intent\nOrder fixture %s.\n\n## Firstmate spec\nVerify workspace order.\n' "$id" > "$data/$id/brief.md"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT/.test-phase/runtime" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" \
    --mode no-mistakes --yolo off --backend herdr > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" \
    || fail "spawn $id failed: $(cat "$TMP_ROOT/$id.err")"
  WORKTREES+=("$(grep '^worktree=' "$state/$id.meta" | cut -d= -f2-)")
  cat "$TMP_ROOT/$id.out"; cat "$TMP_ROOT/$id.err"; LAST_ERR="$TMP_ROOT/$id.err"
}

teardown_task() {  # <home> <id>
  local home=$1 id=$2 state data
  state=$(home_state "$home"); data=$(home_data "$home")
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT/.test-phase/runtime" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force > "$TMP_ROOT/$id-teardown.out" 2> "$TMP_ROOT/$id-teardown.err" \
    || fail "teardown $id failed: $(cat "$TMP_ROOT/$id-teardown.err")"
  cat "$TMP_ROOT/$id-teardown.out"; cat "$TMP_ROOT/$id-teardown.err"; LAST_ERR="$TMP_ROOT/$id-teardown.err"
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
  printf "scenario: %s\nsidebar: %s\nfocused: %s\n" "$2" "$actual" "$(focused_workspace)"
  lab workspace list > "$EVIDENCE/$SNAP-$2.json"
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
make_project "$TMP_ROOT/projects/shared-app"
make_project "$TMP_ROOT/projects/alpha-app"
make_project "$TMP_ROOT/projects/bravo-app"
make_project "$TMP_ROOT/projects/fleet-tools"


EVIDENCE=/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46QDNV1250V3J2NJPF2GK3V
SNAP=extended
home_state() { if [ "$1" = "$PRIMARY_HOME" ]; then printf '%s' "$PRIMARY_STATE"; elif [ "$1" = "$ALPHA_HOME" ]; then printf '%s' "$ALPHA_STATE"; else printf '%s/state' "$1"; fi; }
home_data() { if [ "$1" = "$PRIMARY_HOME" ]; then printf '%s' "$PRIMARY_DATA"; else printf '%s/data' "$1"; fi; }
PRIMARY_STATE="$TMP_ROOT/primary-state-override"
PRIMARY_DATA="$TMP_ROOT/primary-data-override"
ALPHA_STATE="$ALPHA_HOME/state"
mkdir -p "$PRIMARY_STATE" "$PRIMARY_DATA"
mv "$PRIMARY_HOME/data/secondmates.md" "$PRIMARY_DATA/secondmates.md"
# Deliberately misleading default records: only effective records may decide coverage.
printf -- '- bravo - Stale. (home: %s; scope: bravo; projects: alpha-app; added 2026-10-05)\n' "$BRAVO_HOME" > "$PRIMARY_HOME/data/secondmates.md"
# Both mates cover shared-app until alpha is retired.
sed 's/projects: alpha-app;/projects: alpha-app, shared-app;/; s/projects: bravo-app;/projects: bravo-app, shared-app;/' "$PRIMARY_DATA/secondmates.md" > "$PRIMARY_DATA/next"
mv "$PRIMARY_DATA/next" "$PRIMARY_DATA/secondmates.md"
TAG="lv$$"
PO="$TAG-po"; PA="$TAG-pa"; PB="$TAG-pb"; A1="$TAG-a1"; B1="$TAG-b1"; PX="$TAG-px"; SH="$TAG-sh"; A2="$TAG-a2"
read -r LIFE_WS LIFE_TAB <<EOF
$(make_workspace life)
EOF
for label in firstmate 2ndmate-alpha 2ndmate-bravo dotfiles; do make_workspace "$label" >/dev/null || fail "workspace $label"; done
lab tab focus "$LIFE_TAB" >/dev/null || fail 'focus personal space'
spawn_task "$PRIMARY_HOME" "$PO" "$TMP_ROOT/projects/fleet-tools"
spawn_task "$PRIMARY_HOME" "$PA" "$TMP_ROOT/projects/alpha-app"
spawn_task "$PRIMARY_HOME" "$PB" "$TMP_ROOT/projects/bravo-app"
assert_sidebar "firstmate 2ndmate-alpha $PA 2ndmate-bravo $PB $PO life dotfiles" primary-effective-record-directories
# A later primary pass must preserve a version-one worker without its spawn hint.
token=$(sed -n 's/^projection_id=//p' "$PRIMARY_STATE/$PA.herdr-presentation")
printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$PA" "$token" > "$PRIMARY_STATE/$PA.herdr-presentation"
spawn_task "$PRIMARY_HOME" "$PX" "$TMP_ROOT/projects/fleet-tools"
assert_sidebar "firstmate 2ndmate-alpha $PA 2ndmate-bravo $PB $PO $PX life dotfiles" primary-later-pass-with-overrides
# Other homes use the primary's default records, per the documented context boundary.
rm -rf "$PRIMARY_HOME/state" "$PRIMARY_HOME/data"
mv "$PRIMARY_STATE" "$PRIMARY_HOME/state"; PRIMARY_STATE="$PRIMARY_HOME/state"
mv "$PRIMARY_DATA" "$PRIMARY_HOME/data"; PRIMARY_DATA="$PRIMARY_HOME/data"
spawn_task "$ALPHA_HOME" "$A1" "$TMP_ROOT/projects/alpha-app"
spawn_task "$BRAVO_HOME" "$B1" "$TMP_ROOT/projects/bravo-app"
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 2ndmate-bravo $PB $B1 $PO $PX life dotfiles" every-home-metadata-ownership
# Save actual TUI bytes through the lab's 40x120 pty; no synthetic sidebar.
export LAB_ANSI_CAPTURE="$EVIDENCE/sidebar.ansi"
"$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" || fail 'viewer capture'
sleep 1
"$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" || fail 'viewer detach'
for pair in "$ALPHA_STATE/$A1" "$BRAVO_HOME/state/$B1"; do
  token=$(sed -n 's/^projection_id=//p' "$pair.herdr-presentation")
  printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "${pair##*/}" "$token" > "$pair.herdr-presentation"
done
arrange_later() { FM_HOME="$PRIMARY_HOME" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_presentation_arrange "$1"' "$ROOT" "$HERDR_LAB_SESSION"; }
arrange_later
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 2ndmate-bravo $PB $B1 $PO $PX life dotfiles" later-pass-with-version-one-journals
[ "$(focused_workspace)" = "$LIFE_WS" ] || fail 'focus moved'
pass 'valid task metadata preserves ownership on later passes without a spawn hint or restart binding'
# A running registered mate uses its effective state directory, while other homes retain theirs.
ALPHA_STATE="$TMP_ROOT/alpha-state-override"
mv "$ALPHA_HOME/state" "$ALPHA_STATE"
mkdir "$ALPHA_HOME/state"
spawn_task "$ALPHA_HOME" "$A2" "$TMP_ROOT/projects/alpha-app"
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 $A2 2ndmate-bravo $PB $B1 $PO $PX life dotfiles" registered-mate-state-override
teardown_task "$ALPHA_HOME" "$A2"
rmdir "$ALPHA_HOME/state"
mv "$ALPHA_STATE" "$ALPHA_HOME/state"
ALPHA_STATE="$ALPHA_HOME/state"
# Overlapping coverage stays with main-home work, per the accepted projects-list rule.
spawn_task "$PRIMARY_HOME" "$SH" "$TMP_ROOT/projects/shared-app"
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 2ndmate-bravo $PB $B1 $PO $PX $SH life dotfiles" overlapping-coverage
# Unowned spaces directly after a mate must remain personal, never inferred from adjacency.
make_workspace notes >/dev/null
ARRANGE=' . "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_presentation_arrange "$1" '
arrange() { FM_HOME="$PRIMARY_HOME" FM_STATE_OVERRIDE="$PRIMARY_STATE" FM_DATA_OVERRIDE="$PRIMARY_DATA" bash -c "$ARRANGE" "$ROOT" "$HERDR_LAB_SESSION"; }
move_ws() { session_socket=$(lab session list --json | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[] | select(.name==$s) | .socket_path'); "$ROOT/bin/backends/herdr-workspace-move.py" "$session_socket" "$1" "$2" >/dev/null; }
NOTES=$(lab workspace list | jq -r '.result.workspaces[]|select(.label=="notes")|.workspace_id')
move_ws "$NOTES" 2
arrange
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 2ndmate-bravo $PB $B1 $PO $PX $SH notes life dotfiles" no-adjacency-inference
# Repeat the real arranger and prove complete workspace inventory and focus unchanged.
lab workspace list > "$EVIDENCE/idempotent-before.json"
arrange
lab workspace list > "$EVIDENCE/idempotent-after.json"
cmp "$EVIDENCE/idempotent-before.json" "$EVIDENCE/idempotent-after.json" || fail 'non-idempotent order or focus'
# Adoption relaunch after stopping the disposable shell worker.
PANE=$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY_STATE/$PO.meta")
OLD_WS=$(sed -n 's/^herdr_workspace_id=//p' "$PRIMARY_STATE/$PO.meta")
lab pane send-keys "$PANE" ctrl+c >/dev/null || fail 'stop disposable worker'
sleep 1
move_ws "$LIFE_WS" 0
relaunch() {
 env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
 FM_HOME="$PRIMARY_HOME" FM_STATE_OVERRIDE="$PRIMARY_STATE" FM_DATA_OVERRIDE="$PRIMARY_DATA" FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
 "$ROOT/bin/fm-spawn.sh" "$PO" --relaunch --harness "sh -c 'while :; do sleep 60; done'" > "$TMP_ROOT/relaunch-$1.out" 2> "$TMP_ROOT/relaunch-$1.err" || fail "relaunch $1: $(cat "$TMP_ROOT/relaunch-$1.err")"
 cat "$TMP_ROOT/relaunch-$1.out"; cat "$TMP_ROOT/relaunch-$1.err"
}
relaunch adopt
[ "$(sed -n 's/^herdr_pane_id=//p' "$PRIMARY_STATE/$PO.meta")" = "$PANE" ] || fail 'adoption changed endpoint'
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 2ndmate-bravo $PB $B1 $PO $PX $SH life notes dotfiles" relaunch-adopts-and-sorts
# Missing-endpoint relaunch must also sort drift while recreating the endpoint.
lab pane close "$PANE" >/dev/null || fail 'remove disposable endpoint'
move_ws "$LIFE_WS" 0
relaunch recreate
NEW_WS=$(sed -n 's/^herdr_workspace_id=//p' "$PRIMARY_STATE/$PO.meta")
[ "$NEW_WS" != "$OLD_WS" ] || fail 'recreation kept gone workspace'
FIRSTMATE_WS=$(lab workspace list | jq -r '.result.workspaces[]|select(.label=="firstmate")|.workspace_id')
[ "$NEW_WS" = "$FIRSTMATE_WS" ] || fail 'recreation did not use documented flat recovery'
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 2ndmate-bravo $PB $B1 $PX $SH life notes dotfiles" relaunch-recreates-and-sorts
# Worker cleanup heals deliberate drift even with an unrelated ambient session.
move_ws "$LIFE_WS" 0
teardown_task "$PRIMARY_HOME" "$PX"
assert_sidebar "firstmate 2ndmate-alpha $PA $A1 2ndmate-bravo $PB $B1 $SH life notes dotfiles" cleanup-heals-drift
# Retire alpha's own worker, then its registered home through real teardown.
teardown_task "$ALPHA_HOME" "$A1"
ROW=$(lab workspace list | jq -r '.result.workspaces[]|select(.label=="2ndmate-alpha")|[.workspace_id,.active_tab_id]|@tsv')
AWS=${ROW%%$'\t'*}; ATAB=${ROW#*$'\t'}
APANE=$(lab pane list --tab "$ATAB" | jq -r '.result.panes[0].pane_id')
printf 'window=%s:%s\nendpoint_task_id=alpha\nworktree=%s\nproject=%s\nhome=%s\nharness=sh\nkind=secondmate\nmode=secondmate\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$HERDR_LAB_SESSION" "$APANE" "$ALPHA_HOME" "$ALPHA_HOME" "$ALPHA_HOME" "$HERDR_LAB_SESSION" "$AWS" "$ATAB" "$APANE" > "$PRIMARY_STATE/alpha.meta"
teardown_task "$PRIMARY_HOME" alpha
assert_sidebar "firstmate 2ndmate-bravo $PB $B1 $SH $PA life notes dotfiles" retirement-recomputes-final-coverage
[ ! -d "$ALPHA_HOME" ] || fail 'retired home remains'
[ "$(focused_workspace)" = "$LIFE_WS" ] || fail 'final focus moved'
pass 'registry removal moves the shared-project worker under the sole surviving covering mate'
for id in "$PA" "$PB" "$SH" "$PO"; do teardown_task "$PRIMARY_HOME" "$id"; done
teardown_task "$BRAVO_HOME" "$B1"
assert_sidebar 'firstmate 2ndmate-bravo life notes dotfiles' all-fixtures-cleaned
cleanup_all || exit 1
pass 'isolated lab teardown verified unchanged default-session tripwire'
