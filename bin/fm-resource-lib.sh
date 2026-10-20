#!/usr/bin/env bash
# Optional host-budget integration for local stages, including gate agents that
# do not inherit the worker environment. fm-resource-run --help owns policy.
# fm_resource_stage <class> <executable> [argv...]
# Reexecutes once under a lease when configured; no-op without a policy.
# Explicit FM_RESOURCE_CONFIG wins, then FM_HOME/config/host-budget.json, then
# the per-user canonical ~/.config/firstmate/host-budget.json. Missing service
# under configured policy fails closed. Never starts/restarts a shared daemon.
# Call only for executing modes; help/list/dry inspection requires no compute.
fm_resource_stage() {
  local resource_class=$1 executable=$2 config=${FM_RESOURCE_CONFIG:-} root
  shift 2
  [ "${FM_RESOURCE_STAGE_ENTRY:-}" != "$executable" ] || return 0
  if [ -z "$config" ] && [ -n "${FM_HOME:-}" ] && [ -e "$FM_HOME/config/host-budget.json" ]; then
    config="$FM_HOME/config/host-budget.json"
  fi
  if [ -z "$config" ] && [ -e "$HOME/.config/firstmate/host-budget.json" ]; then
    config="$HOME/.config/firstmate/host-budget.json"
  fi
  [ -n "$config" ] || return 0
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
  exec env FM_RESOURCE_STAGE_ENTRY="$executable" "$root/fm-resource-run" --config "$config" \
    run --class "$resource_class" -- "$executable" "$@"
}
