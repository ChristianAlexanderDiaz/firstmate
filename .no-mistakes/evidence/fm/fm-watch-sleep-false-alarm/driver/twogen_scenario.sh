#!/usr/bin/env bash
# <LAB>: generation N parks on the healthy watcher; the whole host sleeps >GRACE (watcher AND gen-N hook frozen,
# ledger + beacon age); the next Stop (gen N+1) supersedes the stuck claim. The recovered watcher's later wake
# must be delivered by exactly one live generation, not dropped.
. /tmp/fm-drv.tPrkva/common.sh "$1"
echo "== two-generation: lab=$LAB commit=$(git -C $LAB log --oneline -1)"
start_watcher
echo "[$(ts)] real watcher running: pid=$WPID"
fire_hook "$DRV/$(basename $LAB).gen1.out"; H1=$HOOKPID
sleep 6
echo "[$(ts)] gen-N hook pid=$H1 parked: $(head -1 $LAB/state/.claude-autoarm-epoch)"
H1PIDS=$(pstree -p $H1 | grep -o '([0-9]*)' | tr -d '()' | tr '\n' ' ')
kill -STOP -- -"$WPGID"; kill -STOP $H1PIDS
touch -d "@$(( $(date +%s) - 486 ))" "$LAB/state/.last-watcher-beat" "$LAB/state/.claude-autoarm-epoch"
echo "[$(ts)] SIMULATED HOST SLEEP: froze watcher group + gen-N hook tree ($H1PIDS); beacon and epoch ledger aged to 486s"
fire_hook "$DRV/$(basename $LAB).gen2.out"; H2=$HOOKPID; T0=$(date +%s)
echo "[$(ts)] gen-N+1 Stop hook fired (pid=$H2)"
sleep 4; kill -CONT -- -"$WPGID"; kill -CONT $H1PIDS
echo "[$(ts)] HOST WAKE: resumed everything"
sleep 40
echo "[$(ts)] gen-N running=$(kill -0 $H1 2>/dev/null && echo yes || echo no), gen-N+1 running=$(kill -0 $H2 2>/dev/null && echo yes || echo no); ledger: $(head -1 $LAB/state/.claude-autoarm-epoch)"
echo "    gen-N+1 output so far:"; sed 's/^/    | /' "$DRV/$(basename $LAB).gen2.out"
echo "done: lab task finished after the sleep" > "$LAB/state/labtask.status"
echo "[$(ts)] wrote labtask.status (done:) to make the recovered watcher wake"
for i in $(seq 1 90); do { kill -0 $H1 2>/dev/null || kill -0 $H2 2>/dev/null; } || break; sleep 1; done
echo "[$(ts)] gen-N   (superseded) output:"; sed 's/^/    | /' "$DRV/$(basename $LAB).gen1.out"
echo "[$(ts)] gen-N+1 (owner)      output:"; sed 's/^/    | /' "$DRV/$(basename $LAB).gen2.out"
echo "    epoch ledger: $(head -1 $LAB/state/.claude-autoarm-epoch)"
echo "    failure-notice marker: $([ -e $LAB/state/.claude-autoarm-failure-notified ] && echo PRESENT || echo absent)"
echo "    wake queue: $(cat $LAB/state/.wake-queue 2>/dev/null | cut -c1-120)"
pkill -CONT -f "$LAB/bin/"; pkill -f "$LAB/bin/"; sleep 1; pkill -9 -f "$LAB/bin/"; wait 2>/dev/null
echo "[$(ts)] cleaned up"
