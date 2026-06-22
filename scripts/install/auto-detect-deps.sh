#!/usr/bin/env bash
# Parse the anodizer config in the workdir (YAML or TOML — the binary
# discovers both) and emit `deps=<csv>` listing the build/pipeline
# dependencies the configured stages need.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

anodizer::verb Detecting "pipeline dependencies"

deps=()
if ! cfg=$(find_anodizer_config); then
    gha_warning "auto-install: no anodizer config found, skipping"
    anodizer::warn "no anodizer config found; nothing to auto-install"
    gha_set_output deps ""
    exit 0
fi

is_toml=false
anodizer_config_is_toml "$cfg" && is_toml=true

# True when the config declares the installer/packager BLOCK `$1` either at
# top level (single-crate flat config) OR nested under a crate entry
# (workspace per-crate config: `crates:` → crate → indented `key:` in YAML,
# `[[crates.<name>.key]]` / `[crates.<name>.key]` table headers in TOML).
# The key is anchored right after the leading whitespace (YAML) or bracket /
# `crates.<name>.` prefix (TOML) so e.g. `signs` never matches `binary_signs:`
# / `docker_signs:` and `pkgs` never matches a longer key like `app_bundles:`.
has_cfg_block() {
    if [ "$is_toml" = true ]; then
        grep -qE "^${1}[[:space:]]*=|^\[\[?${1}[].]|^\[\[?crates\.[^]]*\.${1}[].]" "$cfg"
    else
        grep -qE "^[[:space:]]*${1}:" "$cfg"
    fi
}

# True when `$1` is assigned value `$2` anywhere in the config — YAML
# `key: value` / TOML `key = "value"` — at any nesting depth. The value is
# end-anchored (closing quote, whitespace, or EOL) so a prefix match never
# fires: `cmd: cosignx` / `cmd: cosign-foo` must NOT pull `cosign`.
has_kv() {
    if [ "$is_toml" = true ]; then
        grep -qE "${1}[[:space:]]*=[[:space:]]*\"?${2}(\"|[[:space:]]|$)" "$cfg"
    else
        grep -qE "${1}:[[:space:]]*\"?${2}(\"|[[:space:]]|$)" "$cfg"
    fi
}

# nfpm (deb/rpm/apk), makeself (.run self-extractor), snapcraft (snap) and
# rpmbuild (source RPM) all produce Linux-only package formats and are
# provisioned via Linux package managers — none has a Windows path, and the
# determinism Windows/macOS shards never run these stages. Emit the dep on
# Linux; warn (don't fail) elsewhere, mirroring flatpaks/appimages. (A Windows
# shard with auto-install previously emitted `nfpm` unconditionally, which the
# dispatcher tried to `choco install` — nfpm has no choco package — and the
# install hard-failed before anodizer ran.)
add_linux_pkg_dep() {
    if [ "${RUNNER_OS:-}" = "Linux" ]; then
        deps+=("$1")
    else
        gha_warning "auto-install: $1: builds a Linux-only package format (got ${RUNNER_OS:-unset}); skipping"
    fi
}
if has_cfg_block nfpm || has_kv name anodizer-stage-nfpm; then add_linux_pkg_dep nfpm; fi
has_cfg_block makeselfs && add_linux_pkg_dep makeself || true
has_cfg_block snapcrafts && add_linux_pkg_dep snapcraft || true
has_cfg_block srpm && add_linux_pkg_dep rpmbuild || true
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
[ -z "$need_cosign" ] && has_cfg_block docker_signs && need_cosign=1
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
# npms: publishes an npm metapackage via `npm publish` (Trusted Publishing
# OIDC), which needs node/npm on PATH. npm publish runs on any runner OS, so
# no OS guard.
has_cfg_block npms && deps+=("node") || true
has_cfg_block sboms && deps+=("syft") || true
has_cfg_block upx && deps+=("upx") || true
# nsis builds on every platform (makensis: nsis apt on Linux, brew on macOS,
# choco on Windows), so it emits unconditionally.
has_cfg_block nsis && deps+=("nsis") || true
# dmgs: a .dmg builds on macOS (hdiutil) and Linux (genisoimage) but has no
# Windows path — warn (don't fail) and omit there, like pkgs.
if has_cfg_block dmgs; then
    if [ "${RUNNER_OS:-}" = "Windows" ]; then
        gha_warning "auto-install: dmgs: needs macOS hdiutil or Linux genisoimage (got Windows); skipping"
    else
        deps+=("create-dmg")
    fi
