#!/usr/bin/env bash
# Resolve `artifact-run-id` to a numeric workflow run ID, dispatching to
# the auto-resolver when the input is "auto".
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

if [ "$ARTIFACT_RUN_ID" = "auto" ]; then
    "${GITHUB_ACTION_PATH}/scripts/install/resolve-artifact-run.sh"
else
    gha_set_output run_id "$ARTIFACT_RUN_ID"
fi
