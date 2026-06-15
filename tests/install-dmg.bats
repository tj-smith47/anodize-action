#!/usr/bin/env bats
# install-dmg.bats — unit tests for the create-dmg installer in
# scripts/install/deps.sh AND the dmgs: auto-detect wiring in
# scripts/install/auto-detect-deps.sh.
#
# The dmg installer feeds anodizer's `dmgs:` stage (crates/stage-dmg). That
# stage prefers macOS-native `hdiutil`, then falls back to `genisoimage`, then
# `mkisofs` on Linux — so the Linux runner needs `genisoimage` (apt). macOS
# installs `create-dmg` (brew). Windows has no .dmg path and is skipped (warn,
# don't fail).
#
# Stubs brew so no network is needed. Covers:
#
#   1. macOS → `brew install create-dmg`, exits 0
#   2. Linux → queues the genisoimage apt package, exits 0
#   3. Windows → skipped (no .dmg path), exits 0
#   4. auto-detect: dmgs: config on macOS/Linux emits the create-dmg dep
#   5. auto-detect: dmgs: config on Windows warns + omits it (no .dmg path on
#      Windows), like pkgs

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_OUTPUT"

    # ── Stub: brew — echo the invocation so tests can assert on it. ──
    cat > "${FAKE_BIN}/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/brew"
}

teardown() {
    common_teardown
}

# Source deps.sh (source-safe) and call install_create_dmg directly, then
# apt_flush so queued apt packages surface in the output. skip_unsupported_os
# is stubbed so the Windows arm can be exercised without its real side-effects.
_run_install_create_dmg() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_create_dmg
            apt_flush
        "
}

# ── Test 1: macOS → brew install create-dmg ───────────────────────────────

@test "create-dmg: macOS installs create-dmg via brew, exits 0" {
    _run_install_create_dmg RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"brew install create-dmg"* ]]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 2: Linux → queues genisoimage (the dmg stage's Linux fallback) ────

@test "create-dmg: Linux queues the genisoimage apt package, exits 0" {
    _run_install_create_dmg RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    [[ "$output" == *"genisoimage queued for batch apt install"* ]]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 3: Windows has no .dmg path and is skipped ───────────────────────

@test "create-dmg: Windows is skipped, exits 0" {
    _run_install_create_dmg RUNNER_OS="Windows"
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

@test "auto-detect: dmgs: config on macOS emits the create-dmg dep" {
    _run_auto_detect $'dmgs:\n  - name: app' "macOS"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*create-dmg' "$GITHUB_OUTPUT"
}

@test "auto-detect: dmgs: config on Linux emits the create-dmg dep (genisoimage path)" {
    _run_auto_detect $'dmgs:\n  - name: app' "Linux"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*create-dmg' "$GITHUB_OUTPUT"
}

@test "auto-detect: dmgs: config on Windows warns and omits create-dmg" {
    # No .dmg build path on Windows (needs hdiutil or genisoimage), so the dep
    # is warned-and-omitted rather than emitted, like pkgs.
    _run_auto_detect $'dmgs:\n  - name: app' "Windows"
    [ "$status" -eq 0 ]
    [[ "$output" == *"got Windows"* ]]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'create-dmg' "$GITHUB_OUTPUT"
}
