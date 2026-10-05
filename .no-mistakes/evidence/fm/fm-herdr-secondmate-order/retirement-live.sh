#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46QDNV1250V3J2NJPF2GK3V
LAB=$(mktemp -d "$PWD/.test-phase/tmp/fm-lab-retire.XXXXXX")
bin/fm-lab-home.sh create "$LAB/primary"
bin/fm-lab-home.sh create "$LAB/alpha"
bin/fm-lab-home.sh create "$LAB/bravo"
SESSION=$(bin/fm-herdr-lab.sh name retire-order)
cleanup() { bin/fm-herdr-lab.sh teardown "$SESSION"; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$SESSION"
run() { bin/fm-herdr-lab.sh run "$SESSION" "$@"; }
make_ws() { run workspace create --cwd "$LAB" --label "$1" --no-focus; }
make_ws life > "$LAB/life.json"
make_ws firstmate > "$LAB/main.json"
make_ws 2ndmate-alpha > "$LAB/alpha.json"
make_ws 2ndmate-bravo > "$LAB/bravo.json"
make_ws '└ other · p:AbCdEfGhIjKlMnOpQrStUv' > "$LAB/other.json"
make_ws '└ shared · p:BbCdEfGhIjKlMnOpQrStUv' > "$LAB/shared.json"
make_ws dotfiles > "$LAB/dotfiles.json"
LIFE=$(jq -r .result.workspace.workspace_id "$LAB/life.json")
LTAB=$(jq -r .result.tab.tab_id "$LAB/life.json")
run tab focus "$LTAB" >/dev/null
STATE="$LAB/effective-state"; DATA="$LAB/effective-data"; mkdir -p "$STATE" "$DATA"
printf alpha > "$LAB/alpha/.fm-secondmate-home"
printf bravo > "$LAB/bravo/.fm-secondmate-home"
for mate in alpha bravo; do
 printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/primary" > "$LAB/$mate/.fm-secondmate-parent"
 printf -- '- %s - Retirement fixture. (home: %s; scope: shared; projects: shared-app; added 2026-10-05)\n' "$mate" "$LAB/$mate" >> "$DATA/secondmates.md"
done
write_task() {
 local id=$1 json=$2 project=$3 kind=$4 wt=$5 ws tab pane
 ws=$(jq -r .result.workspace.workspace_id "$json")
 tab=$(jq -r .result.tab.tab_id "$json")
 pane=$(run pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id')
 [ -n "$pane" ] && [ "$pane" != null ]
 printf 'window=%s:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=sh\nkind=%s\nmode=secondmate\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$pane" "$id" "$wt" "$project" "$kind" "$SESSION" "$ws" "$tab" "$pane" > "$STATE/$id.meta"
}
write_task shared "$LAB/shared.json" /fixture/projects/shared-app ship /fixture/shared-worker
write_task other "$LAB/other.json" /fixture/projects/uncovered ship /fixture/other-worker
write_task alpha "$LAB/alpha.json" "$LAB/alpha" secondmate "$LAB/alpha"
export FM_HOME="$LAB/primary" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$LAB/primary/config" FM_ROOT_OVERRIDE="$ROOT/.test-phase/runtime"
# No explicit presentation opt-in: eligibility must use the recorded named session.
export HERDR_SESSION=default
FM_GATE_REFUSE_BYPASS=1 bin/fm-teardown.sh alpha --force > "$EVIDENCE/retirement-command.log" 2>&1 || { cat "$EVIDENCE/retirement-command.log"; exit 1; }
run workspace list > "$EVIDENCE/retirement-final-sidebar.json"
SIDEBAR=$(run workspace list | jq -r '[.result.workspaces[].label | if startswith("└ ") then (ltrimstr("└ ")|split(" · ")[0]) else . end]|join(" ")')
printf 'sidebar after registry removal: %s\n' "$SIDEBAR"
[ "$SIDEBAR" = 'firstmate 2ndmate-bravo shared other life dotfiles' ]
[ ! -d "$LAB/alpha" ]
! rg '^\- alpha ' "$DATA/secondmates.md"
rg '^\- bravo ' "$DATA/secondmates.md"
cp "$DATA/secondmates.md" "$EVIDENCE/retirement-final-registry.md"
FOCUS=$(run workspace list | jq -r '.result.workspaces[]|select(.focused==true)|.workspace_id')
[ "$FOCUS" = "$LIFE" ]
printf 'recorded-session eligibility, alternate record directories, sole-survivor coverage, and focus preservation passed\n'
