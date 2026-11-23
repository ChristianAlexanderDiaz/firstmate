#!/usr/bin/env bash
# Launch a harness with the home's automatic compaction threshold.
# Usage: fm-context-launch.sh [--config-dir <dir>] [--print-command] <harness> [args...]
# Default: 200000 tokens; config/context-cap overrides it with one decimal
# integer from 100000 through 1000000 (the range Claude supports without
# clamping). FM_CONFIG_OVERRIDE, then FM_HOME/config, select the home config;
# without either, use this script's repository config/.
# --print-command emits the same executable prefix for fm-spawn's existing
# launch templates, resolving and validating configuration before dispatch.
# Claude receives CLAUDE_CODE_AUTO_COMPACT_WINDOW; Codex receives its
# model_auto_compact_token_limit CLI override, counting the total context.
# Other harnesses pass through
# without reading this setting. No user settings file is written, and native
# compaction, persistence instructions and session-start hooks remain in charge.
set -eu

config=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/config}
print_command=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --config-dir)
    [ "$#" -ge 2 ] || { echo 'error: --config-dir needs a directory' >&2; exit 1; }
    config=$2
    shift 2
    ;;
  --print-command) print_command=1; shift ;;
  -h | --help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --) shift; break ;;
  *) break ;;
  esac
done
[ "$#" -gt 0 ] || { echo 'error: a harness is required' >&2; exit 1; }
harness=$1
shift
command=("$harness")
case "$harness" in
claude | codex)
  tokens=200000
  if [ -e "$config/context-cap" ] || [ -L "$config/context-cap" ]; then
    if [ ! -f "$config/context-cap" ] || [ ! -r "$config/context-cap" ]; then
      echo 'error: config/context-cap must be a readable regular file' >&2
      exit 1
    fi
    tokens=$(cat "$config/context-cap")
  fi
  if ! [[ "$tokens" =~ ^[1-9][0-9]{5,6}$ ]] || [ "$tokens" -gt 1000000 ]; then
    echo 'error: config/context-cap must contain one integer from 100000 through 1000000' >&2
    exit 1
  fi
  case "$harness" in
  claude) command=(env "CLAUDE_CODE_AUTO_COMPACT_WINDOW=$tokens" claude) ;;
  codex) command=(codex -c "model_auto_compact_token_limit=$tokens" -c 'model_auto_compact_token_limit_scope="total"') ;;
  esac
  ;;
esac
if [ "$print_command" = 1 ]; then
  printf '%q ' "${command[@]}" "$@"
  printf '\n'
else
  exec "${command[@]}" "$@"
fi
