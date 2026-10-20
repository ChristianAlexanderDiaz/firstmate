#!/usr/bin/env bash
# Real Unix-socket/process tests; policy time is advanced in the fixture owner.
set -eu
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export PYTHONDONTWRITEBYTECODE=1
unset FM_RESOURCE_CONFIG FM_RESOURCE_LEASE FM_RESOURCE_STAGE_ENTRY FM_RESOURCE_PORTABLE
exec python3 "$ROOT/tests/fm-resource.test.py"
