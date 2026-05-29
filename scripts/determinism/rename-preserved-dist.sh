#!/usr/bin/env bash
# Suffix each preserved-dist manifest (context.json, artifacts.json,
# metadata.json) with the per-shard label.
#
# Without this, `actions/upload-artifact@v4` followed by
# `download-artifact@v4 merge-multiple: true` collides on identically
# named files across shards.
#
# Handles both the flat layout (preserved-dist/<f>.json) and the
# per-crate layout written by `anodizer check determinism --crate <name>`
# (preserved-dist/<crate>/<f>.json).
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

[ -n "$SHARD_LABEL" ] || gha_fail "preserve-dist requires shard-label input"

if [ ! -d preserved-dist ]; then
    anodizer::warn "preserved-dist/ missing — nothing to rename"
    exit 0
fi

renamed=0

# Rename `{context,artifacts,metadata}.json` inside `dir` (trailing-slash
# included). Each successful rename bumps the shared `renamed` counter.
rename_manifests_in() {
    local dir="$1" f src dst
    for f in context artifacts metadata; do
        src="${dir}${f}.json"
        dst="${dir}${f}-${SHARD_LABEL}.json"
        if [ -f "$src" ]; then
            mv "$src" "$dst"
            anodizer::verb renamed "$src -> $dst"
            renamed=$((renamed + 1))
        fi
    done
}

rename_manifests_in "preserved-dist/"
for subdir in preserved-dist/*/; do
    [ -d "$subdir" ] || continue
    rename_manifests_in "$subdir"
done

if [ "$renamed" -eq 0 ]; then
    anodizer::warn "no manifest files found to rename (neither flat nor per-crate layout under preserved-dist/)"
else
    anodizer::ok "preserved-dist manifests labelled for shard ${SHARD_LABEL} (${renamed} file(s))"
fi
