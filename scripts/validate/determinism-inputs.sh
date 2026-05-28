#!/usr/bin/env bash
# Reject `determinism: true` combined with `args:` — the action drives
# `anodizer check determinism` itself, so a user-supplied args list would
# either be ignored or double-wrap the harness invocation.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

echo "::error::determinism: true is mutually exclusive with args:; the action invokes \`anodizer check determinism\` directly"
anodizer::err "determinism: true is mutually exclusive with args:"
exit 1
