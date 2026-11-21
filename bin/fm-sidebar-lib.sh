# shellcheck shell=bash
# Display vocabulary owner. Sources no state and performs no I/O.
# fm_sidebar_classify <crew-line> <agent-state> <kind> <captain-call>
#                     <landed> <machine-detail> <service-detail> <stall-detail>
#                     [unused] [backend-busy-state]
# Sets FM_SIDEBAR_WORD and FM_SIDEBAR_DETAIL. Empty word means insufficient
# evidence, never a claim that an unreadable endpoint is dead.
# The watcher reporter and crew-state --sidebar use this same classifier.
# Captain ownership wins over recovery; landed is positive merge evidence,
# never the worker's done declaration. A parked ask-user is Needs me even when
# its worker exited; current unattended gates are eligible for recovery.
# Shared workspace urgency is separate from evidence precedence within a task.
FM_SIDEBAR_PRIORITY='["Needs me","Stuck","Needs you","Waiting for machine","Checking","Working","Serving","Idle","Done"]'
fm_sidebar_classify() {
  local line=$1 agent=$2 kind=$3 captain=$4 landed=$5 machine=$6 service=$7 stall=$8
  local state source detail part human=0
  FM_SIDEBAR_WORD='' FM_SIDEBAR_DETAIL=''
  state=${line#state: }; state=${state%% *}
  source=${line#*source: }; source=${source%% *}
  detail=${line#* · source: }; detail=${detail#* · }
  local rest="$line · "
  while [ -n "$rest" ]; do
    part=${rest%% · *}; rest=${rest#* · }
    [ "$part" != 'ask-user: authority decision' ] || human=1
  done
  if [ "$captain" = yes ]; then
    FM_SIDEBAR_WORD='Needs you'; FM_SIDEBAR_DETAIL=$detail
  elif [ "$landed" = yes ]; then
    FM_SIDEBAR_WORD=Done; FM_SIDEBAR_DETAIL=landed
  elif [ "$state" = blocked ] || { [ "$state" = parked ] && { [ "$human" = 1 ] || [ "$source" = status-log ]; }; }; then
    FM_SIDEBAR_WORD='Needs me'; FM_SIDEBAR_DETAIL=$detail
  elif [ "$state" = parked ] && { [ "$agent" = dead ] || [ "$agent" = missing ]; }; then
    FM_SIDEBAR_WORD='Needs me'
    FM_SIDEBAR_DETAIL="$detail - no agent"
  elif [ -n "$stall" ]; then
    FM_SIDEBAR_WORD=Stuck; FM_SIDEBAR_DETAIL=$stall
  elif [ "$kind" = secondmate ] && [ "$agent" = alive ] && [ "$state" != failed ] && [ "$state" != parked ]; then
    case "${10:-unknown}" in
      busy) FM_SIDEBAR_WORD=Working; FM_SIDEBAR_DETAIL='agent busy' ;;
      idle) FM_SIDEBAR_WORD=Idle; FM_SIDEBAR_DETAIL='ready for work' ;;
    esac
  elif [ -n "$machine" ]; then
    FM_SIDEBAR_WORD='Waiting for machine'; FM_SIDEBAR_DETAIL=$machine
  elif [ -n "$service" ] && { [ "$state" != working ] || [ "$agent" != alive ]; }; then
    FM_SIDEBAR_WORD=Serving; FM_SIDEBAR_DETAIL=$service
  elif [ "$state" = 'done' ] && [ "$kind" != secondmate ]; then
    case "$line" in
      'state: done · source: run-step · run passed: PR open'*|\
      'state: done · source: run-step · checks green: PR held for merge (ci monitor ended)'*|\
      'state: done · source: run-step · checks green: PR ready for review'|\
      'state: done · source: run-step · checks green: PR ready for review · '*|\
      'state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'*) FM_SIDEBAR_WORD='Needs you'; FM_SIDEBAR_DETAIL=$detail ;;
    esac
  elif [ "$state" = working ] && [ "$source" = run-step ] && { [ "$agent" = dead ] || [ "$agent" = missing ]; }; then
    FM_SIDEBAR_WORD=Checking; FM_SIDEBAR_DETAIL="$detail - no agent"
  elif [ "$agent" = dead ] || [ "$agent" = missing ]; then
    FM_SIDEBAR_WORD=Stuck; FM_SIDEBAR_DETAIL='agent exited with work pending'
  elif [ "$state" = working ] && [ "$agent" = alive ]; then
    case "${10:-unknown}" in
      busy) FM_SIDEBAR_WORD=Working; FM_SIDEBAR_DETAIL=$detail ;;
      idle)
        if [ "$source" = run-step ]; then
          FM_SIDEBAR_WORD=Checking; FM_SIDEBAR_DETAIL="$detail - agent idle"
        else
          FM_SIDEBAR_WORD='Needs me'; FM_SIDEBAR_DETAIL='agent idle with work pending'
        fi
        ;;
    esac
  elif [ "$state" = failed ] || [ "$state" = parked ]; then
    FM_SIDEBAR_WORD='Needs me'; FM_SIDEBAR_DETAIL=$detail
  elif [ "$agent" = alive ]; then
    FM_SIDEBAR_WORD='Needs me'; FM_SIDEBAR_DETAIL='agent idle with work pending'
  fi
}

# Notification ownership. The watcher's status-span scan, exited-agent paths,
# unavailable inbox delivery, and no-progress escalation own alerts each sweep.
# Display never creates a competing detector or alarm.
fm_sidebar_wake_owner() {  # <agent-state> <stall-detail>
  printf 'watcher'
}
