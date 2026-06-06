#!/usr/bin/env bats
# install-rcodesign.bats — unit tests for the rcodesign installer in
# scripts/install/deps.sh AND the notarize.macos: auto-detect wiring in
# scripts/install/auto-detect-deps.sh.
#
# rcodesign (the apple-codesign project) drives anodizer's cross-platform
# `notarize.macos:` path (`rcodesign sign` / `rcodesign notary-submit`). It
# runs on Linux, macOS, and Windows; the sibling `notarize.macos_native:`
# path uses codesign + xcrun (present on macOS runners) and needs no install.
# Upstream ships no checksums file, so the installer pins shas with an
# override-requires-its-own-sha escape hatch — same shape as the alejandra /
# linuxdeploy pins. Windows has no clean release tarball, so it falls back to
# `cargo install apple-codesign`.
#
# Stubs curl, sha256sum, tar, chmod, cargo so no network or root is needed.
# Covers:
#
#   1. default version on Linux x86_64 → tarball fetched + sha-checked +
#      extracted, binary on PATH, exits 0
#   2. default version on macOS arm64 → fetched + extracted, exits 0
#   3. RCODESIGN_VERSION override missing its sha → loud fail, exits ≠0
#   4. RCODESIGN_VERSION override WITH a sha → install exits 0
#   5. Windows → cargo install fallback fires, exits 0
#   6. Windows without cargo → loud fail (Rust required), exits ≠0
#   7. auto-detect: notarize.macos: config emits the rcodesign dep
#   8. auto-detect: notarize.macos_native: config does NOT emit rcodesign

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    export GITHUB_ENV="${_TEST_HOME}/github_env"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_PATH"
    : > "$GITHUB_ENV"
    : > "$GITHUB_OUTPUT"

    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"

    # ── Stub: curl — write a deterministic placeholder to the -o target ────
    cat > "${FAKE_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
for arg; do
    case "$prev" in -o) out="$arg" ;; esac
    prev="$arg"
done
[ -n "$out" ] && printf 'rcodesign-tarball' > "$out"
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: sha256sum -c reads "HASH  FILE" from stdin and returns 0 ─────
    cat > "${FAKE_BIN}/sha256sum" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-c"* ]]; then
    read -r line
    echo "${line##* }": OK
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/sha256sum"

    # ── Stub: tar — materialise the requested rcodesign binary at the
    #    --strip-components=1 destination so chmod + the PATH assert pass. ──
    cat > "${FAKE_BIN}/tar" <<'STUB'
#!/usr/bin/env bash
dest="."
prev=""
for arg; do
    case "$prev" in -C) dest="$arg" ;; esac
    prev="$arg"
done
printf 'fake-rcodesign-binary' > "${dest}/rcodesign"
exit 0
STUB
    chmod +x "${FAKE_BIN}/tar"

    # ── Stub: cargo — record the install invocation, succeed. ─────────────
    cat > "${FAKE_BIN}/cargo" <<'STUB'
#!/usr/bin/env bash
echo "cargo $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/cargo"
}

teardown() {
    common_teardown
}

# Source deps.sh (source-safe — `main "$@"` is gated on direct execution) and
# call install_rcodesign directly. skip_unsupported_os is stubbed so any
# skip-arm can be exercised without its real annotation side-effects.
_run_install_rcodesign() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        GITHUB_ENV="${GITHUB_ENV}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_rcodesign
        "
}

# Same as above but make cargo undiscoverable so the Windows no-Rust arm fails.
# Shadowing the `command` builtin to report cargo as absent is deterministic —
# unlike pruning PATH, it does not depend on whether a host coreutils dir (e.g.
# /usr/bin) happens to also carry a cargo symlink (GitHub runners preinstall
# Rust there, so a PATH-based prune would silently re-find it).
_run_install_rcodesign_no_cargo() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            # Report cargo as not-installed; pass every other lookup through.
            command() {
                if [ \"\$1\" = '-v' ] && [ \"\$2\" = 'cargo' ]; then return 1; fi
                builtin command \"\$@\"
            }
            install_rcodesign
        "
}

# ── Test 1: default version on Linux x86_64 → installs, exits 0 ────────────

@test "rcodesign: default version installs on Linux x86_64" {
    _run_install_rcodesign RUNNER_OS="Linux" RUNNER_ARCH="X64"
    [ "$status" -eq 0 ]
    [ -x "${RUNNER_TEMP}/rcodesign/rcodesign" ]
    grep -q "${RUNNER_TEMP}/rcodesign" "$GITHUB_PATH"
}

# ── Test 2: default version on macOS arm64 → installs, exits 0 ─────────────

@test "rcodesign: default version installs on macOS arm64" {
    _run_install_rcodesign RUNNER_OS="macOS" RUNNER_ARCH="ARM64"
    [ "$status" -eq 0 ]
    [ -x "${RUNNER_TEMP}/rcodesign/rcodesign" ]
}

# ── Test 3: version override missing its sha → loud failure ────────────────

@test "rcodesign: RCODESIGN_VERSION override without sha fails loudly" {
    _run_install_rcodesign RUNNER_OS="Linux" RUNNER_ARCH="X64" RCODESIGN_VERSION="9.9.9"
    [ "$status" -ne 0 ]
    [[ "$output" == *"RCODESIGN_SHA256"* ]]
    [[ "$output" != *"installed"* ]]
}

# ── Test 4: version override WITH a sha → install proceeds ─────────────────

@test "rcodesign: RCODESIGN_VERSION + sha installs" {
    _run_install_rcodesign \
        RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        RCODESIGN_VERSION="9.9.9" \
        RCODESIGN_SHA256="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    [ "$status" -eq 0 ]
}

# ── Test 5: Windows → cargo install fallback ──────────────────────────────

@test "rcodesign: Windows uses cargo install fallback" {
    _run_install_rcodesign RUNNER_OS="Windows" RUNNER_ARCH="X64"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cargo install apple-codesign"* ]]
}

# ── Test 6: Windows without cargo → loud failure (Rust required) ───────────

@test "rcodesign: Windows without cargo fails (Rust required)" {
    _run_install_rcodesign_no_cargo RUNNER_OS="Windows" RUNNER_ARCH="X64"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires Rust"* ]]
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

@test "auto-detect: notarize.macos: config emits the rcodesign dep" {
    _run_auto_detect $'notarize:\n  macos:\n    - sign:\n        certificate: cert.p12' "Linux"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*rcodesign' "$GITHUB_OUTPUT"
}

@test "auto-detect: notarize.macos_native: config does NOT emit rcodesign" {
    _run_auto_detect $'notarize:\n  macos_native:\n    - use: dmg\n      sign:\n        identity: Developer ID' "macOS"
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'rcodesign' "$GITHUB_OUTPUT"
}
