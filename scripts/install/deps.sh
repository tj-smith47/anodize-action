#!/usr/bin/env bash
# Install anodizer pipeline dependencies via the platform-native package manager.
#
# Merges $EXPLICIT_INSTALL, $AUTO_INSTALL, and $DETERMINISM_INSTALL (comma-
# separated lists), dedupes, and installs each requested dep.
#
# Recognised deps: nfpm, makeself, snapcraft, rpmbuild, cosign, syft, zig,
# cargo-zigbuild, upx, nsis, create-dmg, flatpak, alejandra, linuxdeploy,
# rcodesign, wix.
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

# linuxdeploy + its appimage output plugin ship only a rolling `continuous`
# release (no version tags, no checksums sidecar), so the pinned shas below
# are keyed to the asset bytes served at pin time — verified against the
# GitHub releases API `digest` field AND a download-and-sha256 of each asset.
# Override with LINUXDEPLOY_VERSION + the four matching *_SHA_* env vars (all
# required together) to pull a different snapshot; an override without its own
# shas is rejected, mirroring the alejandra pin.
LINUXDEPLOY_DEFAULT_VERSION="continuous"
LINUXDEPLOY_DEFAULT_SHA_AMD64="514d4ffe2a2f757369b41863a4f63fbbb222c429652803ebc081cb16ba21ac25"
LINUXDEPLOY_DEFAULT_SHA_ARM64="6d2f140cc8c3b07831b1011922ed453b34f7e90d21a4bfbc65e1ec99ca71b8f3"
LINUXDEPLOY_PLUGIN_DEFAULT_SHA_AMD64="c603eb063609daa2cc953cfcf6e117cea13fa00c8bfcbbfa5efa88a205adc424"
LINUXDEPLOY_PLUGIN_DEFAULT_SHA_ARM64="a8b267f2511389235729028590542c76f7212da8cf2b045b37fbe829b0e0c843"

# rcodesign (the apple-codesign project, indygreg/apple-platform-rs) drives
# anodizer's cross-platform `notarize.macos:` path. Release tarballs are named
# `apple-codesign-<ver>-<triple>.tar.gz` and carry the `rcodesign` binary one
# directory deep (verified by `tar -tzf`). Upstream ships NO checksums file, so
# the shas below were computed by download-and-sha256sum of each pinned asset.
# Override with RCODESIGN_VERSION + the matching *_SHA_* env vars (all required
# together — an override without its own shas is rejected, mirroring the
# alejandra/linuxdeploy pins).
RCODESIGN_DEFAULT_VERSION="0.29.0"
RCODESIGN_DEFAULT_SHA_LINUX_AMD64="dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002"
RCODESIGN_DEFAULT_SHA_LINUX_ARM64="4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f"
RCODESIGN_DEFAULT_SHA_MACOS_AMD64="14ef11bedd51a8d95eafd767939ae96d5900e5a61511bef75bb21db6e7c74140"
RCODESIGN_DEFAULT_SHA_MACOS_ARM64="d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a"

# WiX v4 is anodizer's default MSI toolchain (`wix build`); the CLI is the
# `wix` dotnet global tool. Pinned for reproducibility — override with
# WIX_VERSION. dotnet (the host for the global tool) is preinstalled on the
# GitHub windows runner images.
WIX_DEFAULT_VERSION="4.0.6"

# snapcraft's PyPI releases stopped at 4.8.1 (June 2021 — pre-dates
# SNAPCRAFT_STORE_CREDENTIALS), so the no-snapd fallback installs from the
# upstream git tag instead, constrained to that tag's own uv.lock. The pin
# tracks the snap store's latest/stable channel so a pip-installed snapcraft
# matches the version a snapd-equipped runner gets from
# `snap install snapcraft`. Override with SNAPCRAFT_VERSION (also honoured
# by the macOS brew path).
SNAPCRAFT_DEFAULT_VERSION="8.14.5"

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
    anodizer::step "installing apt batch: ${APT_NAMES[*]}"
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

