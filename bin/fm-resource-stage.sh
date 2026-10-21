#!/usr/bin/env bash
# Local no-mistakes/test/build/hook adapter; no daemon lifecycle management.
# Usage: fm-resource-stage.sh [--class <class>] -- <executable> [argv...]
# Unconfigured hosts execute normally; configured hosts require the one owner.
# fm-resource-run --help owns configuration and leases.
set -eu
resource_class=exclusive
if [ "${1:-}" = --class ]; then
  resource_class=$2
  shift 2
fi
[ "${1:-}" != -- ] || shift
[ "$#" -gt 0 ] || { echo 'usage: fm-resource-stage.sh [--class class] -- command [args...]' >&2; exit 2; }
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-resource-lib.sh
. "$ROOT/fm-resource-lib.sh"
fm_resource_stage "$resource_class" "$0" "$@"
exec "$@"
