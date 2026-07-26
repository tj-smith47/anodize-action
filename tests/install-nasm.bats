#!/usr/bin/env bats
# install-nasm.bats — unit tests for the nasm installer in
# scripts/install/deps.sh.
#
# aws-lc-sys (pulled in transitively via octocrab's aws-lc-rs JWT provider)
# hard-requires nasm on PATH to assemble its perlasm .asm on windows-msvc,
# panicking with no fallback when it is missing. The GitHub-hosted windows
# image ships NASM with its install dir already on the machine PATH, so the
# fast path (already on PATH) is the expected default. A last-resort
# `choco install nasm` covers images/configurations where that PATH entry is
# missing.
#
# Stubs choco so no network is needed. Covers:
#
#   1. Windows, nasm already on PATH → no-op, no choco call
#   2. Windows, known NASM install dir present (no PATH hit) → that dir added
#      to PATH, no choco call
#   3. Windows, neither known dir nor PATH hit → choco install nasm, then
#      `command -v nasm` resolves → its dir added to PATH
#   4. Windows, post-choco where.exe empty result must NOT poison PATH with "."
#   5. Windows, nothing resolvable anywhere → warns, exits 0
#   6. Linux → skipped
#   7. macOS → skipped

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

# A curated bin dir that shims every standard tool EXCEPT nasm/where.exe,
# so a real host nasm (unlikely, but mirrors install-clang.bats's clang-cl
# curation) can't leak into the `command -v nasm` fast path and mask the
# known-dir / choco-fallback branches.
_curated_bin_without_nasm() {
    curated_bin "${_TEST_HOME}/curated-bin" "nasm nasm.exe where.exe"
}

_run_install_nasm() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_nasm
            apt_flush
        "
}

# ── Test 1: already on PATH → no-op, no choco call ────────────────────────

@test "nasm: Windows with nasm already on PATH is a no-op" {
    local nasm_dir="${_TEST_HOME}/preinstalled-nasm-bin"
    mkdir -p "$nasm_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${nasm_dir}/nasm"
    chmod +x "${nasm_dir}/nasm"

    _run_install_nasm RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        PATH="${nasm_dir}:${FAKE_BIN}:${PATH}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nasm already on PATH"* ]]
    [[ "$output" != *"choco install"* ]]
    # Nothing new added to GITHUB_PATH — the tool was already resolvable.
    [ ! -s "$GITHUB_PATH" ]
}

# ── Test 2: known NASM install dir found (image ships it, off PATH) ───────

@test "nasm: Windows finds the known NASM install dir and adds it to PATH" {
    local prefix="${_TEST_HOME}/glob-prefix"
    local nasm_dir="${prefix}/c/Program Files/NASM"
    mkdir -p "$nasm_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${nasm_dir}/nasm.exe"
    chmod +x "${nasm_dir}/nasm.exe"

    local curated
    curated="$(_curated_bin_without_nasm)"
    _run_install_nasm RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        NASM_GLOB_ROOT_PREFIX="$prefix" \
        PATH="${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nasm found at"* ]]
    [[ "$output" != *"choco install"* ]]
    grep -qxF "$nasm_dir" "$GITHUB_PATH"
}

# ── Test 3: known dir absent → choco install nasm, then `command -v`
#    resolves nasm's dir (fast path immediately after install) ────────────

@test "nasm: Windows falls back to choco install nasm and surfaces the resolved dir" {
    local choco_dir="${_TEST_HOME}/choco-bin"
    mkdir -p "$choco_dir"
    # Simulate chocolatey's shim mechanism: `choco install` drops a shim into
    # its OWN bin dir, which is already on PATH — `command -v` sees it
    # immediately afterward with no process restart needed. Placing the fake
    # nasm on PATH before the call (like the "already on PATH" test does)
    # would instead fool the upfront on-PATH short-circuit into skipping
    # choco entirely, so this stub creates the binary as a side effect of the
    # choco invocation itself.
    cat > "${choco_dir}/choco" <<STUB
#!/usr/bin/env bash
echo "choco \$*"
printf '#!/usr/bin/env bash\nexit 0\n' > "${choco_dir}/nasm"
chmod +x "${choco_dir}/nasm"
exit 0
STUB
    chmod +x "${choco_dir}/choco"

    local curated
    curated="$(_curated_bin_without_nasm)"
    _run_install_nasm RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        NASM_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${choco_dir}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"choco install nasm"* ]]
    [[ "$output" == *"nasm installed via choco nasm"* ]]
    grep -qxF "$choco_dir" "$GITHUB_PATH"
}

# NASM_VERSION override is forwarded to --version (choco_install's contract).

@test "nasm: NASM_VERSION override is forwarded to choco --version" {
    local curated
    curated="$(_curated_bin_without_nasm)"
    _run_install_nasm RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        NASM_VERSION="2.16.3" \
        NASM_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--version=2.16.3"* ]]
}

# ── Test 4: post-choco where.exe empty result must NOT poison PATH with "." ─
# Real Windows `where.exe` exits 1 (not 0) when it finds nothing — the state
# right after `choco install nasm` before any shim reaches PATH. `dirname ""`
# would otherwise yield "." — adding cwd to GITHUB_PATH. `|| true` + the
# explicit `if` (mirroring the makensis/candle/clang-cl fix) keep the lookup
# set -e-safe so the whole install doesn't abort under pipefail.
@test "nasm: empty where.exe result does NOT add '.' to GITHUB_PATH" {
    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"

    local curated
    curated="$(_curated_bin_without_nasm)"
    _run_install_nasm RUNNER_OS="Windows" \
        NASM_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${empty_where_dir}:${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    ! grep -qxF '.' "$GITHUB_PATH"
}

# ── Test 5: nothing resolvable anywhere → warns, exits 0 ──────────────────

@test "nasm: Windows warns (not fails) when nasm is unresolvable after choco install" {
    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"

    local curated
    curated="$(_curated_bin_without_nasm)"
    _run_install_nasm RUNNER_OS="Windows" \
        NASM_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${empty_where_dir}:${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nasm: bin dir not found after choco install nasm"* ]]
}

# ── Test 6 + 7: non-Windows runners are skipped ───────────────────────────

@test "nasm: Linux is skipped, exits 0" {
    _run_install_nasm RUNNER_OS="Linux" PATH="${FAKE_BIN}:${PATH}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED: nasm"* ]]
}

@test "nasm: macOS is skipped, exits 0" {
    _run_install_nasm RUNNER_OS="macOS" PATH="${FAKE_BIN}:${PATH}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED: nasm"* ]]
}
