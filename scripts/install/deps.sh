#!/usr/bin/env bash
# Install anodizer pipeline dependencies via the platform-native package manager.
#
# Merges $EXPLICIT_INSTALL, $AUTO_INSTALL, and $DETERMINISM_INSTALL (comma-
# separated lists), dedupes, and installs each requested dep.
#
# Recognised deps: nfpm, makeself, snapcraft, rpmbuild, cosign, syft, zig,
# cargo-zigbuild, upx, nsis, create-dmg, flatpak, alejandra.
set -euo pipefail

# shellcheck source=../lib/gha.sh
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

: "${RUNNER_OS:?RUNNER_OS is required}"
EXPLICIT_INSTALL="${EXPLICIT_INSTALL:-}"
AUTO_INSTALL="${AUTO_INSTALL:-}"
DETERMINISM_INSTALL="${DETERMINISM_INSTALL:-}"

# Pinned defaults must be updated together — sha256 is keyed to version.
# Override with ALEJANDRA_VERSION + ALEJANDRA_SHA256 (both required) when
# pulling a different release.
ALEJANDRA_DEFAULT_VERSION="4.0.0"
ALEJANDRA_DEFAULT_SHA_AMD64="a23b9d47cba945805c6169541046de890e94e07a5aa416c86dee15bca2da6216"
ALEJANDRA_DEFAULT_SHA_ARM64="a30b0d54ee3f0d6633d0398b50258408d2cc31646a9c8c4ba3ee4ebf2cebd8c8"

DEPS=()

# ── input merge + dedupe ─────────────────────────────────────────────

merge_dep_inputs() {
    local combined="${EXPLICIT_INSTALL}" extra
    # Merge order: explicit (user) → auto-detect (.anodizer.yaml) →
    # determinism (action-derived). Dedupe collapses overlaps.
    for extra in "$AUTO_INSTALL" "$DETERMINISM_INSTALL"; do
        [ -z "$extra" ] && continue
        if [ -n "$combined" ]; then
            combined="${combined},${extra}"
        else
            combined="$extra"
        fi
    done
    echo "$combined"
}

dedupe_deps() {
    # POSIX-safe linear scan (macOS ships bash 3.2 — no associative arrays).
    local combined="$1" dep seen_list=""
    local -a raw
    IFS=',' read -ra raw <<< "$combined"
    DEPS=()
    for dep in "${raw[@]}"; do
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
}

# ── apt batching ─────────────────────────────────────────────────────

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
    sudo apt-get install -yq "${APT_PKGS[@]}" \
        || gha_fail "apt batch install failed for: ${APT_NAMES[*]}"
    local name
    for name in "${APT_NAMES[@]}"; do
        anodizer::ok "${name} installed"
    done
    APT_PKGS=()
    APT_NAMES=()
}

# ── shared installer helpers ─────────────────────────────────────────

skip_unsupported_os() {
    local tool="$1"
    local reason="${2:-not natively supported on ${RUNNER_OS}}"
    gha_warning "${tool} is ${reason}; skipping"
    anodizer::warn "${tool} is ${reason}; skipping"
}

# If `$<var>` is set, pin the brew formula to `<formula>@<version>`.
brew_install() {
    # `var` documents that $2 is the env-var name; the indirection in
    # `${!2:-}` reads its value. shellcheck cannot see the indirect use.
    # shellcheck disable=SC2034
    local formula="$1" var="$2" version="${!2:-}"
    if [ -n "$version" ]; then
        brew install "${formula}@${version}"
    else
        brew install "$formula"
    fi
}

# If `$<var>` is set, pass `--version=<version>` to choco.
choco_install() {
    # shellcheck disable=SC2034
    local pkg="$1" var="$2" version="${!2:-}"
    if [ -n "$version" ]; then
        choco install "$pkg" -y --no-progress --version="$version"
    else
        choco install "$pkg" -y --no-progress
    fi
}

