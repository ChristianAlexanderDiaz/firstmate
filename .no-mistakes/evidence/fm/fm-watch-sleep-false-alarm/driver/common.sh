# usage: . common.sh <LAB>
LAB=$1
DRV=/tmp/fm-drv.tPrkva
fmenv() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u TMUX -u CLAUDE_CODE_CHILD_SESSION FM_HOME="$LAB" "$@"; }
beat_age() { echo $(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat" 2>/dev/null || echo 0) )); }
ts() { date '+%H:%M:%S'; }
start_watcher() { # start a real arm (which forks the real watcher) in its own session
  fmenv setsid nohup "$LAB/bin/fm-watch-arm.sh" > "$LAB/../$(basename $LAB).bg-arm.out" 2>&1 < /dev/null &
  for i in $(seq 1 60); do
    [ -s "$LAB/state/.watch.lock/pid" ] && [ -e "$LAB/state/.last-watcher-beat" ] && [ "$(beat_age)" -lt 30 ] && break
    sleep 1
  done
  WPID=$(cat "$LAB/state/.watch.lock/pid"); WPGID=$(ps -o pgid= -p "$WPID" | tr -d ' ')
}
fire_hook() { # <outfile>  run the real Stop hook as a child of a process named "claude" that holds state/.lock
  printf '%s\n' '{"session_id":"sess-lab","stop_hook_active":false}' | fmenv "$DRV/fakebin/claude" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-claude-stop-autoarm.sh"; echo "HOOK_EXIT=$?" >&2' > "$1" 2>&1 &
  HOOKPID=$!
}
