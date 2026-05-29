#!/usr/bin/env bash
# Resolve the requested version input to an installable release tag.
#
# Accepts:
#   - "latest"  → newest published GitHub release.
#   - "nightly" → newest non-draft release whose tag matches `*-nightly`.
#                 Mirrors goreleaser-action ≥ v7.2.0 immutable-nightly
#                 resolution. Anodizer's nightly tag format is
#                 `vX.Y.Z-<sha>-nightly`, exact to this jq pattern.
#   - "vMAJOR.MINOR.PATCH[-…]" or "MAJOR.MINOR.PATCH[-…]" — exact tag.
#
# Rejects semver ranges (~>, ^, >=, <=, >, <) — there is no resolver for
# them. Pass an explicit tag, "latest", or "nightly".
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

resolve_latest() {
    local t
    t=$(gh api repos/tj-smith47/anodizer/releases/latest --jq '.tag_name' 2>/dev/null || echo "")
    [ -n "$t" ] || gha_fail "Could not resolve latest anodizer release"
    printf '%s\n' "$t"
}

resolve_nightly() {
    local t
    t=$(gh api 'repos/tj-smith47/anodizer/releases?per_page=30' \
        --jq '[.[] | select(.draft == false) | .tag_name | select(test("-nightly$"))] | .[0] // empty' \
        2>/dev/null || echo "")
    [ -n "$t" ] || gha_fail "Could not resolve nightly anodizer release (no published tag matches '*-nightly')"
    printf '%s\n' "$t"
}

resolve_exact_tag() {
    local input="$1" t
    if [[ "$input" =~ ^(~\>|\^|\>=|\<=|\>|\<) ]]; then
        gha_fail "version: '$input' is not supported — pass an exact tag (e.g. 'v0.1.1'), 'latest', or 'nightly'"
    fi
    t="$input"
    [[ "$t" =~ ^v ]] || t="v$t"
    [[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]] \
        || gha_fail "version: '$input' is not a valid semver tag (expected 'vMAJOR.MINOR.PATCH')"
    printf '%s\n' "$t"
}

case "$INPUT_VERSION" in
    latest)  tag=$(resolve_latest) ;;
    nightly) tag=$(resolve_nightly) ;;
    *)       tag=$(resolve_exact_tag "$INPUT_VERSION") ;;
esac

gha_set_output tag "$tag"
gha_notice "Installing anodizer $tag"
anodizer::verb Installing "anodizer ${tag}"
