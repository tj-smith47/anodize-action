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
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

if [ -z "$SHARD_LABEL" ]; then
    anodizer::err "preserve-dist requires shard-label input"
    exit 1
fi

if [ ! -d preserved-dist ]; then
    anodizer::warn "preserved-dist/ missing — nothing to rename"
    exit 0
fi

renamed=0

for f in context artifacts metadata; do
    src="preserved-dist/${f}.json"
    dst="preserved-dist/${f}-${SHARD_LABEL}.json"
    if [ -f "$src" ]; then
        mv "$src" "$dst"
        anodizer::verb renamed "$src -> $dst"
        renamed=$((renamed + 1))
    fi
done

for subdir in preserved-dist/*/; do
    [ -d "$subdir" ] || continue
    for f in context artifacts metadata; do
        src="${subdir}${f}.json"
        dst="${subdir}${f}-${SHARD_LABEL}.json"
        if [ -f "$src" ]; then
            mv "$src" "$dst"
            anodizer::verb renamed "$src -> $dst"
            renamed=$((renamed + 1))
        fi
    done
done

if [ "$renamed" -eq 0 ]; then
    anodizer::warn "no manifest files found to rename (neither flat nor per-crate layout under preserved-dist/)"
else
    anodizer::ok "preserved-dist manifests labelled for shard ${SHARD_LABEL} (${renamed} file(s))"
fi
