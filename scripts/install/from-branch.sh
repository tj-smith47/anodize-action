#!/usr/bin/env bash
# Shallow-clone tj-smith47/anodizer at $FROM_BRANCH into $RUNNER_TEMP/anodizer-src
# and emit ANODIZER_SRC_DIR for the subsequent from-source build step.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

clone_dest="${RUNNER_TEMP}/anodizer-src"
repo_url="https://github.com/tj-smith47/anodizer.git"

if [ -d "$clone_dest" ]; then
    anodizer::verb Removing "stale clone at ${clone_dest}"
    rm -rf "$clone_dest"
fi

anodizer::verb Cloning "tj-smith47/anodizer@${FROM_BRANCH}"
echo "::group::Cloning tj-smith47/anodizer branch ${FROM_BRANCH}"
git clone --depth 1 --branch "$FROM_BRANCH" --single-branch "$repo_url" "$clone_dest"
echo "::endgroup::"

echo "clone_dest=${clone_dest}" >> "$GITHUB_OUTPUT"
echo "ANODIZER_SRC_DIR=${clone_dest}" >> "$GITHUB_ENV"
anodizer::ok "cloned tj-smith47/anodizer@${FROM_BRANCH} to ${clone_dest}"
