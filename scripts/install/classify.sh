#!/usr/bin/env bash
# Classify the install method and derive the toolchain/run gating booleans
# from the action inputs, so the many duplicated long `if:` conditionals in
# action.yml collapse to a single source of truth consumed via this step's
# outputs.
#
# Reads (env, all optional — empty when unset):
#   FROM_ARTIFACT FROM_BRANCH FROM_SOURCE DETERMINISM VERSION
#   INSTALL_RUST INSTALL_ONLY ARGS
#
# Emits ($GITHUB_OUTPUT):
#   install_method    one of: artifact | branch | source | release
#   needs_rust        'true' | 'false'
#   needs_cargo_cache 'true' | 'false'
#   needs_sccache     'true' | 'false'
#   run_anodizer      'true' | 'false'
#
# install_method precedence is artifact > branch > source > release; the
# source-vs-release split honors an explicit version pin under determinism
# (a pinned tag downloads that release; latest/unset rebuilds from source).
set -euo pipefail
# shellcheck source=../lib/gha.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

# A pinned version is any explicit, non-'latest' value.
version_pinned=false
if [ -n "$VERSION" ] && [ "$VERSION" != "latest" ]; then
    version_pinned=true
fi

if [ -n "$FROM_ARTIFACT" ]; then
    install_method=artifact
elif [ -n "$FROM_BRANCH" ]; then
    install_method=branch
elif [ "$FROM_SOURCE" = "true" ] || { [ "$DETERMINISM" = "true" ] && [ "$version_pinned" = "false" ]; }; then
    install_method=source
else
    install_method=release
fi

emit_bool() {
    if [ "$1" = "true" ]; then
        gha_set_output "$2" "true"
    else
        gha_set_output "$2" "false"
    fi
}

needs_rust=false
if [ "$INSTALL_RUST" = "true" ] || [ "$DETERMINISM" = "true" ] || [ -n "$FROM_BRANCH" ]; then
    needs_rust=true
fi

needs_cargo_cache=false
if [ "$DETERMINISM" = "true" ] || [ "$FROM_SOURCE" = "true" ] || [ -n "$FROM_BRANCH" ]; then
    needs_cargo_cache=true
fi

needs_sccache=false
if [ "$DETERMINISM" = "true" ] || [ "$FROM_SOURCE" = "true" ]; then
    needs_sccache=true
fi

run_anodizer=false
if [ "$INSTALL_ONLY" != "true" ] && [ -n "$ARGS" ] && [ "$DETERMINISM" != "true" ]; then
    run_anodizer=true
fi

gha_set_output install_method "$install_method"
emit_bool "$needs_rust" needs_rust
emit_bool "$needs_cargo_cache" needs_cargo_cache
emit_bool "$needs_sccache" needs_sccache
emit_bool "$run_anodizer" run_anodizer