# Convert a uv.lock (`$1`) into `name==version` pip constraint lines on
# stdout. Skips non-registry packages (the project itself) and names whose
# lock holds conflicting versions across dependency-group forks (dev/docs
# only in snapcraft's lock) — pip rejects conflicting duplicate constraints,
# and every runtime dependency resolves to a single locked version.
snapcraft_lock_to_constraints() {
    python3 - "$1" <<'PYEOF'
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("python >= 3.11 (tomllib) required to derive pip constraints from uv.lock\n")
    sys.exit(1)

with open(sys.argv[1], "rb") as f:
    lock = tomllib.load(f)
versions = {}
for pkg in lock["package"]:
    if "registry" not in pkg.get("source", {}):
        continue
    versions.setdefault(pkg["name"], set()).add(pkg["version"])
for name in sorted(versions):
    if len(versions[name]) == 1:
        print(f"{name}=={versions[name].pop()}")
PYEOF
}

# Containerised runners (e.g. ARC pods) have no snapd — snapd cannot run
# inside a container — so `snap install snapcraft` is impossible there. A
# pip install covers the publish-only case: `snapcraft upload` needs just
# the CLI + SNAPCRAFT_STORE_CREDENTIALS, no snapd/lxd/multipass (the .snap
# itself is packed on a snapd-equipped runner). PyPI's snapcraft is
# abandoned at 4.8.1, so the install pulls the upstream git tag, with the
# tag's uv.lock as a pip constraints file — an unconstrained resolve picks
# a newer craft-application whose lifecycle-command API breaks snapcraft at
# import time.
snapcraft_install_linux_pip() {
    local version="${SNAPCRAFT_VERSION:-$SNAPCRAFT_DEFAULT_VERSION}"
    command -v python3 > /dev/null 2>&1 \
        || gha_fail "snapcraft: no snapd and no python3 on this runner — preinstall snapcraft in the runner image, or provide python3 + pip for the pip fallback"
    command -v git > /dev/null 2>&1 \
        || gha_fail "snapcraft: the pip fallback installs from a git tag and requires git on PATH"
    local -a apt_needs=()
    command -v pipx > /dev/null 2>&1 || python3 -m pip --version > /dev/null 2>&1 \
        || apt_needs+=(python3-pip)
    # snapcraft imports the distro's apt bindings at startup on Linux
    # (snapcraft_legacy's repo module does `import apt` unconditionally).
    # python-apt is not pip-installable from PyPI, so it must come from the
    # system package manager and stay visible to the snapcraft install —
    # hence --user / --system-site-packages below rather than an isolated
    # venv.
    python3 -c 'import apt' > /dev/null 2>&1 \
        || apt_needs+=(python3-apt)
    if [ "${#apt_needs[@]}" -gt 0 ]; then
        command -v apt-get > /dev/null 2>&1 \
            || gha_fail "snapcraft: no snapd, and the pip fallback needs ${apt_needs[*]} (no apt-get available to install them) — preinstall snapcraft in the runner image"
        anodizer::detail "installing ${apt_needs[*]} via apt for the pip fallback"
        sudo apt-get update -q \
            || gha_fail "snapcraft: apt-get update failed"
        sudo apt-get install -yq "${apt_needs[@]}" \
            || gha_fail "snapcraft: apt install of ${apt_needs[*]} failed — preinstall snapcraft (or these packages) in the runner image"
    fi

    local workdir="${RUNNER_TEMP:-/tmp}/snapcraft-pip"
    mkdir -p "$workdir"
    curl -sSfL "https://raw.githubusercontent.com/canonical/snapcraft/${version}/uv.lock" \
        -o "${workdir}/uv.lock" \
        || gha_fail "snapcraft: failed to fetch uv.lock for tag ${version} — does the tag exist upstream?"
    snapcraft_lock_to_constraints "${workdir}/uv.lock" > "${workdir}/constraints.txt" \
        || gha_fail "snapcraft: could not derive pip constraints from uv.lock for ${version}"
    # An empty constraints file silently degrades to an unconstrained
    # resolve — the exact failure mode the lock exists to prevent.
    [ -s "${workdir}/constraints.txt" ] \
        || gha_fail "snapcraft: uv.lock for ${version} yielded no constraints — lock schema changed?"

    local spec="git+https://github.com/canonical/snapcraft@${version}"
    if command -v pipx > /dev/null 2>&1; then
        # PIP_CONSTRAINT reaches the pip inside pipx's venv, constraining
        # the whole dependency resolve (--pip-args would not).
        # --system-site-packages keeps the distro's python-apt visible —
        # an isolated venv breaks snapcraft at import.
        PIP_CONSTRAINT="${workdir}/constraints.txt" \
            pipx install --system-site-packages "$spec" \
            || gha_fail "snapcraft: pipx install failed for ${spec}"
    else
        local -a pip_args=(--user)
        # PEP 668: Ubuntu >= 24.04 marks the system interpreter
        # externally-managed; --user installs need the explicit opt-out.
        local stdlib
        stdlib=$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')
        [ -f "${stdlib}/EXTERNALLY-MANAGED" ] && pip_args+=(--break-system-packages)
        python3 -m pip install "${pip_args[@]}" --quiet \
            --constraint "${workdir}/constraints.txt" "$spec" \
            || gha_fail "snapcraft: pip install failed for ${spec}"
    fi
    # Both pipx and pip --user land console scripts in ~/.local/bin; expose
    # it to later workflow steps AND to this shell for the probe below.
    gha_add_path "${HOME}/.local/bin"
    export PATH="${HOME}/.local/bin:${PATH}"
    # Run the CLI, don't just stat it — a missing runtime module (e.g.
    # python-apt outside the venv) only surfaces at import time.
    local probe
    probe=$(snapcraft version 2>&1) \
        || gha_fail "snapcraft: installed but 'snapcraft version' failed — ${probe}"
    anodizer::ok "snapcraft ${version} installed via pip (upload-capable; packing snaps still needs a snapd-equipped runner)"
}

