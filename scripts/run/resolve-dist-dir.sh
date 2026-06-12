#!/usr/bin/env bash
# Surface the configured dist directory as step outputs so composite
# `uses:` steps (artifact upload/download) point at the same tree the
# action's scripts resolve from the anodizer config.
#
#   dist — the configured value as written (default "dist")
#   path — absolute path, anchored at the workdir this step runs in
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/config.sh"

dist=$(resolve_dist_dir)
case "$dist" in
    /*) abs="$dist" ;;
    *)  abs="$(pwd)/${dist}" ;;
esac
gha_set_output dist "$dist"
gha_set_output path "$abs"
anodizer::step "dist directory resolved to ${dist}"
