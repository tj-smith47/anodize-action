#!/usr/bin/env bash
# Verify that the merged dist/ has at least one split context.json — a
# missing context.json means the build matrix produced no shards, which
# would silently downgrade the merge job to a no-op release.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

count=$(find dist -name context.json -type f 2>/dev/null | wc -l)
[ "$count" -gt 0 ] || gha_fail "No split context files found in dist/"
anodizer::ok "found $count split context(s)"
