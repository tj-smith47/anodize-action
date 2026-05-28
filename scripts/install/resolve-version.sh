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
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

if [ "$INPUT_VERSION" = "latest" ]; then
    tag=$(gh api repos/tj-smith47/anodizer/releases/latest --jq '.tag_name' 2>/dev/null || echo "")
    if [ -z "$tag" ]; then
        echo "::error::Could not resolve latest anodizer release"
        anodizer::err "could not resolve latest anodizer release"
        exit 1
    fi
elif [ "$INPUT_VERSION" = "nightly" ]; then
    tag=$(gh api 'repos/tj-smith47/anodizer/releases?per_page=30' \
        --jq '[.[] | select(.draft == false) | .tag_name | select(test("-nightly$"))] | .[0] // empty' \
        2>/dev/null || echo "")
    if [ -z "$tag" ]; then
        echo "::error::Could not resolve nightly anodizer release (no published tag matches '*-nightly')"
        anodizer::err "could not resolve nightly anodizer release"
        exit 1
    fi
else
    if [[ "$INPUT_VERSION" =~ ^(~\>|\^|\>=|\<=|\>|\<) ]]; then
        echo "::error::version: '$INPUT_VERSION' is not supported — pass an exact tag (e.g. 'v0.1.1'), 'latest', or 'nightly'"
        anodizer::err "version: '$INPUT_VERSION' is not supported — pass an exact tag (e.g. 'v0.1.1'), 'latest', or 'nightly'"
        exit 1
    fi
    tag="$INPUT_VERSION"
    if [[ ! "$tag" =~ ^v ]]; then
        tag="v$tag"
    fi
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]]; then
        echo "::error::version: '$INPUT_VERSION' is not a valid semver tag (expected 'vMAJOR.MINOR.PATCH')"
        anodizer::err "version: '$INPUT_VERSION' is not a valid semver tag (expected 'vMAJOR.MINOR.PATCH')"
        exit 1
    fi
fi

echo "tag=$tag" >> "$GITHUB_OUTPUT"
echo "::notice::Installing anodizer $tag"
anodizer::verb Installing "anodizer ${tag}"
