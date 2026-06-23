#!/usr/bin/env bats
# install-pkgbuild.bats — unit tests for the pkgbuild installer in
# scripts/install/deps.sh AND the pkgs: auto-detect wiring in
# scripts/install/auto-detect-deps.sh.
#
# pkgbuild drives anodizer's `pkgs:` stage (crates/stage-pkg). On macOS the
# native `pkgbuild` ships with the Xcode Command Line Tools (no install). On
# Linux the stage assembles the flat XAR package by hand from `xar` + `mkbom`
# + `cpio` (gzip in-process). Ubuntu 24.04 (noble) dropped the `xar` package
# and bomutils was never packaged, so the installer builds BOTH from source
# (mackyle/xar via autotools; bomutils via make), guarded by `command -v` so a
# runner image that already ships them skips the build. macOS .pkg is a macOS
# installer format, so Windows is skipped (warn, don't fail).
#
# Stubs sudo (apt-get / make install / ldconfig), git (clone), make, and the
# autotools scripts, and toggles `xar`/`mkbom` presence so no root, network, or
# compiler is needed. Covers:
#
#   1. macOS → no-op (pkgbuild ships with Xcode CLT), exits 0
#   2. Linux, both absent → xar + bomutils built from source; build-deps apt'd
#   3. Linux, both present → no build-deps, no clone, no build
#   4. Linux, xar present + mkbom absent → only bomutils built (guards split)
#   5. dispatch emits exactly one completion line (no duplicate)
#   6. Windows → skipped (macOS installer format), exits 0
#   7-9. auto-detect: pkgs: config emits/omits the pkgbuild dep per OS

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

    # The xar `configure` stub records whether the OpenSSL autoconf-cache
    # override reached it, so we can assert the OpenSSL-3 build fix stays wired.
    CONFIGURE_LOG="${_TEST_HOME}/configure.log"
    export CONFIGURE_LOG
    : > "$CONFIGURE_LOG"

    # The autogen.sh stub records its args. The real xar autogen.sh runs
    # ./configure itself unless --noconfigure is passed; the stub mirrors that
    # so the test catches a regression where autogen's own (unprimed) configure
    # runs before the primed one.
    AUTOGEN_LOG="${_TEST_HOME}/autogen.log"
    export AUTOGEN_LOG
    : > "$AUTOGEN_LOG"

    # ── Stub: sudo — record argv, succeed. apt_flush calls `sudo apt-get
    #    install ...`; the xar/bomutils installs call `sudo make ... install`
    #    and `sudo ldconfig`. ──
    SUDO_LOG="${_TEST_HOME}/sudo.log"
    export SUDO_LOG
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SUDO_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # ── Stub: git — record argv (clone target), create the dir, succeed. For
    #    the mackyle/xar clone, also materialise the `xar/` source subdir with
    #    executable autotools stubs so `cd "$dest/xar" && ./autogen.sh && …`
    #    works without a network or real autotools. ──
    GIT_LOG="${_TEST_HOME}/git.log"
    export GIT_LOG
    cat > "${FAKE_BIN}/git" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GIT_LOG"
if [ "$1" = "clone" ]; then
    dest="${@: -1}"
    mkdir -p "$dest"
    case "$*" in
        *mackyle/xar*)
            mkdir -p "$dest/xar"
            # autogen records its args and — like the real script — runs
            # ./configure itself UNLESS --noconfigure is passed.
            printf '#!/usr/bin/env bash\necho "$*" >> "$AUTOGEN_LOG"\n[ "$1" = "--noconfigure" ] || ./configure\nexit 0\n' > "$dest/xar/autogen.sh"
            # configure records the OpenSSL autoconf-cache override it inherited,
            # so the test can prove the OpenSSL-3 build fix stays wired.
            printf '#!/usr/bin/env bash\necho "ac_cv_lib_crypto_OpenSSL_add_all_ciphers=${ac_cv_lib_crypto_OpenSSL_add_all_ciphers:-UNSET}" >> "$CONFIGURE_LOG"\nexit 0\n' > "$dest/xar/configure"
            chmod +x "$dest/xar/autogen.sh" "$dest/xar/configure"
            ;;
    esac
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
# `command -v xar` / `command -v mkbom` are what the installer uses to decide
# whether to build each tool. The host running the suite may itself have either
# on PATH, so MASK_XAR / MASK_MKBOM override the `command` builtin to report a
# deterministic presence ("present" → found, "absent" → missing); an empty mask
# falls through to the real builtin. The override delegates to the real builtin
# for every other lookup.
_run_install_pkgbuild() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        SUDO_LOG="${SUDO_LOG}" \
        GIT_LOG="${GIT_LOG}" \
        MAKE_LOG="${MAKE_LOG}" \
        CONFIGURE_LOG="${CONFIGURE_LOG}" \
        AUTOGEN_LOG="${AUTOGEN_LOG}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        MASK_MKBOM="${MASK_MKBOM:-}" \
        MASK_XAR="${MASK_XAR:-}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c '
            source "${GITHUB_ACTION_PATH}/scripts/install/deps.sh"
            skip_unsupported_os() { echo "SKIPPED: $1"; }
            if [ -n "${MASK_MKBOM}" ] || [ -n "${MASK_XAR}" ]; then
                command() {
                    if [ "$1" = "-v" ]; then
                        case "$2" in
                            mkbom) case "${MASK_MKBOM}" in present) echo mkbom; return 0;; absent) return 1;; esac ;;
                            xar)   case "${MASK_XAR}"   in present) echo xar;   return 0;; absent) return 1;; esac ;;
                        esac
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
        CONFIGURE_LOG="${CONFIGURE_LOG}" \
        AUTOGEN_LOG="${AUTOGEN_LOG}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        MASK_MKBOM="${MASK_MKBOM:-}" \
        MASK_XAR="${MASK_XAR:-}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c '
            source "${GITHUB_ACTION_PATH}/scripts/install/deps.sh"
            skip_unsupported_os() { echo "SKIPPED: $1"; }
            if [ -n "${MASK_MKBOM}" ] || [ -n "${MASK_XAR}" ]; then
                command() {
                    if [ "$1" = "-v" ]; then
                        case "$2" in
                            mkbom) case "${MASK_MKBOM}" in present) echo mkbom; return 0;; absent) return 1;; esac ;;
                            xar)   case "${MASK_XAR}"   in present) echo xar;   return 0;; absent) return 1;; esac ;;
                        esac
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

