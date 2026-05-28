#!/usr/bin/env bash
# Verify that the merged dist/ has at least one split context.json — a
# missing context.json means the build matrix produced no shards, which
# would silently downgrade the merge job to a no-op release.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

count=$(find dist -name context.json -type f 2>/dev/null | wc -l)
if [ "$count" -eq 0 ]; then
    echo "::error::No split context files found in dist/"
    anodizer::err "no split context files found in dist/"
    exit 1
fi
anodizer::ok "found $count split context(s)"
