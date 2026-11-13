#!/usr/bin/env bash
# Registered Docker checks use only fake endpoints and a fake Docker executable.
set -eu
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$ROOT/tests/fm-docker-check.test.py"
