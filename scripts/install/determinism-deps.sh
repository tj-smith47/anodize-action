#!/usr/bin/env bash
# Emit the per-OS dependency set the determinism harness needs for the
# default stage list.
#
# Linux adds nfpm because its default stage list includes nfpm. zig and
# cargo-zigbuild are Linux-only — cross-compile from non-Linux runners
# isn't supported by the matrix. cosign / syft are pre-installed even
# when sign / sbom would skip; both are cheap and the determinism
# default exercises both.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

if [ "$RUNNER_OS" = "Linux" ]; then
    gha_set_output deps "zig,cargo-zigbuild,upx,nfpm,makeself,snapcraft,syft,cosign"
else
    gha_set_output deps "upx,syft,cosign"
fi
