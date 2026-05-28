#!/usr/bin/env bash
# Resolve the triggering tag to its monorepo crate via `anodizer resolve-tag`
# and surface (crate, path, has-builds) as step outputs.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

if ! command -v anodizer > /dev/null 2>&1; then
    echo "::error::resolve-workspace requires anodizer to be installed"
    anodizer::err "resolve-workspace requires anodizer to be installed"
    exit 1
fi

output=$(anodizer resolve-tag "$TAG")
crate=$(echo "$output" | grep '^crate=' | cut -d= -f2)
path=$(echo "$output" | grep '^path=' | cut -d= -f2)
has_builds=$(echo "$output" | grep '^has-builds=' | cut -d= -f2)

if [ -z "$crate" ]; then
    echo "::error::No crate matches tag '$TAG'"
    anodizer::err "no crate matches tag '$TAG'"
    exit 1
fi

echo "crate=$crate" >> "$GITHUB_OUTPUT"
echo "path=$path" >> "$GITHUB_OUTPUT"
echo "has-builds=$has_builds" >> "$GITHUB_OUTPUT"
echo "::notice::Tag '$TAG' → crate '$crate' (path=$path, has-builds=$has_builds)"
anodizer::verb Resolved "'$TAG' → $crate"
anodizer::kv path "$path"
anodizer::kv has-builds "$has_builds"
