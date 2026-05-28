#!/usr/bin/env bash
# Emit `::add-mask::` for each non-empty line of a secret value.
#
# Defence-in-depth against auto-masking loss across reusable-workflow
# boundaries — a multi-line key (GPG, RSA, etc.) only auto-masks as a
# single opaque string when bound from `secrets.*`, leaving individual
# lines visible if the value crosses a workflow boundary.
#
# Source-and-call (no subshell), so masks register against the calling
# step's log stream:
#
#   source "${GITHUB_ACTION_PATH}/scripts/lib/mask-secret.sh"
#   anodizer::mask_lines "$SECRET"

anodizer::mask_lines() {
    local value="$1"
    while IFS= read -r line; do
        [ -n "$line" ] && echo "::add-mask::$line"
    done <<< "$value"
}