install_snapcraft() {
    case "$RUNNER_OS" in
        Linux)
            # Run the CLI rather than stat it: a broken preinstall (e.g. a
            # venv missing python-apt) must fall through to a fresh install,
            # not pass here and die later at upload.
            if snapcraft version > /dev/null 2>&1; then
                anodizer::detail "snapcraft already present ($(command -v snapcraft))"
                return
            fi
            # `snap version` succeeds only when the client can reach a live
            # snapd socket; a bare `command -v snap` would wrongly take the
            # snap path in containers that ship the client without snapd.
            if command -v snap > /dev/null 2>&1 && snap version > /dev/null 2>&1; then
                sudo snap install snapcraft --classic
            else
                snapcraft_install_linux_pip
            fi
            ;;
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

# linuxdeploy drives anodizer's `appimages:` stage. It is itself an AppImage,
# as is the appimage output plugin it needs to emit a `.AppImage` (anodizer
# invokes `linuxdeploy --output appimage`, which is a no-op without
# linuxdeploy-plugin-appimage on PATH). Both are installed side by side into
# one PATH dir.
#
# CI runners frequently lack FUSE (no /dev/fuse), so an AppImage can't
# self-mount. APPIMAGE_EXTRACT_AND_RUN=1 is linuxdeploy's documented escape
# hatch: each AppImage extracts itself to a temp dir and runs from there
# instead of FUSE-mounting. It is exported into $GITHUB_ENV so anodizer's
# stage sees it when it later spawns linuxdeploy, and the plugin is named
# `linuxdeploy-plugin-appimage` (no extension) so linuxdeploy's plugin
# discovery finds it on PATH.
install_linuxdeploy() {
    case "$RUNNER_OS" in
        Linux)
            local version="${LINUXDEPLOY_VERSION:-$LINUXDEPLOY_DEFAULT_VERSION}"
            local arch ld_sha plugin_sha
            case "$RUNNER_ARCH" in
                X64)   arch=x86_64;  ld_sha="$LINUXDEPLOY_DEFAULT_SHA_AMD64"; plugin_sha="$LINUXDEPLOY_PLUGIN_DEFAULT_SHA_AMD64" ;;
                ARM64) arch=aarch64; ld_sha="$LINUXDEPLOY_DEFAULT_SHA_ARM64"; plugin_sha="$LINUXDEPLOY_PLUGIN_DEFAULT_SHA_ARM64" ;;
                *)     gha_fail "Unsupported Linux arch for linuxdeploy: $RUNNER_ARCH" ;;
            esac
            if [ "$version" != "$LINUXDEPLOY_DEFAULT_VERSION" ]; then
                # The `continuous` release rolls its assets in place, so a
                # version override MUST carry its own shas — refusing
                # unverified installs (no upstream checksums file exists).
                ld_sha="${LINUXDEPLOY_SHA256:-}"
                plugin_sha="${LINUXDEPLOY_PLUGIN_SHA256:-}"
                { [ -n "$ld_sha" ] && [ -n "$plugin_sha" ]; } \
                    || gha_fail "LINUXDEPLOY_VERSION=$version requires LINUXDEPLOY_SHA256 and LINUXDEPLOY_PLUGIN_SHA256 (upstream publishes no checksums file)"
            fi

            local install_dir="${RUNNER_TEMP:-/tmp}/linuxdeploy"
            mkdir -p "$install_dir"

            local ld_url="https://github.com/linuxdeploy/linuxdeploy/releases/download/${version}/linuxdeploy-${arch}.AppImage"
            curl -sSfL "$ld_url" -o "${install_dir}/linuxdeploy"
            echo "${ld_sha}  ${install_dir}/linuxdeploy" | sha256sum -c -
            chmod +x "${install_dir}/linuxdeploy"

            local plugin_url="https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/${version}/linuxdeploy-plugin-appimage-${arch}.AppImage"
            curl -sSfL "$plugin_url" -o "${install_dir}/linuxdeploy-plugin-appimage"
            echo "${plugin_sha}  ${install_dir}/linuxdeploy-plugin-appimage" | sha256sum -c -
            chmod +x "${install_dir}/linuxdeploy-plugin-appimage"

            gha_add_path "$install_dir"
            # Persist for the later `anodizer release` step (which spawns
            # linuxdeploy itself) — $GITHUB_ENV survives across steps; a bare
            # `export` would not.
            gha_set_env APPIMAGE_EXTRACT_AND_RUN 1
            anodizer::ok "linuxdeploy + appimage plugin (${version}/${arch}) installed at ${install_dir}"
            ;;
        macOS|Windows) skip_unsupported_os linuxdeploy "Linux-only (appimages: config requires a Linux runner)" ;;
    esac
}