fi
# flatpaks: Flatpak is Linux-only — emit on Linux, warn (don't fail) elsewhere,
# like appimages.
if has_cfg_block flatpaks; then
    if [ "${RUNNER_OS:-}" = "Linux" ]; then
        deps+=("flatpak")
    else
        gha_warning "auto-install: flatpaks: requires a Linux runner (got ${RUNNER_OS:-unset}); skipping"
    fi
fi
# appimages: shells out to linuxdeploy + its appimage output plugin, both
# Linux-only AppImages — emit the dep on Linux, warn (don't fail) elsewhere.
if has_cfg_block appimages; then
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

# pkgs: builds macOS .pkg installers — native pkgbuild on macOS, the Linux flat
# XAR toolchain (xar + mkbom) on Linux. Either host can produce the artifact, so
# emit the dep on both; only Windows lacks a path.
if has_cfg_block pkgs; then
    if [ "${RUNNER_OS:-}" = "Windows" ]; then
        gha_warning "auto-install: pkgs: needs macOS pkgbuild or the Linux flat-package toolchain (got Windows); skipping"
    else
        deps+=("pkgbuild")
    fi
fi
# Print only the lines belonging to a `msis:` block, whether it sits at the
# top level (single-crate flat config) or nested under a crate entry (workspace
# per-crate config). The block runs from the `msis:` header to the next line
# indented at or below the header's own indentation, so a `version:` or `wxs:`
# sniff cannot pick up a sibling block's key. The leading-whitespace anchor
# requires `msis:` immediately after the indent, so a longer key never matches.
msis_block() {
    awk '
        !inblock && /^[[:space:]]*msis:/ {
            match($0, /^[[:space:]]*/); hdr = RLENGTH
            inblock = 1; next
        }
        inblock {
            match($0, /^[[:space:]]*/)
            if ($0 ~ /[^[:space:]]/ && RLENGTH <= hdr) { inblock = 0 }
        }
        inblock { print }
    ' "$cfg"
}

# Resolve the WiX dialect of a SINGLE `msis:` list entry, mirroring
# crates/stage-msi's WixVersion logic so the Windows install matches the
# toolchain the stage actually runs:
#   - explicit `version: v3` / `wixl` / `linux`  → `wix3` (candle+light)
#   - explicit `version: v4`                     → `wix`  (v4 `wix build`)
#   - no version → sniff the referenced `wxs:` file's XML namespace:
#       `http://schemas.microsoft.com/wix/2006/wi` (v3) → `wix3`, else `wix`
# Linux installs `wixl` for either token, so the distinction only changes the
# Windows toolchain. anodizer's msis: is a YAML-only block in practice, so the
# sniff reads the YAML shape. `$1` is the entry's text (version/wxs lines).
detect_entry_dialect() {
    local entry="$1" version wxs
    version=$(printf '%s\n' "$entry" \
        | grep -E '^[[:space:]]*(-[[:space:]]+)?version:[[:space:]]*' \
        | sed -E 's/^[[:space:]]*(-[[:space:]]+)?version:[[:space:]]*//' \
        | tr -d '"' | tr -d "'" | head -1 | xargs || true)
    case "$(printf '%s' "$version" | tr '[:upper:]' '[:lower:]')" in
        v3|3|wixl|linux) echo "wix3"; return ;;
        v4|4)            echo "wix";  return ;;
    esac
    # No explicit version — sniff the referenced .wxs namespace.
    wxs=$(printf '%s\n' "$entry" \
        | grep -E '^[[:space:]]*(-[[:space:]]+)?wxs:[[:space:]]*' \
        | sed -E 's/^[[:space:]]*(-[[:space:]]+)?wxs:[[:space:]]*//' \
        | tr -d '"' | tr -d "'" | head -1 | xargs || true)
    if [ -n "$wxs" ] && [ -f "$wxs" ] \
        && grep -q 'http://schemas.microsoft.com/wix/2006/wi' "$wxs"; then
        echo "wix3"; return
    fi
    # v4 namespace, unknown, or unreadable .wxs all default to v4, matching
    # WixVersion::detect_from_wxs.
    echo "wix"
}

