#!/usr/bin/env bats
# install-snapcraft.bats — unit tests for the snapcraft installer in
# scripts/install/deps.sh.
#
# Stubs snap, sudo, curl, pipx, and (where needed) python3 so no network,
# snapd, or root is needed. The host machine may carry real snap/snapcraft/
# pipx binaries, so every test runs with a CONTROLLED PATH (fake-bin +
# /usr/bin:/bin only) instead of inheriting the developer's full PATH —
# /snap/bin and linuxbrew must never leak into an assertion.
#
# Covers seven behaviours:
#
#   1. snapcraft already on PATH            → skipped, exits 0
#   2. snapd alive                          → sudo snap install --classic
#   3. no snapd, pipx available             → pipx install, constrained
#   4. no snapd, no pipx                    → pip --user install, constrained
#   5. Windows                              → skipped with a warning, exits 0
#   6. uv.lock → constraints conversion     → dups + non-registry excluded
#   7. uv.lock fetch failure                → loud fail, exits ≠0

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"
    CONTROLLED_PATH="${FAKE_BIN}:/usr/bin:/bin"

    # Real interpreter, reachable from the controlled PATH regardless of
    # where the host installs it.
    REAL_PYTHON="$(command -v python3)"
    ln -s "$REAL_PYTHON" "${FAKE_BIN}/python3"

    GITHUB_PATH_FILE="${_TEST_HOME}/github_path"
    : > "$GITHUB_PATH_FILE"
    RUNNER_TEMP_DIR="${_TEST_HOME}/runner-temp"

    # ── Fixture uv.lock: one runtime pin, one project entry (non-registry),
    #    one name locked at two versions (dependency-group fork) ──────────
    FIXTURE_LOCK="${_TEST_HOME}/fixture-uv.lock"
    cat > "$FIXTURE_LOCK" <<'TOML'
version = 1

[[package]]
name = "craft-application"
version = "6.2.0"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "snapcraft"
version = "8.14.5"
source = { editable = "." }

[[package]]
name = "sphinx-design"
version = "0.6.0"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "sphinx-design"
version = "0.5.0"
source = { registry = "https://pypi.org/simple" }
TOML

    # ── Stub: curl — copy the fixture lock to the -o target ──────────────
    cat > "${FAKE_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out="" prev=""
for arg; do
    case "$prev" in -o) out="$arg" ;; esac
    prev="$arg"
done
[ -n "$out" ] && cat "$FIXTURE_LOCK" > "$out"
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: snap — DEAD by default (no snapd); tests for the snap path
    #    overwrite this with a live stub ────────────────────────────────────
    cat > "${FAKE_BIN}/snap" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "${FAKE_BIN}/snap"

    # ── Stub: sudo — record args, succeed ─────────────────────────────────
    SUDO_LOG="${_TEST_HOME}/sudo.log"
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$SUDO_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/sudo"
}

teardown() {
    common_teardown
}

# Shared invocation wrapper. Sources scripts/install/deps.sh (source-safe —
# its `main "$@"` is gated on direct execution), then calls
# install_snapcraft directly under the controlled PATH.
_run_install_snapcraft() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_ARCH="X64" \
        RUNNER_TEMP="${RUNNER_TEMP_DIR}" \
        GITHUB_PATH="${GITHUB_PATH_FILE}" \
        FIXTURE_LOCK="${FIXTURE_LOCK}" \
        SUDO_LOG="${SUDO_LOG}" \
        PATH="${CONTROLLED_PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install() { :; }
            skip_unsupported_os() { :; }
            install_snapcraft
        "
}

# ── Test 1: snapcraft already on PATH → skipped ─────────────────────────

@test "snapcraft: already on PATH is skipped" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/snapcraft"
    chmod +x "${FAKE_BIN}/snapcraft"

    _run_install_snapcraft RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already present"* ]]
    # Neither install mechanism may fire.
    [ ! -s "$SUDO_LOG" ]
}

# ── Test 2: live snapd → classic snap install ────────────────────────────

@test "snapcraft: live snapd takes the snap install path" {
    # Overwrite the dead default with a live snapd probe.
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/snap"
    chmod +x "${FAKE_BIN}/snap"

    _run_install_snapcraft RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    grep -q '^snap install snapcraft --classic$' "$SUDO_LOG"
}

