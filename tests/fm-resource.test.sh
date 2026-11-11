#!/usr/bin/env bash
# Real Unix-socket/process tests; policy time is advanced in the fixture owner.
set -eu
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export PYTHONDONTWRITEBYTECODE=1
unset FM_RESOURCE_CONFIG FM_RESOURCE_LEASE FM_RESOURCE_STAGE_ENTRY FM_RESOURCE_PORTABLE
# A leased worker session prepends `prepare` adapters (DIR/bin beside DIR/manifest.json)
# that route npm and node to the live host budget instead of this suite's fixture owner.
clean=
IFS=: read -r -a entries <<<"$PATH"
for dir in "${entries[@]}"; do
  if [ "${dir##*/}" = bin ] && [ -f "$dir/../manifest.json" ]; then
    continue
  fi
  clean=${clean:+$clean:}$dir
done
export PATH=$clean
exec python3 "$ROOT/tests/fm-resource.test.py"
