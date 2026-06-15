#!/usr/bin/env bats
# install-pkgbuild.bats — unit tests for the pkgbuild installer in
# scripts/install/deps.sh AND the pkgs: auto-detect wiring in
# scripts/install/auto-detect-deps.sh.
#
# pkgbuild drives anodizer's `pkgs:` stage (crates/stage-pkg). On macOS the
# native `pkgbuild` ships with the Xcode Command Line Tools (no install). On
# Linux the stage assembles the flat XAR package by hand from `xar` + `mkbom`
# + `cpio` (gzip in-process); `xar` comes from apt, but `mkbom` is not packaged
# for Debian/Ubuntu so the installer builds it from the bomutils source. macOS
# .pkg is a macOS installer format, so Windows is skipped (warn, don't fail).
#
# Stubs sudo (which fronts `apt-get install`), git, make, and toggles `mkbom`
# presence so no root, network, or compiler is needed. Covers:
#
#   1. macOS → no-op (pkgbuild ships with Xcode CLT), exits 0
#   2. Linux, mkbom absent → xar apt-installed + bomutils cloned/built/installed
#   3. Linux, mkbom found on PATH → xar installed, bomutils build skipped
#   4. Windows → skipped (macOS installer format), exits 0
#   5. auto-detect: pkgs: config on Linux/macOS emits the pkgbuild dep
#   6. auto-detect: pkgs: config on Windows warns + omits it

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_OUTPUT"

    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"

    # ── Stub: sudo — record argv, succeed. apt_flush calls `sudo apt-get
    #    install ...`; the bomutils install calls `sudo make ... install`. ──
    SUDO_LOG="${_TEST_HOME}/sudo.log"
    export SUDO_LOG
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SUDO_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # ── Stub: git — record argv (clone target), create the dir, succeed. ──
    GIT_LOG="${_TEST_HOME}/git.log"
    export GIT_LOG
    cat > "${FAKE_BIN}/git" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GIT_LOG"
# `git clone --depth 1 <url> <dest>` → create <dest> so the later make -C works.
if [ "$1" = "clone" ]; then
    dest="${@: -1}"
    mkdir -p "$dest"
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/git"

    # ── Stub: make — record argv, succeed (no real compile). ──
    MAKE_LOG="${_TEST_HOME}/make.log"
    export MAKE_LOG
    cat > "${FAKE_BIN}/make" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$MAKE_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/make"
}

teardown() {
    common_teardown
}

# Source deps.sh (source-safe) and call install_pkgbuild directly, then
# apt_flush so queued apt packages register on the sudo log.
# skip_unsupported_os is stubbed so the Windows arm can be exercised without
# its real annotation side-effects.
#
# `command -v mkbom` is what the installer uses to decide whether to build
# bomutils. The host running the suite may itself have an mkbom on PATH, so
# the "mkbom absent" case overrides the `command` builtin to report mkbom as
# missing (MASK_MKBOM=1); the "mkbom found" case overrides it to report mkbom
# present (MASK_MKBOM=0). Both make the branch deterministic regardless of the
# host. The override delegates to the real builtin for every other lookup.
_run_install_pkgbuild() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        SUDO_LOG="${SUDO_LOG}" \
        GIT_LOG="${GIT_LOG}" \
        MAKE_LOG="${MAKE_LOG}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        MASK_MKBOM="${MASK_MKBOM:-}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c '
            source "${GITHUB_ACTION_PATH}/scripts/install/deps.sh"
            skip_unsupported_os() { echo "SKIPPED: $1"; }
            # Deterministic mkbom presence for the bomutils branch.
            if [ -n "${MASK_MKBOM}" ]; then
                command() {
                    if [ "$1" = "-v" ] && [ "$2" = "mkbom" ]; then
                        [ "${MASK_MKBOM}" = "present" ] && { echo mkbom; return 0; }
                        return 1
                    fi
                    builtin command "$@"
                }
            fi
            install_pkgbuild
            apt_flush
        '
}

