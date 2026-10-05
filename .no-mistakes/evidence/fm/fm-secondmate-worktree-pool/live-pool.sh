#!/usr/bin/env bash
set -eu
ROOT=$PWD
BASE="$ROOT/.nm-test/live"
EVIDENCE=/Users/christianalexanderdiaz/.no-mistakes/evidence/01M46QZ8CAQCM8ERNVV3R2SQBM
REAL_TMUX=$(command -v tmux)
mkdir -p "$BASE/shim"
cat > "$BASE/shim/tmux" <<EOF
#!/usr/bin/env bash
cd '$ROOT'
exec '$REAL_TMUX' -f /dev/null -S .nm-test/live.sock "\$@"
EOF
chmod +x "$BASE/shim/tmux"
export PATH="$BASE/shim:$ROOT/.nm-test/install:$PATH"
export TREEHOUSE_ROOT="$BASE/pools" TREEHOUSE_NO_UPDATE_CHECK=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH FM_BACKEND CLAUDE_CONFIG_DIR
cleanup() {
  for file in "$BASE"/*/state/*.worker.log; do
    [ -f "$file" ] || continue
    touch "${file%.worker.log}.stop"
  done
  sleep 1
  tmux kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$BASE" 2>/dev/null || true
  rm -rf "$BASE" "$ROOT/.nm-test/live.sock"
}
trap cleanup EXIT
for name in main secondmate; do
  "$ROOT/bin/fm-lab-home.sh" create "$BASE/$name"
  mkdir -p "$BASE/$name/claude-config"
  printf 'tmux\n' > "$BASE/$name/config/backend"
  printf 'manual\n' > "$BASE/$name/config/backlog-backend"
done
mkdir -p "$BASE/seed/demo"
git -C "$BASE/seed/demo" init -q
git -C "$BASE/seed/demo" config user.name 'Live Test'
git -C "$BASE/seed/demo" config user.email live-test@example.invalid
printf 'isolated live spawn fixture\n' > "$BASE/seed/demo/README.md"
git -C "$BASE/seed/demo" add README.md
git -C "$BASE/seed/demo" -c commit.gpgsign=false commit -qm init
git clone -q --bare "$BASE/seed/demo" "$BASE/origin/demo.git"
for name in main secondmate; do
  git clone -q "file://$BASE/origin/demo.git" "$BASE/$name/projects/demo"
done
cat > "$BASE/secondmate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$BASE/main
EOF
tmux new-session -d -s firstmate -x 120 -y 40 -c "$ROOT" /bin/bash
tmux set-option -g default-shell /bin/bash
tmux set-option -g default-command '/bin/bash --noprofile --norc -i'
copy_of() { sed -n 's/^worktree=//p' "$1/state/$2.meta"; }
clone_of() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }
spawn() {
  local home="$BASE/$1" id=$2
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Prove the worker launches from its own project's clone.

## Firstmate spec
Run the read-only Claude launch probe. Change no project files.
EOF
  FM_HOME="$home" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$home/projects/demo" "bash $ROOT/.nm-test/live-worker.sh $ROOT $home $home/projects/demo $id" --scout
  for attempt in $(seq 1 90); do
    if [ -f "$home/state/$id.worker.log" ] && grep -q WORKER_COMPLETED "$home/state/$id.worker.log"; then
      cat "$home/state/$id.worker.log"
      grep -q LIVE_WORKER_OK "$home/state/$id.worker.log"
      return 0
    fi
    sleep 1
  done
  cat "$home/state/$id.worker.log" || true
  tmux capture-pane -p -t "firstmate:fm-$id" -S -100
  return 1
}
status() { (cd "$BASE/main/projects/demo" && treehouse status --json); }
wait_idle() {
  for attempt in $(seq 1 60); do
    if status | jq -e --arg p "$1" '.[] | select(.path == $p and .status == "available")' >/dev/null; then return 0; fi
    sleep .5
  done
  status
  return 1
}
assert_clone() {
  local want="$BASE/$1/projects/demo/.git" copy=$2
  actual=$(clone_of "$copy")
  printf 'ASSERT clone ownership: expected=%s actual=%s\n' "$want" "$actual"
  [ "$actual" = "$want" ]
}
printf '\n=== Parent creates the shared pool first ===\n'
spawn main main-a
MAIN_COPY=$(copy_of "$BASE/main" main-a)
assert_clone main "$MAIN_COPY"
touch "$BASE/main/state/main-a.stop"
sleep 1
tmux kill-window -t firstmate:fm-main-a
wait_idle "$MAIN_COPY"
printf '\n=== Parent copy is idle before secondmate launch ===\n'
status
spawn secondmate sm-a
SM_COPY=$(copy_of "$BASE/secondmate" sm-a)
assert_clone secondmate "$SM_COPY"
[ "$MAIN_COPY" != "$SM_COPY" ]
printf '\n=== Secondmate copy returns; parent reuses its own copy ===\n'
touch "$BASE/secondmate/state/sm-a.stop"
sleep 1
tmux kill-window -t firstmate:fm-sm-a
wait_idle "$SM_COPY"
spawn main main-b
[ "$(copy_of "$BASE/main" main-b)" = "$MAIN_COPY" ]
printf '\n=== Only secondmate copy is idle before parent launch ===\n'
wait_idle "$SM_COPY"
status
spawn main main-c
MAIN_C=$(copy_of "$BASE/main" main-c)
assert_clone main "$MAIN_C"
[ "$MAIN_C" != "$SM_COPY" ]
printf '\n=== Cross-clone trust registration actively refused ===\n'
set +e
CLAUDE_CONFIG_DIR="$BASE/secondmate/claude-config" "$ROOT/bin/fm-claude-trust.sh" "$MAIN_COPY" "$BASE/secondmate/projects/demo"
rc=$?
set -e
printf 'Cross-clone registration exit: %s\n' "$rc"
[ "$rc" -ne 0 ]
printf '\n=== Final shared pool state ===\n'
status
printf '\nLIVE_POOL_SCENARIOS_COMPLETED\n'
