#!/usr/bin/env bats
# install-cosign-verify.bats — unit tests for cosign keyless-signature
# verification behaviour in scripts/install-deps.sh.
#
# These tests stub out curl, sha256sum, sudo, install, and cosign so no
# network or elevated privileges are required.  They focus on the three
# verification outcomes:
#
#   1. cosign verify-blob succeeds          → install proceeds, exits 0
#   2. cosign verify-blob fails             → loud error + exit non-zero
#   3. ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1 → SHA-256-only warning, exits 0
#   4. correct keyless identity/issuer flags are passed to cosign

load test_helper

# Shared wrapper — sources lib-colors.sh and install_cosign() in a clean
# sub-shell with the fake-bin PATH.  Accepts optional extra env exports as
# arguments.  Usage: _cosign_subshell [extra env assignments...]
_INSTALL_COSIGN_SRC=""

setup() {
    common_setup

    # Fake bin dir — all stubs live here and are first on PATH.
    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    # ── Stub: curl ────────────────────────────────────────────────────────────
    cat > "${FAKE_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
# Capture -o <file> and write deterministic placeholder content.
out=""
for arg; do
    case "$prev" in -o) out="$arg" ;; esac
    prev="$arg"
done
if [ -n "$out" ]; then
    case "$out" in
        *cosign_checksums.txt)
            # Hash of "fakebinary" so sha256sum -c passes.
            printf '%s  cosign-linux-amd64\n' \
                "$(printf 'fakebinary' | sha256sum | awk '{print $1}')" > "$out"
            ;;
        *) printf 'fakebinary' > "$out" ;;
    esac
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: sha256sum ───────────────────────────────────────────────────────
    # When called with -c it reads "HASH  FILE" from stdin and returns 0.
    cat > "${FAKE_BIN}/sha256sum" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-c"* ]]; then
    read -r line   # consume stdin
    echo "${line##* }": OK
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/sha256sum"

    # ── Stub: sudo ────────────────────────────────────────────────────────────
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # ── Stub: install (coreutils) ─────────────────────────────────────────────
    # `sudo install /tmp/cosign /usr/local/bin/cosign` — redirect to fake dir.
    FAKE_USR="${_TEST_HOME}/usr-local-bin"
    mkdir -p "$FAKE_USR"
    cat > "${FAKE_BIN}/install" <<STUB
#!/usr/bin/env bash
# Last two non-flag args are src and dst.
args=()
for a; do [[ "\$a" != -* ]] && args+=("\$a"); done
src="\${args[-2]}"
dst="${FAKE_USR}/\$(basename "\${args[-1]}")"
cp "\$src" "\$dst" 2>/dev/null || true
exit 0
STUB
    chmod +x "${FAKE_BIN}/install"

    # ── Pre-extract install_cosign() source ───────────────────────────────────
    # We need just the function body so we can inject it into sub-shells
    # without sourcing the full install-deps.sh (which needs RUNNER_OS, DEPS,
    # etc. and starts executing immediately on source).
    _INSTALL_COSIGN_SRC="$(awk '/^install_cosign\(\)/{found=1} found{print} found && /^}$/{exit}' \
        "${REPO_ROOT}/scripts/install-deps.sh")"
}

teardown() {
    common_teardown
}

# ── Test 1: verify-blob succeeds → exits 0 ───────────────────────────────────

@test "cosign: verify-blob success → install exits 0" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Linux" \
        PATH="${FAKE_BIN}:${PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/lib-colors.sh'
            brew_install()  { :; }
            choco_install() { :; }
            ${_INSTALL_COSIGN_SRC}
            install_cosign
        "
    [ "$status" -eq 0 ]
}

# ── Test 2: verify-blob fails → loud error + non-zero exit ───────────────────

