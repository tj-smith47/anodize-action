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
# Covers eleven behaviours:
#
#   1.  working snapcraft already on PATH    → skipped, exits 0
#   2.  BROKEN snapcraft already on PATH     → falls through to reinstall
#   3.  snapd alive                          → sudo snap install --classic
#   4.  no snapd, pipx available             → pipx install, constrained
#   5.  no snapd, no pipx                    → pip --user install, constrained
#   6.  Windows                              → skipped with a warning, exits 0
#   7.  uv.lock → constraints conversion     → dups + non-registry excluded
#   8.  uv.lock fetch failure                → loud fail, exits ≠0
#   9.  unsquashfs absent + apt-get present  → squashfs-tools added to apt batch
#   10. unsquashfs absent + no apt-get       → loud fail naming squashfs-tools
#   11. unsquashfs still absent after apt    → post-install assert fails loudly

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

    # ── Stub: apt-get — the bootstrap's `command -v apt-get` gate must pass
    #    on any host (macOS dev boxes ship no apt-get); sudo is stubbed so
    #    the real package manager is never reached either way ─────────────
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/apt-get"
    chmod +x "${FAKE_BIN}/apt-get"
}

teardown() {
    common_teardown
}

# The constraints generator needs stdlib tomllib; hosts on python < 3.11
# cannot exercise the pip-fallback paths.
_require_tomllib() {
    "$REAL_PYTHON" -c 'import tomllib' 2>/dev/null \
        || skip "host python3 lacks tomllib (< 3.11)"
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

# ── Test 1: working snapcraft already on PATH → skipped ─────────────────

@test "snapcraft: already on PATH is skipped" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/snapcraft"
    chmod +x "${FAKE_BIN}/snapcraft"

    # The "already present" skip detail is verbose-only; run under verbose so it
    # surfaces for the assertion.
    _run_install_snapcraft RUNNER_OS="Linux" ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"already present"* ]]
    # Neither install mechanism may fire.
    [ ! -s "$SUDO_LOG" ]
}

# ── Test 2: BROKEN snapcraft on PATH → falls through to reinstall ───────

@test "snapcraft: broken preinstall falls through to reinstall" {
    _require_tomllib
    # On PATH but dying at startup (e.g. a venv missing python-apt) — the
    # early-skip probe runs the CLI, so this must NOT short-circuit.
    printf '#!/usr/bin/env bash\nexit 1\n' > "${FAKE_BIN}/snapcraft"
    chmod +x "${FAKE_BIN}/snapcraft"

    PIPX_LOG="${_TEST_HOME}/pipx.log"
    cat > "${FAKE_BIN}/pipx" <<STUB
#!/usr/bin/env bash
echo "args=\$*" >> "${PIPX_LOG}"
mkdir -p "\$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "\$HOME/.local/bin/snapcraft"
chmod +x "\$HOME/.local/bin/snapcraft"
exit 0
STUB
    chmod +x "${FAKE_BIN}/pipx"

    _run_install_snapcraft RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already present"* ]]
    grep -q 'git+https://github.com/canonical/snapcraft@' "$PIPX_LOG"
}

# ── Test 3: live snapd → classic snap install ────────────────────────────

@test "snapcraft: live snapd takes the snap install path" {
    # Overwrite the dead default with a live snapd probe.
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/snap"
    chmod +x "${FAKE_BIN}/snap"

    _run_install_snapcraft RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    grep -q '^snap install snapcraft --classic$' "$SUDO_LOG"
}

# ── Test 4: no snapd, pipx available → constrained pipx install ─────────

