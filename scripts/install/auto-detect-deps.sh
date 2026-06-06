#!/usr/bin/env bash
# Parse .anodizer.yaml in the workdir and emit `deps=<csv>` listing the
# build/pipeline dependencies the configured stages need.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

deps=()
cfg=""
for candidate in .anodizer.yaml .anodizer.yml anodizer.yaml anodizer.yml; do
    if [ -f "$candidate" ]; then
        cfg="$candidate"
        break
    fi
done
if [ -z "$cfg" ]; then
    gha_warning "auto-install: no anodizer config found, skipping"
    gha_set_output deps ""
    exit 0
fi

grep -qE '^nfpm:|^  - name: anodizer-stage-nfpm' "$cfg" && deps+=("nfpm") || true
grep -qE '^makeselfs:' "$cfg" && deps+=("makeself") || true
grep -qE '^snapcrafts:' "$cfg" && deps+=("snapcraft") || true
grep -qE '^srpm:' "$cfg" && deps+=("rpmbuild") || true
# cosign is the signing backend only for blocks that actually target it.
# anodizer's per-block default `cmd:` differs by sign type (verified against
# crates/core/src/signing.rs + crates/stage-sign/src/helpers.rs):
#   - `signs:` / `binary_signs:` (SignConfig) DEFAULT TO GPG when `cmd:` is
#     unset — default_sign_cmd reads `git config gpg.program`, falling back to
#     literal `gpg`. They need cosign only when `cmd: cosign` is set.
#   - `docker_signs:` (DockerSignConfig) has a STATIC cosign default
#     (DEFAULT_CMD = "cosign") — it needs cosign even with no `cmd:` line.
# So: install cosign when any sign block sets `cmd: cosign` (matches a top-level
# `signs:`/`binary_signs:`/`docker_signs:` block alike — the grep is cmd-based,
# not block-based), OR when a `docker_signs:` block is present at all. GPG needs
# no installer (it is pre-installed on every GitHub runner image), so a
# `binary_signs:` with `cmd: gpg` correctly pulls nothing.
need_cosign=""
grep -qE 'cmd:[[:space:]]*"?cosign"?' "$cfg" && need_cosign=1
[ -z "$need_cosign" ] && grep -qE '^docker_signs:' "$cfg" && need_cosign=1
[ -n "$need_cosign" ] && deps+=("cosign") || true
# notarize.macos:[] drives the CROSS-PLATFORM signing/notarization path, which
# shells out to `rcodesign` (the apple-codesign project) — verified against
# crates/stage-notarize/src/run.rs (spawns "rcodesign") and
# crates/core/src/config/notarize.rs (NotarizeConfig.macos →
# MacOSSignNotarizeConfig, rcodesign-based, works on ANY OS). The sibling
# `notarize.macos_native:[]` path uses codesign + xcrun notarytool — present on
# macOS runners, no installer needed — so only `macos:` triggers rcodesign.
# Both keys live under a top-level `notarize:` block and are indented, hence the
# leading-whitespace match. rcodesign runs cross-platform; no OS guard.
if grep -qE '^notarize:' "$cfg" && grep -qE '^[[:space:]]+macos:[[:space:]]*$' "$cfg"; then
    deps+=("rcodesign")
fi
grep -qE '^sboms:' "$cfg" && deps+=("syft") || true
grep -qE '^upx:' "$cfg" && deps+=("upx") || true
grep -qE '^nsis:' "$cfg" && deps+=("nsis") || true
grep -qE '^dmgs:' "$cfg" && deps+=("create-dmg") || true
grep -qE '^flatpaks:' "$cfg" && deps+=("flatpak") || true
# appimages: shells out to linuxdeploy + its appimage output plugin, both
# Linux-only AppImages — emit the dep on Linux, warn (don't fail) elsewhere.
if grep -qE '^appimages:' "$cfg"; then
    if [ "${RUNNER_OS:-}" = "Linux" ]; then
        deps+=("linuxdeploy")
    else
        gha_warning "auto-install: appimages: requires a Linux runner (got ${RUNNER_OS:-unset}); skipping"
    fi
fi
# alejandra is only needed when the nix publisher opts into it as the
# formatter (the alternative, `nixfmt`, has no auto-installer here yet).
grep -qE '^[[:space:]]+formatter:[[:space:]]*alejandra[[:space:]]*$' "$cfg" && deps+=("alejandra") || true

# pkgs/msis can't be cross-built — warn (don't fail) when config asks for
# them on the wrong runner; the build will fail later with a better error.
if grep -qE '^pkgs:' "$cfg" && [ "${RUNNER_OS:-}" != "macOS" ]; then
    gha_warning "auto-install: pkgs: requires macOS runner (got ${RUNNER_OS:-unset}); skipping"
fi
# msis: builds MSIs via WiX (crates/stage-msi/src/wix.rs — v4 `wix build`, or
# v3 `candle`+`light`). anodizer defaults to v4, whose CLI is the `wix` dotnet
# global tool. On Windows, install it (newer windows-2022/2025 images no longer
# ship WiX preinstalled); on other runners keep the existing can't-cross-build
# warning — MSIs require a Windows runner.
if grep -qE '^msis:' "$cfg"; then
    if [ "${RUNNER_OS:-}" = "Windows" ]; then
        deps+=("wix")
    else
        gha_warning "auto-install: msis: requires Windows runner (got ${RUNNER_OS:-unset}); skipping"
    fi
fi

grep -qE '^[[:space:]]*cross:[[:space:]]*(auto|zigbuild)[[:space:]]*$' "$cfg" && deps+=("zig" "cargo-zigbuild") || true

joined=$(IFS=','; echo "${deps[*]}")
gha_notice "auto-install detected: ${joined:-none}"
gha_set_output deps "$joined"
