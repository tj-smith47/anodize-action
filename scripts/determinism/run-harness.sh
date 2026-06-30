#!/usr/bin/env bash
# Run `anodizer check determinism` with the resolved target CSV and optional
# preserve-dist / per-crate scoping.
#
# Stage selection is the BINARY's job, not this wrapper's. Omitting `--stages`
# tells the harness to byte-verify the full host-OS-native partition via
# `default_stages_for_host()` (the single source of truth: Linux adds
# nfpm/makeself/snapcraft/srpm/docker/appimage/flatpak, macOS adds
# appbundle/dmg/pkg, Windows adds msi/nsis). This wrapper used to re-derive a
# per-OS list in bash, which drifted from the binary's partition; that
# re-derivation is gone. $STAGES_INPUT is forwarded verbatim only when an
# operator explicitly overrides the set.
#
# `--require-tools` always: this is the CI path, where a missing OS-native
# backing tool must HARD-FAIL the shard rather than warn-skip. A silent skip
# is false coverage — a shard claiming it byte-verified a format it then
# produced nothing for (the failure mode that hid the macOS/Windows installers
# from every release).
#
# No retry loop here. The harness gates release-quality drift; a retry
# would mask a flaky-but-real failure. Fail loudly on the first run.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

extra_args=()
if [ -n "$STAGES_INPUT" ]; then
    extra_args+=(--stages="$STAGES_INPUT")
fi
if [ "$PRESERVE_DIST" = "true" ]; then
    extra_args+=(--preserve-dist=./preserved-dist)
fi
if [ -n "$CRATE" ]; then
    extra_args+=(--crate="$CRATE")
fi

# No header/parameter echo here: the binary's own "Checking determinism"
# group prints targets/stages/runs/preserve-dist/crate with one formatter.
# Echoing them from the wrapper too doubled the header in release logs.
anodizer check determinism \
    --require-tools \
    --runs="$RUNS" \
    --targets="$TARGETS" \
    "${extra_args[@]}"
