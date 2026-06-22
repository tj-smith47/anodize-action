#!/usr/bin/env bash
# `rustup target add` every triple in $TARGETS.
#
# The from-source build only installed the host triple. The determinism
# harness rebuilds anodizer per configured target inside its hermetic
# worktree, so each shard's per-OS target list must be added.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

anodizer::verb Adding "rust targets"

IFS=',' read -ra triples <<< "$TARGETS"
for t in "${triples[@]}"; do
    t=$(printf '%s' "$t" | xargs)
    [ -z "$t" ] && continue
    anodizer::step "adding rust target $t"
    anodizer::run_quiet rustup target add "$t"
done
anodizer::ok "rust targets installed: ${TARGETS}"