@test "snapcraft: no snapd installs via pipx with uv.lock constraints" {
    _require_tomllib
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

# ── Test 5: no snapd, no pipx → constrained pip --user install ──────────

@test "snapcraft: no snapd and no pipx installs via pip --user" {
    _require_tomllib
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

# ── Test 6: Windows is skipped (snapcraft upload is Linux/macOS-only) ───

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

# ── Test 7: uv.lock → constraints excludes dups + non-registry ──────────

@test "snapcraft: lock-to-constraints drops forked and non-registry packages" {
    _require_tomllib
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

# ── Test 8: uv.lock fetch failure → loud fail ───────────────────────────

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

# ── Test 9: unsquashfs missing + apt-get available → squashfs-tools queued ──
#
# Overrides _squashfs_tools_available to return 1 (simulates a runner image
# without squashfs-tools) so apt_needs includes squashfs-tools and the apt
# batch install runs. apt-get stub records args; the apt-get "install" call
# also registers _squashfs_tools_available as returning 0 so the
# end-of-install assert passes (the test uses a per-call counter approach via
# a flag file, mirroring what the real apt install would achieve on the host).

@test "snapcraft: missing unsquashfs triggers apt install of squashfs-tools" {
    _require_tomllib

    # pipx stub so the install reaches the post-install assert.
    PIPX_LOG="${_TEST_HOME}/pipx.log"
    cat > "${FAKE_BIN}/pipx" <<STUB
#!/usr/bin/env bash
echo "args=\$*" >> "${PIPX_LOG}"
mkdir -p "\$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "\$HOME/.local/bin/snapcraft"
chmod +x "\$HOME/.local/bin/snapcraft"
exit 0
STUB
    chmod +x "${FAKE_BIN}/pipx"

    # _squashfs_tools_available always returns 1 so apt_needs includes
    # squashfs-tools and the post-install assert also fires (exit != 0);
    # we verify the sudo apt-get call carried squashfs-tools.
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_ARCH="X64" \
        RUNNER_OS="Linux" \
        RUNNER_TEMP="${RUNNER_TEMP_DIR}" \
        GITHUB_PATH="${GITHUB_PATH_FILE}" \
        FIXTURE_LOCK="${FIXTURE_LOCK}" \
        SUDO_LOG="${SUDO_LOG}" \
        PATH="${CONTROLLED_PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install() { :; }
            skip_unsupported_os() { :; }
            _squashfs_tools_available() { return 1; }
            install_snapcraft
        "
    # The post-install assert fires too (unsquashfs still absent), so we
    # expect a non-zero exit; what we are verifying is that squashfs-tools
    # was passed to apt-get before that point.
    grep -q 'squashfs-tools' "$SUDO_LOG"
}

# ── Test 10: unsquashfs missing + no apt-get → loud fail naming squashfs-tools

@test "snapcraft: missing unsquashfs and no apt-get fails with squashfs-tools message" {
    _require_tomllib
    # Remove apt-get stub so command -v apt-get fails.
    rm -f "${FAKE_BIN}/apt-get"

    # The "installing squashfs-tools … via apt for the pip fallback" detail is a
    # verbose-only line; run under verbose so the squashfs-tools string surfaces.
    # (When command -v apt-get genuinely misses, the gha_fail message names
    # squashfs-tools unconditionally; under verbose the apt-batch detail also
    # carries it — either path satisfies the assertion.)
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_ARCH="X64" \
        RUNNER_OS="Linux" \
        RUNNER_TEMP="${RUNNER_TEMP_DIR}" \
        GITHUB_PATH="${GITHUB_PATH_FILE}" \
        FIXTURE_LOCK="${FIXTURE_LOCK}" \
        SUDO_LOG="${SUDO_LOG}" \
        PATH="${CONTROLLED_PATH}" \
        ANODIZER_VERBOSE=1 \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install() { :; }
            skip_unsupported_os() { :; }
            _squashfs_tools_available() { return 1; }
            install_snapcraft
        "
    [ "$status" -ne 0 ]
    [[ "$output" == *"squashfs-tools"* ]]
}

# ── Test 11: post-install assert fires independently of apt_needs path ───────
#
# _squashfs_tools_available returns true on the first call (so apt_needs is
# empty and no apt install runs), then false on the second call (simulating
# a broken install). The post-install assert must fire and name unsquashfs.

@test "snapcraft: post-install assert fails when unsquashfs absent after install" {
    _require_tomllib
    CALL_COUNT_FILE="${_TEST_HOME}/squash_call_count"
    printf '0' > "$CALL_COUNT_FILE"

    PIPX_LOG="${_TEST_HOME}/pipx.log"
    cat > "${FAKE_BIN}/pipx" <<STUB
#!/usr/bin/env bash
echo "args=\$*" >> "${PIPX_LOG}"
mkdir -p "\$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "\$HOME/.local/bin/snapcraft"
chmod +x "\$HOME/.local/bin/snapcraft"
exit 0
STUB
    chmod +x "${FAKE_BIN}/pipx"

    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RUNNER_ARCH="X64" \
        RUNNER_OS="Linux" \
        RUNNER_TEMP="${RUNNER_TEMP_DIR}" \
        GITHUB_PATH="${GITHUB_PATH_FILE}" \
        FIXTURE_LOCK="${FIXTURE_LOCK}" \
        SUDO_LOG="${SUDO_LOG}" \
        CALL_COUNT_FILE="${CALL_COUNT_FILE}" \
        PATH="${CONTROLLED_PATH}" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            brew_install() { :; }
            skip_unsupported_os() { :; }
            # First call (apt_needs check): returns 0 so no apt install runs.
            # Second call (post-install assert): returns 1 to trigger the fail.
            _squashfs_tools_available() {
                local n
                n=\$(cat \"\${CALL_COUNT_FILE}\")
                printf '%d' \$(( n + 1 )) > \"\${CALL_COUNT_FILE}\"
                [ \"\$n\" -eq 0 ]
            }
            install_snapcraft
        "
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsquashfs"* ]]
}
