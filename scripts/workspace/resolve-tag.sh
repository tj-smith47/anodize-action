#!/usr/bin/env bash
# Resolve the triggering tag to its monorepo crate via `anodizer resolve-tag`
# and surface (crate, path, has-builds) as step outputs.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

command -v anodizer > /dev/null 2>&1 || gha_fail "resolve-workspace requires anodizer to be installed"

output=$(anodizer resolve-tag "$TAG")
crate=$(echo "$output" | grep '^crate=' | cut -d= -f2)
path=$(echo "$output" | grep '^path=' | cut -d= -f2)
has_builds=$(echo "$output" | grep '^has-builds=' | cut -d= -f2)

[ -n "$crate" ] || gha_fail "No crate matches tag '$TAG'"

gha_set_output crate "$crate"
gha_set_output path "$path"
gha_set_output has-builds "$has_builds"
gha_notice "Tag '$TAG' → crate '$crate' (path=$path, has-builds=$has_builds)"
anodizer::verb Resolved "'$TAG' → $crate"
anodizer::kv path "$path"
anodizer::kv has-builds "$has_builds"
