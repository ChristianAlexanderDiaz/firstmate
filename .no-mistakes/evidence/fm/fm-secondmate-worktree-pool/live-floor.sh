#!/usr/bin/env bash
set -eu
ROOT=$PWD
BASE="$ROOT/.nm-test/floor"
mkdir -p "$BASE"
trap 'rm -rf "$BASE"' EXIT
unset TMUX TMUX_PANE FM_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
"$ROOT/bin/fm-lab-home.sh" create "$BASE/home"
printf 'tmux\n' > "$BASE/home/config/backend"
printf 'manual\n' > "$BASE/home/config/backlog-backend"
export TREEHOUSE_ROOT="$BASE/pools" TREEHOUSE_NO_UPDATE_CHECK=1
for version in 2.3.0 3.0.0 3.0.1 3.1.0; do
  case "$version" in
    3.1.0) tools="$ROOT/.nm-test/install" ;;
    *) tools="$ROOT/.nm-test/releases/$version" ;;
  esac
  printf '\n=== Real Treehouse %s, tmux home bootstrap ===\n' "$version"
  PATH="$tools:$PATH" treehouse --version
  out=$(PATH="$tools:$PATH" FM_HOME="$BASE/home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out"
  if [ "$version" = 3.1.0 ]; then
    if printf '%s\n' "$out" | grep -q '^MISSING: treehouse '; then exit 1; fi
    printf 'Observed: installed version accepted; no Treehouse upgrade requested.\n'
  else
    printf '%s\n' "$out" | grep '^MISSING: treehouse '
    printf 'Observed: upgrade requested for incompatible version.\n'
  fi
done
printf '\n=== Orca home does not request Treehouse ===\n'
printf 'orca\n' > "$BASE/home/config/backend"
out=$(PATH="$ROOT/.nm-test/releases/2.3.0:$PATH" FM_HOME="$BASE/home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh")
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -q '^MISSING: treehouse '; then exit 1; fi
printf 'Observed: no Treehouse diagnostic for Orca.\nLIVE_FLOOR_SCENARIOS_COMPLETED\n'
