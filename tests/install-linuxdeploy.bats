#!/usr/bin/env bats
# install-linuxdeploy.bats — unit tests for the linuxdeploy installer in
# scripts/install/deps.sh.
#
# linuxdeploy drives anodizer's `appimages:` stage; it (and the appimage
# output plugin it needs to emit a `.AppImage`) ships only as a rolling
# `continuous` AppImage release with no checksums sidecar, so the installer
# pins shas with an override-requires-its-own-sha escape hatch — same shape
# as the alejandra pin.
#
# Stubs curl, sha256sum, chmod so no network or root is needed. Covers:
#
#   1. default version on Linux x86_64 → both AppImages fetched + sha-checked,
#      placed on PATH, APPIMAGE_EXTRACT_AND_RUN exported, exits 0
#   2. LINUXDEPLOY_VERSION override missing its shas → loud fail, exits ≠0
#   3. LINUXDEPLOY_VERSION override WITH both shas → install exits 0
#   4. macOS / Windows → skipped (linuxdeploy is Linux-only), exits 0
#
# Config detection (appimages: → linuxdeploy) now lives in `anodizer tools`;
# the action's binary→keyword translation is covered by auto-detect-deps.bats.

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    # GitHub Actions sinks — gha_add_path / gha_set_env append to these.
    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_ENV="${_TEST_HOME}/github_env"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_ENV"
    : > "$GITHUB_OUTPUT"

    # Keep the installer's downloads inside the test sandbox.
    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"

    # ── Stub: curl — write deterministic placeholder content to -o target ──
    cat > "${FAKE_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
for arg; do
    case "$prev" in -o) out="$arg" ;; esac
    prev="$arg"
done
[ -n "$out" ] && printf 'appimage-bin' > "$out"
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: sha256sum -c reads "HASH  FILE" from stdin and returns 0 ─────
    cat > "${FAKE_BIN}/sha256sum" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-c"* ]]; then
    read -r line
    echo "${line##* }": OK
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/sha256sum"
}

teardown() {
    common_teardown
}

# Source scripts/install/deps.sh (source-safe — its `main "$@"` is gated on
# direct execution) so every helper is in scope, then call install_linuxdeploy
# directly. skip_unsupported_os is stubbed so the macOS/Windows arms can be
# exercised without their real annotation side-effects.
_run_install_linuxdeploy() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        GITHUB_ENV="${GITHUB_ENV}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        NO_COLOR=1 \
        RUNNER_ARCH="X64" \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_linuxdeploy
        "
}

# ── Test 1: default version on Linux x86_64 → installs both, exits 0 ───────

@test "linuxdeploy: default version installs linuxdeploy + appimage plugin on Linux x86_64" {
    _run_install_linuxdeploy RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # Both binaries landed on PATH under one install dir.
    [ -x "${RUNNER_TEMP}/linuxdeploy/linuxdeploy" ]
    [ -x "${RUNNER_TEMP}/linuxdeploy/linuxdeploy-plugin-appimage" ]
    # Install dir was added to PATH.
    grep -q "${RUNNER_TEMP}/linuxdeploy" "$GITHUB_PATH"
    # FUSE-less escape hatch exported for the later `anodizer release` step.
    grep -q '^APPIMAGE_EXTRACT_AND_RUN=1$' "$GITHUB_ENV"
}

# ── Test 2: version override missing shas → loud failure ──────────────────

@test "linuxdeploy: LINUXDEPLOY_VERSION override without shas fails loudly" {
    _run_install_linuxdeploy RUNNER_OS="Linux" LINUXDEPLOY_VERSION="9.9.9"
    [ "$status" -ne 0 ]
    [[ "$output" == *"LINUXDEPLOY_SHA256"* ]]
    [[ "$output" == *"LINUXDEPLOY_PLUGIN_SHA256"* ]]
    # Must NOT silently fall back to the pinned default shas.
    [[ "$output" != *"installed"* ]]
}

# ── Test 3: version override WITH both shas → install proceeds ─────────────

@test "linuxdeploy: LINUXDEPLOY_VERSION + both shas installs" {
    _run_install_linuxdeploy \
        RUNNER_OS="Linux" \
        LINUXDEPLOY_VERSION="9.9.9" \
        LINUXDEPLOY_SHA256="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
        LINUXDEPLOY_PLUGIN_SHA256="cafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00d"
    [ "$status" -eq 0 ]
}

# ── Test 4: non-Linux runners are skipped (linuxdeploy is Linux-only) ──────

@test "linuxdeploy: macOS is skipped, exits 0" {
    _run_install_linuxdeploy RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}

@test "linuxdeploy: Windows is skipped, exits 0" {
    _run_install_linuxdeploy RUNNER_OS="Windows"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}
