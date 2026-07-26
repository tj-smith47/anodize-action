#!/usr/bin/env bats
# install-nsis.bats — unit tests for the NSIS installer in
# scripts/install/deps.sh.
#
# NSIS drives anodizer's `nsis:` (Windows installer) stage, which shells out to
# `makensis`. On Windows the choco `nsis` package installs makensis.exe into the
# NSIS ROOT (e.g. C:\Program Files (x86)\NSIS\makensis.exe — no `bin` subdir,
# unlike WiX) but drops no PATH shim, and NSIS is not pre-installed on the
# windows runner image. install_nsis must therefore discover the root and
# surface it on PATH so a later step (anodizer's determinism run) finds makensis.
# On Linux the path is apt (`nsis`); on macOS it is brew (`makensis`).
#
# Stubs choco so no network is needed. Covers:
#
#   1. Windows → choco install nsis, makensis dir appended to GITHUB_PATH
#   2. Windows fast path: `command -v makensis` resolves → its dir on PATH
#   3. Windows glob fallback: command -v/where.exe miss but
#      C:\Program Files (x86)\NSIS\makensis.exe exists → that dir on PATH
#   4. Windows not-found: warns, exits 0, no "." poison in GITHUB_PATH
#   5. Linux → queues the nsis apt package, exits 0
#   6. macOS → brew makensis, exits 0

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_OUTPUT"

    # ── Stub: choco — echo the invocation so tests can assert on it. ──────
    cat > "${FAKE_BIN}/choco" <<'STUB'
#!/usr/bin/env bash
echo "choco $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/choco"

    # ── Stub: brew — echo the invocation (used by the macOS arm). ─────────
    cat > "${FAKE_BIN}/brew" <<'STUB'
#!/usr/bin/env bash
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

# ── Test 1 + 2: Windows fast path — `command -v makensis` resolves ────────
# A fake `makensis` is placed on PATH so the root discovery resolves via
# `command -v makensis` without globbing the real filesystem.
_run_install_nsis() {
    local makensis_dir="${_TEST_HOME}/nsis-root"
    mkdir -p "$makensis_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${makensis_dir}/makensis"
    chmod +x "${makensis_dir}/makensis"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        PATH="${makensis_dir}:${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_nsis
            apt_flush
        "
}

@test "nsis: Windows installs NSIS via choco and surfaces makensis dir on PATH" {
    # ANODIZER_VERBOSE so run_quiet passes choco's argv through (it is swallowed
    # on a green run otherwise), letting the test assert the package installed.
    _run_install_nsis RUNNER_OS="Windows" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"choco install nsis"* ]]
    [[ "$output" == *"NSIS (makensis) installed"* ]]
    # makensis's containing dir (the fast `command -v` path) on PATH.
    grep -qxF "${_TEST_HOME}/nsis-root" "$GITHUB_PATH"
}

# A curated bin dir that shims every standard tool EXCEPT makensis, so a
# real host `makensis` (this build box has one in /usr/bin) cannot leak into the
# `command -v makensis` fast path and mask the where.exe / glob branches.
_curated_bin_without_makensis() {
    curated_bin "${_TEST_HOME}/curated-bin" "makensis makensis.exe"
}

# ── Test 3: where.exe returning empty must NOT poison PATH with "." ───────
# After `choco install nsis`, the choco shim may not be on the current shell's
# PATH, so `command -v makensis` misses and the code falls to `where.exe
# makensis`. When that ALSO finds nothing, `dirname ""` would yield "." —
# adding cwd to GITHUB_PATH. The fix leaves $nsisdir empty so the glob runs (or
# a warning is emitted). NSIS_GLOB_ROOT_PREFIX points the glob at an empty
# sandbox so the roots miss too.
_run_install_nsis_no_makensis() {
    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    # Real Windows `where.exe` exits 1 (not 0) when it finds nothing — the
    # state right after `choco install` before the shim reaches PATH. Modelling
    # exit 1 is load-bearing: it proves the lookup stays set -e-safe (`|| true`),
    # else pipefail would abort the whole install (the v0.12.0 CI failure).
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"
    local curated
    curated="$(_curated_bin_without_makensis)"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        NSIS_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${empty_where_dir}:${FAKE_BIN}:${curated}" \
        "$@" \
        bash -c '
            source "'"${REPO_ROOT}"'/scripts/install/deps.sh"
            skip_unsupported_os() { echo "SKIPPED: $1"; }
            install_nsis
            apt_flush
        '
}

@test "nsis: empty where.exe result does NOT add '.' to GITHUB_PATH" {
    _run_install_nsis_no_makensis RUNNER_OS="Windows"
    [ "$status" -eq 0 ]
    # The `dirname ""` trap poisons PATH with the cwd (".") — assert it never did.
    ! grep -qxF '.' "$GITHUB_PATH"
    # makensis was unresolvable and the rebased glob roots don't exist, so the
    # code falls through to the no-dir warning.
    [[ "$output" == *"makensis dir not found"* ]]
}

# ── Test 4: glob fallback resolves the NSIS install root ──────────────────
# command -v / where.exe both miss; the makensis.exe lives directly in the NSIS
# root (no `bin` subdir). NSIS_GLOB_ROOT_PREFIX rebases the search under the
# sandbox where a fake "/c/Program Files (x86)/NSIS/makensis.exe" exists, so the
# glob resolves and that root is appended to GITHUB_PATH.
@test "nsis: glob fallback appends the NSIS root containing makensis.exe" {
    local prefix="${_TEST_HOME}/glob-prefix"
    local nsis_root="${prefix}/c/Program Files (x86)/NSIS"
    mkdir -p "$nsis_root"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${nsis_root}/makensis.exe"
    chmod +x "${nsis_root}/makensis.exe"

    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    # Real Windows `where.exe` exits 1 (not 0) when it finds nothing — the
    # state right after `choco install` before the shim reaches PATH. Modelling
    # exit 1 is load-bearing: it proves the lookup stays set -e-safe (`|| true`),
    # else pipefail would abort the whole install (the v0.12.0 CI failure).
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"
    local curated
    curated="$(_curated_bin_without_makensis)"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        NSIS_GLOB_ROOT_PREFIX="${prefix}" \
        PATH="${empty_where_dir}:${FAKE_BIN}:${curated}" \
        RUNNER_OS="Windows" \
        bash -c '
            source "'"${REPO_ROOT}"'/scripts/install/deps.sh"
            skip_unsupported_os() { echo "SKIPPED: $1"; }
            install_nsis
            apt_flush
        '
    [ "$status" -eq 0 ]
    grep -qxF "${nsis_root}" "$GITHUB_PATH"
}

# ── Test 5: Linux queues nsis (apt) — the Linux installer path ────────────

@test "nsis: Linux queues the nsis apt package, exits 0" {
    # The per-package ✓ on flush is a verbose-only line; run under verbose so it
    # surfaces for the assertion.
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        RUNNER_OS="Linux" \
        ANODIZER_VERBOSE=1 \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_nsis
            apt_flush
        "
    [ "$status" -eq 0 ]
    [[ "$output" == *"installing apt batch: nsis"* ]]
    [[ "$output" == *"nsis installed"* ]]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 6: macOS installs makensis via brew ──────────────────────────────

@test "nsis: macOS installs makensis via brew, exits 0" {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        RUNNER_OS="macOS" \
        ANODIZER_VERBOSE=1 \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_nsis
            apt_flush
        "
    [ "$status" -eq 0 ]
    [[ "$output" == *"brew install"*"makensis"* ]]
    [[ "$output" != *"SKIPPED"* ]]
}