# Drive the FULL dispatch path (dispatch_install + apt_flush) for a single
# dep, so the generic "<dep> installed" completion line is in play. Used to
# assert self-logging installers do not double-print.
_run_dispatch() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        SUDO_LOG="${SUDO_LOG}" \
        GIT_LOG="${GIT_LOG}" \
        MAKE_LOG="${MAKE_LOG}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        MASK_MKBOM="${MASK_MKBOM:-}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c '
            source "${GITHUB_ACTION_PATH}/scripts/install/deps.sh"
            skip_unsupported_os() { echo "SKIPPED: $1"; }
            if [ -n "${MASK_MKBOM}" ]; then
                command() {
                    if [ "$1" = "-v" ] && [ "$2" = "mkbom" ]; then
                        [ "${MASK_MKBOM}" = "present" ] && { echo mkbom; return 0; }
                        return 1
                    fi
                    builtin command "$@"
                }
            fi
            DEPS=("${DISPATCH_DEP}")
            dispatch_install
            apt_flush
        '
}

# ── Test 1: macOS → no-op (pkgbuild ships with Xcode CLT) ──────────────────

@test "pkgbuild: macOS is a no-op (Xcode CLT provides pkgbuild), exits 0" {
    _run_install_pkgbuild RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    # Nothing apt-installed, cloned, or built on macOS.
    [ ! -s "$SUDO_LOG" ] || ! grep -q 'apt-get' "$SUDO_LOG"
    [ ! -s "$GIT_LOG" ]
}

# ── Test 2: Linux, mkbom absent → xar + bomutils from source ───────────────

@test "pkgbuild: Linux installs xar via apt and builds mkbom from bomutils" {
    MASK_MKBOM="absent" _run_install_pkgbuild RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # xar queued and apt-installed.
    grep -q 'apt-get install .*xar' "$SUDO_LOG"
    # bomutils cloned, built, and installed (sudo make install).
    grep -q 'clone .*bomutils' "$GIT_LOG"
    grep -q '\-C .*bomutils' "$MAKE_LOG"
    grep -q 'make -C .*bomutils install' "$SUDO_LOG"
}

# ── Test 3: Linux, mkbom found on PATH → skip the bomutils build ───────────

@test "pkgbuild: Linux skips the bomutils build when mkbom is found on PATH" {
    # An mkbom found on PATH short-circuits the `command -v mkbom` gate.
    MASK_MKBOM="present" _run_install_pkgbuild RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # xar is still installed.
    grep -q 'apt-get install .*xar' "$SUDO_LOG"
    # But bomutils is NOT cloned or built.
    [ ! -s "$GIT_LOG" ]
    [ ! -s "$MAKE_LOG" ]
}

# ── Test 4: dispatch emits exactly ONE completion line (no duplicate) ──────

@test "pkgbuild: Linux dispatch emits exactly one completion line, not two" {
    # install_pkgbuild flushes apt internally and prints its own completion
    # line, so the generic "pkgbuild installed" must be suppressed — one line,
    # not two.
    DISPATCH_DEP="pkgbuild" MASK_MKBOM="absent" _run_dispatch RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # Snapshot the dispatch output — the `run` below clobbers $output.
    local out="$output"
    # The installer's own completion line is present.
    [[ "$out" == *"Linux flat-pkg toolchain (xar + mkbom) installed"* ]]
    # The generic "pkgbuild installed" line must NOT also appear (no apt
    # package is named "pkgbuild", so this string can only come from the
    # generic dispatch line — its absence proves the suppression).
    [[ "$out" != *"pkgbuild installed"* ]]
    # And the installer's own completion line appears exactly once.
    run bash -c "printf '%s\n' \"\$1\" | grep -c 'flat-pkg toolchain'" _ "$out"
    [ "$output" -eq 1 ]
}

# ── Test 5: Windows is skipped (macOS installer format) ────────────────────

@test "pkgbuild: Windows is skipped, exits 0" {
    _run_install_pkgbuild RUNNER_OS="Windows"
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

@test "auto-detect: pkgs: config on Linux emits the pkgbuild dep" {
    _run_auto_detect $'pkgs:\n  - identifier: org.example.app' "Linux"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*pkgbuild' "$GITHUB_OUTPUT"
}

@test "auto-detect: pkgs: config on macOS emits the pkgbuild dep" {
    _run_auto_detect $'pkgs:\n  - identifier: org.example.app' "macOS"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*pkgbuild' "$GITHUB_OUTPUT"
}

@test "auto-detect: pkgs: config on Windows warns and omits pkgbuild" {
    _run_auto_detect $'pkgs:\n  - identifier: org.example.app' "Windows"
    [ "$status" -eq 0 ]
    [[ "$output" == *"got Windows"* ]]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'pkgbuild' "$GITHUB_OUTPUT"
}
