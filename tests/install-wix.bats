#!/usr/bin/env bats
# install-wix.bats — unit tests for the WiX installer in
# scripts/install/deps.sh AND the msis: auto-detect wiring in
# scripts/install/auto-detect-deps.sh.
#
# WiX drives anodizer's `msis:` stage (crates/stage-msi — v4 `wix build`). The
# v4 CLI is the `wix` dotnet global tool, installed via the dotnet SDK that is
# preinstalled on the GitHub windows runner images. MSIs can only be built on a
# Windows runner, so non-Windows runners are skipped (warn, don't fail).
#
# Stubs dotnet so no network is needed. Covers:
#
#   1. Windows → `dotnet tool install --global wix --version <pin>` runs,
#      tools dir added to PATH, exits 0
#   2. WIX_VERSION override → forwarded to --version
#   3. Linux / macOS → skipped (WiX is Windows-only), exits 0
#   4. auto-detect: msis: config on Windows emits the wix dep
#   5. auto-detect: msis: config on a non-Windows runner warns + omits it

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_OUTPUT"

    # ── Stub: dotnet — echo the invocation so tests can assert on it. ─────
    cat > "${FAKE_BIN}/dotnet" <<'STUB'
#!/usr/bin/env bash
echo "dotnet $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/dotnet"
}

teardown() {
    common_teardown
}

# Source deps.sh (source-safe) and call install_wix directly.
# skip_unsupported_os is stubbed so the Linux/macOS arms can be exercised
# without their real annotation side-effects.
_run_install_wix() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_wix
        "
}

# ── Test 1: Windows → dotnet global tool install + PATH ───────────────────

@test "wix: Windows installs the wix dotnet global tool at the pinned version" {
    _run_install_wix RUNNER_OS="Windows"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dotnet tool install --global wix --version 4.0.6"* ]]
    # dotnet global tools dir surfaced on PATH for later steps.
    grep -q '.dotnet/tools' "$GITHUB_PATH"
}

# ── Test 2: WIX_VERSION override is forwarded ─────────────────────────────

@test "wix: WIX_VERSION override is forwarded to --version" {
    _run_install_wix RUNNER_OS="Windows" WIX_VERSION="5.0.2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--version 5.0.2"* ]]
}

# ── Test 3: non-Windows runners are skipped (WiX is Windows-only) ─────────

@test "wix: Linux is skipped, exits 0" {
    _run_install_wix RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}

@test "wix: macOS is skipped, exits 0" {
    _run_install_wix RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}

# ── auto-detect wiring ────────────────────────────────────────────────────

_run_auto_detect() {
    local cfg_body="$1" runner_os="$2"
    local workdir="${_TEST_HOME}/workdir"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    printf '%s\n' "$cfg_body" > "${workdir}/.anodizer.yaml"
    run env \
        GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
        NO_COLOR=1 \
        RUNNER_OS="$runner_os" \
        bash -c "cd '${workdir}' && bash '${REPO_ROOT}/scripts/install/auto-detect-deps.sh'"
}

@test "auto-detect: msis: config on Windows emits the wix dep" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs' "Windows"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*wix' "$GITHUB_OUTPUT"
}

@test "auto-detect: msis: config on Linux warns and omits wix" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs' "Linux"
    [ "$status" -eq 0 ]
    [[ "$output" == *"requires Windows runner"* ]]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'wix' "$GITHUB_OUTPUT"
}
