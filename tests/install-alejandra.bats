#!/usr/bin/env bats
# install-alejandra.bats — unit tests for the alejandra installer in
# scripts/install/deps.sh.
#
# Stubs curl, sha256sum, sudo, and install so no network or root is needed.
# Covers four behaviours:
#
#   1. default version on Linux x86_64    → sha256 verified, install exits 0
#   2. ALEJANDRA_VERSION override without ALEJANDRA_SHA256 → loud fail, exits ≠0
#   3. ALEJANDRA_VERSION override WITH    ALEJANDRA_SHA256 → install exits 0
#   4. Windows                            → skipped with a warning, exits 0

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    # ── Stub: curl — write deterministic placeholder content ─────────────
    cat > "${FAKE_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
for arg; do
    case "$prev" in -o) out="$arg" ;; esac
    prev="$arg"
done
[ -n "$out" ] && printf 'alejandra-bin' > "$out"
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: sha256sum -c reads "HASH  FILE" from stdin and returns 0 ───
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

    # ── Stub: sudo / install ─────────────────────────────────────────────
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"

    FAKE_USR="${_TEST_HOME}/usr-local-bin"
    mkdir -p "$FAKE_USR"
    cat > "${FAKE_BIN}/install" <<STUB
#!/usr/bin/env bash
args=()
for a; do [[ "\$a" != -* ]] && args+=("\$a"); done
src="\${args[-2]}"
dst="${FAKE_USR}/\$(basename "\${args[-1]}")"
cp "\$src" "\$dst" 2>/dev/null || true
exit 0
STUB
    chmod +x "${FAKE_BIN}/install"
}

teardown() {
    common_teardown
}

# Shared invocation wrapper. Sources scripts/install/deps.sh (source-safe
# — its `main "$@"` is gated on direct execution) so every helper is in
# scope, then calls `install_alejandra` directly. brew_install +
# skip_unsupported_os are stubbed so Linux + Windows arms can be exercised
# without their real side-effects.
_run_install_alejandra() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_ARCH="X64" \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install() { :; }
            skip_unsupported_os() { :; }
            install_alejandra
        "
}

# ── Test 1: default version on Linux x86_64 → install exits 0 ───────────

@test "alejandra: default version installs on Linux x86_64" {
    _run_install_alejandra RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
}

# ── Test 2: version override without SHA → loud failure ─────────────────

@test "alejandra: ALEJANDRA_VERSION override without ALEJANDRA_SHA256 fails loudly" {
    _run_install_alejandra RUNNER_OS="Linux" ALEJANDRA_VERSION="9.9.9"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ALEJANDRA_SHA256"* ]]
    # Must NOT silently fall back to the pinned default sha.
    [[ "$output" != *"installed"* ]]
}

# ── Test 3: version override WITH SHA → install proceeds ────────────────

@test "alejandra: ALEJANDRA_VERSION + ALEJANDRA_SHA256 installs" {
    _run_install_alejandra \
        RUNNER_OS="Linux" \
        ALEJANDRA_VERSION="9.9.9" \
        ALEJANDRA_SHA256="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    [ "$status" -eq 0 ]
}

# ── Test 4: Windows is skipped (alejandra is Linux/macOS-only) ──────────

@test "alejandra: Windows is skipped, exits 0" {
    skip_called_file="${_TEST_HOME}/skip_called"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Windows" \
        RUNNER_ARCH="X64" \
        SKIP_FLAG_FILE="${skip_called_file}" \
        PATH="${FAKE_BIN}:${PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install() { :; }
            skip_unsupported_os() { touch \"\${SKIP_FLAG_FILE}\"; }
            install_alejandra
        "
    [ "$status" -eq 0 ]
    [ -f "${skip_called_file}" ]
}
