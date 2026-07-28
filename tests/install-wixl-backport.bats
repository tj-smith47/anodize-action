#!/usr/bin/env bats
# install-wixl-backport.bats — unit tests for wixl_backport_if_too_old in
# scripts/install/deps.sh.
#
# msitools taught wixl the WiX `<Environment>` element in 0.105. Ubuntu 24.04 —
# the current `ubuntu-latest` — ships 0.103, whose parser aborts the whole build
# with `unhandled child Component node Environment` on any .wxs that puts the
# install dir on PATH. A prebuilt 0.106 .deb will not install on 24.04 either
# (it links libxml2-16), so the fix overlays wixl + wixl-data + libxml2-16 from
# 26.04 LTS behind an apt pin that holds the rest of that suite back.
#
# Stubs wixl/dpkg/sudo/apt-get so no package manager or network is touched, and
# rebases the apt config writes under the sandbox via WIXL_APT_ROOT_PREFIX.
# Covers:
#
#   1. wixl older than the floor → source + pin written, apt install runs
#   2. wixl already at/above the floor → completely untouched (self-retiring)
#   3. wixl absent → no-op (nothing requested it)
#   4. non-Linux → no-op
#   5. an install that does not actually raise the version → hard failure
#   6. arch routing: amd64 → archive.ubuntu.com, arm64 → ports.ubuntu.com
#   7. the pin holds back everything except the three overlaid packages

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    : > "$GITHUB_PATH"

    # The version `wixl --version` reports, so a test can flip it the way a real
    # apt install would.
    WIXL_VERSION_FILE="${_TEST_HOME}/wixl-version"
    export WIXL_VERSION_FILE

    cat > "${FAKE_BIN}/wixl" <<'STUB'
#!/usr/bin/env bash
[ -f "$WIXL_VERSION_FILE" ] || exit 1
cat "$WIXL_VERSION_FILE"
STUB
    chmod +x "${FAKE_BIN}/wixl"

    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # apt-get echoes its argv so the tests can assert on the install, and
    # promotes the reported wixl version the way the real overlay would.
    cat > "${FAKE_BIN}/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*"
case " $* " in
    *" install "*) printf '%s' "${WIXL_INSTALL_YIELDS:-0.106}" > "$WIXL_VERSION_FILE" ;;
esac
exit 0
STUB
    chmod +x "${FAKE_BIN}/apt-get"

    # dpkg: --compare-versions must be real (the floor check depends on it);
    # --print-architecture is driven per-test.
    cat > "${FAKE_BIN}/dpkg" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    --print-architecture) echo "${FAKE_DPKG_ARCH:-amd64}" ;;
    --compare-versions) exec /usr/bin/dpkg "$@" ;;
    *) exec /usr/bin/dpkg "$@" ;;
esac
STUB
    chmod +x "${FAKE_BIN}/dpkg"

    export WIXL_APT_ROOT_PREFIX="${_TEST_HOME}/apt-root"
    SOURCE_LIST="${WIXL_APT_ROOT_PREFIX}/etc/apt/sources.list.d/wixl-backport.list"
    PIN_FILE="${WIXL_APT_ROOT_PREFIX}/etc/apt/preferences.d/wixl-backport"

    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"
}

teardown() {
    common_teardown
}

_run_backport() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        WIXL_APT_ROOT_PREFIX="${WIXL_APT_ROOT_PREFIX}" \
        WIXL_VERSION_FILE="${WIXL_VERSION_FILE}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            wixl_backport_if_too_old
        "
}

# ── Test 1: an old wixl is overlaid from the backport suite ───────────────

@test "wixl backport: 0.103 triggers the overlay and installs wixl + wixl-data" {
    printf '0.103' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"apt-get install -yq wixl wixl-data"* ]]
    # The suite is indexed on its own, not via a full apt-get update.
    [[ "$output" == *"sources.list.d/wixl-backport.list"* ]]
    [ -f "$SOURCE_LIST" ]
    grep -q 'resolute universe' "$SOURCE_LIST"
}

# ── Test 2: a new-enough wixl is left completely alone ────────────────────

@test "wixl backport: 0.106 is left untouched and writes no apt config" {
    printf '0.106' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"wixl 0.106 supports <Environment>"* ]]
    [[ "$output" != *"apt-get install"* ]]
    [ ! -f "$SOURCE_LIST" ]
    [ ! -f "$PIN_FILE" ]
}

# The floor itself is a boundary: 0.105 is the first release carrying the
# element, so it must NOT be overlaid.
@test "wixl backport: the floor version 0.105 is accepted, not overlaid" {
    printf '0.105' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" != *"apt-get install"* ]]
    [ ! -f "$SOURCE_LIST" ]
}

# ── Test 3/4: nothing to do when wixl is absent or the OS is not Linux ────

@test "wixl backport: absent wixl is a no-op" {
    rm -f "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" != *"apt-get install"* ]]
    [ ! -f "$SOURCE_LIST" ]
}

@test "wixl backport: non-Linux runners are a no-op even with an old wixl" {
    printf '0.103' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Windows" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" != *"apt-get install"* ]]
    [ ! -f "$SOURCE_LIST" ]
}

# ── Test 5: an overlay that silently fails to raise the version must fail ─
# The failure this guards is the quiet one: apt exits 0 having installed
# nothing usable, and the msis stage then dies much later on <Environment>.

@test "wixl backport: an install that leaves wixl too old fails loudly" {
    printf '0.103' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux" WIXL_INSTALL_YIELDS="0.103"
    [ "$status" -ne 0 ]
    [[ "$output" == *"still 0.103"* ]]
    [[ "$output" == *"<Environment>"* ]]
}

# ── Test 6: the archive host follows the dpkg architecture ────────────────

@test "wixl backport: amd64 resolves to archive.ubuntu.com" {
    printf '0.103' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux" FAKE_DPKG_ARCH="amd64"
    [ "$status" -eq 0 ]
    grep -q 'arch=amd64' "$SOURCE_LIST"
    grep -q 'http://archive.ubuntu.com/ubuntu' "$SOURCE_LIST"
}

@test "wixl backport: arm64 resolves to ports.ubuntu.com" {
    printf '0.103' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux" FAKE_DPKG_ARCH="arm64"
    [ "$status" -eq 0 ]
    grep -q 'arch=arm64' "$SOURCE_LIST"
    grep -q 'http://ports.ubuntu.com/ubuntu-ports' "$SOURCE_LIST"
}

# ── Test 7: the pin confines the suite to the three overlaid packages ─────
# Without this the added source could upgrade arbitrary packages on the runner.

@test "wixl backport: the pin holds the suite back except wixl's three packages" {
    printf '0.103' > "$WIXL_VERSION_FILE"
    _run_backport RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    [ -f "$PIN_FILE" ]
    # Catch-all at priority 1: installable if explicitly asked for, never
    # preferred, so no unrelated package is pulled forward.
    grep -q 'Pin-Priority: 1$' "$PIN_FILE"
    grep -q 'Package: wixl wixl-data libxml2-16' "$PIN_FILE"
    grep -q 'Pin-Priority: 990' "$PIN_FILE"
}
