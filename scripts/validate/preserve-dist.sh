#!/usr/bin/env bash
# Reject `preserve-dist: true` unless paired with `determinism: true` and
# a non-empty `shard-label`. The harness is the only producer of the
# preserved tree, and the shard label discriminates per-shard manifest
# files (context.json, artifacts.json, ...) when N matrix shards merge
# their artifacts via `download-artifact merge-multiple: true`.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

[ "$DETERMINISM" = "true" ] || gha_fail "preserve-dist: 'true' requires determinism: 'true'"
[ -n "$SHARD_LABEL" ]       || gha_fail "preserve-dist: 'true' requires shard-label to be set"
