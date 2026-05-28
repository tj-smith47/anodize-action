#!/usr/bin/env bash
# Reject combinations of install-path inputs — exactly one of
# version / from-artifact / from-source / from-branch may be active.
#
# `version` defaults to 'latest', so it only counts as user-set when
# explicitly overridden.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

active=()
[ -n "$FROM_BRANCH" ]                                             && active+=("from-branch: '$FROM_BRANCH'")
[ "$FROM_SOURCE" = "true" ]                                       && active+=("from-source: true")
[ -n "$FROM_ARTIFACT" ]                                           && active+=("from-artifact: '$FROM_ARTIFACT'")
[ -n "$VERSION" ] && [ "$VERSION" != "latest" ]                   && active+=("version: '$VERSION'")

echo "::error::only one install path may be active; got: ${active[*]}"
anodizer::err "only one install path may be active; got: ${active[*]}"
exit 1
