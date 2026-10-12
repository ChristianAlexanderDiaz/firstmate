#!/usr/bin/env bash
# <LAB>: watcher holder is DEAD (crashed, not slept) with a stale beacon; the hook must not wait out the settle window.
. /tmp/fm-drv.tPrkva/common.sh "$1"
echo "== dead-holder: lab=$LAB commit=$(git -C $LAB log --oneline -1)"
start_watcher
echo "[$(ts)] real watcher running: pid=$WPID"
kill -9 -- -"$WPGID"; sleep 1
touch -d "@$(( $(date +%s) - 486 ))" "$LAB/state/.last-watcher-beat"
echo "[$(ts)] watcher process group SIGKILLed (lock still names dead pid $(cat $LAB/state/.watch.lock/pid)); beacon aged to $(beat_age)s"
fire_hook "$DRV/dead.hook.out"; T0=$(date +%s)
echo "[$(ts)] Stop hook fired (SLEEP_SETTLE default = 30s)"
for i in $(seq 1 40); do
  NP=$(cat $LAB/state/.watch.lock/pid 2>/dev/null)
  if [ -n "$NP" ] && [ "$NP" != "$WPID" ] && kill -0 "$NP" 2>/dev/null && [ "$(beat_age)" -lt 60 ]; then
    echo "[$(ts)] hook's arm replaced the dead holder with new watcher pid=$NP after $(( $(date +%s) - T0 ))s (no settle wait); hook still running=$(kill -0 $HOOKPID 2>/dev/null && echo yes || echo no)"; break
  fi
  sleep 0.5
done
echo "    cycle log:"; cut -f1-8 "$LAB/state/.watch-cycle-exits.log" 2>/dev/null | sed 's/^/      /'
echo "    epoch ledger: $(head -1 $LAB/state/.claude-autoarm-epoch 2>/dev/null)"
echo "    hook output so far:"; sed 's/^/    | /' "$DRV/dead.hook.out"
pkill -f "$LAB/bin/"; sleep 1; pkill -9 -f "$LAB/bin/"; wait 2>/dev/null
echo "[$(ts)] cleaned up"
