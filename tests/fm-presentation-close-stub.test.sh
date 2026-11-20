#!/usr/bin/env bash
# Portable end-to-end proof: no real Herdr server is contacted.
set -eu
export FM_PRESENTATION_STUB=1
exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-presentation-close-e2e.test.sh"
