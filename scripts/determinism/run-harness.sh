#!/usr/bin/env bash
# Run `anodizer check determinism` with the resolved per-shard stage list,
# target CSV, and optional preserve-dist / per-crate scoping.
#
# Per-OS default stage list (when $STAGES_INPUT is empty):
#   Linux  → build,source,upx,archive,nfpm,makeself,snapcraft,sbom,sign,checksum
#   other  → build,source,upx,archive,sbom,sign,checksum
#
# Linux includes nfpm/makeself/snapcraft because their dependencies only
# install cleanly on the Ubuntu runner (apt is Linux-only; apk/deb/rpm
# signing isn't provisioned on the non-Linux shards). Snapcraft packs a
# pre-assembled prime directory (no build env / lxd) and honors
# SOURCE_DATE_EPOCH for squashfs mtime determinism.
#
# No retry loop here. The harness gates release-quality drift; a retry
# would mask a flaky-but-real failure. Fail loudly on the first run.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

if [ -n "$STAGES_INPUT" ]; then
    stages="$STAGES_INPUT"
elif [ "$RUNNER_OS" = "Linux" ]; then
    stages="build,source,upx,archive,nfpm,makeself,snapcraft,sbom,sign,checksum"
else
    stages="build,source,upx,archive,sbom,sign,checksum"
fi

extra_args=()
if [ "$PRESERVE_DIST" = "true" ]; then
    extra_args+=(--preserve-dist=./preserved-dist)
fi
if [ -n "$CRATE" ]; then
    extra_args+=(--crate="$CRATE")
fi

anodizer::section "anodizer check determinism"
anodizer::kv targets "$TARGETS"
anodizer::kv stages "$stages"
anodizer::kv runs "$RUNS"
if [ "$PRESERVE_DIST" = "true" ]; then
    anodizer::kv preserve-dist ./preserved-dist
fi
if [ -n "$CRATE" ]; then
    anodizer::kv crate "$CRATE"
fi

anodizer check determinism \
    --stages="$stages" \
    --runs="$RUNS" \
    --targets="$TARGETS" \
    "${extra_args[@]}"
