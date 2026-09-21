#!/bin/bash
# Runs every check against the tools first on PATH: the unit tests, the
# output of the tools the plugin parses, then the plugin inside Yazi. Cheap
# checks go first, so that a simple failure stops before Yazi starts.
#
#     bash ci/check.sh
set -euo pipefail
ci=$(cd "$(dirname "$0")" && pwd)
readonly ci
media=$(mktemp -d)
readonly media
trap 'rm -rf "$media"' EXIT

yazi --version
lua5.4 "$ci/../tests/metadata.lua"
bash "$ci/samples.sh" "$media"
bash "$ci/contract.sh" "$media"
bash "$ci/e2e.sh" "$media"
