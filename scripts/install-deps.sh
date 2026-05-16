#!/usr/bin/env bash
# install-deps.sh — install anodizer pipeline dependencies.
#
# Accepts a comma-separated list from the $EXPLICIT_INSTALL env var, merges
# with $AUTO_INSTALL (from the auto-detect step), dedupes, and installs
# each requested dep via the platform-native package manager.
#
# Recognised deps: nfpm, makeself, snapcraft, rpmbuild, cosign, syft, zig,
# cargo-zigbuild, upx, nsis, create-dmg, flatpak, alejandra.
#
# Called from action.yml; expects $GITHUB_ACTION_PATH to point at the
# action root so we can source scripts/lib-colors.sh.
set -euo pipefail

# shellcheck source=./lib-colors.sh
source "${GITHUB_ACTION_PATH}/scripts/lib-colors.sh"

: "${RUNNER_OS:?RUNNER_OS is required}"
EXPLICIT_INSTALL="${EXPLICIT_INSTALL:-}"
AUTO_INSTALL="${AUTO_INSTALL:-}"
DETERMINISM_INSTALL="${DETERMINISM_INSTALL:-}"

# Merge order: explicit (user) → auto-detect (.anodizer.yaml) → determinism
# (action-derived). Dedupe pass below collapses overlaps.
combined="${EXPLICIT_INSTALL}"
for extra in "$AUTO_INSTALL" "$DETERMINISM_INSTALL"; do
    [ -z "$extra" ] && continue
    if [ -n "$combined" ]; then
        combined="${combined},${extra}"
    else
        combined="$extra"
    fi
done

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
            # Keyless signature verification.
            # Cosign releases are signed by the GCP service account
            # keyless@projectsigstore.iam.gserviceaccount.com via Google OIDC
            # (not GitHub Actions OIDC).  See:
            # https://docs.sigstore.dev/cosign/system_config/installation/
            if [ "${ANODIZER_ACTION_SKIP_COSIGN_VERIFY:-}" = "1" ]; then
                echo "::warning::cosign keyless signature verification skipped at user request (ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1); SHA256-only validation was performed"
                anodizer::warn "cosign keyless signature verification skipped by user (SHA256-only, not signature-verified)"
            else
                if ! cosign verify-blob \
                    --certificate /tmp/cosign.pem \
                    --signature /tmp/cosign.sig \
                    --certificate-identity keyless@projectsigstore.iam.gserviceaccount.com \
                    --certificate-oidc-issuer https://accounts.google.com \
                    /tmp/cosign; then
                    echo "::error::cosign keyless signature verification FAILED — refusing to install unverified binary"
                    anodizer::err "cosign keyless signature verification FAILED — refusing to install unverified binary"
                    exit 1
                fi
                anodizer::ok "cosign keyless signature verified"
            fi
            ;;
        macOS)   brew_install cosign COSIGN_VERSION ;;
        Windows) choco_install cosign COSIGN_VERSION ;;
    esac
}

install_syft() {
    case "$RUNNER_OS" in
        Linux)
            local version="${SYFT_VERSION:-v1.18.0}"
            curl -sSfL "https://raw.githubusercontent.com/anchore/syft/main/install.sh" \
                -o /tmp/syft-install.sh
            chmod +x /tmp/syft-install.sh
            sudo /tmp/syft-install.sh -b /usr/local/bin "${version}"
            ;;
        macOS)   brew_install syft SYFT_VERSION ;;
        Windows) choco_install syft SYFT_VERSION ;;
    esac
}

