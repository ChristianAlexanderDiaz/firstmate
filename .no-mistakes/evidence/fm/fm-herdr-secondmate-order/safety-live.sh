#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46QDNV1250V3J2NJPF2GK3V
LAB=$(mktemp -d "$PWD/.test-phase/tmp/fm-lab-order-safety.XXXXXX")
bin/fm-lab-home.sh create "$LAB/home"
bin/fm-lab-home.sh create "$LAB/alpha"
SESSION=$(bin/fm-herdr-lab.sh name order-safety)
cleanup() { bin/fm-herdr-lab.sh teardown "$SESSION"; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$SESSION"
run() { bin/fm-herdr-lab.sh run "$SESSION" "$@"; }
run workspace create --cwd "$LAB" --label life --no-focus > "$LAB/life.json"
run workspace create --cwd "$LAB" --label firstmate --no-focus > "$LAB/main.json"
run workspace create --cwd "$LAB" --label '└ covered · p:AbCdEfGhIjKlMnOpQrStUv' --no-focus > "$LAB/worker.json"
run workspace create --cwd "$LAB" --label 2ndmate-bravo --no-focus >/dev/null
run workspace create --cwd "$LAB" --label dotfiles --no-focus >/dev/null
TAB=$(jq -r .result.tab.tab_id "$LAB/life.json"); run tab focus "$TAB" >/dev/null
WS=$(jq -r .result.workspace.workspace_id "$LAB/worker.json")
WTAB=$(jq -r .result.tab.tab_id "$LAB/worker.json")
PANE=$(run pane list --workspace "$WS"|jq -r .result.panes[0].pane_id)
printf 'window=%s:%s\nendpoint_task_id=covered\nworktree=/fixture/covered\nproject=/fixture/projects/alpha-app\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$PANE" "$SESSION" "$WS" "$WTAB" "$PANE" > "$LAB/home/state/covered.meta"
printf -- '- alpha - Coverage without workspace. (home: %s; scope: alpha; projects: alpha-app; added 2026-10-05)\n' "$LAB/alpha" > "$LAB/home/data/secondmates.md"
export FM_HOME="$LAB/home" HERDR_SESSION="$SESSION"
arrange() { bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_presentation_arrange "$1"' "$ROOT" "$SESSION"; }
arrange
run workspace list > "$EVIDENCE/missing-mate-workspace.json"
ORDER=$(run workspace list | jq -r '[.result.workspaces[].label|if startswith("└ ") then ltrimstr("└ ")|split(" · ")[0] else . end]|join(" ")')
printf 'covered worker with missing mate workspace: %s\n' "$ORDER"
[ "$ORDER" = 'firstmate 2ndmate-bravo covered life dotfiles' ]
run workspace create --cwd "$LAB" --label firstmate --no-focus > "$LAB/duplicate.json"
run workspace list > "$EVIDENCE/ambiguous-before.json"
arrange > "$EVIDENCE/ambiguous-warning.log" 2>&1
run workspace list > "$EVIDENCE/ambiguous-after.json"
cmp "$EVIDENCE/ambiguous-before.json" "$EVIDENCE/ambiguous-after.json"
rg 'ambiguous' "$EVIDENCE/ambiguous-warning.log"
printf 'duplicate home labels warn and preserve every workspace, label, and focus\n'