@test "cosign: verify-blob failure → exits non-zero with error message" {
    cat > "${FAKE_BIN}/cosign" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"verify-blob"* ]]; then
    echo "Error: exactly one of --key/--cert/--sk required" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Linux" \
        PATH="${FAKE_BIN}:${PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/lib-colors.sh'
            brew_install()  { :; }
            choco_install() { :; }
            ${_INSTALL_COSIGN_SRC}
            install_cosign
        "
    # Must exit non-zero.
    [ "$status" -ne 0 ]
    # Must emit the loud-fail message from install-deps.sh verbatim.  The
    # bytes are stable in both NO_COLOR=1 (current test) and ANSI-on modes
    # because anodizer::err inserts colour escapes around the leading glyph,
    # not inside the message text.
    [[ "$output" == *"cosign keyless signature verification FAILED"* ]]
    # Must NOT treat the SHA256 hash-check as a substitute for signature verification.
    [[ "$output" != *"SHA256 already verified"* ]]
}

# ── Test 3: ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1 → SHA-256-only, exits 0 ─────

@test "cosign: SKIP_COSIGN_VERIFY=1 → warns + exits 0, verify-blob not called" {
    verify_called_file="${_TEST_HOME}/verify_called"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"verify-blob"* ]]; then
    touch "${verify_called_file}"
    echo "Error: should not be called" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Linux" \
        ANODIZER_ACTION_SKIP_COSIGN_VERIFY=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/lib-colors.sh'
            brew_install()  { :; }
            choco_install() { :; }
            ${_INSTALL_COSIGN_SRC}
            install_cosign
        "
    # Must succeed.
    [ "$status" -eq 0 ]
    # verify-blob must NOT have been invoked.
    [ ! -f "${verify_called_file}" ]
    # Output must mention that verification was skipped.
    [[ "$output" == *"skipped"* ]] || [[ "$output" == *"skip"* ]] || [[ "$output" == *"SHA256-only"* ]]
}

# ── Test 4: correct keyless flags passed to cosign ────────────────────────────

@test "cosign: verify-blob uses correct GCP service-account identity and Google OIDC issuer" {
    invocation_file="${_TEST_HOME}/cosign_args"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
echo "\$@" > "${invocation_file}"
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Linux" \
        PATH="${FAKE_BIN}:${PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/lib-colors.sh'
            brew_install()  { :; }
            choco_install() { :; }
            ${_INSTALL_COSIGN_SRC}
            install_cosign
        "
    [ "$status" -eq 0 ]

    invocation="$(cat "${invocation_file}")"
    # Must use the correct GCP service-account identity.
    [[ "$invocation" == *"keyless@projectsigstore.iam.gserviceaccount.com"* ]]
    # Must use Google OIDC issuer.
    [[ "$invocation" == *"https://accounts.google.com"* ]]
    # Must NOT use the wrong GitHub Actions OIDC issuer.
    [[ "$invocation" != *"token.actions.githubusercontent.com"* ]]
}

# ── Test 5: COSIGN_KEY in caller env must be stripped from verify-blob ───────
#
# Regression guard: when the caller (anodizer's release workflow) sets
# COSIGN_KEY at step level for the downstream sign stage, cosign's PEM
# verify-blob would otherwise see both KeyRef (from env) and CertRef
# (from --certificate flag) and bail with PubKeyParseError. The
# `env -u COSIGN_KEY` prefix in install-deps.sh must strip the key
# before cosign sees it.

@test "cosign: COSIGN_KEY in caller env is stripped before verify-blob runs" {
    env_capture_file="${_TEST_HOME}/cosign_env"
    cat > "${FAKE_BIN}/cosign" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"verify-blob"* ]]; then
    env > "${env_capture_file}"
fi
exit 0
STUB
    chmod +x "${FAKE_BIN}/cosign"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Linux" \
        COSIGN_KEY="fake-key-reference" \
        COSIGN_PUB_KEY="fake-pub-key" \
        PATH="${FAKE_BIN}:${PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/lib-colors.sh'
            brew_install()  { :; }
            choco_install() { :; }
            ${_INSTALL_COSIGN_SRC}
            install_cosign
        "
    [ "$status" -eq 0 ]

    # verify-blob ran (captured env file exists)
    [ -f "${env_capture_file}" ]
    # COSIGN_KEY / COSIGN_PUB_KEY must NOT be present in the captured env
    ! grep -q '^COSIGN_KEY=' "${env_capture_file}"
    ! grep -q '^COSIGN_PUB_KEY=' "${env_capture_file}"
}
