#!/usr/bin/env bash
# install-deps.sh — install anodizer pipeline dependencies.
#
# Accepts a comma-separated list from the $EXPLICIT_INSTALL env var, merges
# with $AUTO_INSTALL (from the auto-detect step), dedupes, and installs
# each requested dep via the platform-native package manager.
#
# Recognised deps: nfpm, makeself, snapcraft, rpmbuild, cosign, zig,
# cargo-zigbuild, upx, nsis, create-dmg, flatpak.
#
# Called from action.yml; expects $GITHUB_ACTION_PATH to point at the
# action root so we can source scripts/lib-colors.sh.
set -euo pipefail

# shellcheck source=./lib-colors.sh
source "${GITHUB_ACTION_PATH}/scripts/lib-colors.sh"

: "${RUNNER_OS:?RUNNER_OS is required}"
EXPLICIT_INSTALL="${EXPLICIT_INSTALL:-}"
AUTO_INSTALL="${AUTO_INSTALL:-}"

combined="${EXPLICIT_INSTALL}"
if [ -n "$AUTO_INSTALL" ]; then
    if [ -n "$combined" ]; then
        combined="${combined},${AUTO_INSTALL}"
    else
        combined="$AUTO_INSTALL"
    fi
fi

# Dedupe (POSIX-safe; macOS ships bash 3.2 — no associative arrays).
IFS=',' read -ra RAW <<< "$combined"
DEPS=()
seen_list=""
for dep in "${RAW[@]}"; do
    dep=$(echo "$dep" | xargs)
    [ -z "$dep" ] && continue
    case ",${seen_list}," in
        *",${dep},"*) ;;
        *)
            DEPS+=("$dep")
            seen_list="${seen_list:+${seen_list},}${dep}"
            ;;
    esac
done

if [ "${#DEPS[@]}" -eq 0 ]; then
    anodizer::detail "no dependencies requested"
    exit 0
fi

anodizer::section "Dependency installation (${#DEPS[@]})"

# Batch apt installs for efficiency (one apt-get install call instead of N)
APT_PKGS=()
APT_NAMES=()
apt_queue() {
    APT_PKGS+=("$1")
    APT_NAMES+=("$2")
    anodizer::detail "${2} queued for batch apt install"
}
apt_flush() {
    [ "${#APT_PKGS[@]}" -eq 0 ] && return
    anodizer::verb Installing "apt batch: ${APT_NAMES[*]}"
    if ! sudo apt-get install -yq "${APT_PKGS[@]}"; then
        anodizer::err "apt batch install failed for: ${APT_NAMES[*]}"
        exit 1
    fi
    for name in "${APT_NAMES[@]}"; do
        anodizer::ok "${name} installed"
    done
    APT_PKGS=()
    APT_NAMES=()
}

skip_unsupported_os() {
    local tool="$1"
    local reason="${2:-not natively supported on ${RUNNER_OS}}"
    echo "::warning::${tool} is ${reason}; skipping"
    anodizer::warn "${tool} is ${reason}; skipping"
}

# brew_install <formula> <version_env_var>
# If the named env var is set and non-empty, pins the formula to `formula@VERSION`.
brew_install() {
    local formula="$1"
    local var="$2"
    local version="${!var:-}"
    if [ -n "$version" ]; then
        brew install "${formula}@${version}"
    else
        brew install "$formula"
    fi
}

# choco_install <package> <version_env_var>
# If the named env var is set and non-empty, passes --version=VERSION to choco.
choco_install() {
    local pkg="$1"
    local var="$2"
    local version="${!var:-}"
    if [ -n "$version" ]; then
        choco install "$pkg" -y --no-progress --version="$version"
    else
        choco install "$pkg" -y --no-progress
    fi
}

install_nfpm() {
    case "$RUNNER_OS" in
        Linux)
            echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' | sudo tee /etc/apt/sources.list.d/goreleaser.list > /dev/null
            sudo apt-get update -q
            sudo apt-get install -yq nfpm
            ;;
        macOS)   brew_install goreleaser/tap/nfpm NFPM_VERSION ;;
        Windows) choco_install nfpm NFPM_VERSION ;;
    esac
}

install_makeself() {
    case "$RUNNER_OS" in
        Linux)   apt_queue makeself makeself ;;
        macOS)   brew_install makeself MAKESELF_VERSION ;;
        Windows) skip_unsupported_os makeself ;;
    esac
}

install_snapcraft() {
    case "$RUNNER_OS" in
        Linux)   sudo snap install snapcraft --classic ;;
        macOS)   brew_install snapcraft SNAPCRAFT_VERSION ;;
        Windows) skip_unsupported_os snapcraft ;;
    esac
}

install_rpmbuild() {
    case "$RUNNER_OS" in
        Linux)   apt_queue rpm rpmbuild ;;
        macOS)   brew_install rpm RPM_VERSION ;;
        Windows) skip_unsupported_os rpmbuild ;;
    esac
}

