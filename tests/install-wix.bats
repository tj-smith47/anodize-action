#!/usr/bin/env bats
# install-wix.bats — unit tests for the WiX installer in
# scripts/install/deps.sh AND the msis: auto-detect wiring in
# scripts/install/auto-detect-deps.sh.
#
# WiX drives anodizer's `msis:` stage (crates/stage-msi). On Windows the v4 CLI
# is the `wix` dotnet global tool; WiX itself is Windows-only and EULA-gated, so
# on Linux the stage uses `wixl` (msitools, apt) from the v3-dialect .wxs. macOS
# has no MSI path and is skipped (warn, don't fail).
#
# Stubs dotnet so no network is needed. Covers:
#
#   1. Windows → `dotnet tool install --global wix --version <pin>` runs,
#      tools dir added to PATH, exits 0
#   2. WIX_VERSION override → forwarded to --version
#   3. Linux → queues the wixl apt package, exits 0
#   4. macOS → skipped (no MSI path), exits 0
#   5. auto-detect: msis: config on Windows AND Linux emits the wix dep
#   6. auto-detect: msis: config on macOS warns + omits it

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

# ── Test 3: Linux queues wixl (msitools) — the Linux MSI path ─────────────

@test "wix: Linux queues the wixl apt package, exits 0" {
    _run_install_wix RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wixl queued for batch apt install"* ]]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 4: macOS has no MSI path and is skipped ──────────────────────────

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

@test "auto-detect: msis: config on Linux emits the wix dep (wixl path)" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs' "Linux"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*wix' "$GITHUB_OUTPUT"
}

@test "auto-detect: msis: config on macOS warns and omits wix" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs' "macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"got macOS"* ]]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'wix' "$GITHUB_OUTPUT"
}