# rcodesign (apple-codesign) drives anodizer's cross-platform
# `notarize.macos:` path (`rcodesign sign` / `rcodesign notary-submit`). It runs
# on Linux, macOS, and Windows, so this installs a pinned, sha-verified release
# binary on each. The tarball carries `rcodesign` one directory deep, so
# `tar --strip-components=1` lands the bare binary; macOS uses the
# `macos-universal`-equivalent per-arch tarballs (x86_64 / aarch64 darwin).
# Windows has no clean musl/release-binary story here (upstream ships a
# *-pc-windows-msvc.zip, not a tarball), so the Windows arm falls back to
# `cargo install apple-codesign --locked` — a Rust toolchain is available in
# the action via install-rust (the cross-platform notarize path is the only
# notarize mode usable on a Windows runner anyway). Override the pinned binary
# with RCODESIGN_VERSION + the matching *_SHA_* env vars (all required
# together).
install_rcodesign() {
    case "$RUNNER_OS" in
        Linux|macOS)
            local version="${RCODESIGN_VERSION:-$RCODESIGN_DEFAULT_VERSION}"
            local triple sha
            case "${RUNNER_OS}:${RUNNER_ARCH}" in
                Linux:X64)    triple="x86_64-unknown-linux-musl"; sha="$RCODESIGN_DEFAULT_SHA_LINUX_AMD64" ;;
                Linux:ARM64)  triple="aarch64-unknown-linux-musl"; sha="$RCODESIGN_DEFAULT_SHA_LINUX_ARM64" ;;
                macOS:X64)    triple="x86_64-apple-darwin";  sha="$RCODESIGN_DEFAULT_SHA_MACOS_AMD64" ;;
                macOS:ARM64)  triple="aarch64-apple-darwin"; sha="$RCODESIGN_DEFAULT_SHA_MACOS_ARM64" ;;
                *) gha_fail "Unsupported ${RUNNER_OS} arch for rcodesign: $RUNNER_ARCH" ;;
            esac
            if [ "$version" != "$RCODESIGN_DEFAULT_VERSION" ]; then
                # Upstream publishes no checksums file, so a version override
                # MUST come with its own sha — refusing unverified installs.
                local override_sha="${RCODESIGN_SHA256:-}"
                [ -n "$override_sha" ] \
                    || gha_fail "RCODESIGN_VERSION=$version requires RCODESIGN_SHA256 (upstream publishes no checksums file)"
                sha="$override_sha"
            fi

            local install_dir="${RUNNER_TEMP:-/tmp}/rcodesign"
            mkdir -p "$install_dir"
            local tarball="apple-codesign-${version}-${triple}.tar.gz"
            # The release tag is URL-encoded (`apple-codesign/<ver>` → `%2F`).
            local url="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F${version}/${tarball}"
            curl -sSfL "$url" -o "${install_dir}/${tarball}"
            echo "${sha}  ${install_dir}/${tarball}" | sha256sum -c -
            # `rcodesign` sits one dir deep (apple-codesign-<ver>-<triple>/rcodesign);
            # strip the leading component and extract only the binary.
            tar -xzf "${install_dir}/${tarball}" -C "$install_dir" --strip-components=1 \
                "apple-codesign-${version}-${triple}/rcodesign"
            chmod +x "${install_dir}/rcodesign"
            gha_add_path "$install_dir"
            anodizer::ok "rcodesign ${version} (${triple}) installed at ${install_dir}/rcodesign"
            ;;
        Windows)
            # No clean release tarball for Windows (upstream ships a
            # *-pc-windows-msvc.zip), so build from crates.io via the action's
            # Rust toolchain. The cross-platform notarize.macos path is the only
            # notarize mode usable on a Windows runner.
            command -v cargo > /dev/null 2>&1 \
                || gha_fail "rcodesign on Windows requires Rust; set install-rust: true"
            local version="${RCODESIGN_VERSION:-$RCODESIGN_DEFAULT_VERSION}"
            cargo install apple-codesign --locked --version "$version"
            ;;
    esac
}

