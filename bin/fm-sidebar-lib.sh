# shellcheck shell=bash
# Display vocabulary owner. Sources no state and performs no I/O.
# fm_sidebar_classify <crew-line> <agent-state> <kind> <captain-call>
#                     <landed> <machine-detail> <service-detail> <stall-detail>
#                     [checking-run]
# Sets FM_SIDEBAR_WORD and FM_SIDEBAR_DETAIL. Empty word means insufficient
# evidence, never a claim that an unreadable endpoint is dead.
# The watcher reporter and crew-state --sidebar use this same classifier.
# Captain ownership wins over recovery; landed is positive merge evidence,
# never the worker's done declaration. A parked ask-user is Needs me even when
# its worker exited; an unattended ordinary gate is Stuck until recovery.
fm_sidebar_classify() {
  local line=$1 agent=$2 kind=$3 captain=$4 landed=$5 machine=$6 service=$7 stall=$8
  local state source detail part human=0
  FM_SIDEBAR_WORD= FM_SIDEBAR_DETAIL=
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
  elif [ -n "$stall" ]; then
    FM_SIDEBAR_WORD=Stuck; FM_SIDEBAR_DETAIL=$stall
  elif [ "$state" = blocked ] || { [ "$state" = parked ] && { [ "$human" = 1 ] || [ "$source" = status-log ]; }; }; then
    FM_SIDEBAR_WORD='Needs me'; FM_SIDEBAR_DETAIL=$detail
  elif [ "$state" = parked ] && { [ "$agent" = dead ] || [ "$agent" = missing ]; }; then
    if [ "${9:-}" = yes ]; then FM_SIDEBAR_WORD='Needs me'; else FM_SIDEBAR_WORD=Stuck; fi
    FM_SIDEBAR_DETAIL="$detail - no agent"
  elif [ -n "$machine" ]; then
    FM_SIDEBAR_WORD='Waiting for machine'; FM_SIDEBAR_DETAIL=$machine
  elif [ -n "$service" ]; then
    FM_SIDEBAR_WORD=Serving; FM_SIDEBAR_DETAIL=$service
  elif [ "$state" = done ] && [ "$kind" != secondmate ]; then
    FM_SIDEBAR_WORD='Needs you'; FM_SIDEBAR_DETAIL=$detail
  elif [ "$state" = working ] && [ "$source" = run-step ] && { [ "$agent" = dead ] || [ "$agent" = missing ]; }; then
    FM_SIDEBAR_WORD=Checking; FM_SIDEBAR_DETAIL="$detail - no agent"
  elif [ "$agent" = dead ] || [ "$agent" = missing ]; then
    FM_SIDEBAR_WORD=Stuck; FM_SIDEBAR_DETAIL='agent exited with work pending'
  elif [ "$state" = working ] && [ "$agent" = alive ]; then
    FM_SIDEBAR_WORD=Working; FM_SIDEBAR_DETAIL=$detail
  elif [ "$kind" = secondmate ] && [ "$agent" = alive ]; then
    FM_SIDEBAR_WORD=Idle; FM_SIDEBAR_DETAIL='ready for work'
  elif [ "$state" = failed ] || [ "$state" = parked ]; then
    FM_SIDEBAR_WORD='Needs me'; FM_SIDEBAR_DETAIL=$detail
  fi
}
