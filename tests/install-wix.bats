#!/usr/bin/env bats
# install-wix.bats — unit tests for the WiX installer in
# scripts/install/deps.sh.
#
# WiX drives anodizer's `msis:` stage (crates/stage-msi). On Windows the v4 CLI
# is the `wix` dotnet global tool; WiX itself is Windows-only and EULA-gated, so
# on Linux the stage uses `wixl` (msitools, apt) from the v3-dialect .wxs. macOS
# has no MSI path and is skipped (warn, don't fail). The v3 dialect installs
# candle+light via choco wixtoolset on Windows.
#
# Stubs dotnet + choco so no network is needed. Covers:
#
#   1. Windows (v4) → `dotnet tool install --global wix --version <pin>` runs,
#      tools dir added to PATH, exits 0
#   2. WIX_VERSION override → forwarded to --version
#   3. Linux → queues the wixl apt package, exits 0
#   4. macOS → skipped (no MSI path), exits 0
#   5. Windows (v3) → choco wixtoolset (candle+light), candle bin dir on PATH
#   6. wix3 Linux → wixl; wix3 macOS → skipped
#
# Dialect resolution (version: / .wxs namespace sniff → wix vs wix3) now lives
# in `anodizer tools`; the action's wix→wix and candle/light/wixl→wix3
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

    # ── Stub: dotnet — echo the invocation so tests can assert on it. ─────
    cat > "${FAKE_BIN}/dotnet" <<'STUB'
#!/usr/bin/env bash
echo "dotnet $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/dotnet"

    # ── Stub: choco — echo the invocation (used by the wix3/Windows arm). ──
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
            apt_flush
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
    # The per-package ✓ on flush is a verbose-only line; run under verbose so it
    # surfaces for the assertion.
    _run_install_wix RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    # wixl rides the single batched apt install — one batch header plus a
    # per-package ✓ on flush, NOT a per-tool "queued"/"installing" line.
    [[ "$output" == *"installing apt batch: wixl"* ]]
    [[ "$output" == *"wixl installed"* ]]
    [[ "$output" != *"SKIPPED"* ]]
}

# ── Test 4: macOS has no MSI path and is skipped ──────────────────────────

@test "wix: macOS is skipped, exits 0" {
    _run_install_wix RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}

# ── wix3 (v3 dialect): Windows → choco wixtoolset (candle+light) ──────────

# Source deps.sh and call install_wix3. A fake `candle` is placed on PATH so
# the bin-dir discovery resolves via `command -v candle` without globbing the
# real filesystem.
_run_install_wix3() {
    local candle_dir="${_TEST_HOME}/wix3-bin"
    mkdir -p "$candle_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${candle_dir}/candle"
    chmod +x "${candle_dir}/candle"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        PATH="${candle_dir}:${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_wix3
            apt_flush
        "
}

@test "wix3: Windows installs WiX v3 via choco wixtoolset (candle+light)" {
    # ANODIZER_VERBOSE so run_quiet passes choco's argv through (it is swallowed
    # on a green run otherwise), letting the test assert the package installed.
    _run_install_wix3 RUNNER_OS="Windows" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"choco install wixtoolset"* ]]
    # The completion line names the v3 (candle+light) toolchain.
    [[ "$output" == *"WiX v3 (candle+light) installed"* ]]
    # The v3 toolchain is candle+light, NOT the v4 `wix` dotnet global tool.
    [[ "$output" != *"dotnet tool install"* ]]
    # candle's bin dir is discovered and surfaced on PATH.
    grep -q 'wix3-bin' "$GITHUB_PATH"
}

# ── Test: where.exe returning empty must NOT poison PATH with "." ─────────
# After `choco install wixtoolset`, the choco shim may not be on the current
# shell's PATH, so `command -v candle` misses and the code falls to a
# `where.exe candle` lookup. When that ALSO finds nothing, `dirname ""` would
# yield "." — adding cwd to GITHUB_PATH instead of the WiX bin dir. The fix
# leaves $bindir empty so the glob fallback runs (or a warning is emitted).
_run_install_wix3_no_candle() {
    # A fake `where.exe` that finds nothing (real where.exe exits 1, not 0),
    # and NO `candle` anywhere on PATH — the post-choco-install state the bug
    # hits. The exit-1 model proves the lookup stays set -e-safe under pipefail.
    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        PATH="${empty_where_dir}:${FAKE_BIN}:/usr/bin:/bin" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_wix3
            apt_flush
        "
}

@test "wix3: empty where.exe result does NOT add '.' to GITHUB_PATH" {
    _run_install_wix3_no_candle RUNNER_OS="Windows"
    [ "$status" -eq 0 ]
    # The bug poisoned PATH with the cwd (".") — assert it never landed there.
    ! grep -qxF '.' "$GITHUB_PATH"
    # candle was unresolvable and the glob roots don't exist in the sandbox, so
    # the code falls through to the no-bin-dir warning rather than a bogus path.
    [[ "$output" == *"candle/light bin dir not found"* ]]
}

# A curated bin dir that symlinks every standard tool EXCEPT candle, so a real
# host `candle` cannot leak into the `command -v candle` fast path and mask the
# where.exe / glob branches (mirrors install-nsis.bats's makensis curation).
_curated_bin_without_candle() {
    local dir="${_TEST_HOME}/curated-bin"
    mkdir -p "$dir"
    local d f base
    for d in /usr/bin /bin /usr/local/bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            base="$(basename "$f")"
            case "$base" in candle|candle.exe) continue ;; esac
            [ -e "${dir}/${base}" ] || ln -s "$f" "${dir}/${base}" 2>/dev/null || true
        done
    done
    printf '%s' "$dir"
}

# ── Test: glob fallback resolves the WiX v3 toolset bin dir ───────────────
# command -v / where.exe both miss; candle.exe lives under the versioned
# "WiX Toolset v<major>.<minor>\bin" subdir. WIX_GLOB_ROOT_PREFIX rebases the
# search under the sandbox where a fake bin dir exists, so the glob resolves and
# that dir is appended to GITHUB_PATH. This is the production path that actually
# fires on the real windows runner (candle IS found via the glob there).
@test "wix3: glob fallback appends the WiX bin dir containing candle.exe" {
    local prefix="${_TEST_HOME}/glob-prefix"
    local wix_bin="${prefix}/c/Program Files (x86)/WiX Toolset v3.14/bin"
    mkdir -p "$wix_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${wix_bin}/candle.exe"
    chmod +x "${wix_bin}/candle.exe"

    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${empty_where_dir}/where.exe"
    chmod +x "${empty_where_dir}/where.exe"
    local curated
    curated="$(_curated_bin_without_candle)"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        NO_COLOR=1 \
        WIX_GLOB_ROOT_PREFIX="${prefix}" \
        PATH="${empty_where_dir}:${FAKE_BIN}:${curated}" \
        RUNNER_OS="Windows" \
        bash -c '
            source "'"${REPO_ROOT}"'/scripts/install/deps.sh"
            skip_unsupported_os() { echo "SKIPPED: $1"; }
            install_wix3
            apt_flush
        '
    [ "$status" -eq 0 ]
    grep -qxF "${wix_bin}" "$GITHUB_PATH"
}

@test "wix3: Linux queues wixl (msitools) — same as the v4 arm" {
    # The per-package ✓ on flush is a verbose-only line; run under verbose so it
    # surfaces for the assertion.
    _run_install_wix3 RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"installing apt batch: wixl"* ]]
    [[ "$output" == *"wixl installed"* ]]
}

@test "wix3: macOS is skipped, exits 0" {
    _run_install_wix3 RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}
