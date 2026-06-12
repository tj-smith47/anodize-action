#!/usr/bin/env bash
# Verify that the merged dist tree has at least one split context manifest —
# a missing context means the build matrix produced no shards, which would
# silently downgrade the merge job to a no-op release.
#
# Accepts `context.json` (plain split builds) and `context-<shard>.json`
# (preserved-dist manifests suffixed per shard by rename-preserved-dist.sh),
# at the dist root and in first-level subdirs (the per-crate layout) — the
# same shapes has_preserved_context() in scripts/run/anodizer.sh protects.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/config.sh"

dist=$(resolve_dist_dir)

count=$(find "$dist" -maxdepth 2 -type f \
    \( -name 'context.json' -o -name 'context-*.json' \) 2>/dev/null | wc -l)
[ "$count" -gt 0 ] || gha_fail "No split context files found in ${dist}/ (looked for context.json / context-*.json at the root and one level deep)"
anodizer::ok "found $count split context(s)"
