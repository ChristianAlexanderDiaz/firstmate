#!/usr/bin/env bash
# Bounded machine-local GitHub observation cache; no daemon or merge authority.
# Usage: fm-github-read.sh core <canonical-pr-url> [state|head|json]
#        fm-github-read.sh batch <fm-merge-wait GraphQL query>
#        fm-github-read.sh fresh-head <canonical-pr-url>
#        fm-github-read.sh read|fresh <read-only gh arguments...>
# core and batch share PR observations for the configured interval. read caches
# exact requests for that interval; fresh bypasses success caching for coherence checks.
# fresh-head reads the head live and invalidates its shared PR observation.
# All modes share quota backoff. Exit 75 and "waiting:" mean no observation,
# never a failed check or readiness. Other read errors retain a nonzero status.
# The local root home's state/github-read directory is shared by local mates;
# remote parent routes stop at this machine, as fm_firstmate_root_home specifies.
# FM_GITHUB_CACHE_DIR selects a shared directory for independent local roots.
# FM_GITHUB_CACHE_TTL (default 300, 0 disables success reuse) bounds freshness.
# The Python helper owns storage, locking, credential partitioning and backoff.
# The existing gh transport is intentional: GH_DEBUG=api exposes response reset
# headers even for pr view; gh-axi api does not expose response headers.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in -h|--help) sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; exit 0 ;; esac
if [ -z "${FM_GITHUB_CACHE_DIR:-}" ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  root=$(fm_firstmate_root_home "$FM_HOME") || {
    echo 'waiting: cannot resolve GitHub cache home' >&2
    exit 75
  }
  # Explicit test/standalone state overrides stay isolated at the root.
  if [ "$root" = "$(cd "$FM_HOME" && pwd -P)" ]; then
    FM_GITHUB_CACHE_DIR="$STATE/github-read"
  else
    FM_GITHUB_CACHE_DIR="$root/state/github-read"
  fi
fi
exec python3 "$SCRIPT_DIR/fm-github-read.py" "$FM_GITHUB_CACHE_DIR" "$@"
