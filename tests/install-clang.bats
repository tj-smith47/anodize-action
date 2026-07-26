#!/usr/bin/env bats
# install-clang.bats — unit tests for the clang-cl installer in
# scripts/install/deps.sh.
#
# clang-cl drives anodizer's determinism harness, which HARD-REQUIRES it on
# PATH for windows-msvc builds (pinning it as the C/C++ compiler fixes an
# intermittent cl.exe C-object codegen non-determinism). The GitHub-hosted
# windows image ships LLVM 20.1.8 with its bin dir already on the machine
# PATH, so the fast path (already on PATH) is the expected default. Two
# fallbacks cover images/configurations where that PATH entry is missing: a
# known standalone-LLVM install dir, and Visual Studio's bundled ClangCL
# toolset dir; a last-resort `choco install llvm` covers neither existing.
#
# Stubs choco so no network is needed. Covers:
#
#   1. Windows, clang-cl already on PATH → no-op, no choco call
#   2. Windows, standalone LLVM dir present (no PATH hit) → that dir added to
#      PATH, no choco call
#   3. Windows, VS bundled ClangCL toolset dir present → that dir added to
#      PATH, no choco call
#   4. Windows, neither known dir nor PATH hit → choco install llvm, then
#      `command -v clang-cl` resolves → its dir added to PATH
#   5. Windows, post-choco where.exe empty result must NOT poison PATH with "."
#   6. Windows, nothing resolvable anywhere → warns, exits 0
#   7. Linux → skipped
#   8. macOS → skipped

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

# A curated bin dir that shims every standard tool EXCEPT clang-cl/where.exe,
# so a real host clang-cl (unlikely, but mirrors install-nsis.bats's makensis
# curation) can't leak into the `command -v clang-cl` fast path and mask the
# known-dir / choco-fallback branches.
_curated_bin_without_clang_cl() {
    curated_bin "${_TEST_HOME}/curated-bin" "clang-cl clang-cl.exe where.exe"
}

_run_install_clang_cl() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_clang_cl
            apt_flush
        "
}

# ── Test 1: already on PATH → no-op, no choco call ────────────────────────

@test "clang-cl: Windows with clang-cl already on PATH is a no-op" {
    local clang_dir="${_TEST_HOME}/preinstalled-llvm-bin"
    mkdir -p "$clang_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${clang_dir}/clang-cl"
    chmod +x "${clang_dir}/clang-cl"

    _run_install_clang_cl RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        PATH="${clang_dir}:${FAKE_BIN}:${PATH}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"clang-cl already on PATH"* ]]
    [[ "$output" != *"choco install"* ]]
    # Nothing new added to GITHUB_PATH — the tool was already resolvable.
    [ ! -s "$GITHUB_PATH" ]
}

# ── Test 2: standalone LLVM install dir found (image ships it, off PATH) ──

@test "clang-cl: Windows finds the standalone LLVM bin dir and adds it to PATH" {
    local prefix="${_TEST_HOME}/glob-prefix"
    local llvm_bin="${prefix}/c/Program Files/LLVM/bin"
    mkdir -p "$llvm_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${llvm_bin}/clang-cl.exe"
    chmod +x "${llvm_bin}/clang-cl.exe"

    local curated
    curated="$(_curated_bin_without_clang_cl)"
    _run_install_clang_cl RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        CLANG_GLOB_ROOT_PREFIX="$prefix" \
        PATH="${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"clang-cl found at"* ]]
    [[ "$output" != *"choco install"* ]]
    grep -qxF "$llvm_bin" "$GITHUB_PATH"
}

# ── Test 3: VS bundled ClangCL toolset dir found ──────────────────────────

@test "clang-cl: Windows finds the VS bundled ClangCL toolset dir and adds it to PATH" {
    local prefix="${_TEST_HOME}/glob-prefix"
    local vs_bin="${prefix}/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/Llvm/x64/bin"
    mkdir -p "$vs_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${vs_bin}/clang-cl.exe"
    chmod +x "${vs_bin}/clang-cl.exe"

    local curated
    curated="$(_curated_bin_without_clang_cl)"
    _run_install_clang_cl RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        CLANG_GLOB_ROOT_PREFIX="$prefix" \
        PATH="${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"clang-cl found at"* ]]
    [[ "$output" != *"choco install"* ]]
    grep -qxF "$vs_bin" "$GITHUB_PATH"
}

