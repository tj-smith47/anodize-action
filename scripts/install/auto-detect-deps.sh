#!/usr/bin/env bash
# Parse the anodizer config in the workdir (YAML or TOML — the binary
# discovers both) and emit `deps=<csv>` listing the build/pipeline
# dependencies the configured stages need.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

deps=()
if ! cfg=$(find_anodizer_config); then
    gha_warning "auto-install: no anodizer config found, skipping"
    gha_set_output deps ""
    exit 0
fi

is_toml=false
anodizer_config_is_toml "$cfg" && is_toml=true

# True when the config declares top-level key `$1` — YAML `key:` at column
# 0; TOML `key =` at column 0, or a `[key]` / `[[key]]` / `[key.sub]`
# table header.
has_top_key() {
    if [ "$is_toml" = true ]; then
        grep -qE "^${1}[[:space:]]*=|^\[\[?${1}[].]" "$cfg"
    else
        grep -qE "^${1}:" "$cfg"
    fi
}

# True when `$1` is assigned value `$2` anywhere in the config — YAML
# `key: value` / TOML `key = "value"` — at any nesting depth.
has_kv() {
    if [ "$is_toml" = true ]; then
        grep -qE "${1}[[:space:]]*=[[:space:]]*\"?${2}\"?" "$cfg"
    else
        grep -qE "${1}:[[:space:]]*\"?${2}\"?" "$cfg"
    fi
}

if has_top_key nfpm || has_kv name anodizer-stage-nfpm; then
    deps+=("nfpm")
fi
has_top_key makeselfs && deps+=("makeself") || true
has_top_key snapcrafts && deps+=("snapcraft") || true
has_top_key srpm && deps+=("rpmbuild") || true
# cosign is the signing backend only for blocks that actually target it.
# anodizer's per-block default `cmd:` differs by sign type (verified against
# crates/core/src/signing.rs + crates/stage-sign/src/helpers.rs):
#   - `signs:` / `binary_signs:` (SignConfig) DEFAULT TO GPG when `cmd:` is
#     unset — default_sign_cmd reads `git config gpg.program`, falling back to
#     literal `gpg`. They need cosign only when `cmd: cosign` is set.
#   - `docker_signs:` (DockerSignConfig) has a STATIC cosign default
#     (DEFAULT_CMD = "cosign") — it needs cosign even with no `cmd:` line.
# So: install cosign when any sign block sets `cmd: cosign` (matches a top-level
# `signs:`/`binary_signs:`/`docker_signs:` block alike — the probe is cmd-based,
# not block-based), OR when a `docker_signs:` block is present at all. GPG needs
# no installer (it is pre-installed on every GitHub runner image), so a
# `binary_signs:` with `cmd: gpg` correctly pulls nothing.
need_cosign=""
has_kv cmd cosign && need_cosign=1
[ -z "$need_cosign" ] && has_top_key docker_signs && need_cosign=1
[ -n "$need_cosign" ] && deps+=("cosign") || true
# notarize.macos:[] drives the CROSS-PLATFORM signing/notarization path, which
# shells out to `rcodesign` (the apple-codesign project) — verified against
# crates/stage-notarize/src/run.rs (spawns "rcodesign") and
# crates/core/src/config/notarize.rs (NotarizeConfig.macos →
# MacOSSignNotarizeConfig, rcodesign-based, works on ANY OS). The sibling
# `notarize.macos_native:[]` path uses codesign + xcrun notarytool — present on
# macOS runners, no installer needed — so only `macos:` triggers rcodesign.
# YAML nests both keys (indented) under a top-level `notarize:` block; TOML
# spells the same shape as `[[notarize.macos]]` / `[notarize.macos]` headers,
# a dotted `notarize.macos =` key, or a bare `macos =` inside `[notarize]`.
# Every regex requires a non-word char right after `macos`, so `macos_native`
# never matches. rcodesign runs cross-platform; no OS guard.
notarize_macos_configured() {
    if [ "$is_toml" = true ]; then
        grep -qE '^\[\[?notarize\.macos[].]' "$cfg" && return 0
        grep -qE '^notarize\.macos[[:space:]]*=' "$cfg" && return 0
        grep -qE '^\[notarize\]' "$cfg" && grep -qE '^[[:space:]]*macos[[:space:]]*=' "$cfg" && return 0
        return 1
    fi
    grep -qE '^notarize:' "$cfg" && grep -qE '^[[:space:]]+macos:[[:space:]]*$' "$cfg"
}
if notarize_macos_configured; then
    deps+=("rcodesign")
fi
has_top_key sboms && deps+=("syft") || true
has_top_key upx && deps+=("upx") || true
has_top_key nsis && deps+=("nsis") || true
has_top_key dmgs && deps+=("create-dmg") || true
has_top_key flatpaks && deps+=("flatpak") || true
# appimages: shells out to linuxdeploy + its appimage output plugin, both
# Linux-only AppImages — emit the dep on Linux, warn (don't fail) elsewhere.
if has_top_key appimages; then
    if [ "${RUNNER_OS:-}" = "Linux" ]; then
        deps+=("linuxdeploy")
    else
        gha_warning "auto-install: appimages: requires a Linux runner (got ${RUNNER_OS:-unset}); skipping"
    fi
fi
# alejandra is only needed when the nix publisher opts into it as the
# formatter (the alternative, `nixfmt`, has no auto-installer here yet).
if [ "$is_toml" = true ]; then
    grep -qE '^[[:space:]]*formatter[[:space:]]*=[[:space:]]*"?alejandra"?[[:space:]]*$' "$cfg" && deps+=("alejandra") || true
else
    grep -qE '^[[:space:]]+formatter:[[:space:]]*alejandra[[:space:]]*$' "$cfg" && deps+=("alejandra") || true
fi

# pkgs/msis can't be cross-built — warn (don't fail) when config asks for
# them on the wrong runner; the build will fail later with a better error.
if has_top_key pkgs && [ "${RUNNER_OS:-}" != "macOS" ]; then
    gha_warning "auto-install: pkgs: requires macOS runner (got ${RUNNER_OS:-unset}); skipping"
fi
# msis: builds MSIs via WiX (crates/stage-msi/src/wix.rs — v4 `wix build`, or
# v3 `candle`+`light`). anodizer defaults to v4, whose CLI is the `wix` dotnet
# global tool. On Windows, install it (newer windows-2022/2025 images no longer
# ship WiX preinstalled); on other runners keep the existing can't-cross-build
# warning — MSIs require a Windows runner.
if has_top_key msis; then
    if [ "${RUNNER_OS:-}" = "Windows" ]; then
        deps+=("wix")
    else
        gha_warning "auto-install: msis: requires Windows runner (got ${RUNNER_OS:-unset}); skipping"
    fi
fi

if [ "$is_toml" = true ]; then
    grep -qE '^[[:space:]]*cross[[:space:]]*=[[:space:]]*"?(auto|zigbuild)"?[[:space:]]*$' "$cfg" && deps+=("zig" "cargo-zigbuild") || true
else
    grep -qE '^[[:space:]]*cross:[[:space:]]*(auto|zigbuild)[[:space:]]*$' "$cfg" && deps+=("zig" "cargo-zigbuild") || true
fi

joined=$(IFS=','; echo "${deps[*]}")
gha_notice "auto-install detected: ${joined:-none}"
gha_set_output deps "$joined"
