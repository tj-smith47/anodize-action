#!/usr/bin/env bash
# Stage a pre-downloaded artifact binary onto $PATH after
# actions/download-artifact has dropped it under
# $RUNNER_TOOL_CACHE/anodizer/artifact.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

install_dir="${RUNNER_TOOL_CACHE}/anodizer/artifact"
chmod +x "${install_dir}/${BIN}" 2>/dev/null || true
echo "${install_dir}" >> "$GITHUB_PATH"

echo "::notice::anodizer installed from artifact to ${install_dir}"
anodizer::verb Installed "anodizer from artifact"
anodizer::detail "${install_dir}/${BIN}"