# Resolve the DISTINCT WiX dialect tokens the whole `msis:` block needs. anodizer
# resolves WiX version per `msis:` entry (crates/stage-msi env_requirements loops
# per entry), so a mixed v3+v4 block needs BOTH toolchains. Split the block on
# the YAML `- ` list markers, resolve each entry, and print each distinct token
# (`wix` and/or `wix3`) on its own line. The dispatch loop + _APT_BATCHED_DEPS
# tolerate both.
detect_msi_dialects() {
    local block emitted_wix="" emitted_wix3=""
    block=$(msis_block)
    # Group the block into per-entry chunks: a line starting (after indent) with
    # the `- ` list marker opens a new entry; intervening indented lines belong
    # to it. A block with no `- ` marker is treated as a single entry.
    local token
    while IFS= read -r token; do
        case "$token" in
            wix3) emitted_wix3=1 ;;
            wix)  emitted_wix=1 ;;
        esac
    done < <(
        printf '%s\n' "$block" | awk '
            /^[[:space:]]*-[[:space:]]/ {
                if (entry != "") print entry "\036"
                entry = $0 "\n"; next
            }
            { entry = entry $0 "\n" }
            END { if (entry != "") print entry "\036" }
        ' | while IFS= read -r -d $'\036' entry; do
            [ -n "$entry" ] && detect_entry_dialect "$entry"
        done
    )
    [ -n "$emitted_wix3" ] && echo "wix3"
    [ -n "$emitted_wix" ] && echo "wix"
}

# msis: builds MSIs. WiX itself is Windows-only and EULA-gated, so on Linux the
# msi stage uses `wixl` (msitools) from the v3-dialect .wxs. Both Windows (WiX)
# and Linux (wixl) can produce the artifact; only macOS lacks a path. The
# emitted token is dialect-aware (wix3 = v3 candle+light, wix = v4 wix build).
if has_cfg_block msis; then
    if [ "${RUNNER_OS:-}" = "macOS" ]; then
        gha_warning "auto-install: msis: needs WiX (Windows) or wixl (Linux) — got macOS; skipping"
    elif [ "$is_toml" = true ]; then
        # The per-entry dialect resolver is YAML-shaped (`version:` / `wxs:`),
        # so a TOML `[[crates.<n>.msis]]` block's dialect can't be read here;
        # emit BOTH WiX majors so whichever the stage selects is on PATH (Linux
        # uses wixl for either, so the superset only adds one Windows install).
        deps+=("wix3" "wix")
    else
        # A mixed-dialect block emits both tokens (one per line); append each.
        while IFS= read -r _msi_tok; do
            [ -n "$_msi_tok" ] && deps+=("$_msi_tok")
        done < <(detect_msi_dialects)
    fi
fi

if [ "$is_toml" = true ]; then
    grep -qE '^[[:space:]]*cross[[:space:]]*=[[:space:]]*"?(auto|zigbuild)"?[[:space:]]*$' "$cfg" && deps+=("zig" "cargo-zigbuild") || true
else
    grep -qE '^[[:space:]]*cross:[[:space:]]*(auto|zigbuild)[[:space:]]*$' "$cfg" && deps+=("zig" "cargo-zigbuild") || true
fi

joined=$(IFS=','; echo "${deps[*]}")
anodizer::kv detected "${joined:-none}"
gha_set_output deps "$joined"
