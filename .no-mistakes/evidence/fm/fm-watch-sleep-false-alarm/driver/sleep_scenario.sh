#!/usr/bin/env bash
# <LAB> <label> <resume_after_secs|never> [wake=yes|no]
. /tmp/fm-drv.tPrkva/common.sh "$1"
LABEL=$2 RESUME=$3 WAKE=${4:-yes}
echo "== $LABEL: lab=$LAB commit=$(git -C $LAB log --oneline -1)"
start_watcher
echo "[$(ts)] real watcher running: pid=$WPID (arm pgid=$WPGID), beacon age $(beat_age)s"
kill -STOP -- -"$WPGID"
touch -d "@$(( $(date +%s) - 486 ))" "$LAB/state/.last-watcher-beat"
echo "[$(ts)] SIMULATED HOST SLEEP: SIGSTOP watcher process group; beacon aged to $(beat_age)s (GRACE=300)"
ps -o pid,stat,args -g "$WPGID" | cut -c1-90 | sed 's/^/    /'
fire_hook "$DRV/$LABEL.hook.out"
T0=$(date +%s)
echo "[$(ts)] Stop hook fired (hook pid=$HOOKPID)"
if [ "$RESUME" != never ]; then
  sleep "$RESUME"
  kill -CONT -- -"$WPGID"
  echo "[$(ts)] HOST WAKE: SIGCONT watcher process group after ${RESUME}s; beacon age $(beat_age)s"
fi
for i in $(seq 1 70); do kill -0 $HOOKPID 2>/dev/null || break; sleep 1; [ "$(beat_age)" -lt 60 ] && [ -z "${REFRESHED:-}" ] && { REFRESHED=1; echo "[$(ts)] watcher refreshed its beacon (age $(beat_age)s)"; }; done
if kill -0 $HOOKPID 2>/dev/null; then
  echo "[$(ts)] after $(( $(date +%s) - T0 ))s the Stop hook is still running (parked on the watcher, no FAILED notice); hook output so far:"
  sed 's/^/    | /' "$DRV/$LABEL.hook.out"
  echo "    epoch ledger: $(head -1 $LAB/state/.claude-autoarm-epoch 2>/dev/null)"
  if [ "$WAKE" = yes ]; then
    echo "done: lab task finished after the sleep" > "$LAB/state/labtask.status"
    echo "[$(ts)] wrote state/labtask.status (done:) to make the recovered watcher wake"
    for i in $(seq 1 90); do kill -0 $HOOKPID 2>/dev/null || break; sleep 1; done
  fi
fi
wait $HOOKPID 2>/dev/null
echo "[$(ts)] Stop hook finished after $(( $(date +%s) - T0 ))s. Full hook stdout+stderr:"
sed 's/^/    | /' "$DRV/$LABEL.hook.out"
echo "    epoch ledger: $(head -1 $LAB/state/.claude-autoarm-epoch 2>/dev/null)"
echo "    failure-notice marker: $([ -e $LAB/state/.claude-autoarm-failure-notified ] && echo PRESENT || echo absent)"
echo "    watcher cycle log:"; cut -f1-12 "$LAB/state/.watch-cycle-exits.log" 2>/dev/null | sed 's/^/      /'
echo "    background arm output:"; sed 's/^/      /' "$LAB/../$(basename $LAB).bg-arm.out"
pkill -CONT -f "$LAB/bin/"; pkill -f "$LAB/bin/"; sleep 1; pkill -9 -f "$LAB/bin/"
echo "[$(ts)] cleaned up lab processes"
