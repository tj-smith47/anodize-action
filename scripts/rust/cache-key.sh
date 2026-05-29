#!/usr/bin/env bash
# Compute the rust-cache key suffix and pre-create the workspace dir.
#
# Key disambiguation: a from-source consumer must not collide with a
# determinism shard (different feature sets / build profiles), and a
# from-branch run keys on the branch slug so concurrent feature branches
# don't share a cache.
#
# Pre-create: Swatinem/rust-cache validates the `workspaces:` path exists
# before restoring. On a cache-miss first run of from-branch the clone
# step that creates the dir runs LATER, so an empty placeholder keeps the
# cache action happy; a subsequent `git clone` into the same empty dir is
# fine.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

if [ "$DETERMINISM" = "true" ]; then
    suffix=determinism
elif [ -n "$FROM_BRANCH" ]; then
    # Branch names can contain `/` and whitespace; GHA expressions have no
    # `replace()` so slug-formation happens here.
    slug=$(printf '%s' "$FROM_BRANCH" | tr '/ ' '--')
    suffix="from-branch-${slug}"
else
    suffix=from-source
fi
gha_set_output suffix "$suffix"

if [ -n "$WORKSPACE_DIR" ] && [ ! -d "$WORKSPACE_DIR" ]; then
    mkdir -p "$WORKSPACE_DIR"
fi