# Look up `$2`'s SHA256 in a `<sha>  <filename>` checksums file (`$1`).
# Echoes the SHA; bails (with location detail) when the filename is absent.
sha_from_checksums() {
    local file="$1" name="$2" sha
    sha=$(grep " ${name}\$" "$file" | awk '{print $1}')
    [ -n "$sha" ] || gha_fail "checksum entry for ${name} not found in $(basename "$file")"
    echo "$sha"
}

# ── per-dep installers ───────────────────────────────────────────────

install_nfpm() {
    case "$RUNNER_OS" in
        Linux)
            echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' \
                | sudo tee /etc/apt/sources.list.d/goreleaser.list > /dev/null
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

cosign_install_linux() {
    local version="${COSIGN_VERSION:-v2.4.1}"
    local base="https://github.com/sigstore/cosign/releases/download/${version}"
    local bin="cosign-linux-amd64"
    curl -sSfL "${base}/${bin}" -o /tmp/cosign
    # Sigstore publishes the keyless .pem and .sig as base64-encoded files
    # (single-line, starts with `LS0tLS1CRUdJTiB...`). Decode before
    # handing to cosign — its PEM parser does not strip base64, so a raw
    # download fails verify-blob with a misleading "exactly one of: key
    # reference (--key), certificate (--cert)..." error (the cert IS
    # passed, but the file content can't be parsed).
    curl -sSfL "${base}/${bin}-keyless.pem" | base64 -d > /tmp/cosign.pem
    curl -sSfL "${base}/${bin}-keyless.sig" | base64 -d > /tmp/cosign.sig
    curl -sSfL "${base}/cosign_checksums.txt" -o /tmp/cosign_checksums.txt

    # SHA256 first — bootstraps trust without requiring cosign-to-verify-cosign.
    local expected
    expected=$(sha_from_checksums /tmp/cosign_checksums.txt "$bin")
    echo "${expected}  /tmp/cosign" | sha256sum -c -
    sudo install /tmp/cosign /usr/local/bin/cosign

    # Then keyless signature. Cosign releases are signed by the GCP service
    # account keyless@projectsigstore.iam.gserviceaccount.com via Google
    # OIDC (not GitHub Actions OIDC). See
    # https://docs.sigstore.dev/cosign/system_config/installation/
    if [ "${ANODIZER_ACTION_SKIP_COSIGN_VERIFY:-}" = "1" ]; then
        gha_warning "cosign keyless signature verification skipped at user request (ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1); SHA256-only validation was performed"
        anodizer::warn "cosign keyless signature verification skipped by user (SHA256-only, not signature-verified)"
        return
    fi
    # Strip COSIGN_KEY / COSIGN_PUB_KEY from the verify-blob env: the
    # caller (e.g. anodizer's release workflow) sets COSIGN_KEY at step
    # level for the downstream signing pipeline, but cosign auto-binds
    # COSIGN_KEY → --key. With --certificate also set, cosign's NOf(KeyRef,
    # Sk, CertRef) check rejects the call with a misleading "exactly one
    # of --key/--cert/--sk must be provided" error before the cert file
    # is even parsed.
    env -u COSIGN_KEY -u COSIGN_PUB_KEY cosign verify-blob \
        --certificate /tmp/cosign.pem \
        --signature /tmp/cosign.sig \
        --certificate-identity keyless@projectsigstore.iam.gserviceaccount.com \
        --certificate-oidc-issuer https://accounts.google.com \
        /tmp/cosign \
        || gha_fail "cosign keyless signature verification FAILED — refusing to install unverified binary"
    anodizer::ok "cosign keyless signature verified"
}