# ── Test 3: no snapd, pipx available → constrained pipx install ─────────

@test "snapcraft: no snapd installs via pipx with uv.lock constraints" {
    PIPX_LOG="${_TEST_HOME}/pipx.log"
    cat > "${FAKE_BIN}/pipx" <<STUB
#!/usr/bin/env bash
echo "constraint=\${PIP_CONSTRAINT:-unset} args=\$*" >> "${PIPX_LOG}"
mkdir -p "\$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "\$HOME/.local/bin/snapcraft"
chmod +x "\$HOME/.local/bin/snapcraft"
exit 0
STUB
    chmod +x "${FAKE_BIN}/pipx"

    _run_install_snapcraft RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    grep -q 'constraint=.*/snapcraft-pip/constraints.txt' "$PIPX_LOG"
    grep -q 'git+https://github.com/canonical/snapcraft@' "$PIPX_LOG"
    # The venv must see the distro's python-apt or snapcraft dies at import.
    grep -q -- '--system-site-packages' "$PIPX_LOG"
    # ~/.local/bin must be exposed to later workflow steps.
    grep -q "^${_TEST_HOME}/.local/bin$" "$GITHUB_PATH_FILE"
    # Constraints derived from the fixture lock: runtime pin only.
    [ "$(cat "${RUNNER_TEMP_DIR}/snapcraft-pip/constraints.txt")" = "craft-application==6.2.0" ]
}

# ── Test 4: no snapd, no pipx → constrained pip --user install ──────────

@test "snapcraft: no snapd and no pipx installs via pip --user" {
    PIP_LOG="${_TEST_HOME}/pip.log"
    # Dispatching python3 stub: intercept `-m pip`, pass everything else
    # (constraints generator, sysconfig probe) to the real interpreter.
    rm "${FAKE_BIN}/python3"
    cat > "${FAKE_BIN}/python3" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ]; then
    echo "\$@" >> "${PIP_LOG}"
    if [ "\$3" = "install" ]; then
        mkdir -p "\$HOME/.local/bin"
        printf '#!/usr/bin/env bash\nexit 0\n' > "\$HOME/.local/bin/snapcraft"
        chmod +x "\$HOME/.local/bin/snapcraft"
    fi
    exit 0
fi
exec "${REAL_PYTHON}" "\$@"
STUB
    chmod +x "${FAKE_BIN}/python3"

    _run_install_snapcraft RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    grep -q -- '--constraint .*/snapcraft-pip/constraints.txt' "$PIP_LOG"
    grep -q -- '--user' "$PIP_LOG"
    grep -q 'git+https://github.com/canonical/snapcraft@' "$PIP_LOG"
    grep -q "^${_TEST_HOME}/.local/bin$" "$GITHUB_PATH_FILE"
}

# ── Test 5: Windows is skipped (snapcraft upload is Linux/macOS-only) ───

@test "snapcraft: Windows is skipped, exits 0" {
    skip_called_file="${_TEST_HOME}/skip_called"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Windows" \
        RUNNER_ARCH="X64" \
        SKIP_FLAG_FILE="${skip_called_file}" \
        PATH="${CONTROLLED_PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install() { :; }
            skip_unsupported_os() { touch \"\${SKIP_FLAG_FILE}\"; }
            install_snapcraft
        "
    [ "$status" -eq 0 ]
    [ -f "${skip_called_file}" ]
}

# ── Test 6: uv.lock → constraints excludes dups + non-registry ──────────

@test "snapcraft: lock-to-constraints drops forked and non-registry packages" {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_OS="Linux" \
        PATH="${CONTROLLED_PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            snapcraft_lock_to_constraints '${FIXTURE_LOCK}'
        "
    [ "$status" -eq 0 ]
    [ "$output" = "craft-application==6.2.0" ]
}

# ── Test 7: uv.lock fetch failure → loud fail ───────────────────────────

@test "snapcraft: uv.lock fetch failure fails loudly" {
    cat > "${FAKE_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
    chmod +x "${FAKE_BIN}/curl"

    _run_install_snapcraft RUNNER_OS="Linux"
    [ "$status" -ne 0 ]
    [[ "$output" == *"uv.lock"* ]]
}