# ── Test 2: Linux, both absent → xar + bomutils built from source ──────────

@test "pkgbuild: Linux builds xar and mkbom from source when both absent" {
    MASK_XAR="absent" MASK_MKBOM="absent" _run_install_pkgbuild RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # Autotools build-deps apt-installed (xar needs libxml2/openssl/zlib + tools).
    grep -q 'apt-get install .*libxml2-dev' "$SUDO_LOG"
    grep -q 'apt-get install .*libssl-dev' "$SUDO_LOG"
    grep -q 'apt-get install .*zlib1g-dev' "$SUDO_LOG"
    # The `xar` apt PACKAGE is never installed — it is gone from noble.
    ! grep -qE 'apt-get install [^|]* xar( |$)' "$SUDO_LOG"
    # xar cloned from the maintained fork, built, installed, linker cache refreshed.
    grep -q 'clone .*mackyle/xar' "$GIT_LOG"
    grep -q 'make -C .*xar install' "$SUDO_LOG"
    grep -q 'ldconfig' "$SUDO_LOG"
    # The OpenSSL-3 build fix is wired: autogen is told --noconfigure (so its
    # own unprimed configure can't run first), and every configure invocation
    # carries the autoconf-cache override that skips xar's broken
    # OpenSSL_add_all_ciphers link probe — no unprimed (UNSET) configure ran.
    grep -q -- '--noconfigure' "$AUTOGEN_LOG"
    grep -q 'ac_cv_lib_crypto_OpenSSL_add_all_ciphers=yes' "$CONFIGURE_LOG"
    ! grep -q 'UNSET' "$CONFIGURE_LOG"
    # bomutils cloned, built, and installed (sudo make install).
    grep -q 'clone .*bomutils' "$GIT_LOG"
    grep -q '\-C .*bomutils' "$MAKE_LOG"
    grep -q 'make -C .*bomutils install' "$SUDO_LOG"
}

# ── Test 3: Linux, both present → skip all builds and build-deps ───────────

@test "pkgbuild: Linux skips builds entirely when xar and mkbom are present" {
    MASK_XAR="present" MASK_MKBOM="present" _run_install_pkgbuild RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # Nothing cloned or built.
    [ ! -s "$GIT_LOG" ]
    [ ! -s "$MAKE_LOG" ]
    # No autotools build-deps pulled (the xar-absent guard short-circuits).
    [ ! -s "$SUDO_LOG" ] || ! grep -q 'libxml2-dev' "$SUDO_LOG"
}

# ── Test 4: guards split — xar present, mkbom absent → only bomutils built ──

@test "pkgbuild: Linux builds only bomutils when xar present but mkbom absent" {
    MASK_XAR="present" MASK_MKBOM="absent" _run_install_pkgbuild RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # xar present → no build-deps, no xar clone/build.
    [ ! -s "$SUDO_LOG" ] || ! grep -q 'libxml2-dev' "$SUDO_LOG"
    ! grep -q 'mackyle/xar' "$GIT_LOG"
    # bomutils still built.
    grep -q 'clone .*bomutils' "$GIT_LOG"
    grep -q 'make -C .*bomutils install' "$SUDO_LOG"
}

# ── Test 5: dispatch emits exactly ONE completion line (no duplicate) ──────

@test "pkgbuild: Linux dispatch emits exactly one completion line, not two" {
    # install_pkgbuild flushes apt internally and prints its own completion
    # line, so the generic "pkgbuild installed" must be suppressed — one line,
    # not two.
    # The installer's own completion line is verbose-only; run under verbose so
    # it surfaces for the single-occurrence assertion.
    DISPATCH_DEP="pkgbuild" MASK_XAR="absent" MASK_MKBOM="absent" _run_dispatch RUNNER_OS="Linux" ANODIZER_VERBOSE=1
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

# ── Test 6: Windows is skipped (macOS installer format) ────────────────────

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

@test "auto-detect: pkgs: config on Windows omits pkgbuild (OS-incompatible)" {
    # macOS .pkg has no Windows build path, so the dep is silently omitted at
    # default verbosity.
    _run_auto_detect $'pkgs:\n  - identifier: org.example.app' "Windows"
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'pkgbuild' "$GITHUB_OUTPUT"
}