cosign_install_windows() {
    # Chocolatey ships cosign 1.3.1, which pre-dates several flags
    # anodizer's sign blocks rely on (`--bundle`, `--output-key-prefix`).
    # Direct download from the sigstore release page gets us 2.x cleanly.
    # SHA256 verification mirrors the Linux path.
    local version="${COSIGN_VERSION:-v2.4.1}"
    local base="https://github.com/sigstore/cosign/releases/download/${version}"
    local bin="cosign-windows-amd64.exe"
    local install_dir="${RUNNER_TEMP:-/tmp}/cosign"
    mkdir -p "$install_dir"
    curl -sSfL "${base}/${bin}" -o "${install_dir}/cosign.exe"
    curl -sSfL "${base}/cosign_checksums.txt" -o "${install_dir}/cosign_checksums.txt"

    local expected actual
    expected=$(sha_from_checksums "${install_dir}/cosign_checksums.txt" "$bin")
    # `cd` into the install dir so sha256sum sees a bare filename; passing
    # a Windows-style path (with backslashes) triggers sha256sum's
    # GNU-coreutils escape format which prepends `\` to the hash and
    # breaks string equality below.
    actual=$(cd "$install_dir" && sha256sum cosign.exe | awk '{print $1}')
    [ "$expected" = "$actual" ] \
        || gha_fail "cosign SHA256 mismatch (expected ${expected}, got ${actual})"

    gha_add_path "$install_dir"
    anodizer::ok "cosign ${version} installed at ${install_dir}/cosign.exe"
}

install_cosign() {
    case "$RUNNER_OS" in
        Linux)   cosign_install_linux ;;
        macOS)   brew_install cosign COSIGN_VERSION ;;
        Windows) cosign_install_windows ;;
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
                *)     gha_fail "Unsupported Linux arch for zig: $RUNNER_ARCH" ;;
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
            [ -n "$expected" ] \
                || gha_fail "zig sha256 missing from index.json for ${version}/${arch}-linux"
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
    command -v cargo > /dev/null 2>&1 \
        || gha_fail "cargo-zigbuild requires Rust; set install-rust: true"
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

install_alejandra() {
    case "$RUNNER_OS" in
        Linux)
            local version="${ALEJANDRA_VERSION:-$ALEJANDRA_DEFAULT_VERSION}"
            local arch sha
            case "$RUNNER_ARCH" in
                X64)   arch=x86_64;  sha="$ALEJANDRA_DEFAULT_SHA_AMD64" ;;
                ARM64) arch=aarch64; sha="$ALEJANDRA_DEFAULT_SHA_ARM64" ;;
                *)     gha_fail "Unsupported Linux arch for alejandra: $RUNNER_ARCH" ;;
            esac
            if [ "$version" != "$ALEJANDRA_DEFAULT_VERSION" ]; then
                # Upstream publishes no checksums file, so a version
                # override MUST come with its own sha — refusing
                # unverified installs.
                local override_sha="${ALEJANDRA_SHA256:-}"
                [ -n "$override_sha" ] \
                    || gha_fail "ALEJANDRA_VERSION=$version requires ALEJANDRA_SHA256 (upstream publishes no checksums file)"
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

# ── dispatch ─────────────────────────────────────────────────────────

dispatch_install() {
    local dep pre_queue
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
            *) gha_fail "Unknown dependency: $dep (supported: nfpm, makeself, snapcraft, rpmbuild, cosign, syft, zig, cargo-zigbuild, upx, nsis, create-dmg, flatpak, alejandra)" ;;
        esac
        # Skip the per-dep "installed" line for apt-queued items —
        # apt_flush emits one per package after the batch lands.
        [ "${#APT_PKGS[@]}" -eq "$pre_queue" ] && anodizer::ok "${dep} installed"
    done
}

main() {
    local combined
    combined=$(merge_dep_inputs)
    dedupe_deps "$combined"

    if [ "${#DEPS[@]}" -eq 0 ]; then
        anodizer::detail "no dependencies requested"
        exit 0
    fi

    anodizer::section "Dependency installation (${#DEPS[@]})"
    dispatch_install
    apt_flush
}

# Source-safe: only run `main` when executed directly. Lets tests source
# this file to exercise individual installer helpers without the dispatch
# loop firing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
