#!/usr/bin/env bats
# install-flatpak.bats — unit tests for the flatpak installer in
# scripts/install/deps.sh AND the flatpaks: auto-detect wiring in
# scripts/install/auto-detect-deps.sh.
#
# flatpak drives anodizer's `flatpaks:` stage, which shells out to
# `flatpak-builder ... build <manifest>` then `flatpak build-bundle`. The
# installer therefore lands BOTH the `flatpak` CLI and `flatpak-builder`,
# adds the flathub remote, and pre-stages the org.freedesktop.Platform +
# Sdk runtimes the manifest pins (default branch 24.08, override via
# FLATPAK_RUNTIME_VERSION). Flatpak is Linux-only.
#
# Stubs sudo (which fronts both `apt-get install` and `flatpak`) so no root,
# apt, or network is needed. Covers:
#
#   1. default runtime on Linux → flathub remote added + Platform//24.08 +
#      Sdk//24.08 installed, exits 0
#   2. FLATPAK_RUNTIME_VERSION override → that branch pre-staged, exits 0
#   3. macOS / Windows → skipped (flatpak is Linux-only), exits 0
#   4. auto-detect: `flatpaks:` config emits the flatpak dep

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

    # ── Stub: sudo — record the command it was asked to run, succeed ──────
    # apt_flush calls `sudo apt-get install ...`; the runtime stage calls
    # `sudo flatpak remote-add` / `sudo flatpak install`. Recording every
    # `sudo` argv lets the tests assert the flathub remote + runtimes.
    SUDO_LOG="${_TEST_HOME}/sudo.log"
    export SUDO_LOG
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SUDO_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/sudo"
}

teardown() {
    common_teardown
}

# Source scripts/install/deps.sh (source-safe) so every helper is in scope,
# then call install_flatpak directly. skip_unsupported_os is stubbed so the
# macOS/Windows arms can be exercised without their real side-effects.
_run_install_flatpak() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        GITHUB_ENV="${GITHUB_ENV}" \
        SUDO_LOG="${SUDO_LOG}" \
        NO_COLOR=1 \
        RUNNER_ARCH="X64" \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            skip_unsupported_os() { echo \"SKIPPED: \$1\"; }
            install_flatpak
            apt_flush
        "
}

# ── Test 1: default runtime on Linux → remote + runtimes staged, exits 0 ───

@test "flatpak: default runtime stages flathub remote + Platform//24.08 + Sdk//24.08 on Linux" {
    _run_install_flatpak RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    # apt batch installed both the CLI and the builder.
    grep -q 'apt-get install .*flatpak' "$SUDO_LOG"
    grep -q 'flatpak-builder' "$SUDO_LOG"
    # flathub remote added idempotently.
    grep -q 'flatpak remote-add --if-not-exists flathub' "$SUDO_LOG"
    # Both runtimes pinned to the default 24.08 branch.
    grep -q 'org.freedesktop.Platform//24.08' "$SUDO_LOG"
    grep -q 'org.freedesktop.Sdk//24.08' "$SUDO_LOG"
}

# ── Test 2: FLATPAK_RUNTIME_VERSION override → that branch is pre-staged ────

@test "flatpak: FLATPAK_RUNTIME_VERSION override pre-stages that branch" {
    _run_install_flatpak RUNNER_OS="Linux" FLATPAK_RUNTIME_VERSION="23.08"
    [ "$status" -eq 0 ]
    grep -q 'org.freedesktop.Platform//23.08' "$SUDO_LOG"
    grep -q 'org.freedesktop.Sdk//23.08' "$SUDO_LOG"
    ! grep -q '//24.08' "$SUDO_LOG"
}

# ── Test 3: non-Linux runners are skipped (flatpak is Linux-only) ──────────

@test "flatpak: macOS is skipped, exits 0" {
    _run_install_flatpak RUNNER_OS="macOS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}

@test "flatpak: Windows is skipped, exits 0" {
    _run_install_flatpak RUNNER_OS="Windows"
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

@test "auto-detect: flatpaks: config emits the flatpak dep" {
    _run_auto_detect $'flatpaks:\n  - app_id: org.example.App\n    runtime_version: "24.08"' "Linux"
    [ "$status" -eq 0 ]
    grep -q '^deps=.*flatpak' "$GITHUB_OUTPUT"
}