# WiX drives anodizer's `msis:` stage (crates/stage-msi — v4 `wix build`). The
# v4 CLI is the `wix` dotnet global tool, installed via the dotnet SDK that is
# preinstalled on the GitHub windows runner images. dotnet global tools land in
# `%USERPROFILE%\.dotnet\tools`, which the dotnet installer adds to PATH on the
# hosted images; we add it explicitly so a fresh shell in the same job sees it.
# Pin the version with WIX_VERSION (default tracks WiX v4, anodizer's default).
install_wix() {
    case "$RUNNER_OS" in
        Windows)
            local version="${WIX_VERSION:-$WIX_DEFAULT_VERSION}"
            dotnet tool install --global wix --version "$version" \
                || gha_fail "dotnet tool install wix@${version} failed"
            # dotnet global tools install to $HOME/.dotnet/tools; surface it on
            # PATH for later steps in case the image's default PATH lacks it.
            gha_add_path "${USERPROFILE:-$HOME}/.dotnet/tools"
            anodizer::ok "wix ${version} installed via dotnet global tool"
            ;;
        Linux|macOS) skip_unsupported_os wix "Windows-only (msis: config requires a Windows runner)" ;;
    esac
}

# ── dispatch ─────────────────────────────────────────────────────────

dispatch_install() {
    local dep pre_queue
    for dep in "${DEPS[@]}"; do
        anodizer::step "installing ${dep}"
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
            linuxdeploy)    install_linuxdeploy ;;
            rcodesign)      install_rcodesign ;;
            wix)            install_wix ;;
            *) gha_fail "Unknown dependency: $dep (supported: nfpm, makeself, snapcraft, rpmbuild, cosign, syft, zig, cargo-zigbuild, upx, nsis, create-dmg, flatpak, alejandra, linuxdeploy, rcodesign, wix)" ;;
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

    anodizer::verb Installing "${#DEPS[@]} dependencies"
    dispatch_install
    apt_flush
}

# Source-safe: only run `main` when executed directly. Lets tests source
# this file to exercise individual installer helpers without the dispatch
# loop firing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
