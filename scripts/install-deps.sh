#!/usr/bin/env bash
# install-deps.sh — install anodize pipeline dependencies.
#
# Accepts a comma-separated list from the $EXPLICIT_INSTALL env var, merges
# with $AUTO_INSTALL (from the auto-detect step), dedupes, and installs
# each requested dep via the platform-native package manager.
#
# Recognised deps: nfpm, makeself, snapcraft, rpmbuild, cosign, zig,
# cargo-zigbuild, upx.
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
    anodize::detail "no dependencies requested"
    exit 0
fi

anodize::section "Dependency installation (${#DEPS[@]})"

# Batch apt installs for efficiency (one apt-get install call instead of N)
APT_PKGS=()
APT_NAMES=()
apt_queue() {
    APT_PKGS+=("$1")
    APT_NAMES+=("$2")
    anodize::detail "${2} queued for batch apt install"
}
apt_flush() {
    [ "${#APT_PKGS[@]}" -eq 0 ] && return
    anodize::verb Installing "apt batch: ${APT_NAMES[*]}"
    if ! sudo apt-get install -yq "${APT_PKGS[@]}"; then
        anodize::err "apt batch install failed for: ${APT_NAMES[*]}"
        exit 1
    fi
    for name in "${APT_NAMES[@]}"; do
        anodize::ok "${name} installed"
    done
    APT_PKGS=()
    APT_NAMES=()
}

install_nfpm() {
    case "$RUNNER_OS" in
        Linux)
            echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' | sudo tee /etc/apt/sources.list.d/goreleaser.list > /dev/null
            sudo apt-get update -q
            sudo apt-get install -yq nfpm
            ;;
        macOS)   brew install goreleaser/tap/nfpm ;;
        Windows) choco install nfpm -y --no-progress ;;
    esac
}

install_makeself() {
    case "$RUNNER_OS" in
        Linux)   apt_queue makeself makeself ;;
        macOS)   brew install makeself ;;
        Windows)
            echo "::warning::makeself is not natively supported on Windows; skipping"
            anodize::warn "makeself is not natively supported on Windows; skipping"
            ;;
    esac
}

install_snapcraft() {
    case "$RUNNER_OS" in
        Linux)   sudo snap install snapcraft --classic ;;
        macOS)   brew install snapcraft ;;
        Windows)
            echo "::warning::snapcraft is not natively supported on Windows; skipping"
            anodize::warn "snapcraft is not natively supported on Windows; skipping"
            ;;
    esac
}

install_rpmbuild() {
    case "$RUNNER_OS" in
        Linux)   apt_queue rpm rpmbuild ;;
        macOS)   brew install rpm ;;
        Windows)
            echo "::warning::rpmbuild is not natively supported on Windows; skipping"
            anodize::warn "rpmbuild is not natively supported on Windows; skipping"
            ;;
    esac
}

install_cosign() {
    case "$RUNNER_OS" in
        Linux)
            curl -sSfL https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 -o /tmp/cosign
            sudo install /tmp/cosign /usr/local/bin/cosign
            ;;
        macOS)   brew install cosign ;;
        Windows) choco install cosign -y --no-progress ;;
    esac
}

install_zig() {
    case "$RUNNER_OS" in
        Linux)
            curl -sSfL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz -o /tmp/zig.tar.xz
            sudo mkdir -p /opt/zig
            sudo tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
            sudo ln -sf /opt/zig/zig /usr/local/bin/zig
            ;;
        macOS)   brew install zig ;;
        Windows) choco install zig -y --no-progress ;;
    esac
}

install_cargo_zigbuild() {
    if ! command -v cargo > /dev/null 2>&1; then
        echo "::error::cargo-zigbuild requires Rust; set install-rust: true"
        anodize::err "cargo-zigbuild requires Rust; set install-rust: true"
        exit 1
    fi
    cargo install --locked cargo-zigbuild
}

install_upx() {
    case "$RUNNER_OS" in
        Linux)   apt_queue upx upx ;;
        macOS)   brew install upx ;;
        Windows) choco install upx -y --no-progress ;;
    esac
}

for dep in "${DEPS[@]}"; do
    anodize::verb Installing "${dep}"
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
        *)
            echo "::error::Unknown dependency: $dep (supported: nfpm, makeself, snapcraft, rpmbuild, cosign, zig, cargo-zigbuild, upx)"
            anodize::err "unknown dependency: $dep"
            exit 1
            ;;
    esac
    # Only print "installed" for deps that ran immediately (not apt-queued).
    [ "${#APT_PKGS[@]}" -eq "$pre_queue" ] && anodize::ok "${dep} installed"
done

# Flush any batched apt packages (makeself, rpm, upx queued above).
# apt_flush prints its own success messages per package.
apt_flush
