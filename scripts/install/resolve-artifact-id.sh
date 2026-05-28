#!/usr/bin/env bash
# Resolve `artifact-run-id` to a numeric workflow run ID, dispatching to
# the auto-resolver when the input is "auto".
set -euo pipefail

if [ "$ARTIFACT_RUN_ID" = "auto" ]; then
    "${GITHUB_ACTION_PATH}/scripts/install/resolve-artifact-run.sh"
else
    echo "run_id=$ARTIFACT_RUN_ID" >> "$GITHUB_OUTPUT"
fi
