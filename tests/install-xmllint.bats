#!/usr/bin/env bats
# install-xmllint.bats — unit tests for the xmllint installer in
# scripts/install/deps.sh.
#
# xmllint backs anodizer's chocolatey prepublish guard, which hard-requires it
# to schema-validate the generated .nuspec before push. Linux gets it from the
# libxml2-utils apt package; macOS ships /usr/bin/xmllint with the OS (no
# install); Windows is skipped (the choco push is plain HTTPS — the validating
# runner in practice is Linux).
#
# Stubs apt-get so no network is needed. Covers:
#
#   1. Linux → queues the libxml2-utils apt package (display name xmllint), exits 0
#   2. macOS → no-op (ships with the OS), no package manager touched, exits 0
#   3. Windows → skipped, exits 0
#
# The binary→keyword translation (anodizer reporting `xmllint`) is covered by
# auto-detect-deps.bats.

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_OUTPUT"

    # ── Stub: sudo / apt-get — apt_flush's batched update+install runs
    #    hermetically (no real package manager, no network). apt-get records
    #    its argv so the test can assert the PACKAGE (libxml2-utils), not just
    #    the xmllint display name the batch header shows. ──
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"
    export APT_LOG="${_TEST_HOME}/apt.log"
    cat > "${FAKE_BIN}/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$APT_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/apt-get"

    # Keep run_quiet's capture file inside the sandbox.
    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"
}

teardown() {
    common_teardown
}

# Source deps.sh (source-safe) and call install_xmllint directly, then
# apt_flush so queued apt packages surface in the output. skip_unsupported_os
# is stubbed so the Windows arm can be exercised without its real side-effects.
_run_install_xmllint() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        APT_LOG="${APT_LOG}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_xmllint
            apt_flush
        "
}

# ── Test 1: Linux → queues libxml2-utils (the package shipping /usr/bin/xmllint) ──

@test "xmllint: Linux queues the libxml2-utils apt package, exits 0" {
    # The per-package ✓ on flush is a verbose-only line; run under verbose so it
    # surfaces for the assertion.
    _run_install_xmllint RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    # xmllint rides the single batched apt install — one batch header plus a
    # per-package ✓ on flush, NOT a per-tool "queued"/"installing" line.
    [[ "$output" == *"installing apt batch: xmllint"* ]]
    [[ "$output" == *"xmllint installed"* ]]
    # The installed PACKAGE is libxml2-utils, not a nonexistent "xmllint" pkg.
    grep -q "install .*libxml2-utils" "$APT_LOG"
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 2: macOS ships /usr/bin/xmllint with the OS — nothing to install ──

@test "xmllint: macOS is a no-op (ships with the OS), touches no package manager, exits 0" {
    _run_install_xmllint RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [ ! -f "$APT_LOG" ]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 3: Windows is skipped (choco push is plain HTTPS; no xmllint needed) ──

@test "xmllint: Windows is skipped, exits 0" {
    _run_install_xmllint RUNNER_OS="Windows"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [ ! -f "$APT_LOG" ]
}