# ── Test 4: neither known dir present → choco install llvm, then command -v
#    resolves clang-cl's dir (fast path immediately after install) ─────────

@test "clang-cl: Windows falls back to choco install llvm and surfaces the resolved dir" {
    local choco_dir="${_TEST_HOME}/choco-bin"
    mkdir -p "$choco_dir"
    # Simulate chocolatey's shim mechanism: `choco install` drops a shim into
    # its OWN bin dir, which is already on PATH — `command -v` sees it
    # immediately afterward with no process restart needed. Placing the fake
    # clang-cl on PATH before the call (like the "already on PATH" test does)
    # would instead fool the upfront on-PATH short-circuit into skipping choco
    # entirely, so this stub creates the binary as a side effect of the choco
    # invocation itself.
    cat > "${choco_dir}/choco" <<STUB
#!/usr/bin/env bash
echo "choco \$*"
printf '#!/usr/bin/env bash\nexit 0\n' > "${choco_dir}/clang-cl"
chmod +x "${choco_dir}/clang-cl"
exit 0
STUB
    chmod +x "${choco_dir}/choco"

    local curated
    curated="$(_curated_bin_without_clang_cl)"
    _run_install_clang_cl RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        CLANG_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${choco_dir}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"choco install llvm"* ]]
    [[ "$output" == *"clang-cl (LLVM) installed via choco llvm"* ]]
    grep -qxF "$choco_dir" "$GITHUB_PATH"
}

# LLVM_VERSION override is forwarded to --version (choco_install's contract).

@test "clang-cl: LLVM_VERSION override is forwarded to choco --version" {
    local curated
    curated="$(_curated_bin_without_clang_cl)"
    _run_install_clang_cl RUNNER_OS="Windows" ANODIZER_VERBOSE=1 \
        LLVM_VERSION="20.1.8" \
        CLANG_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--version=20.1.8"* ]]
}

# ── Test 5: post-choco where.exe empty result must NOT poison PATH with "." ─
# Real Windows `where.exe` exits 1 (not 0) when it finds nothing — the state
# right after `choco install llvm` before any shim reaches PATH. `dirname ""`
# would otherwise yield "." — adding cwd to GITHUB_PATH. `|| true` + the
# explicit `if` (mirroring the makensis/candle fix) keep the lookup
# set -e-safe so the whole install doesn't abort under pipefail.
@test "clang-cl: empty where.exe result does NOT add '.' to GITHUB_PATH" {
    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"

    local curated
    curated="$(_curated_bin_without_clang_cl)"
    _run_install_clang_cl RUNNER_OS="Windows" \
        CLANG_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${empty_where_dir}:${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    ! grep -qxF '.' "$GITHUB_PATH"
}

# ── Test 6: nothing resolvable anywhere → warns, exits 0 ──────────────────

@test "clang-cl: Windows warns (not fails) when clang-cl is unresolvable after choco install" {
    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"

    local curated
    curated="$(_curated_bin_without_clang_cl)"
    _run_install_clang_cl RUNNER_OS="Windows" \
        CLANG_GLOB_ROOT_PREFIX="${_TEST_HOME}/empty-roots" \
        PATH="${empty_where_dir}:${FAKE_BIN}:${curated}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"clang-cl: bin dir not found after choco install llvm"* ]]
}

# ── Test 7 + 8: non-Windows runners are skipped ───────────────────────────

@test "clang-cl: Linux is skipped, exits 0" {
    _run_install_clang_cl RUNNER_OS="Linux" PATH="${FAKE_BIN}:${PATH}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED: clang-cl"* ]]
}

@test "clang-cl: macOS is skipped, exits 0" {
    _run_install_clang_cl RUNNER_OS="macOS" PATH="${FAKE_BIN}:${PATH}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED: clang-cl"* ]]
}
