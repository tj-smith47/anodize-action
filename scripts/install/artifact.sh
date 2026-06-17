#!/usr/bin/env bash
# Stage a pre-downloaded artifact binary onto $PATH after
# actions/download-artifact has dropped it under
# $RUNNER_TOOL_CACHE/anodizer/artifact.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

install_dir="${RUNNER_TOOL_CACHE}/anodizer/artifact"
chmod +x "${install_dir}/${BIN}" 2>/dev/null || true
gha_add_path "$install_dir"

anodizer::verb Installing "anodizer from artifact"
anodizer::ok "anodizer installed from artifact"
anodizer::detail "${install_dir}/${BIN}"