install_zig() {
    case "$RUNNER_OS" in
        Linux)
            local version="${ZIG_VERSION:-0.13.0}"
            local arch
            case "$RUNNER_ARCH" in
                X64)   arch=x86_64 ;;
                ARM64) arch=aarch64 ;;
                *)
                    echo "::error::Unsupported Linux arch for zig: $RUNNER_ARCH"
                    anodizer::err "Unsupported Linux arch for zig: $RUNNER_ARCH"
                    exit 1
                    ;;
            esac
            local tarball="zig-linux-${arch}-${version}.tar.xz"
            local base="https://ziglang.org/download/${version}"
            # ziglang.org does not publish per-tarball .sha256 sidecars;
            # canonical shasums live in download/index.json.
            curl -sSfL "${base}/${tarball}" -o /tmp/zig.tar.xz
            local expected
            expected=$(curl -sSfL "https://ziglang.org/download/index.json" \
                | jq -r --arg v "$version" --arg k "${arch}-linux" \
                    '.[$v][$k].shasum // empty')
            if [ -z "$expected" ]; then
                echo "::error::zig sha256 missing from index.json for ${version}/${arch}-linux"
                anodizer::err "zig sha256 missing from index.json for ${version}/${arch}-linux"
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

# Pinned defaults below MUST be updated together — sha256 is keyed to version.
# Override with ALEJANDRA_VERSION + ALEJANDRA_SHA256 (both required) when
# pulling a different release.
ALEJANDRA_DEFAULT_VERSION="4.0.0"
ALEJANDRA_DEFAULT_SHA_AMD64="a23b9d47cba945805c6169541046de890e94e07a5aa416c86dee15bca2da6216"
ALEJANDRA_DEFAULT_SHA_ARM64="a30b0d54ee3f0d6633d0398b50258408d2cc31646a9c8c4ba3ee4ebf2cebd8c8"

install_alejandra() {
    case "$RUNNER_OS" in
        Linux)
            local version="${ALEJANDRA_VERSION:-$ALEJANDRA_DEFAULT_VERSION}"
            local arch sha
            case "$RUNNER_ARCH" in
                X64)   arch=x86_64;  sha="$ALEJANDRA_DEFAULT_SHA_AMD64" ;;
                ARM64) arch=aarch64; sha="$ALEJANDRA_DEFAULT_SHA_ARM64" ;;
                *)
                    echo "::error::Unsupported Linux arch for alejandra: $RUNNER_ARCH"
                    anodizer::err "Unsupported Linux arch for alejandra: $RUNNER_ARCH"
                    exit 1
                    ;;
            esac
            if [ "$version" != "$ALEJANDRA_DEFAULT_VERSION" ]; then
                # Upstream publishes no checksums file, so a version override
                # MUST come with its own sha — refusing unverified installs.
                local override_sha="${ALEJANDRA_SHA256:-}"
                if [ -z "$override_sha" ]; then
                    echo "::error::ALEJANDRA_VERSION=$version requires ALEJANDRA_SHA256 (upstream publishes no checksums file)"
                    anodizer::err "ALEJANDRA_VERSION=$version requires ALEJANDRA_SHA256"
                    exit 1
                fi
                sha="$override_sha"
            fi
            local bin="alejandra-${arch}-unknown-linux-musl"
            curl -sSfL "https://github.com/kamadorueda/alejandra/releases/download/${version}/${bin}" -o /tmp/alejandra
            echo "${sha}  /tmp/alejandra" | sha256sum -c -
            sudo install -m 0755 /tmp/alejandra /usr/local/bin/alejandra
            rm -f /tmp/alejandra
            ;;
        macOS)   brew_install alejandra ALEJANDRA_VERSION ;;
        Windows) skip_unsupported_os alejandra "Linux/macOS only (nix publisher targets Unix runners)" ;;
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
        syft)           install_syft ;;
        zig)            install_zig ;;
        cargo-zigbuild) install_cargo_zigbuild ;;
        upx)            install_upx ;;
        nsis)           install_nsis ;;
        create-dmg)     install_create_dmg ;;
        flatpak)        install_flatpak ;;
        alejandra)      install_alejandra ;;
        *)
            echo "::error::Unknown dependency: $dep (supported: nfpm, makeself, snapcraft, rpmbuild, cosign, syft, zig, cargo-zigbuild, upx, nsis, create-dmg, flatpak, alejandra)"
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
