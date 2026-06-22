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
# anodizer's msi stage is dialect-aware: a v3-dialect .wxs (or `version: v3`/
# `wixl`) selects candle+light (choco wixtoolset on Windows), a v4-dialect .wxs
# (or `version: v4`, or unknown) selects the `wix` dotnet global tool. Both use
# wixl on Linux. auto-detect emits the matching token (`wix3` vs `wix`).
#
# Stubs dotnet + choco so no network is needed. Covers:
#
#   1. Windows (v4) → `dotnet tool install --global wix --version <pin>` runs,
#      tools dir added to PATH, exits 0
#   2. WIX_VERSION override → forwarded to --version
#   3. Linux → queues the wixl apt package, exits 0
#   4. macOS → skipped (no MSI path), exits 0
#   5. auto-detect: msis: config on Windows AND Linux emits the wix dep
#   6. auto-detect: msis: config on macOS warns + omits it
#   7. Windows (v3) → choco wixtoolset (candle+light), candle bin dir on PATH
#   8. wix3 Linux → wixl; wix3 macOS → skipped
#   9. auto-detect dialect: version v3/wixl → wix3; version v4 → wix;
#      namespace sniff (v3 ns → wix3, v4 ns / missing .wxs → wix)

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
    _run_install_wix RUNNER_OS="Linux"
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
    # A fake `where.exe` that finds nothing (empty stdout, exit 0), and NO
    # `candle` anywhere on PATH — the post-choco-install state the bug hits.
    local empty_where_dir="${_TEST_HOME}/empty-where"
    mkdir -p "$empty_where_dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${empty_where_dir}/where.exe"
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
    printf '#!/usr/bin/env bash\nexit 0\n' > "${empty_where_dir}/where.exe"
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
    _run_install_wix3 RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installing apt batch: wixl"* ]]
    [[ "$output" == *"wixl installed"* ]]
}

@test "wix3: macOS is skipped, exits 0" {
    _run_install_wix3 RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}

# ── auto-detect dialect selection ─────────────────────────────────────────

# Like _run_auto_detect but also writes a .wxs fixture so the namespace sniff
# has a file to read. $3 is the .wxs body (optional).
_run_auto_detect_with_wxs() {
    local cfg_body="$1" runner_os="$2" wxs_body="${3:-}"
    local workdir="${_TEST_HOME}/workdir"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    printf '%s\n' "$cfg_body" > "${workdir}/.anodizer.yaml"
    if [ -n "$wxs_body" ]; then
        printf '%s\n' "$wxs_body" > "${workdir}/app.wxs"
    fi
    run env \
        GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
        NO_COLOR=1 \
        RUNNER_OS="$runner_os" \
        bash -c "cd '${workdir}' && bash '${REPO_ROOT}/scripts/install/auto-detect-deps.sh'"
}

@test "auto-detect: explicit version: v3 → wix3 dep on Windows" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs\n    version: v3' "Windows"
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix3(,|$)' "$GITHUB_OUTPUT"
}

@test "auto-detect: explicit version: v4 → wix (v4) dep, not wix3" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs\n    version: v4' "Windows"
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix(,|$)' "$GITHUB_OUTPUT"
    ! grep -q 'wix3' "$GITHUB_OUTPUT"
}

@test "auto-detect: version: wixl → wix3 (candle+light is the v3-dialect Windows fallback)" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs\n    version: wixl' "Windows"
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix3(,|$)' "$GITHUB_OUTPUT"
}

@test "auto-detect: no version + v3-namespace .wxs sniff → wix3" {
    _run_auto_detect_with_wxs \
        $'msis:\n  - wxs: app.wxs' "Windows" \
        '<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi"></Wix>'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix3(,|$)' "$GITHUB_OUTPUT"
}

@test "auto-detect: no version + v4-namespace .wxs sniff → wix (default)" {
    _run_auto_detect_with_wxs \
        $'msis:\n  - wxs: app.wxs' "Windows" \
        '<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs"></Wix>'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix(,|$)' "$GITHUB_OUTPUT"
    ! grep -q 'wix3' "$GITHUB_OUTPUT"
}

@test "auto-detect: no version + missing .wxs file → wix (v4 default)" {
    _run_auto_detect $'msis:\n  - wxs: nonexistent.wxs' "Windows"
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix(,|$)' "$GITHUB_OUTPUT"
    ! grep -q 'wix3' "$GITHUB_OUTPUT"
}

# ── Test: a mixed v3+v4 msis: block must emit BOTH tokens ─────────────────
# anodizer resolves WiX version PER msis: entry (stage-msi env_requirements
# loops per entry), so a block with one v3 and one v4 entry needs BOTH
# toolchains. The old `head -1` emitted only one, leaving the other entry's MSI
# to hard-fail at release.
@test "auto-detect: mixed v3+v4 msis: block emits BOTH wix3 and wix" {
    _run_auto_detect \
        $'msis:\n  - wxs: a.wxs\n    version: v3\n  - wxs: b.wxs\n    version: v4' \
        "Windows"
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix3(,|$)' "$GITHUB_OUTPUT"
    grep -qE '^deps=([^=]*,)?wix(,|$)' "$GITHUB_OUTPUT"
}

# ── SUGGESTION tests: case/format-insensitive v3 parsing ──────────────────

@test "auto-detect: version: V3 (uppercase) → wix3" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs\n    version: V3' "Windows"
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix3(,|$)' "$GITHUB_OUTPUT"
}

@test "auto-detect: version: 3 (bare) → wix3" {
    _run_auto_detect $'msis:\n  - wxs: app.wxs\n    version: 3' "Windows"
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^=]*,)?wix3(,|$)' "$GITHUB_OUTPUT"
}
