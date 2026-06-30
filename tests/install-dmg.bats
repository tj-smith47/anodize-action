#!/usr/bin/env bats
# install-dmg.bats — unit tests for the create-dmg installer in
# scripts/install/deps.sh.
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
#
# Config detection (dmgs: → create-dmg, incl. the genisoimage/mkisofs Linux
# fallback) now lives in `anodizer tools`; the action's binary→keyword
# translation is covered by auto-detect-deps.bats.

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_OUTPUT"

    # ── Stub: brew — record the invocation to a log AND echo it. The
    #    installer wraps brew in anodizer::run_quiet, which swallows stdout
    #    on success, so assert on the log file (a side-effect run_quiet
    #    cannot suppress), not on captured output. ──
    export BREW_LOG="${_TEST_HOME}/brew.log"
    cat > "${FAKE_BIN}/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$BREW_LOG"
echo "brew $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/brew"

    # ── Stub: sudo / apt-get — apt_flush's batched update+install runs
    #    hermetically (no real package manager, no network). ──
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/apt-get"
    chmod +x "${FAKE_BIN}/apt-get"

    # Keep run_quiet's capture file inside the sandbox.
    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"
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
        BREW_LOG="${BREW_LOG}" \
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
    grep -q "brew install create-dmg" "$BREW_LOG"
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 2: Linux → queues genisoimage (the dmg stage's Linux fallback) ────

@test "create-dmg: Linux queues the genisoimage apt package, exits 0" {
    # The per-package ✓ on flush is a verbose-only line; run under verbose so it
    # surfaces for the assertion.
    _run_install_create_dmg RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    # genisoimage rides the single batched apt install — one batch header plus a
    # per-package ✓ on flush, NOT a per-tool "queued"/"installing" line.
    [[ "$output" == *"installing apt batch: genisoimage"* ]]
    [[ "$output" == *"genisoimage installed"* ]]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 3: Windows has no .dmg path and is skipped ───────────────────────

@test "create-dmg: Windows is skipped, exits 0" {
    _run_install_create_dmg RUNNER_OS="Windows"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}