install_cosign() {
    case "$RUNNER_OS" in
        Linux)
            local version="${COSIGN_VERSION:-v2.4.1}"
            local base="https://github.com/sigstore/cosign/releases/download/${version}"
            local bin="cosign-linux-amd64"
            curl -sSfL "${base}/${bin}" -o /tmp/cosign
            curl -sSfL "${base}/${bin}-keyless.pem" -o /tmp/cosign.pem
            curl -sSfL "${base}/${bin}-keyless.sig" -o /tmp/cosign.sig
            curl -sSfL "${base}/cosign_checksums.txt" -o /tmp/cosign_checksums.txt
            # SHA256 verification — bootstraps trust without requiring cosign-to-verify-cosign.
            expected=$(grep " ${bin}\$" /tmp/cosign_checksums.txt | awk '{print $1}')
            if [ -z "$expected" ]; then
                echo "::error::cosign checksum entry for ${bin} not found in cosign_checksums.txt (${version})"
                anodizer::err "cosign checksum entry for ${bin} not found (${version})"
                exit 1
            fi
            echo "${expected}  /tmp/cosign" | sha256sum -c -
            sudo install /tmp/cosign /usr/local/bin/cosign
            # Post-install keyless signature verification (best-effort — won't block install).
            COSIGN_EXPERIMENTAL=1 cosign verify-blob \
                --certificate /tmp/cosign.pem \
                --signature /tmp/cosign.sig \
                --certificate-identity-regexp 'https://github\.com/sigstore/cosign/.*' \
                --certificate-oidc-issuer https://token.actions.githubusercontent.com \
                /tmp/cosign || anodizer::warn "cosign keyless signature verification failed (SHA256 already verified)"
            ;;
        macOS)   brew_install cosign COSIGN_VERSION ;;
        Windows) choco_install cosign COSIGN_VERSION ;;
    esac
}

install_zig() {
    case "$RUNNER_OS" in
        Linux)
            local version="${ZIG_VERSION:-0.13.0}"
            local tarball="zig-linux-x86_64-${version}.tar.xz"
            local base="https://ziglang.org/download/${version}"
            curl -sSfL "${base}/${tarball}" -o /tmp/zig.tar.xz
            curl -sSfL "${base}/${tarball}.sha256" -o /tmp/zig.tar.xz.sha256
            expected=$(awk '{print $1}' /tmp/zig.tar.xz.sha256)
            if [ -z "$expected" ]; then
                echo "::error::zig sha256 sidecar empty for ${tarball}"
                anodizer::err "zig sha256 sidecar empty for ${tarball}"
                exit 1
            fi
            echo "${expected}  /tmp/zig.tar.xz" | sha256sum -c -
            sudo mkdir -p /opt/zig
            sudo tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
            sudo ln -sf /opt/zig/zig /usr/local/bin/zig
            ;;
        macOS)   brew_install zig ZIG_VERSION ;;
        Windows) choco_install zig ZIG_VERSION ;;
    esac
}

install_cargo_zigbuild() {
    if ! command -v cargo > /dev/null 2>&1; then
        echo "::error::cargo-zigbuild requires Rust; set install-rust: true"
        anodizer::err "cargo-zigbuild requires Rust; set install-rust: true"
        exit 1
    fi
    cargo install --locked cargo-zigbuild
}

install_upx() {
    case "$RUNNER_OS" in
        Linux)   apt_queue upx upx ;;
        macOS)   brew_install upx UPX_VERSION ;;
        Windows) choco_install upx UPX_VERSION ;;
    esac
}

install_nsis() {
    case "$RUNNER_OS" in
        Linux)   apt_queue nsis nsis ;;
        macOS)   brew_install makensis NSIS_VERSION ;;
        Windows) choco_install nsis NSIS_VERSION ;;
    esac
}

install_create_dmg() {
    case "$RUNNER_OS" in
        macOS)   brew_install create-dmg CREATE_DMG_VERSION ;;
        Linux|Windows) skip_unsupported_os create-dmg "macOS-only (dmgs: config requires a macOS runner)" ;;
    esac
}

install_flatpak() {
    case "$RUNNER_OS" in
        Linux)   apt_queue flatpak-builder flatpak-builder ;;
        macOS|Windows) skip_unsupported_os flatpak-builder "Linux-only (flatpaks: config requires a Linux runner)" ;;
    esac
}

for dep in "${DEPS[@]}"; do
    anodizer::verb Installing "${dep}"
    pre_queue=${#APT_PKGS[@]}
    case "$dep" in
        nfpm)           install_nfpm ;;
        makeself)       install_makeself ;;
        snapcraft)      install_snapcraft ;;
        rpmbuild)       install_rpmbuild ;;
        cosign)         install_cosign ;;
        zig)            install_zig ;;
        cargo-zigbuild) install_cargo_zigbuild ;;
        upx)            install_upx ;;
        nsis)           install_nsis ;;
        create-dmg)     install_create_dmg ;;
        flatpak)        install_flatpak ;;
        *)
            echo "::error::Unknown dependency: $dep (supported: nfpm, makeself, snapcraft, rpmbuild, cosign, zig, cargo-zigbuild, upx, nsis, create-dmg, flatpak)"
            anodizer::err "unknown dependency: $dep"
            exit 1
            ;;
    esac
    # Only print "installed" for deps that ran immediately (not apt-queued).
    [ "${#APT_PKGS[@]}" -eq "$pre_queue" ] && anodizer::ok "${dep} installed"
done

# Flush any batched apt packages (makeself, rpm, upx queued above).
# apt_flush prints its own success messages per package.
apt_flush
